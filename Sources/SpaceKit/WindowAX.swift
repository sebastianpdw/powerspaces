// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import ApplicationServices
import CoreGraphics
import Foundation

/// Cap how long *any* synchronous Accessibility call in this process may block, by
/// setting the global AX messaging timeout once at startup.
///
/// Why this matters: an AX read (window list, title, frame, …) is an IPC round-trip
/// served by the *target* app's main run loop. If that app is itself wedged, an
/// un-capped call blocks **our** main thread — the dock refresh reads window titles
/// there — until the system default timeout (many seconds) finally fires. One stuck
/// app then presents as Powerspaces freezing: the dock stops updating and the menu
/// won't open. A tight cap turns that into "this one app's title is briefly missing"
/// and the next refresh recovers.
///
/// Passing the system-wide element sets the timeout *process-wide*: every accessibility
/// object uses it unless it sets its own (per the `AXUIElementSetMessagingTimeout`
/// contract — setting it on an individual element would cover only that element, not
/// the window elements our title reads use). Call once, before the first AX call.
public func capAccessibilityMessagingTimeout(_ seconds: Float = 1.0) {
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
}

/// Accessibility-API helpers for acting on another app's windows. Everything
/// here needs Accessibility permission; callers must check `isTrusted` first and
/// degrade gracefully (e.g. to a warning) when it's false.
enum WindowAX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// All AX window elements for an app (empty when AX can't answer). Fetching
    /// this is the costly part — one IPC round-trip to the app — so callers that
    /// need several of an app's windows should fetch once and reuse (see
    /// `WindowTitleReader`).
    static func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return [] }
        return windows
    }

    /// The element matching `windowID` within an already-fetched window list.
    static func firstWindow(windowID: CGWindowID, in windows: [AXUIElement]) -> AXUIElement? {
        for window in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(window, &wid) == .success, wid == windowID { return window }
        }
        return nil
    }

    /// The window-server id backing an AX window element, or nil when AX can't
    /// answer. Lets a caller go from an element (e.g. the main window) back to the
    /// `CGWindowID` the dock keys its items by.
    static func cgWindowID(of window: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(window, &wid) == .success ? wid : nil
    }

    /// The AXUIElement for a specific on-screen window (matched by CGWindowID).
    static func axWindow(windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        firstWindow(windowID: windowID, in: windows(of: pid))
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, CFGetTypeID(posValue) == AXValueGetTypeID(),
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    static func setFrame(_ frame: CGRect, of window: AXUIElement) {
        var origin = frame.origin
        var size = frame.size
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    static func minimize(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    /// De-miniaturize a window (pull it back out of the Dock). Harmless if the
    /// window isn't minimized.
    static func unminimize(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    /// Whether a window is currently minimized (sitting in the Dock).
    static func isMinimized(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    /// Whether this window is its app's main window (the primary front window).
    /// Combined with "is the app frontmost", this tells the per-window dock click
    /// whether a click should minimize *this* window or instead raise it from
    /// behind. Defaults to false (→ raise) when AX can't answer.
    static func isMain(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMainAttribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    /// A window's AX role (e.g. "AXWindow", "AXSheet"), or nil when AX can't answer.
    static func role(of window: AXUIElement) -> String? {
        stringAttribute(window, kAXRoleAttribute as CFString)
    }

    /// A window's AX subrole (e.g. "AXStandardWindow", "AXDialog"), or nil when AX
    /// can't answer. The key signal for telling a real window from a dialog.
    static func subrole(of window: AXUIElement) -> String? {
        stringAttribute(window, kAXSubroleAttribute as CFString)
    }

    /// Whether a window is application-modal (blocks the rest of the app until
    /// dismissed). Defaults to false when AX can't answer.
    static func isModal(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXModalAttribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    /// Whether this element is a real, standalone application window — not a sheet,
    /// dialog, modal panel, or a non-window accessory (e.g. a search-suggestions
    /// list) that happens to back its own window-server window. Delegates the
    /// decision to the pure `WindowFilter.isStandaloneWindow` so the rule stays
    /// unit-testable.
    static func isStandaloneWindow(_ window: AXUIElement) -> Bool {
        WindowFilter.isStandaloneWindow(role: role(of: window), subrole: subrole(of: window),
                                        isModal: isModal(window))
    }

    /// Whether this window is itself a blocking dialog (a modal alert panel). See
    /// `WindowFilter.isBlockingDialog`.
    static func isBlockingDialog(_ window: AXUIElement) -> Bool {
        WindowFilter.isBlockingDialog(role: role(of: window), subrole: subrole(of: window),
                                      isModal: isModal(window))
    }

    /// Whether app `pid` is currently presenting a blocking dialog — the signal that
    /// it's asking the user something (overwhelmingly "Save changes before
    /// quitting?") and so shouldn't be force-quit out from under them. Two shapes:
    ///   - a **standalone modal alert** is its own top-level window, caught directly;
    ///   - a **sheet** (the slide-down "save?" prompt) is *not* a top-level window —
    ///     it's a child of the document window — so we also scan each window's
    ///     children for an `AXSheet`.
    /// Needs Accessibility; with AX untrusted there are no windows to read and this
    /// returns false (the caller falls back to its own conservative rule).
    static func isShowingBlockingDialog(pid: pid_t) -> Bool {
        for window in windows(of: pid) {
            if isBlockingDialog(window) { return true }
            if children(of: window).contains(where: { role(of: $0) == "AXSheet" }) { return true }
        }
        return false
    }

    /// An element's immediate AX children (empty when AX can't answer).
    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let children = ref as? [AXUIElement] else { return [] }
        return children
    }

    private static func stringAttribute(_ window: AXUIElement, _ name: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, name, &ref) == .success,
              let value = ref as? String, !value.isEmpty else { return nil }
        return value
    }

    /// A window's title-bar text (e.g. a browser's page title), via AX. nil/empty
    /// when the app doesn't expose one.
    static func title(of window: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &ref) == .success,
              let value = ref as? String, !value.isEmpty else { return nil }
        return value
    }
    /// Close a window by pressing its close button. Returns false if there's no
    /// close button (so the caller can warn instead of assuming success).
    @discardableResult
    static func close(_ window: AXUIElement) -> Bool {
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &buttonRef) == .success,
              let button = buttonRef, CFGetTypeID(button) == AXUIElementGetTypeID() else {
            return false
        }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }
}

/// Reads window titles via Accessibility while memoizing each app's window list,
/// so a single dock refresh that labels several windows of the same app fetches
/// that app's AX window array **once** instead of once per window (the fetch is
/// an IPC round-trip; the per-window title read off the cached list is cheap).
///
/// Create a fresh reader per refresh: the memo is intentionally short-lived so it
/// can never go stale as windows open and close between refreshes — no cache
/// invalidation, no pruning, no leak.
public final class WindowTitleReader {
    private var windowsByPID: [pid_t: [AXUIElement]] = [:]

    public init() {}

    /// The live title of `windowID`, or nil when AX is untrusted, the window is
    /// gone, or it exposes no title. Reuses the memoized window list for repeat
    /// calls on the same app.
    public func title(windowID: CGWindowID, pid: pid_t) -> String? {
        guard WindowAX.isTrusted else { return nil }
        guard let window = WindowAX.firstWindow(windowID: windowID, in: windows(of: pid)) else { return nil }
        return WindowAX.title(of: window)
    }

    /// The `CGWindowID` of an app's main window — the one that's frontmost when the
    /// app itself is frontmost, i.e. the active/forefront window. nil when AX is
    /// untrusted or the app exposes no main window. Reuses the memoized window list
    /// (the same one `title` reads), so marking the active window costs no extra IPC
    /// for an app the dock is already labeling.
    public func mainWindowID(pid: pid_t) -> CGWindowID? {
        guard WindowAX.isTrusted else { return nil }
        guard let main = windows(of: pid).first(where: WindowAX.isMain) else { return nil }
        return WindowAX.cgWindowID(of: main)
    }

    /// This app's AX window list, fetched once per reader lifetime and memoized.
    private func windows(of pid: pid_t) -> [AXUIElement] {
        if let cached = windowsByPID[pid] { return cached }
        let windows = WindowAX.windows(of: pid)
        windowsByPID[pid] = windows
        return windows
    }
}
