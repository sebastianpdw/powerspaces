// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

public extension Sequence {
    /// The elements in order, keeping only the first occurrence of each distinct
    /// `key` value. The order-preserving de-dup used wherever a list is stitched
    /// together from several sources (all-desktops + this-desktop pins, the saved
    /// dock order, the installed-apps scan across folders).
    func uniqued<Key: Hashable>(on key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}

public extension Sequence where Element: Hashable {
    /// The elements in order, with duplicates removed (first occurrence wins).
    func uniqued() -> [Element] { uniqued(on: { $0 }) }
}
