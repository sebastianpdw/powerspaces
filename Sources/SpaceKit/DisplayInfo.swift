// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import ColorSync
import CoreGraphics
import Foundation

/// Live reads of the physical display layout, in the global top-left-origin
/// coordinate space that `CGDisplayBounds` and the Accessibility position
/// attribute share — so the rects here can be compared and applied directly to
/// AX window frames (see `DisplayPlacement`).
enum DisplayInfo {
    /// Physical identities remain distinct even when CGS reports one shared
    /// logical "Main" Space. Put the primary display first for that fallback.
    static func activeDisplays() -> [(uuid: String, bounds: CGRect)] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let primary = CGMainDisplayID()
        let ordered = ids.prefix(Int(count)).filter { $0 == primary }
            + ids.prefix(Int(count)).filter { $0 != primary }
        return ordered.compactMap { id in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let name = CFUUIDCreateString(nil, uuid) as String? else { return nil }
            return (name, CGDisplayBounds(id))
        }
    }
}
