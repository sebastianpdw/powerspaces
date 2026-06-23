// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import CoreGraphics

/// A macOS Space identifier (the window-server's managed space id).
public typealias SpaceID = UInt64

/// A single on-screen window, tagged with the Space(s) it lives on.
public struct WindowInfo: Equatable, Sendable {
    public let windowID: CGWindowID
    public let pid: pid_t
    public let ownerName: String
    public let bundleID: String?
    /// The Space(s) this window belongs to. Usually one; can be several if
    /// the user pinned the window to "All Desktops".
    public let spaceIDs: [SpaceID]
    /// The window's screen rectangle (global, top-left origin). Used to decide
    /// which physical *display* a window is on for the per-display dock — macOS
    /// only reliably reports Space membership for the active display, so display
    /// membership is derived geometrically instead. `.zero` when unknown.
    public let bounds: CGRect
    /// Whether the window server reports the window as currently on screen. A
    /// window is on its display's *visible* Space iff it's onscreen; an off-screen
    /// window is on a hidden Space (another desktop) of that display — or minimized.
    public let isOnscreen: Bool
    /// Whether the window is minimized (sitting in the Dock). A minimized window is
    /// off-screen yet still belongs to its display's dock, so the two flags
    /// together separate "on the visible desktop" from "on a hidden desktop".
    public let isMinimized: Bool
    /// Whether the window's app is currently *hidden* (the user pressed ⌘H). A
    /// hidden app's windows go off-screen without being minimized, so — like a
    /// minimized window — a hidden window is a real, user-facing window that still
    /// belongs to its desktop's dock. Tracking it separately keeps such a window
    /// from being mistaken for an off-screen placeholder (which the phantom filter
    /// drops), and lets the dock optionally show or hide these.
    public let isHidden: Bool

    public init(windowID: CGWindowID, pid: pid_t, ownerName: String, bundleID: String?,
                spaceIDs: [SpaceID], bounds: CGRect = .zero,
                isOnscreen: Bool = true, isMinimized: Bool = false, isHidden: Bool = false) {
        self.windowID = windowID
        self.pid = pid
        self.ownerName = ownerName
        self.bundleID = bundleID
        self.spaceIDs = spaceIDs
        self.bounds = bounds
        self.isOnscreen = isOnscreen
        self.isMinimized = isMinimized
        self.isHidden = isHidden
    }

    public func isOn(_ space: SpaceID) -> Bool { spaceIDs.contains(space) }

    /// The window's center, used for display membership.
    public var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    /// On the visible desktop of whatever display it's on (so it belongs in a
    /// per-display dock), as opposed to a window parked on a hidden Space. A
    /// minimized *or* hidden (⌘H) window is off-screen yet still belongs to its
    /// desktop's dock — like its Dock tile on macOS — so both count as visible here.
    public var isOnVisibleSpace: Bool { isOnscreen || isMinimized || isHidden }

    /// Whether this window sits on the given display rectangle (by its center).
    public func isOnDisplay(_ display: CGRect) -> Bool { display.contains(center) }
}

/// A display and the Space currently visible on it. With "Displays have separate
/// Spaces" on, each display has its own active Space; the per-display dock builds
/// one bar per display from these. `bounds` is the global top-left-origin
/// rectangle (same space as `WindowInfo.bounds`), so window→display membership is
/// a geometric test.
public struct DisplaySpaceInfo: Equatable, Sendable, Identifiable {
    /// The window server's stable identifier for the display (its UUID string).
    public let displayUUID: String
    public let bounds: CGRect
    public let currentSpaceID: SpaceID
    /// The visible Space's persistent UUID — what per-desktop pins/tints are keyed
    /// by. Empty when the window server didn't report one.
    public let currentSpaceUUID: String
    /// Whether this display currently owns the menu bar (the screen the user is on).
    public let isActive: Bool
    /// 1-based ordinal of the visible Space among this display's Spaces (so the dock
    /// can show "Desktop 2"), matching the order macOS itself numbers desktops in.
    /// `0` when the window server didn't report the Space list.
    public let spaceIndex: Int
    /// Whether the visible Space on this display is a **full-screen** Space (a single
    /// app taking the whole screen, or a Split View pair) rather than a normal user
    /// desktop. The per-desktop dock reads this to hide / auto-hide / show itself per
    /// the full-screen dock preference. Comes from the window server's Space `type`.
    public let isFullscreen: Bool

    public init(displayUUID: String, bounds: CGRect, currentSpaceID: SpaceID,
                currentSpaceUUID: String, isActive: Bool, spaceIndex: Int = 0,
                isFullscreen: Bool = false) {
        self.displayUUID = displayUUID
        self.bounds = bounds
        self.currentSpaceID = currentSpaceID
        self.currentSpaceUUID = currentSpaceUUID
        self.isActive = isActive
        self.spaceIndex = spaceIndex
        self.isFullscreen = isFullscreen
    }

    public var id: String { displayUUID }
}

/// A point-in-time view of the window/space world. Everything in the decision
/// layer is a pure function of this value, which is what makes it testable.
public struct SpaceSnapshot: Equatable, Sendable {
    public let activeSpaceID: SpaceID
    public let windows: [WindowInfo]
    /// Bundle ids of every currently-running app, including ones with **no
    /// window** in `windows`. The window list alone can't tell "not running"
    /// from "running but window-less" (Finder after a quit auto-relaunches with
    /// no windows) — this distinguishes a cold launch from a new-window request.
    public let runningBundleIDs: Set<String>

    public init(activeSpaceID: SpaceID, windows: [WindowInfo], runningBundleIDs: Set<String> = []) {
        self.activeSpaceID = activeSpaceID
        self.windows = windows
        self.runningBundleIDs = runningBundleIDs
    }

    public func windows(onSpace space: SpaceID) -> [WindowInfo] {
        windows.filter { $0.isOn(space) }
    }

    /// All windows belonging to `target` (bundle-id match, owner-name fallback) —
    /// the base query the launch layer builds on, instead of repeating the
    /// `target.matches($0)` filter at every call site.
    public func windows(of target: AppTarget) -> [WindowInfo] {
        windows.filter { target.matches($0) }
    }

    /// `target`'s windows that are on a specific Space.
    public func windows(of target: AppTarget, onSpace space: SpaceID) -> [WindowInfo] {
        windows.filter { target.matches($0) && $0.isOn(space) }
    }

    /// `target`'s windows that live on a *real* Space — i.e. excluding the
    /// spaceless off-screen phantoms an app can leave behind (empty `spaceIDs`).
    /// Those placeholders belong to no desktop at all (the canonical case is an
    /// Electron app like Claude after you ✕ its last real window: the process
    /// lingers, owning only `space[]` ghost windows), so they must not read as
    /// "the app has a window somewhere". This is the query the launch layer turns
    /// on to tell a genuine window (here or on another desktop) from a windowless
    /// instance that can simply be reused.
    public func realWindows(of target: AppTarget) -> [WindowInfo] {
        windows.filter { target.matches($0) && !$0.spaceIDs.isEmpty }
    }

    /// Is the target's app process alive right now (with or without windows)?
    /// Bundle-id based; name-only targets can't be matched this way and report
    /// `false`, so they fall back to window-presence as before.
    public func isRunning(_ target: AppTarget) -> Bool {
        guard let bundleID = target.bundleID else { return false }
        return runningBundleIDs.contains(bundleID)
    }

    /// A copy of this snapshot with every ⌘-hidden window removed — what the dock
    /// builds from when the user turns "show hidden apps" off, so a hidden app
    /// disappears from the bar until it's unhidden. The running-app set is left
    /// intact (the app is still running, just window-less to the dock now). A
    /// snapshot with no hidden windows is returned unchanged (equal to `self`).
    public func droppingHiddenWindows() -> SpaceSnapshot {
        SpaceSnapshot(activeSpaceID: activeSpaceID,
                      windows: windows.filter { !$0.isHidden },
                      runningBundleIDs: runningBundleIDs)
    }
}

/// The app a launch request targets. Matched against windows by bundle id
/// first (canonical), falling back to the owner process name.
public struct AppTarget: Equatable, Sendable {
    public let bundleID: String?
    public let name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }

    public func matches(_ window: WindowInfo) -> Bool {
        if let bundleID, let wb = window.bundleID { return bundleID == wb }
        if let name { return window.ownerName == name }
        return false
    }
}
