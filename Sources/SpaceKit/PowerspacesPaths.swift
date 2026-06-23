// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// The single source of truth for where powerspaces keeps its on-disk state —
/// `~/.config/powerspaces/`. Previously each store built this path itself
/// (`PinStore`, `StrategyConfig`, the app's `Preferences`), so a change to the
/// location meant editing several files; now they all route through here.
public enum PowerspacesPaths {
    /// The config directory: `~/.config/powerspaces`.
    public static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/powerspaces", isDirectory: true)
    }

    /// Per-app new-window strategy overrides (`config.json`).
    public static var configFile: URL { configDir.appendingPathComponent("config.json") }
    /// Pinned-apps + saved dock arrangement (`pins.json`).
    public static var pinsFile: URL { configDir.appendingPathComponent("pins.json") }
    /// UI preferences (`preferences.json`).
    public static var preferencesFile: URL { configDir.appendingPathComponent("preferences.json") }
    /// Per-desktop dock color/opacity overrides (`dock-colors.json`), keyed by
    /// Space UUID — set by right-clicking the dock. Kept beside `pins.json` (also
    /// per-desktop) rather than in `preferences.json`, which holds only flat
    /// key/value settings.
    public static var dockColorsFile: URL { configDir.appendingPathComponent("dock-colors.json") }
}
