// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import SpaceKit

/// System mutations are journalled independently of Reset Settings. Restarts are
/// deferred during a mouse drag; no periodic drift handler kills Dock.
@MainActor
enum AppleDockController {
    private static let domain = "com.apple.dock" as CFString
    private static let keys = ["autohide", "autohide-delay", "autohide-time-modifier", "tilesize"]
    private static let journal = SystemSettingsJournal(url: PowerspacesPaths.configDir.appendingPathComponent("dock-recovery.json"))
    private static var pending: Bool?
    private static var retryTimer: Timer?

    /// `now` skips the wait for a mouse drag to end. Quit and uninstall
    /// pass it: the retry timer dies with the app, and the Dock would stay hidden.
    @discardableResult static func apply(hidden: Bool, now: Bool = false) -> Bool {
        if !now, NativeInteraction.isActive {
            Log.notice("Apple Dock: hidden=\(hidden) waits for the mouse button to be released")
            pending = hidden
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
                MainActor.assumeIsolated { if let pending { _ = apply(hidden: pending) } }
            }
            return false
        }
        pending = nil; retryTimer?.invalidate(); retryTimer = nil
        Log.notice("Apple Dock: apply hidden=\(hidden) now=\(now) record=\(journal.exists)")
        do {
            if hidden {
                var originals: [String: Any]?
                try journal.capture(keys: keys) { key in
                    if originals == nil { originals = try userOriginals(readingDock: true) }
                    return try originals?[key].map(encode)
                }
                try set("autohide", true)
                try set("autohide-delay", 1000.0)
                try set("autohide-time-modifier", 0.0)
                try set("tilesize", 1)
            } else {
                // Migrate legacy recovery before restoring when hiding is disabled.
                if !journal.exists, Preferences.shared.appleDockAutohideBackup != nil {
                    let originals = try userOriginals(readingDock: false)
                    try journal.capture(keys: keys) { key in try originals[key].map(encode) }
                }
                guard journal.exists else {
                    Log.notice("Apple Dock: no recovery record, nothing to restore")
                    return true
                }
                try journal.restore(keys: keys, write: { key, data in
                    let value = try data.map(decode)
                    try set(key, value)
                }, finalize: { try restartDock() })
                Log.notice("Apple Dock: restored and recovery record removed")
            }
            Preferences.shared.appleDockAutohideBackup = nil
            Preferences.shared.appleDockTilesizeBackup = nil
            if hidden { try restartDock() }
            return true
        } catch {
            Log.error("Apple Dock: \(hidden ? "hide" : "restore") failed, recovery record kept=\(journal.exists): \(error)")
            HUD.show("Could not update or restore the macOS Dock. Its recovery record was kept for retry.")
            return false
        }
    }

    /// The user's own settings, recorded before the first change. Older releases kept
    /// only the autohide and tile-size originals, so those win when present. Values
    /// that are our own hide (a Dock left hidden with its backup lost) are dropped, so
    /// a restore can never re-hide the Dock.
    private static func userOriginals(readingDock: Bool) throws -> [String: Any] {
        var values: [String: Any] = [:]
        if readingDock { for key in keys { values[key] = try read(key) } }
        if let old = Preferences.shared.appleDockAutohideBackup {
            values["autohide"] = old
            values["autohide-delay"] = nil
            values["autohide-time-modifier"] = nil
        }
        if let old = Preferences.shared.appleDockTilesizeBackup {
            if old.isEmpty { values["tilesize"] = nil } else {
                guard let tile = Int(old) else { throw CocoaError(.propertyListReadCorrupt) }
                values["tilesize"] = tile
            }
        }
        let cleaned = AppleDockOriginals.clean(values)
        if cleaned.isEmpty, !values.isEmpty {
            Log.notice("Apple Dock: current settings are a leftover Powerspaces hide \(values); recording macOS defaults instead")
        }
        Log.notice("Apple Dock: recording originals \(cleaned)")
        return cleaned
    }

    private static func restartDock() throws {
        let result = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/killall"), arguments: ["Dock"])
        Log.notice("Apple Dock: restart result=\(result)")
        guard result == .exited(0) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func encode(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
    }
    private static func decode(_ data: Data) throws -> Any {
        guard let box = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let value = box["value"] else { throw CocoaError(.propertyListReadCorrupt) }
        return value
    }
    private static func read(_ key: String) throws -> Any? {
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            Log.error("Apple Dock: could not synchronize preferences before reading \(key)")
            throw CocoaError(.fileReadUnknown)
        }
        return CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    private static func set(_ key: String, _ value: Any?) throws {
        Log.notice("Apple Dock: write \(key)=\(value.map { "\($0)" } ?? "absent")")
        CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            Log.error("Apple Dock: could not synchronize preferences after writing \(key)")
            throw CocoaError(.fileWriteUnknown)
        }
        let actual = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let matches = value.map { expected in actual.map { ($0 as AnyObject).isEqual(expected) } ?? false } ?? (actual == nil)
        guard matches else {
            Log.error("Apple Dock: \(key) read back \(actual.map { "\($0)" } ?? "absent") after the write")
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
