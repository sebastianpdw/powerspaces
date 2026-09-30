// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation

/// Every state an app can be in *relative to the desktop you're standing on*.
///
/// This is the single source of truth the launch and dock-click decisions switch
/// over. It replaces the scattered booleans — `isRunning`, `hasWindowSomewhere`,
/// `isMinimized`, `isFrontmost` — that each call site used to re-derive on its own.
/// Reading the world once into one named, mutually-exclusive state (instead of
/// re-testing a tangle of flags at every branch) is what makes the behavior
/// predictable and the states inspectable: you can log "Spotify is `.windowElsewhere`"
/// and know exactly which transition will fire.
///
/// The states form a small ladder, ordered "least present" → "here". A launch or a
/// dock click is just a transition out of the current state:
///
/// ```
///                     ┌──────────────┐
///   open / dock-click │  notRunning  │   nothing of the app is alive
///                     └──────┬───────┘
///         cold launch (here) │
///                            ▼
///                  ┌────────────────────┐
///                  │ runningWindowless  │   alive, owns no window anywhere
///                  └─────────┬──────────┘   (Finder after "Quit all desktops")
///                normal open │
///                            ▼
///                  ┌────────────────────┐
///                  │   windowElsewhere  │   window(s) only on *other* Spaces
///                  └─────────┬──────────┘   (issues 1 & 2: never jump away)
///                 new window │
///                            ▼
///                  ┌────────────────────┐
///                  │  windowHere(mode)  │   window on the current desktop
///                  └────────────────────┘   focus it / front↔minimize toggle
/// ```
public enum AppState: Equatable, Sendable {
    /// Nothing of this app is alive — a cold launch puts its first window here.
    case notRunning

    /// The process is alive but owns no real window anywhere. Reopen it through
    /// the same first-window path as a new launch, without another process or a
    /// quit. Finder's first-window primitive opens a folder instead of the bundle.
    case runningWindowless

    /// Has a window, but only on *other* Spaces — none on the desktop you're on.
    /// This is the core fix for issues 1 & 2: open a fresh window *here* instead of
    /// being yanked to the other desktop.
    case windowElsewhere

    /// A real window exists, but its desktop cannot be established safely.
    case windowUnknown

    /// Has a window on the current desktop. `mode` is how that window is presented;
    /// only the dock-click toggle reads it — the launch decision focuses the window
    /// regardless of mode.
    case windowHere(windowID: CGWindowID, pid: pid_t, mode: WindowMode)

    /// How an on-this-desktop window is currently presented to the user. Separated
    /// out so the front↔minimize toggle is a switch over named cases rather than a
    /// `isMinimized ? … : (isFrontmost ? … : …)` ternary chain.
    public enum WindowMode: Equatable, Sendable, CustomStringConvertible {
        /// Up, and its app is frontmost — a dock click minimizes it.
        case active
        /// Up, but another app is in front — a dock click raises it.
        case inactive
        /// Tucked into the Dock — a dock click always restores it.
        case minimized
        /// App-hidden via ⌘H — a dock click brings it back.
        case hidden

        public var description: String {
            switch self {
            case .active: return "active"
            case .inactive: return "inactive"
            case .minimized: return "minimized"
            case .hidden: return "hidden"
            }
        }
    }
}

extension AppState {
    /// Classify a target's state from a pure snapshot — the one place the raw
    /// window/space facts get folded into a single named state.
    ///
    /// `frontmostPID` is the only live fact a snapshot can't carry (which app owns
    /// the keyboard). Pass it when the caller needs the `windowHere` *mode* — i.e.
    /// for the dock-click toggle. Omit it for the plain launch decision, which
    /// ignores the mode; a window here is `.inactive` by default then, which is fine
    /// because launch treats every `windowHere` the same way (focus it).
    /// `currentSpace` is the desktop to treat as "here". It defaults to the active
    /// (menu-bar) display's Space, but a per-display dock passes *its own* display's
    /// visible Space — so clicking a second screen's dock judges the app against that
    /// screen's desktop, not the menu bar's. Without it, an app open only on the
    /// menu-bar screen read as `windowHere` for a click on the *other* screen's dock,
    /// so the click toggled (minimized) it instead of opening a window on that screen.
    public static func classify(
        target: AppTarget, snapshot: SpaceSnapshot, frontmostPID: pid_t? = nil,
        currentSpace: SpaceID? = nil, display: CGRect? = nil
    ) -> AppState {
        // A window on the current Space wins outright — that's the "here" state.
        let hereWindows = snapshot.windows(of: target).filter { $0.isVisible(onSpace: currentSpace ?? snapshot.activeSpaceID, display: display) }
        // Prefer a window that is on screen; otherwise the first one here, so an app
        // whose windows are all minimized or hidden stays restorable.
        if let here = hereWindows.first(where: { $0.isOnscreen }) ?? hereWindows.first {
            return .windowHere(windowID: here.windowID, pid: here.pid,
                               mode: mode(of: here, frontmostPID: frontmostPID))
        }
        // A *real* window exists, just not here → it's on another Space. We test
        // `realWindows`, not all windows: an off-screen window on no desktop (empty
        // `spaceIDs`, what an app like Claude leaves after you ✕ its last window)
        // must not masquerade as "open on another desktop" — that mistake routed
        // a windowless instance to `.newInstance` and piled up copies.
        if snapshot.realWindows(of: target).contains(where: {
            $0.spaceIDs.isEmpty || !$0.spaceMembershipKnown
                || (display != nil && $0.isOn(currentSpace ?? snapshot.activeSpaceID)
                    && ($0.bounds.width <= 0 || $0.bounds.height <= 0))
        }) {
            return .windowUnknown
        }
        if !snapshot.realWindows(of: target).isEmpty {
            return .windowElsewhere
        }
        // No real window anywhere (none, or only leftovers), but the process is alive
        // → running window-less: the ordinary first-window path reopens this
        // instance rather than applying an additional-window strategy.
        if snapshot.isRunning(target) {
            return .runningWindowless
        }
        return .notRunning
    }

    /// Map a here-window's snapshot flags to a `WindowMode`. Minimized and hidden are
    /// off-screen presentations that take priority; otherwise frontmost ownership
    /// decides active vs. inactive.
    private static func mode(of window: WindowInfo, frontmostPID: pid_t?) -> WindowMode {
        if window.isMinimized { return .minimized }
        if window.isHidden { return .hidden }
        // An app can own the menu bar while its window is still off-screen and
        // absent from AX. That click must restore/focus, not minimize again.
        return window.isOnscreen && frontmostPID == window.pid ? .active : .inactive
    }

    /// A short, secret-free label for logs (e.g. `windowHere(active)`,
    /// `windowElsewhere`). Carries no window titles or user content — only the state
    /// name — so it's safe to emit to the unified log.
    public var label: String {
        switch self {
        case .notRunning: return "notRunning"
        case .runningWindowless: return "runningWindowless"
        case .windowElsewhere: return "windowElsewhere"
        case .windowUnknown: return "windowUnknown"
        case let .windowHere(_, _, mode): return "windowHere(\(mode))"
        }
    }
}
