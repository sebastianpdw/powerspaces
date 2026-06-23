// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices

/// Manages the app's Accessibility (AX) permission — the one Powerspaces needs to
/// close or minimize windows and read window titles. The common failure mode for a
/// frequently-rebuilt, *unsigned* app (which this is — see `make-app.sh`) is a
/// **stale TCC grant**: macOS keys the Accessibility approval to the app's code
/// identity, so every rebuild produces a binary the old grant no longer matches.
/// System Settings still shows the toggle on, yet `AXIsProcessTrusted()` returns
/// false — so "Quit (this desktop)" and friends warn "needs Accessibility" even
/// though the user already enabled it.
///
/// The cure is `tccutil reset Accessibility <bundle id>`, which clears every grant
/// for the bundle so the app can be re-added fresh. We then relaunch, because a cold
/// start re-prompts and re-evaluates trust cleanly. We drive the command-line
/// `tccutil` (the same thing a user would type by hand) rather than a private API,
/// so the behaviour is transparent and trivially reproducible from a terminal. The
/// app isn't sandboxed (it already uses private CGS APIs), so spawning it is allowed.
enum AccessibilityPermission {
    /// The app's bundle identifier, used to scope the TCC reset. Falls back to the
    /// known id when running unbundled (`swift run`), where `Bundle.main` has none.
    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "nl.sebastianpdw.powerspaces"
    }

    /// Whether macOS currently trusts this process for Accessibility. Read live each
    /// time, since a reset (or a grant in System Settings) changes it underneath us.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask macOS to show its Accessibility prompt (the dialog with an "Open System
    /// Settings" button) when we're not already trusted. A no-op when already
    /// granted. Used by the first-run welcome window and the cold-launch path.
    static func prompt() {
        // `kAXTrustedCheckOptionPrompt` imports as a mutable global (`CFString`),
        // which trips strict-concurrency checking. Its value is the stable,
        // documented key string, so use the literal directly to stay clean.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Clear the app's Accessibility approval from macOS's TCC database, dropping any
    /// stale entry left by an earlier build. Returns true on success. Doesn't need
    /// sudo: it only touches the current user's permissions.
    @discardableResult
    static func reset() -> Bool {
        run("/usr/bin/tccutil", ["reset", "Accessibility", bundleID])
    }

    /// Open System Settings straight to Privacy & Security ▸ Accessibility, where the
    /// user re-approves Powerspaces after a reset.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Quit and relaunch the app so the fresh process re-requests Accessibility and
    /// re-evaluates trust. A detached shell waits for our PID to exit before
    /// reopening — otherwise macOS sees the still-live instance and just foregrounds
    /// it instead of launching a new one. Only the bundled `.app` can be reopened
    /// this way; unbundled (`swift run`) we just terminate.
    @MainActor static func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { NSApp.terminate(nil); return }
        let pid = ProcessInfo.processInfo.processIdentifier
        // The script is a fixed literal; the pid and bundle path are passed as
        // positional parameters ($1, $2), NOT interpolated into the script text —
        // so a bundle path containing shell metacharacters can't break out of it.
        // (`sh -c <script> <argv0> <arg1> <arg2>` binds $0=argv0, $1=arg1, $2=arg2.)
        let script = #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done; exec /usr/bin/open "$2""#
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "powerspaces-relaunch", String(pid), path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Confirm with the user, clear the stale grant, and relaunch — or explain the
    /// manual `tccutil` line if the reset fails, so they're never left stuck. Shared
    /// by the status-menu item and the Preferences ▸ System reset row, so the copy
    /// and the flow live in exactly one place.
    @MainActor static func confirmResetAndRelaunch() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset Accessibility permission?"
        alert.informativeText = """
            This clears Powerspaces' Accessibility approval from macOS, then relaunches the \
            app so you can grant it fresh. Use it when you've enabled Accessibility but window \
            actions still say it's missing, usually after rebuilding or reinstalling.

            After the relaunch, switch Powerspaces back on in System Settings ▸ Privacy & \
            Security ▸ Accessibility.
            """
        alert.addButton(withTitle: "Reset & Relaunch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performResetAndRelaunch()
    }

    /// Clear the stale grant and relaunch, surfacing a manual-`tccutil` fallback alert
    /// if the reset fails so the user is never left stuck. The shared core behind both
    /// the Preferences/menu "reset" row (which confirms first, via
    /// `confirmResetAndRelaunch`) and the launch-time accessibility-repair popup (which
    /// is itself the confirmation, so it calls this directly).
    @MainActor static func performResetAndRelaunch() {
        guard reset() else {
            let fail = NSAlert()
            fail.alertStyle = .critical
            fail.messageText = "Couldn't reset the permission"
            fail.informativeText = "Running tccutil failed. Reset it manually in Terminal:\n\n"
                + "tccutil reset Accessibility \(bundleID)"
            fail.runModal()
            return
        }
        relaunch()
    }

    /// Run a command-line tool, swallowing its output, and report whether it exited
    /// cleanly. Synchronous: `tccutil` finishes in milliseconds.
    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
