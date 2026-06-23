// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Live implementation of `SpaceProviding` backed by the window server.
public final class CGSSpaceProvider: SpaceProviding {
    private let cid = CGSMainConnectionID()

    public init() {}

    public func currentSpaceID() throws -> SpaceID {
        guard managedDisplaySpaces() != nil else { throw SpaceError.cgsUnavailable }
        if let id = currentSpaceField({ current in
            (current["ManagedSpaceID"] as? NSNumber)?.uint64Value
                ?? (current["id64"] as? NSNumber)?.uint64Value
        }) { return id }
        throw SpaceError.noCurrentSpace
    }

    /// The current Space's **persistent UUID** — stable across reboots (macOS
    /// stores it in com.apple.spaces.plist). This is what per-desktop pins are
    /// keyed by; the numeric id is a runtime value and would not survive reboot.
    public func currentSpaceUUID() throws -> String {
        guard managedDisplaySpaces() != nil else { throw SpaceError.cgsUnavailable }
        if let uuid = currentSpaceField({ $0["uuid"] as? String }) { return uuid }
        throw SpaceError.noCurrentSpace
    }

    public func snapshot() throws -> SpaceSnapshot {
        let active = try currentSpaceID()
        // Enumerate the running-apps list once and reuse it for both the
        // window→bundle resolution and the running-app set (a window-less but
        // alive app — Finder after a quit — must read as "running", not absent).
        var bundleIDByPID: [pid_t: String] = [:]
        var running: Set<String> = []
        // Pids of apps the user has ⌘-hidden: their windows go off-screen without
        // being minimized, so the phantom filter would otherwise drop them. Tag
        // them instead so the dock can keep (and optionally show) them.
        var hiddenPIDs: Set<pid_t> = []
        // Pids of *regular* (Dock-showing) apps — the only kind a per-Space dock
        // should list, exactly as the macOS Dock itself shows only regular apps.
        // `listWindows` drops every other owner's windows: system-UI agents put up
        // full-size, opaque, layer-0 windows that are indistinguishable from a real
        // window by geometry. The most visible offender is the **Dock** process,
        // which draws Mission Control / App Exposé — its overlay surfaced a transient
        // "Dock" icon in the bar for as long as Mission Control was open. WindowManager
        // (Stage Manager), Spotlight, and XPC/helper agents (AutoFill, Open and Save
        // Panel Service) are the same shape. Powerspaces' own accessory process is
        // covered too (its panels are already non-layer-0, so this is just a backstop).
        var regularPIDs: Set<pid_t> = []
        for app in NSWorkspace.shared.runningApplications {
            if app.isHidden { hiddenPIDs.insert(app.processIdentifier) }
            if app.activationPolicy == .regular { regularPIDs.insert(app.processIdentifier) }
            guard let bundleID = app.bundleIdentifier else { continue }
            bundleIDByPID[app.processIdentifier] = bundleID
            running.insert(bundleID)
        }
        return SpaceSnapshot(activeSpaceID: active,
                             windows: listWindows(bundleIDByPID: bundleIDByPID,
                                                  hiddenPIDs: hiddenPIDs, regularPIDs: regularPIDs,
                                                  activeSpace: active),
                             runningBundleIDs: running)
    }

    /// Every attached display with the Space currently visible on it — the basis
    /// for the per-display dock. Geometry (`bounds`) comes from the display layout;
    /// the visible Space's id/uuid and the "owns the menu bar" flag come from the
    /// window server. Returns [] if the window server reports nothing.
    public func displays() -> [DisplaySpaceInfo] {
        guard let managed = managedDisplaySpaces() else { return [] }
        let activeUUID = CGSCopyActiveMenuBarDisplayIdentifier(cid)?.takeRetainedValue() as String?
        return managed.compactMap { display in
            guard let uuid = display["Display Identifier"] as? String,
                  let current = display["Current Space"] as? [String: Any] else { return nil }
            let spaceID = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value
                ?? (current["id64"] as? NSNumber)?.uint64Value ?? 0
            let spaceUUID = (current["uuid"] as? String) ?? ""
            // The 1-based position of the visible Space among this display's Spaces,
            // so the dock can label "Desktop N" the way macOS numbers them. Match by
            // persistent uuid first, then the managed id; 0 if neither is found.
            let allSpaces = (display["Spaces"] as? [[String: Any]]) ?? []
            let spaceIndex: Int = {
                if !spaceUUID.isEmpty,
                   let i = allSpaces.firstIndex(where: { ($0["uuid"] as? String) == spaceUUID }) {
                    return i + 1
                }
                if let i = allSpaces.firstIndex(where: {
                    (($0["ManagedSpaceID"] as? NSNumber)?.uint64Value
                        ?? ($0["id64"] as? NSNumber)?.uint64Value) == spaceID
                }) {
                    return i + 1
                }
                return 0
            }()
            // The window server tags each Space with a `type`: 0 is a normal user
            // desktop, 4 is a full-screen Space (one app filling the screen, or a Split
            // View pair). Read it from the matched Space entry (most reliable), falling
            // back to the Current Space dict. This is the same field yabai / AeroSpace
            // read for full-screen detection.
            let currentSpaceType: Int = {
                if !spaceUUID.isEmpty,
                   let s = allSpaces.first(where: { ($0["uuid"] as? String) == spaceUUID }) {
                    return (s["type"] as? NSNumber)?.intValue ?? 0
                }
                if let s = allSpaces.first(where: {
                    (($0["ManagedSpaceID"] as? NSNumber)?.uint64Value
                        ?? ($0["id64"] as? NSNumber)?.uint64Value) == spaceID
                }) {
                    return (s["type"] as? NSNumber)?.intValue ?? 0
                }
                return (current["type"] as? NSNumber)?.intValue ?? 0
            }()
            return DisplaySpaceInfo(
                displayUUID: uuid,
                bounds: DisplayInfo.bounds(forDisplayUUID: uuid) ?? .zero,
                currentSpaceID: spaceID,
                currentSpaceUUID: spaceUUID,
                isActive: uuid == activeUUID,
                spaceIndex: spaceIndex,
                isFullscreen: currentSpaceType == 4)
        }
    }

    /// Exposed for the CLI `dump-spaces` debug command.
    public func rawManagedDisplaySpaces() -> [[String: Any]]? { managedDisplaySpaces() }

    // MARK: - Private

    private func managedDisplaySpaces() -> [[String: Any]]? {
        CGSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]]
    }

    /// Pull a field out of the current Space of the active display (falling back
    /// to the first display that reports one).
    private func currentSpaceField<T>(_ extract: ([String: Any]) -> T?) -> T? {
        guard let displays = managedDisplaySpaces() else { return nil }
        let activeDisplayUUID = CGSCopyActiveMenuBarDisplayIdentifier(cid)?.takeRetainedValue() as String?
        if let activeDisplayUUID {
            for display in displays where (display["Display Identifier"] as? String) == activeDisplayUUID {
                if let current = display["Current Space"] as? [String: Any], let value = extract(current) {
                    return value
                }
            }
        }
        for display in displays {
            if let current = display["Current Space"] as? [String: Any], let value = extract(current) {
                return value
            }
        }
        return nil
    }

    /// `bundleIDByPID` is the pid→bundle map built once by `snapshot()` (resolved
    /// from the running-apps list rather than per-window, which added up on every
    /// poll tick).
    private func listWindows(bundleIDByPID: [pid_t: String], hiddenPIDs: Set<pid_t>,
                             regularPIDs: Set<pid_t>, activeSpace: SpaceID) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var windows: [WindowInfo] = []
        // Memoize each app's AX window list for the minimized check below, so an
        // app with several off-screen windows costs at most one IPC fetch.
        var axWindowsByPID: [pid_t: [AXUIElement]] = [:]
        for info in raw {
            // Keep only real, user-facing windows. Layer 0 alone isn't enough:
            // apps emit transparent overlays and short toolbar/tab/status strips
            // at the same layer, and counting those makes one Safari/Finder window
            // read as several (see `WindowFilter`). Filter on layer + alpha + size.
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            guard WindowFilter.isRealWindow(layer: layer, alpha: alpha,
                                            width: bounds.width, height: bounds.height),
                  let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            // Keep only windows owned by a *regular* (Dock-showing) app. System-UI
            // agents (the Dock drawing Mission Control / App Exposé, WindowManager,
            // Spotlight) and XPC/helper processes (AutoFill, Open and Save Panel
            // Service) put up full-size, opaque, layer-0 windows that survive the
            // geometry filter but are not apps you'd switch to — the macOS Dock
            // doesn't list them either. The Dock process's Mission Control overlay
            // is the reported case: a transient extra icon in the bar that vanished
            // the moment Mission Control closed.
            guard regularPIDs.contains(pid) else { continue }
            // Second pass: drop full-size off-screen placeholders that momentarily
            // claim the *current* Space (default 500×500 / 800×600 windows many apps
            // spawn) — they'd otherwise inflate this app's window count. A visible
            // window reports onscreen on the active Space even when stacked behind
            // others; placeholders never do (see `WindowFilter`).
            let onscreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
            let spaceIDs = spaces(for: wid)
            let claimsActiveSpace = spaceIDs.contains(activeSpace)
            // A *minimized* window is off-screen yet a real window in the Dock — keep
            // it so a minimized-only app still shows in its display's dock, and so the
            // per-display dock can tell a minimized window apart from one parked on a
            // hidden Space (both report onscreen=false). Only ask AX for off-screen
            // windows (the visible path stays AX-free); the per-pid list is memoized.
            // Untrusted/placeholder windows answer "not minimized".
            let minimized = !onscreen
                && isMinimized(windowID: wid, pid: pid, cache: &axWindowsByPID)
            // A ⌘-hidden app's windows are off-screen but real (like minimized
            // ones), so they're not phantoms — keep and tag them.
            let hidden = hiddenPIDs.contains(pid)
            if WindowFilter.isActiveSpacePhantom(
                claimsActiveSpace: claimsActiveSpace, isOnscreen: onscreen,
                isMinimized: minimized, isHidden: hidden) { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            windows.append(
                WindowInfo(
                    windowID: wid,
                    pid: pid,
                    ownerName: owner,
                    bundleID: bundleIDByPID[pid],
                    spaceIDs: spaceIDs,
                    bounds: bounds,
                    isOnscreen: onscreen,
                    isMinimized: minimized,
                    isHidden: hidden
                )
            )
        }
        return filteringToStandaloneWindows(windows, cache: &axWindowsByPID)
    }

    /// Drop the windows that aren't real, standalone application windows — a
    /// blocking dialog (the sheet that slides down in System Settings, a modal alert
    /// panel) or a non-window accessory that surfaces as its own window-server window
    /// (Safari's search-suggestions list, an `AXScrollArea`) — so they don't read as
    /// a second window (and a duplicate dock icon) for their app. These survive the
    /// size/phantom filters above because they're full-size, opaque, on-screen
    /// windows; only their AX *kind* gives them away (see
    /// `WindowFilter.isStandaloneWindow`). A genuine new window (a second Safari
    /// window) is a standard window and stays.
    ///
    /// Scoped to apps with **two or more** candidate windows — the only case where
    /// an impostor can create a duplicate — which also guarantees we never strip an
    /// app's *last* window, so this pass can't erase an app from the dock. For such
    /// an app we ask AX which of its windows are real, standalone ones and keep only
    /// those. When AX can't answer for a pid, `standaloneWindowIDs` is nil and we
    /// keep all of its windows — the conservative fallback the rest of this file uses.
    /// Only *on-screen* windows are gated: the impostors are always visible, while a
    /// minimized/⌘-hidden window is off-screen and frequently absent from AX's window
    /// list, so checking it here would wrongly strip a real, restorable window.
    private func filteringToStandaloneWindows(_ windows: [WindowInfo],
                                              cache: inout [pid_t: [AXUIElement]]) -> [WindowInfo] {
        guard WindowAX.isTrusted else { return windows }
        var countByPID: [pid_t: Int] = [:]
        for window in windows { countByPID[window.pid, default: 0] += 1 }
        let multiWindowPIDs = countByPID.filter { $0.value > 1 }.keys
        guard !multiWindowPIDs.isEmpty else { return windows }

        var standaloneByPID: [pid_t: Set<CGWindowID>] = [:]
        for pid in multiWindowPIDs {
            if let ids = standaloneWindowIDs(pid: pid, cache: &cache) { standaloneByPID[pid] = ids }
        }
        return windows.filter { window in
            // Off-screen windows (minimized or ⌘-hidden) are never the impostors this
            // pass targets — a blocking dialog or a search-suggestions accessory is
            // always *on screen*. And AX's window list (`kAXWindowsAttribute`) routinely
            // omits an app's minimized windows, so a minimized window's id is missing
            // from `standalone` not because it's an impostor but because AX never listed
            // it; gating on those ids would wrongly strip a real, restorable window from
            // a multi-window app (the repro: a second VSCode window minimized while
            // another stays open → it vanished from the dock, leaving nothing to click
            // to bring it back). The phantom filter above already vetted off-screen
            // windows, so keep them here unconditionally.
            guard window.isOnscreen else { return true }
            // Not a gated pid, or AX couldn't answer for it → keep.
            guard let standalone = standaloneByPID[window.pid] else { return true }
            return standalone.contains(window.windowID)
        }
    }

    /// The CGWindowIDs of an app's real, standalone windows: its top-level AX windows
    /// that pass `WindowFilter.isStandaloneWindow` (role "AXWindow", not a dialog).
    /// A sheet is excluded for free — it isn't a top-level AX window, so its id never
    /// lands here; a dialog panel or a non-window accessory (an `AXScrollArea`) in the
    /// list is excluded by the predicate. Returns nil (→ keep everything) when AX is
    /// untrusted, the app exposes no AX windows, or *none* of its top-level windows is
    /// a standalone window (so we never erase an app on a fluke). Reuses the per-pid AX
    /// window memo built for the minimized check.
    private func standaloneWindowIDs(pid: pid_t, cache: inout [pid_t: [AXUIElement]]) -> Set<CGWindowID>? {
        guard WindowAX.isTrusted else { return nil }
        let axWindows: [AXUIElement]
        if let cached = cache[pid] {
            axWindows = cached
        } else {
            axWindows = WindowAX.windows(of: pid)
            cache[pid] = axWindows
        }
        guard !axWindows.isEmpty else { return nil }
        var ids = Set<CGWindowID>()
        for window in axWindows where WindowAX.isStandaloneWindow(window) {
            if let id = WindowAX.cgWindowID(of: window) { ids.insert(id) }
        }
        return ids.isEmpty ? nil : ids
    }

    /// Whether `windowID` is a minimized (Dock) window, via Accessibility. The
    /// app's AX window list is fetched once per pid and reused through `cache`.
    /// Returns false when AX is untrusted or the window isn't an AX window (e.g. a
    /// window-server placeholder), so only genuine minimized windows survive the
    /// phantom filter.
    private func isMinimized(windowID: CGWindowID, pid: pid_t,
                             cache: inout [pid_t: [AXUIElement]]) -> Bool {
        guard WindowAX.isTrusted else { return false }
        let axWindows: [AXUIElement]
        if let cached = cache[pid] {
            axWindows = cached
        } else {
            axWindows = WindowAX.windows(of: pid)
            cache[pid] = axWindows
        }
        guard let window = WindowAX.firstWindow(windowID: windowID, in: axWindows) else { return false }
        return WindowAX.isMinimized(window)
    }

    private func spaces(for windowID: CGWindowID) -> [SpaceID] {
        let ids = [NSNumber(value: windowID)] as CFArray
        guard let raw = CGSCopySpacesForWindows(cid, kCGSSpaceAll, ids)?.takeRetainedValue() as? [NSNumber] else {
            return []
        }
        return raw.map { $0.uint64Value }
    }
}
