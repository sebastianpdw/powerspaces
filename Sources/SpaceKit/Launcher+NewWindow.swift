// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// New-window strategies: the per-app dispatch (`newWindow`) and the multi-display
/// "land the fresh window on the screen the user is on" placement.
extension Launcher {
    func newWindow(_ target: AppTarget, kind: StrategyKind, snapshot: SpaceSnapshot,
                   preferredDisplay: CGRect? = nil) -> LaunchOutcome {
        // Windows of this app that already exist, so we can spot the one we're
        // about to create and make sure it opens on the screen the user is on
        // (and on the desktop the user is on — see `placeNewWindowHere`).
        let existing = Set(snapshot.windows(of: target).map(\.windowID))
        switch kind {
        case .newInstance:
            // Pick the route by whether the app owns a *real* window anywhere:
            //
            // • None — only spaceless phantoms, or nothing at all (the runningWindowless
            //   case: an Electron app like Claude after you ✕ its last window leaves an
            //   idle, window-less copy). Reuse that copy with `open -a` (no -n): it
            //   reactivates the existing instance and its reopen handler makes a window,
            //   which lands on the current Space because there's no other window to pull
            //   focus elsewhere. Spawning a `-n` instance here instead would orphan the
            //   ghost and stack up processes — the Claude pile-up bug.
            //
            // • A real window on another desktop (windowElsewhere), or `forceNew` over a
            //   here-window (both have a real window). Activating would yank us to that
            //   window's Space, so launch a fresh instance in the *background*
            //   (`open -n -g`); `focus` below raises just the new window, which is on the
            //   current Space, so focusing it never switches desktops. This is the
            //   no-yank, no-SIP fix for apps that keep windows on other desktops.
            let hasRealWindow = !snapshot.realWindows(of: target).isEmpty
            openApp(target, newInstance: hasRealWindow, background: hasRealWindow)
            // Raise the fresh window, but for a *genuine second instance* (hasRealWindow:
            // the app already owns a window on another desktop) do NOT activate its
            // process. Activating a second Claude instance makes it hand off to the
            // primary and close the new window ~8 s later — "opens briefly then closes".
            // Raising via Accessibility brings the window forward without that trigger;
            // it's on the current Space, so it stays visible. The reuse path (a single
            // windowless instance) keeps activation — there's no duplicate to hand off to.
            let appeared = placeNewWindowHere(target, existing: existing,
                                              preferredDisplay: preferredDisplay,
                                              focus: true, activateApp: !hasRealWindow)
            return appeared ? .newWindow(.newInstance) : newWindowDidNotAppear(target)
        case .openArgs:
            openWithArgs(target, args: config.args(for: target.bundleID))
            let appeared = placeNewWindowHere(target, existing: existing, preferredDisplay: preferredDisplay)
            return appeared ? .newWindow(.openArgs) : newWindowDidNotAppear(target)
        case .appleScript:
            // Finder is special. After a "quit (all desktops)" macOS auto-relaunches
            // it and restores a stray window on whatever Space it was on (so it is
            // NOT window-less), then `make new Finder window` either lags or opens
            // the window onto that restored Space — not the one you're standing on.
            // The Apple event returns success either way, so the first dock click
            // flips the menu bar to Finder but lands no window here and you click
            // again. Use a route that reliably puts a window on the *current* Space
            // and wait for it to actually arrive.
            if target.bundleID == "com.apple.finder" {
                makeNewFinderWindowHere(target)
                return .newWindow(.appleScript)
            }
            let ran = config.appleScript(for: target.bundleID).map(runAppleScript) ?? false
            if !ran {
                // No script, or the app refused the Apple event — almost always
                // -1743 (errAEEventNotPermitted): powerspaces hasn't been granted
                // Automation control of the app, so `make new window` silently did
                // nothing. Without a fallback the activate below is all that fires:
                // the app shows in the menu bar, but no window appears. Recover via
                // a route that needs no Automation consent.
                appleScriptFallback(target)
            }
            activate(target)
            let appeared = placeNewWindowHere(target, existing: existing, preferredDisplay: preferredDisplay)
            return appeared ? .newWindow(.appleScript) : newWindowDidNotAppear(target)
        case .warn:
            return warned(target, "is already open on another desktop — switch desktops to use it.")
        case .quitReopen:
            return quitReopen(target)
        case .cmdN:
            activate(target)
            postCmdN()
            let appeared = placeNewWindowHere(target, existing: existing, preferredDisplay: preferredDisplay)
            return appeared ? .newWindow(.cmdN) : newWindowDidNotAppear(target)
        case .focusOnly:
            // No new window by design — just activate and accept the jump to the
            // app's Space, so there's nothing to detect or warn about here.
            activate(target)
            return .newWindow(.focusOnly)
        }
    }

    /// A window-making strategy ("Open a new window") fired but no window ever
    /// appeared — the case the user hits with apps like GitHub Desktop, which
    /// quietly refuse a second window so the click looks dead. macOS gives us no
    /// reliable way to force a window for such single-instance apps, so rather than
    /// pretend it worked, warn and point the user at switching desktops. (If a given
    /// app never opens a window here, right-click → "When open elsewhere" →
    /// "Show a warning" silences the dead click.)
    func newWindowDidNotAppear(_ target: AppTarget) -> LaunchOutcome {
        warned(target, "is open on another desktop and “Open a new window” didn’t work for it — "
               + "switch desktops to use it.")
    }

    // MARK: - Land the fresh window on the current desktop

    /// After a new-window strategy fires, bring the fresh window onto the desktop
    /// the user is standing on.
    ///
    /// On a multi-display setup it moves the window onto the active (or
    /// `preferredDisplay`) screen: apps like Firefox open `--new-window` on
    /// whichever screen they last used, and macOS then files it under *that*
    /// display's Space, so it looks like the window jumped desktops.
    /// `preferredDisplay` (the bounds of the dock's display) overrides the default
    /// "active display" target, so clicking a given screen's dock opens the window
    /// on *that* screen even when the menu bar lives elsewhere.
    ///
    /// When `focus` is set it raises the fresh window forward. `activateApp`
    /// (default true) additionally makes the app frontmost; pass `false` for a
    /// freshly-spawned *second* instance that must be raised but not activated (see
    /// `raise`), so it isn't pulled to where the app's other windows live and — for a
    /// single-window app like Claude — isn't induced to hand off and close. Either way
    /// the window is on the current Space, so raising it never switches desktops.
    ///
    /// Only ever acts on a *real* window that landed on the current Space: a window
    /// the app parked on another Space, or an off-screen placeholder "phantom"
    /// (empty `spaceIDs`, so not `isOn` the active Space), is skipped — so we never
    /// reposition or focus the wrong one. Best-effort: it needs a fresh window to
    /// appear within ~2 s, and the display move additionally needs Accessibility
    /// and a readable layout.
    ///
    /// Returns whether the strategy produced a window at all. `false` means no fresh
    /// window appeared anywhere within the timeout — the signal that "Open a new
    /// window" silently failed for this app (e.g. a single-instance app that refuses
    /// a second window), so the caller can warn instead of pretending it worked.
    @discardableResult
    func placeNewWindowHere(_ target: AppTarget, existing: Set<CGWindowID>,
                            preferredDisplay: CGRect? = nil, focus: Bool = false,
                            activateApp: Bool = true) -> Bool {
        let trusted = WindowAX.isTrusted
        let displays = trusted ? DisplayInfo.allDisplayBounds() : []
        let active = preferredDisplay ?? DisplayInfo.activeDisplayBounds()
        let needsMove = trusted && displays.count > 1 && active != nil

        // The window may take a beat to exist; poll briefly for a fresh window of the
        // target that landed on the current Space, then act on it once. We always
        // poll now (even single-display, no-focus, where there's nothing to move or
        // raise) so the return value can tell whether a window ever showed up.
        let placedHere = pollUntil(timeout: 2.0, interval: 80_000) {
            guard let snapshot = try? provider.snapshot(),
                  let fresh = snapshot.windows(of: target).first(where: {
                      !existing.contains($0.windowID) && $0.isOn(snapshot.activeSpaceID)
                  })
            else { return false }
            // Multi-display: move it onto the screen the user is on. A freshly-launched
            // window's Accessibility element lags the window-server list, so if we can't
            // read its frame yet, keep polling rather than abandoning the move (which
            // left a cold-launched app on the OS default screen, not the dock's screen).
            if needsMove, let active {
                guard let axWindow = WindowAX.axWindow(windowID: fresh.windowID, pid: fresh.pid),
                      let frame = WindowAX.frame(of: axWindow) else { return false }
                if let moved = DisplayPlacement.reposition(window: frame, displays: displays, active: active) {
                    WindowAX.setFrame(moved, of: axWindow)
                }
            }
            // Bring the new window forward (it's on the current Space → no yank).
            if focus { raise(windowID: fresh.windowID, pid: fresh.pid, activateApp: activateApp) }
            return true
        }
        if placedHere { return true }

        // Nothing reached the current Space within the timeout. On a multi-display
        // setup the app may still have opened the window on another screen's Space —
        // that counts as "worked", just placed elsewhere. Only when NO fresh window
        // exists anywhere did the strategy truly fail. If we can't read the window
        // world, assume success so we never warn spuriously.
        guard let snapshot = try? provider.snapshot() else { return true }
        return snapshot.windows(of: target).contains { !existing.contains($0.windowID) }
    }

    // MARK: - Quit the app entirely, then relaunch on the current Space

    /// `quitReopen`: quit the whole app and relaunch it. A cold launch puts the new
    /// window on the current Space — the engine's normal "launch lands here"
    /// behaviour — so this is the one strategy that reliably brings a stubborn
    /// single-window app (System Settings and the like) to the desktop you're on.
    /// No Accessibility, no SIP. We only get here when the app has NO window on the
    /// current Space (decide() would have focused one otherwise), so quitting can't
    /// destroy a window the user is looking at — but it does drop the app's transient
    /// state, which is why it's opt-in and the UI confirms first.
    private func quitReopen(_ target: AppTarget) -> LaunchOutcome {
        guard let bundleID = target.bundleID else {
            openApp(target, newInstance: false)
            return .launched
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else {
            openApp(target, newInstance: false)
            return .launched
        }
        for app in running { app.terminate() }
        // terminate() is async; wait for the process to actually exit (≤2 s) so the
        // relaunch is a true cold start whose window lands here — otherwise
        // `open -a` would just reactivate the dying instance and jump to its Space.
        pollUntil(timeout: 2.0, interval: 50_000) {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .allSatisfy { $0.isTerminated }
        }
        openApp(target, newInstance: false)
        return .reopenedOnCurrentSpace
    }
}
