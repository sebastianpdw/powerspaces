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
/// un-capped call blocks the sampling or launcher queue until the system default timeout (many seconds) finally fires. One stuck
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

    /// Reading the app role lets lazy native Accessibility implementations
    /// initialize their APIs before we ask for windows (not just client trust).
    private static func application(of pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &role)
        return app
    }

    /// Electron documents AXManualAccessibility for third-party window tools.
    /// Request it only for a clicked window not yet usable through AX, and restore the
    /// original false value when the focus operation ends. No app-name checks.
    static func requestWindowAccess(windowID: CGWindowID, pid: pid_t) -> WindowFocusPolicy.AccessibilityRequest {
        var current: Bool?
        let app = AXUIElementCreateApplication(pid)
        let attribute = "AXManualAccessibility" as CFString
        var needsAccess = false
        if isTrusted {
            switch lookupWindow(windowID: windowID, pid: pid) {
            case .failure: needsAccess = true
            case let .success(window): needsAccess = WindowFocusPolicy.needsWindowAccess(role: role(of: window))
            }
        }
        if needsAccess {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attribute, &ref) == .success,
               let value = ref, CFGetTypeID(value) == CFBooleanGetTypeID() {
                current = CFBooleanGetValue((value as! CFBoolean))
            }
        }
        return WindowFocusPolicy.AccessibilityRequest(currentValue: current) { enabled in
            let error = AXUIElementSetAttributeValue(app, attribute, enabled ? kCFBooleanTrue : kCFBooleanFalse)
            Log.info("Window Accessibility request: pid=\(pid) enabled=\(enabled) axError=\(error.rawValue)")
            return error == .success
        }
    }

    enum LookupFailure: Error {
        case inventory(AXError)
        case malformedInventory
        case identity(AXError)
        case missing

        var diagnostic: String {
            switch self {
            case let .inventory(error): return "inventory axError=\(error.rawValue)"
            case .malformedInventory: return "inventory-type"
            case let .identity(error): return "window-id axError=\(error.rawValue)"
            case .missing: return "ax-window-missing"
            }
        }
    }

    /// All AX window elements for an app (empty when AX can't answer). Fetching
    /// this is the costly part — one IPC round-trip to the app — so callers that
    /// need several of an app's windows should fetch once and reuse (see
    /// `WindowTitleReader`).
    static func windows(of pid: pid_t) -> [AXUIElement] {
        availableWindows(of: pid) ?? []
    }

    /// nil distinguishes an IPC failure from a confirmed empty inventory.
    static func availableWindows(of pid: pid_t) -> [AXUIElement]? {
        let app = application(of: pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return nil }
        return windows
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
        try? lookupWindow(windowID: windowID, pid: pid).get()
    }

    /// Preserve the failure reason for launcher diagnostics. An allowed client
    /// can still encounter an unavailable inventory or a vanished window.
    static func lookupWindow(windowID: CGWindowID, pid: pid_t) -> Result<AXUIElement, LookupFailure> {
        let app = application(of: pid)
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref)
        let windows = error == .success ? ref as? [AXUIElement] : nil
        var identityError: AXError?
        func attributeWindow(_ attribute: String) -> AXUIElement? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        let match = WindowFocusPolicy.exactWindow(id: windowID, windows: windows ?? [],
            focused: { attributeWindow(kAXFocusedWindowAttribute) },
            main: { attributeWindow(kAXMainWindowAttribute) }) { window in
            var wid: CGWindowID = 0
            let error = _AXUIElementGetWindow(window, &wid)
            if error != .success { identityError = error }
            return error == .success ? wid : nil
        }
        if let match { return .success(match) }
        guard error == .success else { return .failure(.inventory(error)) }
        guard windows != nil else { return .failure(.malformedInventory) }
        return .failure(identityError.map(LookupFailure.identity) ?? .missing)
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

    @discardableResult
    static func minimize(_ window: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// Whether a window is currently minimized (sitting in the Dock).
    static func isMinimized(_ window: AXUIElement) -> Bool {
        minimizedStatus(of: window) ?? false
    }

    static func minimizedStatus(of window: AXUIElement) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
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
    /// dismissed), or nil when AX can't answer.
    static func modalStatus(of window: AXUIElement) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXModalAttribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
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

/// A refresh-local AX index. Resolve each app's window identities once instead
/// of walking them through IPC again for every title. No AX objects outlive it.
public final class WindowTitleReader {
    private let trusted = WindowAX.isTrusted
    private let deadline: TimeInterval
    private var windowsByPID: [pid_t: [(id: CGWindowID, element: AXUIElement)]] = [:]

    public init(deadline: TimeInterval = .infinity) { self.deadline = deadline }

    public func title(windowID: CGWindowID, pid: pid_t) -> String? {
        guard trusted, let window = windows(of: pid).first(where: { $0.id == windowID }) else { return nil }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        return WindowAX.title(of: window.element)
    }

    public func mainWindowID(pid: pid_t) -> CGWindowID? {
        guard trusted else { return nil }
        return windows(of: pid).first(where: {
            ProcessInfo.processInfo.systemUptime < deadline && WindowAX.isMain($0.element)
        })?.id
    }

    private func windows(of pid: pid_t) -> [(id: CGWindowID, element: AXUIElement)] {
        if let cached = windowsByPID[pid] { return cached }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return [] }
        var windows: [(id: CGWindowID, element: AXUIElement)] = []
        for element in WindowAX.windows(of: pid) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            if let id = WindowAX.cgWindowID(of: element), id != 0 { windows.append((id, element)) }
        }
        windowsByPID[pid] = windows
        return windows
    }
}
