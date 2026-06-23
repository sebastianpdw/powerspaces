// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import SpaceKit

/// Integrates the third-party **AltTab** app (https://alt-tab.app) as Powerspaces'
/// per-desktop Cmd-Tab.
///
/// AltTab already ships a polished window switcher, and a single setting — "show
/// windows from the active space" — scopes it to the current desktop, which is
/// exactly the behaviour Powerspaces wants.
/// Rather than reimplement a fragile Cmd-Tab event tap, we *detect* AltTab, link to
/// its install, and offer a one-click "configure for Powerspaces" that writes the
/// two settings that matter. Mirrors `RaycastSetup`: a small model the Preferences
/// row drives.
///
/// AltTab is GPL-3.0; we never bundle or redistribute it — the user installs it
/// themselves (we only open the download page). "Configuring" it means writing
/// AltTab's *own* preferences domain (`com.lwouis.alt-tab-macos`), which is
/// best-effort by nature; see `configure()` for the two honest caveats (the values
/// are enum *indices*, and AltTab must be quit before we write).
enum AltTabSetup {
    /// AltTab's bundle identifier (confirmed from its `config/base.xcconfig`). It
    /// doubles as the UserDefaults suite name, so the one string both finds the app
    /// (via Launch Services) and addresses its preferences.
    static let bundleID = "com.lwouis.alt-tab-macos"

    /// AltTab's official site, where it can be downloaded/installed (free, open
    /// source). Backs the "Get AltTab" button.
    static let downloadPage = URL(string: "https://alt-tab.app")!

    /// Where AltTab is installed, if it is (asked of Launch Services). nil = not found.
    static var installedURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static var isInstalled: Bool { installedURL != nil }

    /// AltTab's marketing version (`CFBundleShortVersionString`), if installed.
    static var installedVersion: String? {
        guard let url = installedURL, let bundle = Bundle(url: url) else { return nil }
        return bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// The currently-running AltTab instances (usually 0 or 1).
    static var runningInstances: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    }

    /// The Homebrew command that installs AltTab (a cask).
    static let homebrewInstallCommand = "brew install --cask alt-tab"

    /// Homebrew's executable, if present — the Apple-silicon prefix first, then Intel.
    /// Checked as plain files because a GUI app doesn't inherit the shell `PATH`
    /// where `brew` normally lives, so a path probe is more reliable (and faster)
    /// than spawning a login shell. These two prefixes cover effectively every
    /// standard install.
    static var homebrewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var hasHomebrew: Bool { homebrewPath != nil }

    /// A cheap, `Sendable` snapshot for the Preferences row to show (computed off the
    /// main thread, like the npm probe). Carries whether Homebrew is available, so
    /// the row can offer a one-command install instead of just a download link.
    struct Probe: Sendable {
        let installed: Bool
        let version: String?
        let hasHomebrew: Bool
        var statusText: String {
            guard installed else { return "Not installed" }
            return version.map { "Installed (v\($0))" } ?? "Installed"
        }
    }

    static func probe() -> Probe {
        Probe(installed: isInstalled, version: installedVersion, hasHomebrew: hasHomebrew)
    }

    /// Open AltTab's website so the user can install it (the fallback when Homebrew
    /// isn't available).
    static func openDownloadPage() { NSWorkspace.shared.open(downloadPage) }

    /// Bring AltTab to the front so the user can open its Settings (to set the ⌘
    /// hold shortcut) — no-op if it isn't installed.
    static func openApp() {
        guard let url = installedURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Run `brew install --cask alt-tab` in a Terminal window, so the user can watch
    /// progress and enter a password if Homebrew needs one to write to /Applications.
    /// Mirrors `RaycastSetup`'s "run it in Terminal" pattern. The script relies on the
    /// login shell's `PATH` to find `brew` (the same place the user runs it from).
    static func installViaHomebrew() throws {
        let script = """
            #!/bin/bash
            echo "Installing AltTab via Homebrew…"
            echo "  \(homebrewInstallCommand)"
            echo
            \(homebrewInstallCommand)
            status=$?
            echo
            if [ $status -eq 0 ]; then
              echo "============================================================"
              echo "  ✅  AltTab installed. Safe to close this window (⌘W)."
              echo
              echo "  ➜  Back in Powerspaces ▸ Preferences ▸ System, click"
              echo "     “Configure AltTab with Powerspaces”."
              echo "============================================================"
            else
              echo "⚠️  Homebrew install failed (exit $status)."
              echo "    You can instead download AltTab from https://alt-tab.app"
            fi
            """
        try runInTerminal(script, named: "install-alttab.command")
    }

    /// Write `script` as an executable `.command` under the config dir and open it in
    /// Terminal (`.command` files launch there by default).
    private static func runInTerminal(_ script: String, named name: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: PowerspacesPaths.configDir, withIntermediateDirectories: true)
        let url = PowerspacesPaths.configDir.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    enum SetupError: LocalizedError {
        case notInstalled
        case writeFailed
        case relaunchFailed

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "AltTab isn't installed. Click “Get AltTab” to install it first."
            case .writeFailed:
                return "Couldn't write AltTab's preferences."
            case .relaunchFailed:
                return "Updated AltTab's settings, but couldn't relaunch it automatically. "
                    + "Open AltTab yourself to apply them."
            }
        }
    }

    /// Configure AltTab to scope its switcher to the **active Space** (the current
    /// desktop) — the half of "per-desktop Cmd-Tab" we *can* set reliably.
    ///
    /// We deliberately do **not** set AltTab's trigger to ⌘ here. AltTab stores its
    /// `holdShortcut` not as a simple value but as a dictionary holding an
    /// `NSKeyedArchiver`-archived `Shortcut` object (read back with
    /// `NSKeyedUnarchiver.unarchivedObject(ofClass: Shortcut.self)`). We can't
    /// synthesise that blob without AltTab's own `Shortcut`/`MASShortcut` class, and
    /// any attempt would break on an AltTab update — so the ⌘-Tab trigger is a
    /// one-time **manual** step in AltTab ▸ Settings ▸ Controls (where AltTab also
    /// disables the system ⌘-Tab for you). The Preferences row spells this out.
    ///
    /// `spacesToShow`, by contrast, *is* a plain string — the index of an enum case
    /// (`SpacesToShowPreference.visible` is case #1 → `"1"`) — so it writes cleanly.
    /// The one caveat: it's an *index*, so a future AltTab that reorders that enum
    /// could change what `"1"` means (the manual setting stays the durable fallback).
    ///
    /// AltTab caches its prefs in memory and rewrites them on quit, so a write while
    /// it's running can be clobbered. We therefore quit any running instance, write,
    /// then relaunch — the fresh process reads our value.
    @MainActor
    static func configure() async throws {
        guard let appURL = installedURL else { throw SetupError.notInstalled }

        // 1. Quit any running AltTab so it can't overwrite our value on exit, and
        //    wait (bounded to ~2s) for it to actually go before we write.
        runningInstances.forEach { $0.terminate() }
        var waitedMS = 0
        while !runningInstances.isEmpty && waitedMS < 2000 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waitedMS += 50
        }

        // 2. Scope AltTab to the active Space. The value is a string (the enum index
        //    "1" = visible/active Space). `spacesToShow` is the filter for AltTab's
        //    first shortcut, `spacesToShow2` for the second (AltTab ships both enabled).
        guard let defaults = UserDefaults(suiteName: bundleID) else { throw SetupError.writeFailed }
        defaults.set("1", forKey: "spacesToShow")     // shortcut 1 → active Space only
        defaults.set("1", forKey: "spacesToShow2")    // shortcut 2 → active Space only

        // 3. Relaunch AltTab so it reads the new value.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        } catch {
            throw SetupError.relaunchFailed
        }
    }
}
