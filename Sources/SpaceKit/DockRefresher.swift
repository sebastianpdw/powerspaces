// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation

/// Turns a raw `SpaceSnapshot` (plus the desktop's pins and the user's display
/// options) into the final list of `DockApp`s the per-Space dock should show.
///
/// This is the whole display pipeline the menu-bar app runs on every refresh,
/// lifted out of `AppDelegate` and behind injected closures so it stays a pure
/// function: the name lookup (NSWorkspace) and window-title read (Accessibility)
/// are passed in, so the pipeline is unit-testable with a fake snapshot — the
/// same seam the rest of `SpaceKit` uses.
public enum DockRefresher {
    /// How the running/pinned app list becomes the final per-window display list.
    public struct DisplayOptions {
        /// Expand each multi-window app into one entry per window (the "Windows"
        /// feature; also implied by window labels). Off → one icon per app.
        public let expandPerWindow: Bool
        /// Whether an item standing for an app with this many windows on the
        /// current Space should get a live window-title label. Returning `false`
        /// for everything skips the (Accessibility) title reads entirely, so the
        /// label-off path costs nothing.
        public let shouldLabel: (Int) -> Bool

        public init(expandPerWindow: Bool, shouldLabel: @escaping (Int) -> Bool) {
            self.expandPerWindow = expandPerWindow
            self.shouldLabel = shouldLabel
        }
    }

    /// The dock's display list. Pure given its inputs:
    /// - `nameForBundleID` resolves a name for a pinned-but-not-running app.
    /// - `titleForWindow` reads a window's live title (nil when unavailable). It's
    ///   only called for items `options.shouldLabel` accepts and that actually
    ///   have a window, so it never runs when labels are off.
    /// - `includeLauncher` prepends the App Launcher tile (`DockApp.launcher`); it
    ///   participates in `order` like any item, so its slot persists.
    public static func displayApps(
        snapshot: SpaceSnapshot,
        pinnedHere: [String],
        pinnedEverywhere: [String],
        excludedHere: [String] = [],
        order: [String],
        includeLauncher: Bool = false,
        windowlessApps: [DockApp] = [],
        options: DisplayOptions,
        nameForBundleID: (String) -> String?,
        titleForWindow: (CGWindowID, pid_t) -> String?
    ) -> [DockApp] {
        finish(DockModel.apps(onCurrentSpace: snapshot,
                              pinnedHere: pinnedHere, pinnedEverywhere: pinnedEverywhere,
                              excludedHere: excludedHere,
                              order: order, includeLauncher: includeLauncher,
                              windowlessApps: windowlessApps,
                              nameForBundleID: nameForBundleID),
               options: options, titleForWindow: titleForWindow)
    }

    /// The per-display dock's display list — the same pipeline as `displayApps`,
    /// but scoped to the visible Space of the display at `display` (its pins are
    /// that display's desktop's pins). `visibleSpace` is that display's visible
    /// Space id, so a window minimized on another desktop of the same display is
    /// kept out of this bar; pass `nil` for the active display.
    public static func displayApps(
        onDisplay display: CGRect,
        snapshot: SpaceSnapshot,
        visibleSpace: SpaceID? = nil,
        allDisplays: [CGRect]? = nil,
        pinnedHere: [String],
        pinnedEverywhere: [String],
        excludedHere: [String] = [],
        order: [String],
        includeLauncher: Bool = false,
        windowlessApps: [DockApp] = [],
        options: DisplayOptions,
        nameForBundleID: (String) -> String?,
        titleForWindow: (CGWindowID, pid_t) -> String?
    ) -> [DockApp] {
        finish(DockModel.apps(onDisplay: display, snapshot: snapshot, visibleSpace: visibleSpace,
                              allDisplays: allDisplays,
                              pinnedHere: pinnedHere, pinnedEverywhere: pinnedEverywhere,
                              excludedHere: excludedHere,
                              order: order, includeLauncher: includeLauncher,
                              windowlessApps: windowlessApps,
                              nameForBundleID: nameForBundleID),
               options: options, titleForWindow: titleForWindow)
    }

    /// Shared tail of both `displayApps` overloads: expand per window (if on) and
    /// attach live window-title labels for the items `options.shouldLabel` accepts.
    private static func finish(
        _ apps: [DockApp],
        options: DisplayOptions,
        titleForWindow: (CGWindowID, pid_t) -> String?
    ) -> [DockApp] {
        let display = options.expandPerWindow ? DockModel.expandingPerWindow(apps) : apps
        return display.map { app in
            // Pinned-but-not-running entries have no window and keep a nil title
            // (the panel falls back to the app name).
            guard options.shouldLabel(app.windowCount),
                  let pid = app.pid, let wid = app.windowID ?? app.windowIDs.first else { return app }
            return app.withTitle(titleForWindow(wid, pid))
        }
    }
}
