// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension Launcher {
    func newWindow(_ target: AppTarget, kind: StrategyKind, snapshot: SpaceSnapshot,
                   context: LaunchContext) -> LaunchOutcome {
        guard context.isCurrent(snapshot: snapshot, displays: provider.displays()), !NativeInteraction.isActive else {
            return warned(target, "the desktop changed or the mouse button was held down — try again.")
        }
        let existing = Set(snapshot.windows(of: target).map(\.windowID))
        var activateApp = true
        switch kind {
        case .newInstance:
            guard openApp(target, newInstance: true, background: true, context: context) else { return warned(target, "could not be opened.") }
            activateApp = false
        case .openArgs:
            guard openWithArgs(target, args: config.args(for: target.bundleID), context: context) else { return warned(target, "could not be opened.") }
        case .appleScript:
            let ran = config.appleScript(for: target.bundleID).map(runAppleScript) ?? false
            if !ran {
                guard target.bundleID == "com.apple.finder", openNewFinderWindow() else {
                    return warned(target, "could not create a window. Check its Automation permission.")
                }
            }
        case .warn:
            return warned(target, "is already open on another desktop — switch desktops to use it.")
        case .quitReopen:
            return quitReopen(target, context: context)
        case .cmdN:
            guard postCmdN(to: target, context: context) else { return warned(target, "could not safely send New Window to that app.") }
        case .focusOnly:
            return activate(target) ? .focused : warned(target, "could not be activated.")
        }
        if placeNewWindowHere(target, existing: existing, context: context, focus: true, activateApp: activateApp) {
            return .newWindow(kind)
        }
        return newWindowDidNotAppear(target)
    }

    func newWindowDidNotAppear(_ target: AppTarget) -> LaunchOutcome {
        warned(target, "no new window was confirmed on the requested desktop. The app may have refused or opened it elsewhere. "
            + "Tip: right-click its icon in the dock and try another New-window strategy.")
    }

    /// Only a fresh window on a currently visible desktop is eligible for an AX
    /// display move. Old windows and windows on hidden Spaces are never moved.
    func placeNewWindowHere(_ target: AppTarget, existing: Set<CGWindowID>,
                            context: LaunchContext, focus: Bool = false, activateApp: Bool = true) -> Bool {
        pollUntil(timeout: 2.0, interval: 80_000) {
            guard !NativeInteraction.isActive, let snapshot = try? provider.snapshot(of: target) else { return false }
            let displays = provider.displays()
            guard context.isCurrent(snapshot: snapshot, displays: displays) else { return false }
            let fresh = snapshot.windows(of: target).filter { !existing.contains($0.windowID) && $0.isReal }
            if let here = fresh.first(where: { $0.isVisible(onSpace: context.spaceID, display: context.displayBounds) }) {
                if focus, raise(windowID: here.windowID, pid: here.pid, activateApp: activateApp, context: context) == .failed {
                    warn("A new \(displayName(for: target)) window appeared here. \(displayName(for: target)) \(raiseFailureMessage())")
                }
                return true
            }
            guard WindowAX.isTrusted, let bounds = context.displayBounds,
                  let window = fresh.first(where: { candidate in
                      candidate.isOnscreen && displays.contains { candidate.isVisible(onSpace: $0.currentSpaceID, display: $0.bounds) }
                  }), let ax = WindowAX.axWindow(windowID: window.windowID, pid: window.pid),
                  let frame = WindowAX.frame(of: ax),
                  let moved = DisplayPlacement.reposition(window: frame, displays: displays.map(\.bounds), active: bounds)
            else { return false }
            WindowAX.setFrame(moved, of: ax)
            // Confirm membership/geometry on a later observation, not setFrame's request.
            return false
        }
    }

    private func quitReopen(_ target: AppTarget, context: LaunchContext) -> LaunchOutcome {
        guard let bundleID = target.bundleID else { return warned(target, "needs a bundle ID for quit and reopen.") }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        Log.notice("Quit requested: app=\(bundleID) reason=quit-reopen pids=\(running.map(\.processIdentifier)) space=\(context.spaceID)")
        guard let outcome = QuitCoordinator.reopen(running, timeout: 2.0, open: { openFirstWindow(target, context: context) }) else {
            return warned(target, "has not finished quitting — reopen cancelled so you can resolve its dialogs.")
        }
        if case .launched = outcome { return .reopenedOnCurrentSpace }
        return outcome
    }
}
