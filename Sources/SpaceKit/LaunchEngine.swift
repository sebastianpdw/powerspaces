// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation

/// What a smart-launch should *do*. Pure data — no side effects — so the
/// decision is fully unit-testable.
public enum LaunchDecision: Equatable, Sendable {
    /// App has a window on the current Space — raise that exact window.
    case focusWindow(windowID: CGWindowID, pid: pid_t)
    /// App isn't running at all — just open it; first window lands here.
    case launchApp
    /// App runs only on other Spaces — make a new window here via this strategy.
    case newWindow(StrategyKind)
}

/// What a *dock click* should do — adds the front↔minimize toggle on top of the
/// smart-launch decision. Pure data, so it's unit-testable.
public enum DockClickAction: Equatable, Sendable {
    case raise(windowID: CGWindowID, pid: pid_t)
    case minimize(windowID: CGWindowID, pid: pid_t)
    case launch
    case newWindow(StrategyKind)
}

/// The heart of powerspaces: decide how to honor "open this app on the desktop
/// I'm standing on" given a snapshot of the window/space world.
///
/// Both decisions are **transition tables over `AppState`**: classify the app's
/// state once (see `AppState.classify`), then `switch` over it. The engine never
/// re-tests a tangle of booleans — the state has already named which case we're in.
public enum LaunchEngine {
    /// Dock-click behavior: if the app's window is here and it's already the
    /// frontmost app, minimize it; otherwise bring it to front. A window that's
    /// minimized or app-hidden always restores, so the raise↔minimize cycle keeps
    /// working on repeated clicks. Falls back to the smart-launch decision for
    /// launch / new-window.
    ///
    /// Kept on the `(decision, isFrontmost, isMinimized)` signature its callers and
    /// tests already use, but the body now lifts those live flags into the engine's
    /// `WindowMode` vocabulary and reads the toggle straight off the named mode — so
    /// "Finder stays frontmost with its last window minimized" is just the
    /// `.minimized` case, not a special-cased `if` ahead of the frontmost check.
    public static func dockClick(
        decision: LaunchDecision, isFrontmost: Bool, isMinimized: Bool = false
    ) -> DockClickAction {
        switch decision {
        case let .focusWindow(windowID, pid):
            let mode: AppState.WindowMode =
                isMinimized ? .minimized : (isFrontmost ? .active : .inactive)
            switch mode {
            case .active:
                return .minimize(windowID: windowID, pid: pid)
            case .inactive, .minimized, .hidden:
                return .raise(windowID: windowID, pid: pid)
            }
        case .launchApp:
            return .launch
        case let .newWindow(kind):
            return .newWindow(kind)
        }
    }

    /// Smart-launch decision from a target + snapshot (classifies, then maps the
    /// state). Kept for the CLI and tests that call it directly; the app path
    /// classifies once itself and calls `decide(state:…)` so the state can be logged.
    public static func decide(
        target: AppTarget,
        snapshot: SpaceSnapshot,
        config: StrategyConfig,
        forceNew: Bool
    ) -> LaunchDecision {
        decide(state: AppState.classify(target: target, snapshot: snapshot),
               config: config, target: target, forceNew: forceNew)
    }

    /// The smart-launch transition table: one named state in, one pure decision out.
    /// `forceNew` (shift/option, or the CLI `--new`) is the only modifier — it turns
    /// a window that's *here* into a fresh-window request instead of a focus.
    public static func decide(
        state: AppState,
        config: StrategyConfig,
        target: AppTarget,
        forceNew: Bool
    ) -> LaunchDecision {
        switch state {
        // A window already here → focus that exact window (no Space switch), unless
        // the caller explicitly asked for a brand-new window.
        case let .windowHere(windowID, pid, _) where !forceNew:
            return .focusWindow(windowID: windowID, pid: pid)
        // Truly not running → plain cold launch; its first window lands here.
        case .notRunning:
            return .launchApp
        // Running only elsewhere, alive but window-less, or a forced new window over
        // one that's already here → a fresh window on this desktop via the app's
        // configured strategy (which is what puts the window on the current Space).
        case .windowElsewhere, .runningWindowless, .windowHere:
            return .newWindow(config.strategy(for: target.bundleID))
        }
    }
}
