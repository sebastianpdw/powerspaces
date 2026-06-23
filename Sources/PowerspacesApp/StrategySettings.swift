// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Combine
import SpaceKit

// MARK: - Friendly labels for the strategy enum (UI only; SpaceKit stays neutral)

extension StrategyKind {
    var label: String {
        switch self {
        case .newInstance: return "New instance (open -n)"
        case .openArgs: return "Run with args (--new-window)"
        case .appleScript: return "AppleScript (new document)"
        case .warn: return "Show a warning"
        case .quitReopen: return "Quit there and reopen here"
        case .cmdN: return "Synthesize ⌘N"
        case .focusOnly: return "Focus (accept the jump)"
        }
    }
}

/// One known single-window app macOS can't reliably give a second window.
struct SingleInstanceApp: Identifiable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

enum SingleInstance {
    /// Curated list of single-window apps for which macOS can't reliably give a
    /// second window on the current Space — so "Open a new window" is labelled
    /// experimental for them, and they ship a `warn` default.
    static let apps: [SingleInstanceApp] = [
        SingleInstanceApp(bundleID: "com.apple.MobileSMS", name: "Messages"),
        SingleInstanceApp(bundleID: "com.apple.systempreferences", name: "System Settings"),
        SingleInstanceApp(bundleID: "com.apple.Music", name: "Music"),
        SingleInstanceApp(bundleID: "com.apple.reminders", name: "Reminders"),
        SingleInstanceApp(bundleID: "com.apple.iCal", name: "Calendar"),
        SingleInstanceApp(bundleID: "com.apple.AddressBook", name: "Contacts"),
        SingleInstanceApp(bundleID: "com.apple.mail", name: "Mail"),
    ]

    /// The strategies offered as a global default for unknown apps. (`appleScript`
    /// is excluded — it needs a per-app script.)
    static let defaultChoices: [StrategyKind] = [.newInstance, .openArgs, .cmdN, .focusOnly, .warn]

    /// One of the curated single-instance apps, for which macOS can't reliably
    /// give a second window — so "Open a new window" is labelled experimental.
    static func isSingleInstance(bundleID: String) -> Bool {
        apps.contains { $0.bundleID == bundleID }
    }
}

// MARK: - On-disk overrides (config.json)

/// Reads and writes the user's strategy overrides, preserving any entries the UI
/// doesn't touch (e.g. a hand-tuned browser `--new-window`). It reads/writes the
/// same on-disk shape SpaceKit defines (`StrategyConfig.ConfigFile`) so there's a
/// single schema for `~/.config/powerspaces/config.json`.
final class StrategyStore {
    let url: URL
    private var file: StrategyConfig.ConfigFile

    init(url: URL = StrategyConfig.defaultConfigURL) {
        self.url = url
        self.file = JSONFileStore.read(StrategyConfig.ConfigFile.self, from: url)
            ?? StrategyConfig.ConfigFile()
    }

    /// Effective default = user override, else the shipped code default.
    func effectiveDefault() -> StrategyKind {
        file.defaultStrategy ?? StrategyConfig.defaults.defaultKind
    }

    /// Effective strategy for an app = user override, else shipped code default.
    func effectiveStrategy(for bundleID: String) -> StrategyKind {
        file.apps?.first { $0.bundleID == bundleID }?.strategy
            ?? StrategyConfig.defaults.strategy(for: bundleID)
    }

    func setDefault(_ kind: StrategyKind) {
        file.defaultStrategy = kind
        save()
    }

    /// Upserts one app's strategy, preserving its `appleScript`/`args` so we never
    /// drop a scripted/arg'd entry when only flipping the strategy.
    func setStrategy(_ kind: StrategyKind, for bundleID: String) {
        let existing = file.apps?.first { $0.bundleID == bundleID }
        let appleScript = existing?.appleScript ?? StrategyConfig.defaults.appleScript(for: bundleID)
        let defaultArgs = StrategyConfig.defaults.args(for: bundleID)
        let args = existing?.args ?? (defaultArgs.isEmpty ? nil : defaultArgs)
        let entry = AppStrategy(bundleID: bundleID, strategy: kind, appleScript: appleScript, args: args)
        var apps = file.apps ?? []
        if let i = apps.firstIndex(where: { $0.bundleID == bundleID }) { apps[i] = entry }
        else { apps.append(entry) }
        file.apps = apps
        save()
    }

    private func save() { JSONFileStore.writeEncodable(file, to: url) }
}

// MARK: - Controller shared by the right-click menu and the preferences window

/// Owns the `StrategyStore` and notifies the app to reload its live
/// `StrategyConfig`. Both the dock's right-click menu and the Strategies tab route
/// through this one instance, so they never disagree.
final class StrategySettingsController: ObservableObject {
    // No @Published members (state lives in StrategyStore); drive updates by hand.
    let objectWillChange = ObservableObjectPublisher()
    private let store = StrategyStore()
    /// Set by AppDelegate: reload config.json into the running launcher + refresh.
    var onChanged: (() -> Void)?

    func effectiveDefault() -> StrategyKind { store.effectiveDefault() }
    func effectiveStrategy(for bundleID: String) -> StrategyKind { store.effectiveStrategy(for: bundleID) }

    func setDefault(_ kind: StrategyKind) {
        store.setDefault(kind)
        publish()
    }

    /// Applies a per-app strategy (the dock's right-click menu and the Strategies
    /// tab). `quitReopen` quits the whole app, so it confirms first — any unsaved or
    /// transient state in the app is lost. Returns whether it was applied.
    @discardableResult
    @MainActor func setStrategy(_ kind: StrategyKind, forBundleID bundleID: String, name: String) -> Bool {
        if kind == .quitReopen, !confirmQuitReopen(name: name) { return false }
        store.setStrategy(kind, for: bundleID)
        publish()
        return true
    }

    private func publish() {
        objectWillChange.send()
        onChanged?()
    }

    @MainActor private func confirmQuitReopen(name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit \(name) there and reopen it here?"
        alert.informativeText = """
            When \(name) is open on another desktop, this quits it entirely and \
            relaunches it on the current one, the only reliable way to bring a \
            single-window app here. Any unsaved or transient state in \(name) is lost.
            """
        alert.addButton(withTitle: "Quit and reopen here anyway")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
