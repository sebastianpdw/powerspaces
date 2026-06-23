// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SpaceKit

/// A tiny `UserDefaults`-shaped store backed by a JSON file at a *fixed path*
/// (`~/.config/powerspaces/preferences.json`). Used instead of `UserDefaults` so
/// preferences sit next to the strategy `config.json` and survive app reinstalls
/// and the unbundled→bundled identity switch — `UserDefaults` is keyed by bundle
/// id, so it resets when that identity changes.
///
/// Like UserDefaults' registration domain, `register(defaults:)` supplies
/// fallbacks that are never written to disk: the file holds only the values the
/// user actually changed, so new code defaults keep applying. Values are plain
/// JSON (`Bool`/`Double`/`String`), so the file stays human-readable and editable.
final class JSONPreferencesStore {
    private let url: URL
    private var registered: [String: Any] = [:]
    private var stored: [String: Any] = [:]

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            stored = obj
        }
    }

    /// Register fallback values (never persisted) for keys not set by the user.
    func register(defaults: [String: Any]) {
        for (key, value) in defaults where registered[key] == nil { registered[key] = value }
    }

    private func value(_ key: String) -> Any? { stored[key] ?? registered[key] }

    func double(_ key: String) -> Double { (value(key) as? NSNumber)?.doubleValue ?? 0 }
    func bool(_ key: String) -> Bool { (value(key) as? NSNumber)?.boolValue ?? false }
    func string(_ key: String) -> String? { value(key) as? String }
    /// A stored list of strings (e.g. display UUIDs). nil when unset/malformed.
    func stringArray(_ key: String) -> [String]? { value(key) as? [String] }

    /// Set and persist. `newValue` is a `Bool`, `Double`, `String`, or `[String]`.
    func set(_ newValue: Any, _ key: String) {
        stored[key] = newValue
        save()
    }

    /// Remove a stored key (its registered default, if any, applies again).
    func remove(_ key: String) {
        guard stored[key] != nil else { return }
        stored.removeValue(forKey: key)
        save()
    }

    /// Clear every user-set value, so the registered defaults apply again.
    func removeAll() {
        guard !stored.isEmpty else { return }
        stored.removeAll()
        save()
    }

    private func save() {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: stored, options: [.prettyPrinted, .sortedKeys])
            JSONFileStore.write(data, to: url) // creates the dir + logs on failure
        } catch {
            Log.error("Preferences: failed to serialize preferences: \(error.localizedDescription)")
        }
    }
}
