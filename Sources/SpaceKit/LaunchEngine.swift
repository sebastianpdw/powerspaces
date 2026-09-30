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
    /// No real windows — open or reopen the app normally, reusing its process.
    case launchApp
    /// App runs only on other Spaces — make a new window here via this strategy.
    case newWindow(StrategyKind)
    case warnUnknown
}

/// What a *dock click* should do — adds the front↔minimize toggle on top of the
/// smart-launch decision. Pure data, so it's unit-testable.
public enum DockClickAction: Equatable, Sendable {
    case raise(windowID: CGWindowID, pid: pid_t)
    case minimize(windowID: CGWindowID, pid: pid_t)
    case launch
    case newWindow(StrategyKind)
    case warnUnknown
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
        case .warnUnknown:
            return .warnUnknown
        case .launchApp:
            return .launch
        case let .newWindow(kind):
            return .newWindow(kind)
        }
    }

    public static func dockClick(state: AppState, config: StrategyConfig,
                                 target: AppTarget, forceNew: Bool) -> DockClickAction {
        if case let .windowHere(id, pid, mode) = state, !forceNew {
            switch mode {
            case .active: return .minimize(windowID: id, pid: pid)
            case .inactive, .hidden, .minimized: return .raise(windowID: id, pid: pid)
            }
        }
        return dockClick(decision: decide(state: state, config: config, target: target, forceNew: forceNew),
                         isFrontmost: false)
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
        case .windowUnknown:
            return .warnUnknown
        // First-window opening is the same operation whether the app's process
        // already exists or not. Additional-window strategies must not turn a
        // windowless app into a background-only launch, duplicate or quit request.
        case .notRunning, .runningWindowless:
            return .launchApp
        // Only apps with an existing window need an additional-window strategy.
        case .windowElsewhere, .windowHere:
            return .newWindow(config.strategy(for: target.bundleID))
        }
    }
}
