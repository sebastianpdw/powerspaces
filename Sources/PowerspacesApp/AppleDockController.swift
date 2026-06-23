// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Hides or restores Apple's built-in Dock, so the Powerspaces bar can stand in
/// for it. macOS has no real "off switch" for the Dock — `killall Dock` only makes
/// it respawn, and the process must keep running anyway (Mission Control, the
/// ⌘-Tab switcher and Stage Manager all rely on it). The established, fully
/// reversible trick is to force the Dock to auto-hide with an effectively infinite
/// reveal delay: it never slides into view, yet the process stays alive.
/// Re-enabling puts the user's own auto-hide setting back.
///
/// We drive `com.apple.dock` through the `defaults` / `killall` command-line tools
/// (the same thing a user would type by hand) rather than a private framework, so
/// the behaviour is transparent and trivially undoable from a terminal if anything
/// ever goes wrong. The app isn't sandboxed (it already uses private CGS APIs), so
/// spawning these tools is allowed.
enum AppleDockController {
    private static let domain = "com.apple.dock"
    /// A reveal delay (seconds) so long the Dock will never appear on its own.
    private static let infiniteDelay = "1000"

    /// Make the Apple Dock hidden or visible. The first time we hide it we record
    /// the user's original auto-hide value (into our own `Preferences`, not the dock
    /// domain, so it survives even a `defaults delete com.apple.dock`) and restore
    /// exactly that on re-enable. Each call rewrites the defaults and restarts the
    /// Dock, so only invoke it when the desired state actually changes.
    @MainActor static func apply(hidden: Bool) {
        if hidden {
            // Capture what the user had before we touched anything — but only the
            // first time, so re-applying after a relaunch doesn't record our own
            // forced value as if it were theirs.
            if Preferences.shared.appleDockAutohideBackup == nil {
                Preferences.shared.appleDockAutohideBackup = readAutohide()
            }
            write("autohide", "-bool", "true")
            write("autohide-delay", "-float", infiniteDelay)   // ~never reveals
            write("autohide-time-modifier", "-float", "0")     // no slide animation
        } else {
            // Drop our delay overrides and put auto-hide back the way we found it.
            delete("autohide-delay")
            delete("autohide-time-modifier")
            let original = Preferences.shared.appleDockAutohideBackup ?? false
            write("autohide", "-bool", original ? "true" : "false")
            Preferences.shared.appleDockAutohideBackup = nil
        }
        restartDock()
    }

    /// Read `com.apple.dock autohide` as a Bool (false when unset — the Dock's
    /// out-of-the-box state is always visible).
    private static func readAutohide() -> Bool {
        let out = run("/usr/bin/defaults", ["read", domain, "autohide"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out == "1"
    }

    private static func write(_ key: String, _ args: String...) {
        _ = run("/usr/bin/defaults", ["write", domain, key] + args)
    }

    private static func delete(_ key: String) {
        _ = run("/usr/bin/defaults", ["delete", domain, key])
    }

    /// Restart the Dock so it re-reads its preferences. macOS relaunches it
    /// immediately; without this the new defaults wouldn't take effect.
    private static func restartDock() {
        _ = run("/usr/bin/killall", ["Dock"])
    }

    /// Run a command-line tool and return its stdout, or nil if it couldn't launch
    /// or exited non-zero. Synchronous: these tools finish in milliseconds.
    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // swallow "key does not exist" noise from delete
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
