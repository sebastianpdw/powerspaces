// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Low-level side-effecting primitives the strategies compose: focusing windows
/// (`raise` / `minimize`), launching apps (`coldLaunch` / `openApp` /
/// `openWithArgs` / `activate`), and the raw process / AppleScript / key-event
/// calls underneath them.
extension Launcher {
    // MARK: - Focus an exact window on the current Space

    /// Bring an exact window forward. `activateApp` (default true) also makes the
    /// owning process frontmost. Pass `false` to raise the window *without* process
    /// activation: a freshly-spawned *second* instance of a single-window Electron app
    /// (Claude) treats being activated as "I'm a duplicate", hands off to the primary
    /// instance and closes its own window ~8 s later (the "opens briefly then closes"
    /// bug). For that one path we raise the window via Accessibility but never call
    /// `activate()`; the window is already on the current Space, so it's still visible.
    func raise(windowID: CGWindowID, pid: pid_t, activateApp: Bool = true) {
        // Pull the window out of the Dock and bring it forward. `unminimize` first
        // because kAXRaiseAction does nothing to a minimized window.
        func tryRaise() -> Bool {
            guard let axWindow = WindowAX.axWindow(windowID: windowID, pid: pid) else { return false }
            WindowAX.unminimize(axWindow)
            return AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString) == .success
        }
        var raised = tryRaise()
        // The window is on the current Space, so activating does not jump away. Skipped
        // for a fresh second instance (`activateApp == false`) so it isn't induced to
        // hand off and close its window.
        if activateApp { NSRunningApplication(processIdentifier: pid)?.activate() }
        // Right after a "quit (all desktops)" relaunch, Finder restores its window
        // but its AX element isn't ready for a beat — the lookup above misses, so
        // we'd only activate the app (menu bar flips to Finder) without the window
        // ever coming forward, forcing a second click. Poll briefly and raise it
        // for real once it materializes.
        if !raised {
            let deadline = Date().addingTimeInterval(1.5)
            while !raised && Date() < deadline {
                usleep(80_000) // 80 ms
                raised = tryRaise()
            }
        }
    }

    func minimize(windowID: CGWindowID, pid: pid_t) {
        if WindowAX.isTrusted, let axWindow = WindowAX.axWindow(windowID: windowID, pid: pid) {
            WindowAX.minimize(axWindow)
        } else {
            NSRunningApplication(processIdentifier: pid)?.hide() // fallback without Accessibility
        }
    }

    // MARK: - Open / new-window helpers

    /// Cold launch of a not-running app. For most apps `open -a` is enough, but
    /// Finder is the exception: the app quits it with a graceful `terminate()`,
    /// after which macOS does NOT auto-relaunch it (unlike a crash/kill), so the
    /// next dock click really is a cold launch — and `open -a Finder` brings Finder
    /// up window-less (it only restores old windows, which may be on other Spaces).
    /// That's the "menu bar flips to Finder but no window" first click. Opening a
    /// folder launches Finder AND lands a window on the *current* Space, and needs
    /// no Accessibility, so it works even right after a reinstall resets TCC.
    func coldLaunch(_ target: AppTarget, preferredDisplay: CGRect? = nil) -> LaunchOutcome {
        // The app's windows before we launch (empty for a truly-closed app), so the
        // placement below can pick out the fresh one.
        let existing = Set(((try? provider.snapshot())?.windows(of: target) ?? []).map(\.windowID))
        // macOS can't open a new window directly on a chosen screen — it lands on the
        // active (menu-bar) display, then we move it. On a multi-display setup launch
        // in the *background* (`-g`) so the window doesn't flash to the front on the
        // wrong screen first; `placeNewWindowHere(focus:)` then moves it and brings it
        // to the front on the dock's screen, so the user mostly just sees it appear
        // there. Single-display: activate immediately (there's nothing to move).
        let deferActivation = WindowAX.isTrusted && DisplayInfo.allDisplayBounds().count > 1
        if target.bundleID == "com.apple.finder" {
            openNewFinderWindow()
            if !deferActivation { activate(target) }
        } else {
            openApp(target, newInstance: false, background: deferActivation)
        }
        // Land the fresh window on the dock's screen (multi-display), same as
        // `newWindow`. Without this a cold launch opened on the OS default screen, so
        // clicking a *closed* app in a second screen's dock opened it on the main one.
        placeNewWindowHere(target, existing: existing, preferredDisplay: preferredDisplay, focus: true)
        return .launched
    }

    /// `background` adds `open -g` — launch *without* activating the app. The
    /// `.newInstance` path uses it so summoning an app that's already open on
    /// another desktop doesn't pull its existing window (and us) to that desktop;
    /// the caller then raises just the fresh window, which is on the current Space.
    func openApp(_ target: AppTarget, newInstance: Bool, background: Bool = false) {
        guard let url = AppResolver.appURL(for: target) else {
            warn("could not find application for \(target.bundleID ?? target.name ?? "?")")
            return
        }
        // Shell out to /usr/bin/open synchronously — NSWorkspace.openApplication
        // is async and never dispatches from a short-lived CLI before it exits.
        var arguments = ["-a", url.path]
        if newInstance { arguments.insert("-n", at: 0) }
        if background { arguments.insert("-g", at: 0) }
        runProcess(URL(fileURLWithPath: "/usr/bin/open"), arguments, wait: true)
    }

    /// Run the app's own executable with `args` (e.g. browsers' `--new-window`).
    func openWithArgs(_ target: AppTarget, args: [String]) {
        guard let url = AppResolver.appURL(for: target),
              let executable = Bundle(url: url)?.executableURL else {
            openApp(target, newInstance: true)
            return
        }
        runProcess(executable, args, wait: false)
    }

    func activate(_ target: AppTarget) {
        if let bundleID = target.bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
        } else {
            openApp(target, newInstance: false)
        }
    }

    func runProcess(_ executable: URL, _ arguments: [String], wait: Bool) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        do {
            try process.run()
            if wait { process.waitUntilExit() }
        } catch {
            warn("failed to run \(executable.lastPathComponent): \(error)")
        }
    }

    /// Runs the snippet and reports whether it executed cleanly. Returns false on
    /// any error so the caller can fall back — the common failure is -1743
    /// (errAEEventNotPermitted), where the app silently ignores the event because
    /// powerspaces lacks Automation control of it.
    @discardableResult
    func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else {
            Log.error("AppleScript could not be compiled (malformed source)")
            return false
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            // Surface the real reason (error number + message) so a -1743
            // "not permitted" can be told apart from a script/app error instead of
            // every failure looking the same. No user data is logged.
            let number = error[NSAppleScript.errorNumber] ?? "?"
            let message = error[NSAppleScript.errorMessage] ?? "unknown error"
            Log.error("AppleScript failed (\(number)): \(message)")
            return false
        }
        return true
    }

    func postCmdN() {
        let source = CGEventSource(stateID: .hidSystemState)
        let nKey: CGKeyCode = 0x2D // 'n'
        let down = CGEvent(keyboardEventSource: source, virtualKey: nKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: nKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
