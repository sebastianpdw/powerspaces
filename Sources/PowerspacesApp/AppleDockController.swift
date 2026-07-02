// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Hides or restores Apple's built-in Dock, so the Powerspaces bar can stand in
/// for it. macOS has no real "off switch" for the Dock — `killall Dock` only makes
/// it respawn, and the process must keep running anyway (Mission Control, the
/// ⌘-Tab switcher and Stage Manager all rely on it). The established, fully
/// reversible trick is to force the Dock to auto-hide with an effectively infinite
/// reveal delay: it never slides into view, yet the process stays alive. We also
/// shrink it to the smallest tile, so the one reveal no delay can stop — the Dock
/// that Mission Control / App Exposé / Show Desktop force on screen — is a sliver
/// rather than a full-size Dock. Re-enabling puts the user's own auto-hide value
/// and tile size back.
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
    /// The smallest tile we shrink the Dock to while hidden, so the reveal that
    /// Mission Control / App Exposé force on screen is a barely-visible sliver.
    private static let hiddenTileSize = "1"

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
            // Mission Control / App Exposé / Show Desktop force the Dock visible no
            // matter the reveal delay, at the user's own tile size — so a normal Dock
            // shows full-size there. Back up their tile size (first time only) and
            // shrink it to a sliver; restored on re-enable, like the autohide value.
            if Preferences.shared.appleDockTilesizeBackup == nil {
                Preferences.shared.appleDockTilesizeBackup = readTilesize() ?? ""
            }
            write("tilesize", "-int", hiddenTileSize)
        } else {
            // Drop our delay overrides and put auto-hide back the way we found it.
            delete("autohide-delay")
            delete("autohide-time-modifier")
            let original = Preferences.shared.appleDockAutohideBackup ?? false
            write("autohide", "-bool", original ? "true" : "false")
            Preferences.shared.appleDockAutohideBackup = nil
            // Put the tile size back exactly as we found it ("" = it was unset).
            if let tile = Preferences.shared.appleDockTilesizeBackup {
                if tile.isEmpty { delete("tilesize") } else { write("tilesize", "-int", tile) }
                Preferences.shared.appleDockTilesizeBackup = nil
            }
        }
        restartDock()
    }

    /// Re-assert the hidden state if it has drifted back. macOS can flip auto-hide
    /// off or reset the tile size after sleep/wake or a display attach/rearrange, and
    /// a Dock utility could rewrite the tile — any of which makes the Dock reappear
    /// (full-size) during App Exposé / Mission Control. A no-op when the Dock is
    /// already hidden exactly how we set it, so this is safe to call on every
    /// screen-change / wake without a needless Dock restart. Only acts while "Hide
    /// macOS Dock" is on; never touches a Dock the user wants visible.
    @MainActor static func reassertHiddenIfDrifted() {
        guard Preferences.shared.hideAppleDock else { return }
        if readAutohide(), readTilesize() == hiddenTileSize { return } // already as we set it
        apply(hidden: true)
    }

    /// Read `com.apple.dock autohide` as a Bool (false when unset — the Dock's
    /// out-of-the-box state is always visible).
    private static func readAutohide() -> Bool {
        let out = run("/usr/bin/defaults", ["read", domain, "autohide"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out == "1"
    }

    /// Read `com.apple.dock tilesize` as its raw integer string, or nil when it's
    /// unset (the Dock then uses its own default size).
    private static func readTilesize() -> String? {
        let out = run("/usr/bin/defaults", ["read", domain, "tilesize"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
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
