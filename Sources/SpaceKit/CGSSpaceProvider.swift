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
    private let snapshotLock = NSLock()
    /// The only decision state kept between scans, guarded by `snapshotLock`: the
    /// windows Accessibility has confirmed. No desktops, frames or AX objects.
    private var remembered: Set<WindowFilter.Key> = []
    /// Real windows per app at the previous scan. Read by the change log only.
    private var realCounts: [String: Int] = [:]
    /// When the scan that last committed `remembered` started.
    private var lastCommitted: TimeInterval = 0

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

    public func snapshot() throws -> SpaceSnapshot { try scan(only: nil) }

    public func snapshot(of target: AppTarget) throws -> SpaceSnapshot { try scan(only: target) }

    /// One scan of the window world, or of one app's part of it: an action concerns
    /// one app, so it asks LaunchServices and Accessibility about that app alone.
    private func scan(only target: AppTarget?) throws -> SpaceSnapshot {
        // The dock sampler and the action queue scan side by side, so a click never
        // waits for the dock's scan. Only what is remembered is shared: it is read
        // first and committed last, and the lock is held for neither scan.
        let started = ProcessInfo.processInfo.systemUptime
        let known = snapshotLock.withLock { remembered }
        let active = try currentSpaceID()
        let visible = visibleSpaces().union([active])
        // Enumerate the running-apps list once and reuse it for both the
        // window→bundle resolution and the running-app set (a window-less but
        // alive app — Finder after a quit — must read as "running", not absent).
        var bundleIDByPID: [pid_t: String] = [:]
        var running: Set<String> = []
        // Pids of apps the user has ⌘-hidden: their windows go off-screen without
        // being minimized. Tag them so the dock can keep (and optionally show) them.
        var hiddenPIDs: Set<pid_t> = []
        // Pids of *regular* (Dock-showing) apps — the only kind a per-Space dock
        // should list, exactly as the macOS Dock itself shows only regular apps.
        // `listCandidates` drops every other owner's windows: system-UI agents put up
        // full-size, opaque, layer-0 windows that are indistinguishable from a real
        // window by geometry. The most visible offender is the **Dock** process,
        // which draws Mission Control / App Exposé — its overlay surfaced a transient
        // "Dock" icon in the bar for as long as Mission Control was open. WindowManager
        // (Stage Manager), Spotlight, and XPC/helper agents (AutoFill, Open and Save
        // Panel Service) are the same shape. Powerspaces' own accessory process is
        // covered too (its panels are already non-layer-0, so this is just a backstop).
        var regularPIDs: Set<pid_t> = []
        let apps = target?.bundleID.map(NSRunningApplication.runningApplications(withBundleIdentifier:))
            ?? NSWorkspace.shared.runningApplications
        for app in apps {
            // These properties can each synchronously query LaunchServices.
            // Fetch the pid once, and window-only metadata only for window owners.
            let bundleID = app.bundleIdentifier
            if let bundleID { running.insert(bundleID) }
            guard app.activationPolicy == .regular else { continue }
            let pid = app.processIdentifier
            regularPIDs.insert(pid)
            bundleIDByPID[pid] = bundleID
            if app.isHidden { hiddenPIDs.insert(pid) }
        }
        // The 2 s Accessibility budget covers the whole scan, window list included.
        let appsRead = ProcessInfo.processInfo.systemUptime
        let deadline = appsRead + 2
        let candidates = try listCandidates(bundleIDByPID: bundleIDByPID, hiddenPIDs: hiddenPIDs, regularPIDs: regularPIDs)
            .filter { target?.matches($0) ?? true }
        let windowsRead = ProcessInfo.processInfo.systemUptime
        var slowest = (app: "none", seconds: 0.0)
        let judged = judge(candidates, visibleSpaces: visible, remembered: known, deadline: deadline, slowest: &slowest)
        let ended = ProcessInfo.processInfo.systemUptime
        if ended - started >= 1 {
            // Where a slow scan spent its time, and which app answered slowest.
            let ms = { (seconds: TimeInterval) in Int(seconds * 1000) }
            Log.notice("Window scan slow: scope=\(target == nil ? "all" : "one") totalMs=\(ms(ended - started)) appsMs=\(ms(appsRead - started)) windowsMs=\(ms(windowsRead - appsRead)) accessibilityMs=\(ms(ended - windowsRead)) candidates=\(candidates.count) slowest=\(slowest.app) slowestMs=\(ms(slowest.seconds))")
        }
        // Only a full scan changes what is remembered. One that ran through a desktop
        // change judged some windows against the wrong desktop: its caller discards
        // it, and it must not be learned from. Nor may an older scan that finishes
        // late overwrite a newer one.
        if target == nil, visibleSpaces().isSubset(of: visible) {
            snapshotLock.withLock {
                guard started > lastCommitted else { return }
                lastCommitted = started
                remembered = WindowFilter.remembered(after: judged, previously: known)
                let change = WindowFilter.changeLog(judged, previousCounts: realCounts)
                realCounts = change.counts
                if let line = change.line { Log.notice(line) }
            }
        }
        return SpaceSnapshot(activeSpaceID: active, judged: judged, runningBundleIDs: running)
    }

    /// The desktop visible on each display, read from the window server in one call.
    private func visibleSpaces() -> Set<SpaceID> { Set(displays().map(\.currentSpaceID)) }

    /// Every attached display with the Space currently visible on it — the basis
    /// for the per-display dock. Geometry (`bounds`) comes from the display layout;
    /// the visible Space's id/uuid and the "owns the menu bar" flag come from the
    /// window server. Returns [] if the window server reports nothing.
    public func displays() -> [DisplaySpaceInfo] {
        guard let managed = managedDisplaySpaces() else { return [] }
        let activeUUID = CGSCopyActiveMenuBarDisplayIdentifier(cid)?.takeRetainedValue() as String?
        return Self.displaySpaces(managed: managed, physicalDisplays: DisplayInfo.activeDisplays(), activeUUID: activeUUID)
    }

    /// Map logical Spaces onto physical screens. A single shared "Main" entry
    /// supplies the same desktop to every display, not a zero-sized fake screen.
    public static func displaySpaces(managed: [[String: Any]],
                                     physicalDisplays: [(uuid: String, bounds: CGRect)],
                                     activeUUID: String?) -> [DisplaySpaceInfo] {
        return managed.flatMap { display -> [DisplaySpaceInfo] in
            guard let uuid = display["Display Identifier"] as? String,
                  let current = display["Current Space"] as? [String: Any] else { return [] }
            let spaceID = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value
                ?? (current["id64"] as? NSNumber)?.uint64Value ?? 0
            guard spaceID != 0 else { return [] }
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
            let shared = managed.count == 1 && uuid == "Main"
            let active = shared && !physicalDisplays.contains(where: { $0.uuid == activeUUID })
                ? physicalDisplays.first?.uuid : activeUUID
            return physicalDisplays.compactMap { physical in
                guard shared || physical.uuid == uuid,
                      physical.bounds.width > 0, physical.bounds.height > 0,
                      !physical.bounds.isInfinite, !physical.bounds.isNull else { return nil }
                return DisplaySpaceInfo(displayUUID: physical.uuid, bounds: physical.bounds,
                    currentSpaceID: spaceID, currentSpaceUUID: spaceUUID,
                    isActive: physical.uuid == active, spaceIndex: spaceIndex,
                    isFullscreen: currentSpaceType == 4)
            }
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

    /// Every regular app's window-server windows that pass the geometry filter,
    /// in window-server (front-to-back) order. `bundleIDByPID` is the pid→bundle
    /// map built once by `snapshot()` (resolved from the running-apps list rather
    /// than per-window, which added up on every poll tick).
    private func listCandidates(bundleIDByPID: [pid_t: String], hiddenPIDs: Set<pid_t>,
                                regularPIDs: Set<pid_t>) throws -> [WindowInfo] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw SpaceError.windowListUnavailable
        }
        return raw.compactMap { info in
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  regularPIDs.contains(pid) else { return nil }
            // Layer 0 alone isn't enough: apps emit transparent overlays and short
            // toolbar/tab/status strips at the same layer (see `WindowFilter`).
            let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            guard WindowFilter.isRealWindow(layer: info[kCGWindowLayer as String] as? Int ?? -1,
                                            alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                                            width: bounds.width, height: bounds.height) else { return nil }
            let membership = spaces(for: wid)
            return WindowInfo(windowID: wid, pid: pid,
                              ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                              bundleID: bundleIDByPID[pid], spaceIDs: membership ?? [], bounds: bounds,
                              isOnscreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
                              isHidden: hiddenPIDs.contains(pid), spaceMembershipKnown: membership != nil)
        }
    }

    /// One AX pass per app, all within `deadline`. Apps are read in window-server
    /// order, which favors visible/frontmost apps when another app uses the budget
    /// up. What the answers mean is `WindowFilter.judge`'s decision, not this one's.
    private func judge(_ candidates: [WindowInfo], visibleSpaces: Set<SpaceID>,
                       remembered: Set<WindowFilter.Key>, deadline: TimeInterval,
                       slowest: inout (app: String, seconds: TimeInterval)) -> [WindowFilter.Judged] {
        let trusted = WindowAX.isTrusted
        var judged: [CGWindowID: WindowFilter.Judged] = [:]
        var visited: Set<pid_t> = []
        for owner in candidates where visited.insert(owner.pid).inserted {
            var windows = candidates.filter { $0.pid == owner.pid }
            var accessibility = trusted ? WindowFilter.Accessibility.unanswered : .untrusted
            let asked = ProcessInfo.processInfo.systemUptime
            if trusted, let kinds = accessibilityKinds(of: &windows, deadline: deadline) {
                accessibility = .listed(kinds)
            }
            let took = ProcessInfo.processInfo.systemUptime - asked
            if took > slowest.seconds { slowest = (owner.bundleID ?? owner.ownerName, took) }
            for entry in WindowFilter.judge(windows, accessibility: accessibility,
                                            visibleSpaces: visibleSpaces, remembered: remembered) {
                judged[entry.window.windowID] = entry
            }
        }
        return candidates.compactMap { judged[$0.windowID] }
    }

    /// What Accessibility says about the windows of one app that it lists, or nil
    /// when the app gave no complete answer in time. Marks the windows it reports
    /// as minimized. Every AX object is released before this returns.
    private func accessibilityKinds(of windows: inout [WindowInfo],
                                    deadline: TimeInterval) -> [CGWindowID: WindowFilter.AXKind]? {
        guard let pid = windows.first?.pid, ProcessInfo.processInfo.systemUptime < deadline,
              let elements = WindowAX.availableWindows(of: pid) else { return nil }
        var kinds: [CGWindowID: WindowFilter.AXKind] = [:]
        for element in elements {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            guard let id = WindowAX.cgWindowID(of: element),
                  let index = windows.firstIndex(where: { $0.windowID == id }) else { continue }
            let window = windows[index]
            let minimizedStatus = window.isOnscreen ? false : WindowAX.minimizedStatus(of: element)
            if minimizedStatus == true {
                windows[index] = WindowInfo(windowID: id, pid: pid, ownerName: window.ownerName,
                    bundleID: window.bundleID, spaceIDs: window.spaceIDs, bounds: window.bounds,
                    isOnscreen: window.isOnscreen, isMinimized: true, isHidden: window.isHidden,
                    spaceMembershipKnown: window.spaceMembershipKnown)
            }
            let subrole = WindowAX.subrole(of: element)
            // While a window minimizes, the window server can still report it on screen.
            let minimized = minimizedStatus == true
                || (window.isOnscreen && subrole == "AXDialog" && WindowAX.isMinimized(element))
            kinds[id] = WindowFilter.AXKind(role: WindowAX.role(of: element), subrole: subrole,
                                           isModal: WindowAX.modalStatus(of: element), isMinimized: minimized)
        }
        return kinds
    }

    private func spaces(for windowID: CGWindowID) -> [SpaceID]? {
        let ids = [NSNumber(value: windowID)] as CFArray
        guard let raw = CGSCopySpacesForWindows(cid, kCGSSpaceAll, ids)?.takeRetainedValue() as? [NSNumber] else {
            return nil
        }
        return raw.map { $0.uint64Value }
    }
}
