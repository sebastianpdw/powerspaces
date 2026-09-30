// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Guards the macOS Dock recovery record against our own hide values.
public enum AppleDockOriginals {
    /// A tile size of 1 cannot be set in System Settings (its minimum is 16) and a
    /// 1000-second reveal delay is ours: either means the Dock was still hidden by
    /// Powerspaces when it was read (an earlier run or older release whose backup was
    /// lost). Those are not the user's settings, so nothing is kept and a restore
    /// returns the Dock to macOS defaults: visible, at the default size.
    public static func clean(_ values: [String: Any]) -> [String: Any] {
        let tile = (values["tilesize"] as? NSNumber)?.doubleValue
        let delay = (values["autohide-delay"] as? NSNumber)?.doubleValue ?? 0
        if tile == 1 || delay >= 1000 { return [:] }
        return values
    }
}
