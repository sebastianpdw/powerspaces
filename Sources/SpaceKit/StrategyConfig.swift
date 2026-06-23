// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// How to produce a *new window on the current Space* for an app that is
/// already running elsewhere. The right answer is app-dependent — this is the
/// central, honest limitation of the project.
public enum StrategyKind: String, Codable, Equatable, CaseIterable, Sendable {
    /// Make a window on the current Space via a second app instance — but only
    /// when needed. If the app already owns a real window somewhere (another
    /// desktop, or here under `forceNew`), spawn a fresh instance (`open -n -a`) so
    /// activating it can't yank you to that window's Space. If the app is running
    /// but *window-less* (only spaceless phantoms — e.g. Claude after you ✕ its last
    /// window), reuse that instance (`open -a`, no -n) instead: its reopen handler
    /// makes a window here and no duplicate process accumulates. Works only for
    /// genuinely multi-instance apps; most "single profile" apps (Firefox, Chrome)
    /// ignore `-n` — use `.openArgs` for those.
    case newInstance
    /// Run the app's own binary directly with `args` (e.g. `--new-window`). For
    /// browsers/Electron this hands off to the running instance and opens a new
    /// window on the current Space — the most reliable option for them.
    case openArgs
    /// Ask a scriptable app to make a new window/document. The window lands on
    /// the current Space; we then activate without jumping.
    case appleScript
    /// Single-instance / document app already open on another desktop: don't
    /// jump and don't risk closing it — just show a small warning. The safe
    /// default for anything that might hold unsaved work.
    case warn
    /// Quit the whole app (every instance, on every desktop) and relaunch it so a
    /// fresh window lands on the current Space — the engine's normal "launch lands
    /// here" behaviour. Needs NO Accessibility and NO SIP, so it's the one thing
    /// that reliably brings a stubborn single-window app (System Settings and the
    /// like) to the desktop you're on. The catch: it quits the app, so any unsaved
    /// or transient state is lost. Because of that it's an **opt-in** — never a
    /// shipped default — and the UI confirms before applying it.
    case quitReopen
    /// Activate + synthesize ⌘N. Last resort; may briefly flash the other Space.
    case cmdN
    /// Single-instance apps — just activate and accept the jump to their Space.
    case focusOnly
}

extension StrategyKind {
    /// Whether this strategy tries to give you a *window on the current Space* via
    /// the app's own new-window path, as opposed to the "open elsewhere"
    /// alternatives (warn / quit-and-reopen). Drives the right-click "Open a new
    /// window" grouping.
    public var makesNewWindow: Bool {
        switch self {
        case .warn, .quitReopen: return false
        case .newInstance, .openArgs, .appleScript, .cmdN, .focusOnly: return true
        }
    }
}

public struct AppStrategy: Codable, Equatable, Sendable {
    public let bundleID: String
    public let strategy: StrategyKind
    public let appleScript: String?
    /// Arguments for the `.openArgs` strategy (e.g. ["--new-window"]).
    public let args: [String]?

    public init(bundleID: String, strategy: StrategyKind,
                appleScript: String? = nil, args: [String]? = nil) {
        self.bundleID = bundleID
        self.strategy = strategy
        self.appleScript = appleScript
        self.args = args
    }
}

public struct StrategyConfig: Equatable, Sendable {
    public var byBundleID: [String: AppStrategy]
    public var defaultKind: StrategyKind

    public init(byBundleID: [String: AppStrategy], defaultKind: StrategyKind) {
        self.byBundleID = byBundleID
        self.defaultKind = defaultKind
    }

    public func strategy(for bundleID: String?) -> StrategyKind {
        if let bundleID, let s = byBundleID[bundleID] { return s.strategy }
        return defaultKind
    }

    public func appleScript(for bundleID: String?) -> String? {
        if let bundleID, let s = byBundleID[bundleID] { return s.appleScript }
        return nil
    }

    public func args(for bundleID: String?) -> [String] {
        if let bundleID, let s = byBundleID[bundleID] { return s.args ?? [] }
        return []
    }
}

// MARK: - Defaults & loading

extension StrategyConfig {
    /// Shipped per-app defaults. Unknown apps fall back to `.newInstance`, which
    /// is right for the common multi-window apps and degrades to "focus" on
    /// single-instance ones.
    public static let defaults: StrategyConfig = {
        let entries: [AppStrategy] = [
            // Browsers/Electron: the binary + --new-window hands off to the
            // running instance and opens a window on the current Space.
            AppStrategy(bundleID: "org.mozilla.firefox", strategy: .openArgs, args: ["--new-window"]),
            AppStrategy(bundleID: "com.google.Chrome", strategy: .openArgs, args: ["--new-window"]),
            AppStrategy(bundleID: "com.microsoft.edgemac", strategy: .openArgs, args: ["--new-window"]),
            AppStrategy(bundleID: "company.thebrowser.Browser", strategy: .openArgs, args: ["--new-window"]),
            AppStrategy(bundleID: "com.microsoft.VSCode", strategy: .openArgs, args: ["--new-window"]),
            // Claude (Electron, single-window, NO single-instance lock): it can't
            // open a second window inside one instance, so when a window already lives
            // on another desktop a new *instance* is what lands a window here without
            // yanking you there. But `.newInstance` now reuses an idle, window-less
            // copy (`open -a`, no -n) instead of spawning yet another — so ✕-then-reopen
            // recycles the lingering process rather than stacking duplicates. This
            // matches the global default already, but we pin it so the "open here"
            // behaviour survives any change to that default.
            AppStrategy(bundleID: "com.anthropic.claudefordesktop", strategy: .newInstance),
            // Scriptable apps: ask them to make a new window.
            AppStrategy(bundleID: "com.apple.Safari", strategy: .appleScript,
                        appleScript: "tell application \"Safari\" to make new document"),
            AppStrategy(bundleID: "com.apple.Terminal", strategy: .appleScript,
                        appleScript: "tell application \"Terminal\" to do script \"\""),
            AppStrategy(bundleID: "com.googlecode.iterm2", strategy: .appleScript,
                        appleScript: "tell application \"iTerm\" to create window with default profile"),
            AppStrategy(bundleID: "com.apple.finder", strategy: .appleScript,
                        appleScript: "tell application \"Finder\" to make new Finder window"),
            // Single-window apps that are already open on another desktop: macOS
            // won't hand them a second window on the current Space, and there's no
            // reliable way to drag their existing window over (the Accessibility API
            // can't act on a window sitting on an inactive Space). So don't pretend —
            // just warn and let the user switch desktops. Covers the Apple
            // single-window apps people hit most.
            AppStrategy(bundleID: "com.apple.MobileSMS", strategy: .warn),
            AppStrategy(bundleID: "com.apple.systempreferences", strategy: .warn),
            AppStrategy(bundleID: "com.apple.Music", strategy: .warn),
            AppStrategy(bundleID: "com.apple.reminders", strategy: .warn),
            AppStrategy(bundleID: "com.apple.iCal", strategy: .warn),
            AppStrategy(bundleID: "com.apple.AddressBook", strategy: .warn),
            AppStrategy(bundleID: "com.apple.mail", strategy: .warn),
        ]
        let map = Dictionary(uniqueKeysWithValues: entries.map { ($0.bundleID, $0) })
        // The default for unmapped apps must stay a strategy that opens a window on
        // the *current* desktop and never yanks you to another one — i.e. never
        // `.focusOnly`. `.newInstance` does exactly that for multi-instance-capable
        // apps (the common case) and degrades to "focus" on genuinely single-instance
        // ones.
        return StrategyConfig(byBundleID: map, defaultKind: .newInstance)
    }()

    /// On-disk shape of `~/.config/powerspaces/config.json`. Public + mutable so the
    /// app's strategy editor can read/modify/write the same type instead of keeping
    /// its own duplicate struct (previously `ConfigFileShape`).
    public struct ConfigFile: Codable, Sendable {
        public var defaultStrategy: StrategyKind?
        public var apps: [AppStrategy]?
        public init(defaultStrategy: StrategyKind? = nil, apps: [AppStrategy]? = nil) {
            self.defaultStrategy = defaultStrategy
            self.apps = apps
        }
    }

    /// User overrides are merged on top of the shipped defaults.
    public static func load(from data: Data) throws -> StrategyConfig {
        let file = try JSONDecoder().decode(ConfigFile.self, from: data)
        var map = StrategyConfig.defaults.byBundleID
        for app in file.apps ?? [] { map[app.bundleID] = app }
        return StrategyConfig(byBundleID: map, defaultKind: file.defaultStrategy ?? .newInstance)
    }

    public static func load(from url: URL) -> StrategyConfig {
        // Security (S1): config.json drives AppleScript execution and process
        // launches, so treat it as a trust boundary. Refuse a file that isn't owned
        // by the current user or is group/world-writable — otherwise any process
        // running as another user (or a tampering tool) could plant a config that
        // the app then executes with its Accessibility/Automation privileges.
        guard fileIsTrusted(url) else { return .defaults }
        guard let data = try? Data(contentsOf: url) else { return .defaults } // no file → defaults (normal)
        do {
            return try load(from: data)
        } catch {
            // A present-but-unparseable config silently used to vanish into defaults,
            // leaving the user with no clue their edit was rejected. Log it.
            Log.error("StrategyConfig: ignoring invalid config at \(url.path): \(error.localizedDescription)")
            return .defaults
        }
    }

    /// Whether `url` is safe to read as a privilege-bearing config: it must be owned
    /// by the current user and not writable by group or others. A missing file is
    /// "trusted" (nothing to load — the caller falls back to defaults).
    static func fileIsTrusted(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return true }
        if let owner = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value, owner != getuid() {
            Log.error("StrategyConfig: refusing config not owned by the current user: \(url.path)")
            return false
        }
        if let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value, (perms & 0o022) != 0 {
            Log.error("StrategyConfig: refusing group/world-writable config (mode \(String(perms, radix: 8))): \(url.path)")
            return false
        }
        return true
    }

    public static var defaultConfigURL: URL { PowerspacesPaths.configFile }
}
