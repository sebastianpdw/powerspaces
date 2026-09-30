// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A durable, independent recovery record. nil means the original key was absent.
/// Capture must finish and persist before any system preference is overwritten.
public struct SystemSettingsJournal {
    public let url: URL
    public init(url: URL) { self.url = url }
    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    private struct Backup: Codable { let value: Data? }
    public func capture(keys: [String], read: (String) throws -> Data?) throws {
        if exists {
            let original = try JSONDecoder().decode([String: Backup].self, from: Data(contentsOf: url))
            guard Set(original.keys) == Set(keys) else { throw CocoaError(.propertyListReadCorrupt) }
            return
        }
        var values: [String: Backup] = [:]
        for key in keys { values[key] = Backup(value: try read(key)) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: url, options: .atomic)
    }
    public func restore(keys: [String]? = nil, write: (String, Data?) throws -> Void, finalize: () throws -> Void = {}) throws {
        guard exists else { return }
        let values = try JSONDecoder().decode([String: Backup].self, from: Data(contentsOf: url))
        if let keys, Set(values.keys) != Set(keys) { throw CocoaError(.propertyListReadCorrupt) }
        for key in values.keys.sorted() { try write(key, values[key]!.value) }
        try finalize()
        // Failed/partial restoration leaves the whole record available to retry.
        try FileManager.default.removeItem(at: url)
    }
}
