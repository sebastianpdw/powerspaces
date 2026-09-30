// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation

/// One entry in the per-space dock.
public struct DockApp: Equatable, Sendable {
    public let bundleID: String?
    public let name: String
    /// nil when the app is pinned but not currently running.
    public let pid: pid_t?
    /// Windows this app has on the current Space (0 if pinned-but-not-running).
    public let windowCount: Int
    public let isPinnedHere: Bool
    public let isPinnedEverywhere: Bool
    /// True when this app is pinned to all desktops but the user has hidden it on
    /// *this* one ("unpin this desktop"). Only meaningful alongside
    /// `isPinnedEverywhere`; lets the menu offer to show it here again. Such an
    /// entry only appears in the dock while the app is actually running here —
    /// otherwise it's filtered out entirely.
    public let isExcludedHere: Bool
    /// The window-server ids of this app's windows on the current Space, in a
    /// stable order (ascending). Empty for a pinned-but-not-running shortcut.
    /// `expandingPerWindow` uses these to give each duplicated icon its own
    /// window.
    public let windowIDs: [CGWindowID]
    public let windowPIDs: [CGWindowID: pid_t]

    /// A surviving window retains its join/leave identity when a sibling closes.
    public var slotIdentity: String {
        if let windowID, let pid { return "\(orderKey):\(pid):\(windowID)" }
        return orderKey
    }
    /// When this entry stands for one *specific* window — a duplicated icon from
    /// the "Windows" feature — the id of that window, so a click acts on exactly
    /// it instead of letting the engine pick the app's first window. nil for the
    /// normal one-icon-per-app entry.
    public let windowID: CGWindowID?
    /// A live label describing this entry's window (its title-bar text), shown in
    /// the wide "window titles" dock mode. Filled in by the app layer via the
    /// Accessibility API — the pure snapshot functions leave it nil — so it sits
    /// here on the view-model rather than being re-derived in the panel.
    public let title: String?
    /// True for the single, special "App Launcher" tile (not a real app): clicking
    /// it opens the all-applications grid instead of smart-launching an app. It's a
    /// dock item like any other — reorderable, with a stable `orderKey` — so its
    /// slot persists, but the app layer renders and handles it specially.
    public let isLauncher: Bool
    /// True when this entry stands for the active/forefront window — the main
    /// window of the frontmost application. Filled in by the app layer (it needs
    /// to know which app is frontmost); the pure snapshot functions leave it false.
    /// The wide "window titles" mode renders this item's title in bold so the
    /// focused window stands out among the bars.
    public let isActive: Bool

    public init(bundleID: String?, name: String, pid: pid_t?, windowCount: Int,
                isPinnedHere: Bool = false, isPinnedEverywhere: Bool = false,
                isExcludedHere: Bool = false,
                windowIDs: [CGWindowID] = [], windowID: CGWindowID? = nil,
                windowPIDs: [CGWindowID: pid_t] = [:],
                title: String? = nil, isLauncher: Bool = false, isActive: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
        self.windowCount = windowCount
        self.isPinnedHere = isPinnedHere
        self.isPinnedEverywhere = isPinnedEverywhere
        self.isExcludedHere = isExcludedHere
        self.windowIDs = windowIDs
        self.windowPIDs = windowPIDs
        self.windowID = windowID
        self.title = title
        self.isLauncher = isLauncher
        self.isActive = isActive
    }

    /// Whether this entry shows in the dock as a pinned shortcut. An all-desktops
    /// pin hidden on this desktop is not pinned *here* (it only appears because
    /// it's running).
    public var isPinned: Bool { isPinnedHere || (isPinnedEverywhere && !isExcludedHere) }
    public var isRunning: Bool { pid != nil }
    public var target: AppTarget { AppTarget(bundleID: bundleID, name: name) }

    /// The stable `orderKey` of the App Launcher tile, plus a factory for it. A
    /// fixed sentinel (not a real bundle id) so the launcher keeps its slot in the
    /// saved dock arrangement just like a pinned app does.
    public static let launcherOrderKey = "powerspaces.app-launcher"
    public static var launcher: DockApp {
        DockApp(bundleID: nil, name: "Applications", pid: nil, windowCount: 0, isLauncher: true)
    }

    /// A copy of this entry carrying a live window label (its title-bar text).
    public func withTitle(_ title: String?) -> DockApp {
        DockApp(bundleID: bundleID, name: name, pid: pid, windowCount: windowCount,
                isPinnedHere: isPinnedHere, isPinnedEverywhere: isPinnedEverywhere,
                isExcludedHere: isExcludedHere,
                windowIDs: windowIDs, windowID: windowID, windowPIDs: windowPIDs, title: title,
                isLauncher: isLauncher, isActive: isActive)
    }

    /// A copy of this entry flagged as (or no longer) the active/forefront window.
    public func withActive(_ isActive: Bool) -> DockApp {
        DockApp(bundleID: bundleID, name: name, pid: pid, windowCount: windowCount,
                isPinnedHere: isPinnedHere, isPinnedEverywhere: isPinnedEverywhere,
                isExcludedHere: isExcludedHere,
                windowIDs: windowIDs, windowID: windowID, windowPIDs: windowPIDs, title: title,
                isLauncher: isLauncher, isActive: isActive)
    }

    /// Stable identity used to remember this app's slot in the saved dock order.
    /// Mirrors the grouping key in `apps(onCurrentSpace:)`: bundle id when known,
    /// otherwise the owner name (so apps without a bundle still sort stably). The
    /// launcher tile uses its own fixed sentinel so its slot survives renames.
    public var orderKey: String { isLauncher ? DockApp.launcherOrderKey : (bundleID ?? name) }
}

/// Derives what the per-space dock should show. Pure function of a snapshot
/// (plus the desktop's pins), so it's unit-testable without a window server.
public enum DockModel {
    /// Apps that have at least one window on the current Space.
    public static func apps(onCurrentSpace snapshot: SpaceSnapshot) -> [DockApp] {
        group(snapshot.windows(onSpace: snapshot.activeSpaceID))
    }

    /// Apps that have at least one window on the *visible* Space of the display at
    /// `display` (global, top-left-origin bounds). This is the per-display dock's
    /// content: a window belongs to this display's bar when it's on the display's
    /// currently-visible desktop and physically sits on this display.
    ///
    /// `visibleSpace` is that display's visible Space id; pass `nil` for the active
    /// display (it's `snapshot.activeSpaceID`). It's what keeps a window *minimized
    /// on another desktop of the same display* out of this desktop's dock — without
    /// it, such a window (off-screen but `isMinimized`) would be counted here purely
    /// because it sits on this display, showing a duplicate icon for an app that
    /// also has a real window here (the repro: open an app on two desktops, minimize
    /// one, switch to the other → two icons for one window). See `isOnVisibleDesktop`.
    /// `allDisplays` is every display's bounds, used to keep a window whose center has
    /// transiently left this display during a native desktop slide (see below). Pass
    /// `nil` (the default, used by unit tests) for strict geometric scoping.
    public static func apps(onDisplay display: CGRect, snapshot: SpaceSnapshot,
                            visibleSpace: SpaceID? = nil, allDisplays: [CGRect]? = nil) -> [DockApp] {
        let visible = visibleSpace.flatMap { $0 != 0 ? $0 : nil } ?? snapshot.activeSpaceID
        return group(snapshot.windows.filter { window in
            guard isOnVisibleDesktop(window, visibleSpace: visible) else { return false }
            if window.isOnDisplay(display) { return true }      // center on this display
            // Its center isn't on this display. During a native desktop-switch slide a
            // real window's center leaves the display bounds for a beat as the desktops
            // slide; gating purely on geometry then dropped *every* window at once, so
            // the bar emptied and refilled (the "shrink/scale then grow"). With the
            // full display layout known, keep it only when its center is on *no* display
            // at all (mid-slide) — if it sits on *another* display it belongs to that
            // display's bar. With no layout (unit tests) fall back to strict geometry.
            guard let allDisplays else { return false }
            return !allDisplays.contains { $0.contains(window.center) }
        })
    }

    /// Whether `window` is on the desktop currently visible on its display (the one
    /// whose Space id is `visibleSpace`).
    ///
    /// - An **onscreen** window is, by definition, on its display's visible desktop.
    /// - A **minimized** or **⌘-hidden** window is off-screen yet a real window that
    ///   still belongs to a desktop — but only *its own*. It counts here only when
    ///   its Space is `visibleSpace`; a window minimized on a different desktop of
    ///   the same display must not leak into this one's dock.
    /// - When membership is unavailable, only an onscreen window can be established
    ///   as visible by geometry. Hidden/minimized windows remain unknown.
    /// - Anything else off-screen (a hidden-desktop window, an off-screen
    ///   placeholder) is not on the visible bar.
    private static func isOnVisibleDesktop(_ window: WindowInfo, visibleSpace: SpaceID) -> Bool {
        // Decide membership by the window's Space, which is stable across a desktop
        // slide — not by `onscreen`, which goes false for a beat as the new desktop's
        // windows slide in (the old `isOnVisibleSpace` guard then dropped them, so the
        // bar emptied and refilled). A window positively on this desktop's Space is
        // here regardless of onscreen; one on a *different* Space is not; and one the
        // server reports no Space for falls back to onscreen only.
        if !window.spaceIDs.isEmpty { return window.isOn(visibleSpace) }
        return window.isOnscreen
    }

    /// Group a window list into one `DockApp` per app (by bundle id, else owner
    /// name), counting windows and collecting their ids. Sorted by name.
    private static func group(_ windows: [WindowInfo]) -> [DockApp] {
        var order: [String] = []
        var groups: [String: [WindowInfo]] = [:]
        for window in windows {
            let key = window.bundleID ?? window.ownerName
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(window)
        }
        return order.compactMap { key -> DockApp? in
            guard let windows = groups[key], let first = windows.first else { return nil }
            return DockApp(bundleID: first.bundleID, name: first.ownerName, pid: first.pid,
                           windowCount: windows.count,
                           windowIDs: windows.map(\.windowID).sorted(),
                           windowPIDs: Dictionary(windows.map { ($0.windowID, $0.pid) },
                                                  uniquingKeysWith: { first, _ in first }))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Pinned apps first (all-desktops pins, then this-desktop pins, in order),
    /// then the remaining running apps on this Space (sorted by name). A pinned
    /// app that's also running is shown once. `nameForBundleID` resolves a name
    /// for a pinned app that isn't currently running.
    ///
    /// `order` is the user's saved per-desktop arrangement (a list of
    /// `orderKey`s, see `applying(order:)`). Apps in it appear in that order;
    /// anything not in it (e.g. a freshly launched app) keeps its default
    /// position and is appended after.
    ///
    /// `includeLauncher` adds the special App Launcher tile (`DockApp.launcher`).
    /// It defaults to the leftmost slot but participates in `order` like any other
    /// item, so once the user drags it elsewhere that placement sticks.
    /// `windowlessApps` are running apps that have **no window** on this scope (the
    /// "show apps with no open windows" option supplies them). They're merged into
    /// the running set so they arrange and sort like any other running app; ones
    /// already present (they have a window after all) are skipped.
    public static func apps(onCurrentSpace snapshot: SpaceSnapshot,
                            pinnedHere: [String],
                            pinnedEverywhere: [String],
                            excludedHere: [String] = [],
                            order: [String] = [],
                            includeLauncher: Bool = false,
                            windowlessApps: [DockApp] = [],
                            nameForBundleID: (String) -> String?) -> [DockApp] {
        arrange(running: merging(apps(onCurrentSpace: snapshot), windowlessApps),
                pinnedHere: pinnedHere, pinnedEverywhere: pinnedEverywhere,
                excludedHere: excludedHere, order: order,
                includeLauncher: includeLauncher, nameForBundleID: nameForBundleID)
    }

    /// The per-display equivalent of `apps(onCurrentSpace:pinnedHere:…)`: the dock
    /// for the display at `display`, combining its visible-Space running apps with
    /// the pins for that display's desktop. Same arrangement rules.
    public static func apps(onDisplay display: CGRect,
                            snapshot: SpaceSnapshot,
                            visibleSpace: SpaceID? = nil,
                            allDisplays: [CGRect]? = nil,
                            pinnedHere: [String],
                            pinnedEverywhere: [String],
                            excludedHere: [String] = [],
                            order: [String] = [],
                            includeLauncher: Bool = false,
                            windowlessApps: [DockApp] = [],
                            nameForBundleID: (String) -> String?) -> [DockApp] {
        arrange(running: merging(apps(onDisplay: display, snapshot: snapshot, visibleSpace: visibleSpace, allDisplays: allDisplays), windowlessApps),
                pinnedHere: pinnedHere, pinnedEverywhere: pinnedEverywhere,
                excludedHere: excludedHere, order: order,
                includeLauncher: includeLauncher, nameForBundleID: nameForBundleID)
    }

    /// Append `windowless` running apps to the grouped `running` list, skipping any
    /// whose `orderKey` is already there (an app with a window in this scope is
    /// never window-less). Pure helper for the two `apps(…)` overloads above.
    private static func merging(_ running: [DockApp], _ windowless: [DockApp]) -> [DockApp] {
        guard !windowless.isEmpty else { return running }
        let present = Set(running.map(\.orderKey))
        return running + windowless.filter { !present.contains($0.orderKey) }
    }

    /// Shared arrangement: pinned block (all-desktops then this-desktop) followed
    /// by the remaining `running` apps, applying the saved order and optional
    /// launcher tile. `running` is the already-grouped app list for whichever scope
    /// the caller filtered (a Space or a display).
    private static func arrange(running: [DockApp],
                                pinnedHere: [String],
                                pinnedEverywhere: [String],
                                excludedHere: [String],
                                order: [String],
                                includeLauncher: Bool,
                                nameForBundleID: (String) -> String?) -> [DockApp] {
        let runningByBundle = Dictionary(
            running.compactMap { app in app.bundleID.map { ($0, app) } },
            uniquingKeysWith: { first, _ in first }
        )
        let hereSet = Set(pinnedHere)
        let everywhereSet = Set(pinnedEverywhere)
        // All-desktops pins the user hid here. A local pin still wins, so an app in
        // both lists stays visible (mirrors `PinModel.pinned(onSpace:)`).
        let excludedSet = Set(excludedHere).subtracting(hereSet)

        // Ordered, de-duplicated pinned bundle ids: all-desktops first, minus the
        // ones hidden on this desktop.
        let visibleEverywhere = pinnedEverywhere.filter { !excludedSet.contains($0) }
        let pinnedOrder = (visibleEverywhere + pinnedHere).uniqued()
        let pinnedSet = Set(pinnedOrder)

        func makeApp(_ bundleID: String) -> DockApp? {
            let here = hereSet.contains(bundleID)
            let everywhere = everywhereSet.contains(bundleID)
            let excluded = everywhere && excludedSet.contains(bundleID)
            if let runningApp = runningByBundle[bundleID] {
                return DockApp(bundleID: runningApp.bundleID, name: runningApp.name, pid: runningApp.pid,
                               windowCount: runningApp.windowCount,
                               isPinnedHere: here, isPinnedEverywhere: everywhere,
                               isExcludedHere: excluded,
                               windowIDs: runningApp.windowIDs, windowPIDs: runningApp.windowPIDs)
            }
            guard let name = nameForBundleID(bundleID) else { return nil }
            return DockApp(bundleID: bundleID, name: name, pid: nil, windowCount: 0,
                           isPinnedHere: here, isPinnedEverywhere: everywhere,
                           isExcludedHere: excluded)
        }

        var result = pinnedOrder.compactMap(makeApp)
        // A running app that isn't a visible pin trails the pinned block. Tag the
        // ones that are pinned-everywhere-but-hidden-here so the menu can offer to
        // show them again (they'd be gone entirely if they weren't running).
        let rest = running
            .filter { app in !(app.bundleID.map(pinnedSet.contains) ?? false) }
            .map { app -> DockApp in
                guard let bundleID = app.bundleID, excludedSet.contains(bundleID),
                      everywhereSet.contains(bundleID) else { return app }
                return DockApp(bundleID: app.bundleID, name: app.name, pid: app.pid,
                               windowCount: app.windowCount,
                               isPinnedEverywhere: true, isExcludedHere: true,
                               windowIDs: app.windowIDs, windowPIDs: app.windowPIDs)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        result.append(contentsOf: rest)
        var effectiveOrder = order
        if includeLauncher {
            result.insert(.launcher, at: 0)
            // Default the launcher to leftmost: when there's a saved order that
            // doesn't mention it, lead with its key so ranked pins don't push it to
            // the end. An empty order already keeps it first (applying is a no-op).
            if !order.isEmpty, !order.contains(DockApp.launcherOrderKey) {
                effectiveOrder = [DockApp.launcherOrderKey] + order
            }
        }
        return applying(order: effectiveOrder, to: result)
    }

    /// Expands each app into one entry per window it has on the current Space,
    /// so the dock can show the icon duplicated ("Windows" feature: two Firefox
    /// icons when two Firefox windows are open here). Each copy is tagged with
    /// its own `windowID` so a click acts on that exact window. An app with 0 or
    /// 1 windows yields one entry; real windows always retain their exact identity.
    /// Pinned-but-not-running shortcuts remain untagged.
    ///
    /// Duplicates stay adjacent and keep the same `orderKey`, so the saved
    /// arrangement (which de-dupes by `orderKey`) and drag-to-reorder treat all
    /// copies of an app as one unit.
    public static func expandingPerWindow(_ apps: [DockApp]) -> [DockApp] {
        apps.flatMap { app -> [DockApp] in
            guard !app.windowIDs.isEmpty else { return [app] }
            return app.windowIDs.map { id in
                DockApp(bundleID: app.bundleID, name: app.name, pid: app.windowPIDs[id] ?? app.pid,
                        windowCount: app.windowCount,
                        isPinnedHere: app.isPinnedHere, isPinnedEverywhere: app.isPinnedEverywhere,
                        isExcludedHere: app.isExcludedHere,
                        windowIDs: app.windowIDs, windowID: id, windowPIDs: app.windowPIDs,
                        title: app.title, isLauncher: app.isLauncher, isActive: app.isActive)
            }
        }
    }

    /// The `slotIdentity`s that leave and enter the dock going from `old` to `new`.
    /// An app in both lists changes only by its icon count: an identity that was
    /// replaced in place (a pinned app's last window closed, or it launched) pairs
    /// off against its replacement, so that icon neither leaves nor enters.
    public static func slotChanges(from old: [DockApp], to new: [DockApp]) -> (leaving: Set<String>, entering: Set<String>) {
        let oldKeys = Set(old.map(\.slotIdentity)), newKeys = Set(new.map(\.slotIdentity))
        let gone = Dictionary(grouping: old.filter { !newKeys.contains($0.slotIdentity) }, by: \.orderKey)
        let come = Dictionary(grouping: new.filter { !oldKeys.contains($0.slotIdentity) }, by: \.orderKey)
        let leaving = gone.flatMap { key, apps in apps.dropFirst(come[key]?.count ?? 0) }
        let entering = come.flatMap { key, apps in apps.dropFirst(gone[key]?.count ?? 0) }
        return (Set(leaving.map(\.slotIdentity)), Set(entering.map(\.slotIdentity)))
    }

    /// Move every window icon for an app together, matching app-level persistence.
    /// The insertion index counts only icons belonging to other apps.
    public static func reorderingGroup(_ apps: [DockApp], key: String, insertion: Int) -> [DockApp] {
        let group = apps.filter { $0.orderKey == key }
        guard !group.isEmpty else { return apps }
        let others = apps.filter { $0.orderKey != key }
        var index = min(max(0, insertion), others.count)
        while index > 0, index < others.count, others[index - 1].orderKey == others[index].orderKey {
            index += 1 // Never split another app's group either.
        }
        return Array(others.prefix(index)) + group + Array(others.dropFirst(index))
    }

    /// Reorders `apps` to match the user's saved arrangement. Apps whose
    /// `orderKey` appears in `order` are placed in that order; everything else
    /// keeps its original relative position and trails behind. The sort is
    /// stable, so an empty `order` (or unknown keys) leaves `apps` untouched.
    static func applying(order: [String], to apps: [DockApp]) -> [DockApp] {
        guard !order.isEmpty else { return apps }
        let rank = Dictionary(order.enumerated().map { ($1, $0) },
                              uniquingKeysWith: { first, _ in first })
        return apps.enumerated().sorted { lhs, rhs in
            let lr = rank[lhs.element.orderKey] ?? Int.max
            let rr = rank[rhs.element.orderKey] ?? Int.max
            return lr != rr ? lr < rr : lhs.offset < rhs.offset
        }.map(\.element)
    }
}
