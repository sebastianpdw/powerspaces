// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import ServiceManagement
import SpaceKit

/// Completely removes Powerspaces from the Mac, driven from Preferences ▸ System.
///
/// An uninstall has two jobs: **revert the system state** Powerspaces changed while
/// it ran (so quitting leaves the Mac exactly as it was), and **delete what it put on
/// disk** — the `powerspaces` CLI it installed for Raycast, the app bundle itself, and
/// (optionally) its settings/data. The caller chooses whether to keep the settings: a
/// reinstall reads them back from the same fixed path, so "keep" makes a reinstall
/// restore everything, while "delete" wipes them too.
///
/// We split the work by *when* it has to happen:
///   • System-state reversions run **now**, while the app is still alive and owns the
///     relevant state (login-item registration, the Accessibility grant). The Dock and
///     the space-switch keyboard shortcut are already restored by
///     `AppDelegate.applicationWillTerminate`, which the final `NSApp.terminate` triggers.
///   • The on-disk deletions run **after we exit**: a detached `/bin/sh` waits for our
///     PID to drop, then `rm -rf`s each path — the only way to delete our *own* running
///     `.app` bundle cleanly. This mirrors `AccessibilityPermission.relaunch`'s PID-wait.
///   • Paths we can't delete without admin (a system-wide CLI in `/usr/local/bin`, or an
///     app in the system `/Applications`) are removed up front via a single `osascript`
///     admin prompt, so even a non-per-user install is fully cleaned with one password.
///
/// Like `AppleDockController`/`AccessibilityPermission`, we drive the same command-line
/// tools a user would type by hand (`rm`, `osascript`, `tccutil`) rather than private
/// APIs, so the teardown is transparent and reproducible from a terminal.
enum Uninstaller {
    /// The settings/data files that "Keep My Settings" preserves. They live at a fixed
    /// path independent of the app, so leaving them in place is all a future reinstall
    /// needs to restore everything. Everything *else* in the config dir (the working
    /// Raycast-extension copy, its `setup.command`, the import log) is install
    /// scaffolding and is removed either way.
    static var settingsFiles: [URL] {
        [PowerspacesPaths.preferencesFile, PowerspacesPaths.pinsFile,
         PowerspacesPaths.configFile, PowerspacesPaths.dockColorsFile]
    }

    /// The app bundle to delete, when running as a bundled `.app` (nil under `swift run`).
    static var appBundle: URL? {
        let bundle = URL(fileURLWithPath: Bundle.main.bundlePath)
        return bundle.pathExtension == "app" ? bundle : nil
    }

    /// The two `powerspaces` CLI install locations (per-user and system-wide).
    private static var cliURLs: [URL] {
        [RaycastSetup.CLILocation.userLocal.url, RaycastSetup.CLILocation.systemWide.url]
    }

    /// CLI install paths that currently exist — for the confirmation's bullet list.
    static var presentCLIPaths: [String] {
        cliURLs.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// One removable artifact. Deleting an item is a write to its *containing*
    /// directory, so that's what must be writable for an admin-free `rm`.
    struct Target {
        let url: URL
        var removableWithoutAdmin: Bool {
            FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
        }
    }

    /// Every path to delete for this uninstall, filtered to those that exist:
    ///   • the config dir — wholesale when deleting settings, or only its non-settings
    ///     contents when keeping them (so the settings JSONs survive for a reinstall),
    ///   • the `powerspaces` CLI at both install locations,
    ///   • the app bundle itself, when bundled.
    static func targets(keepPreferences: Bool) -> [Target] {
        let fm = FileManager.default
        var urls: [URL] = []
        let configDir = PowerspacesPaths.configDir
        if keepPreferences {
            // Delete the config dir's contents *except* the settings files, leaving a
            // tidy folder of just the JSONs a reinstall reads back.
            let keepNames = Set(settingsFiles.map(\.lastPathComponent))
            let children = (try? fm.contentsOfDirectory(
                at: configDir, includingPropertiesForKeys: nil)) ?? []
            urls += children.filter { !keepNames.contains($0.lastPathComponent) }
        } else {
            urls.append(configDir)
        }
        urls += cliURLs
        if let appBundle { urls.append(appBundle) }
        return urls.filter { fm.fileExists(atPath: $0.path) }.map { Target(url: $0) }
    }

    /// Whether removing this uninstall's targets needs an admin password (a CLI in
    /// `/usr/local/bin`, or an app in the system `/Applications`).
    static func needsAdmin(keepPreferences: Bool) -> Bool {
        targets(keepPreferences: keepPreferences).contains { !$0.removableWithoutAdmin }
    }

    /// Run the uninstall: revert system state, delete every present artifact (escalating
    /// only for the ones that need admin), then quit. Call this *after* the user has
    /// confirmed — it does not prompt on its own. `keepPreferences` leaves the settings
    /// JSONs in place so a reinstall restores them.
    @MainActor static func run(keepPreferences: Bool) {
        revertSystemState()

        let present = targets(keepPreferences: keepPreferences)
        let needAdmin = present.filter { !$0.removableWithoutAdmin }
        let noAdmin = present.filter { $0.removableWithoutAdmin }

        // Admin-locked paths (system-wide CLI, app in /Applications) go first, via one
        // password prompt while we're still alive — a running .app bundle can be removed
        // out from under itself; the process keeps running from memory until we quit.
        if !needAdmin.isEmpty {
            removeWithAdmin(needAdmin.map(\.url))
        }

        // Everything user-writable — including our own bundle when it's a per-user
        // install — is deleted by a detached shell once our PID exits.
        scheduleRemovalAfterExit(noAdmin.map(\.url))

        NSApp.terminate(nil)
    }

    /// Put back what Powerspaces changed about the system, beyond what quitting already
    /// restores. `applicationWillTerminate` (fired by the `NSApp.terminate` below) brings
    /// back Apple's Dock and the "Move left/right a space" shortcut, so here we only need
    /// the things tied to the app's identity: drop the login item, and clear the
    /// Accessibility grant so no stale TCC entry lingers after the app is gone.
    @MainActor private static func revertSystemState() {
        try? SMAppService.mainApp.unregister()
        AccessibilityPermission.reset()
    }

    /// Delete `urls` with one administrator prompt. Builds a single `rm -rf 'a' 'b' …`
    /// (each path POSIX-single-quoted) and runs it through `osascript … with
    /// administrator privileges`. Synchronous: it blocks on the auth dialog, and if the
    /// user cancels, the admin-locked paths simply stay (the rest of the uninstall still
    /// proceeds) — they were listed in the confirmation so this is a visible no-op.
    private static func removeWithAdmin(_ urls: [URL]) {
        let rm = "/bin/rm -rf " + urls.map { shQuote($0.path) }.joined(separator: " ")
        // AppleScript string literal: escape backslashes then double-quotes.
        let asLiteral = rm
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(asLiteral)\" with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run() } catch { return }
        task.waitUntilExit()
    }

    /// Spawn a detached `/bin/sh` that waits for our process to exit, then `rm -rf`s each
    /// path. The script is a fixed literal; the PID and paths are passed as positional
    /// parameters (`$1` = PID, then `"$@"` = paths) and never interpolated into the
    /// script text, so a path with shell metacharacters can't break out of it.
    @MainActor private static func scheduleRemovalAfterExit(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = #"""
            PID="$1"; shift
            while /bin/kill -0 "$PID" 2>/dev/null; do /bin/sleep 0.1; done
            for path in "$@"; do /bin/rm -rf "$path"; done
            """#
        // sh -c <script> <argv0> <argv1…>  →  $0=argv0, $1=argv1, …
        var args = ["-c", script, "powerspaces-uninstall", String(pid)]
        args.append(contentsOf: urls.map(\.path))
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = args
        try? task.run()
    }

    /// POSIX single-quote a string for safe interpolation into a shell command.
    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
