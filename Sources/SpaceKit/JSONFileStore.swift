// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// One home for the "read/decode" and "encode → make directory → write" dance that
/// `PinStore`, the app's `StrategyStore`, and `JSONPreferencesStore` each repeated.
/// Directory creation and error handling live here once, and failures are logged
/// (via `Log`) instead of vanishing into a `try?`.
public enum JSONFileStore {
    /// Decode `T` from the JSON at `url`. Returns nil when the file is simply
    /// missing/unreadable (the normal "no config yet" case, not logged) and logs
    /// when a file *is* present but can't be decoded (a real, otherwise-silent error).
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Log.error("JSONFileStore: ignoring invalid \(T.self) at \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Encode `value` (pretty-printed, keys sorted) and write it to `url`, creating
    /// the parent directory. Logs and returns on any failure rather than throwing.
    public static func writeEncodable<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            write(try encoder.encode(value), to: url)
        } catch {
            Log.error("JSONFileStore: failed to encode \(T.self) for \(url.path): \(error.localizedDescription)")
        }
    }

    /// Write raw `data` to `url`, creating the parent directory. Logs on failure.
    /// (Used by the preferences store, whose payload is built with `JSONSerialization`.)
    public static func write(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomic write so a crash or full disk mid-write can't truncate the file
            // and leave a half-written JSON that fails to decode on next launch.
            try data.write(to: url, options: .atomic)
        } catch {
            Log.error("JSONFileStore: failed to write \(url.path): \(error.localizedDescription)")
        }
    }
}
