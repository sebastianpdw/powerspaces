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
    private static let cid = CGSMainConnectionID()

    /// Bounds of every active display.
    static func allDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Bounds of the display that currently owns the menu bar — i.e. the screen
    /// the user is on. Returns nil if the window server or the display lookup
    /// can't answer. Uses the same `CGSCopyActiveMenuBarDisplayIdentifier` signal
    /// the Space lookup relies on, so "active display" stays consistent across the
    /// app.
    static func activeDisplayBounds() -> CGRect? {
        guard let uuid = CGSCopyActiveMenuBarDisplayIdentifier(cid)?.takeRetainedValue() as String?,
              let displayID = displayID(forUUID: uuid) else { return nil }
        return CGDisplayBounds(displayID)
    }

    /// Bounds of the display with this UUID string (what the window server
    /// reports), or nil if no attached display matches.
    static func bounds(forDisplayUUID uuid: String) -> CGRect? {
        displayID(forUUID: uuid).map { CGDisplayBounds($0) }
    }

    /// Resolve a display's UUID string (what the window server reports) to its
    /// `CGDirectDisplayID` by matching against every active display.
    private static func displayID(forUUID uuid: String) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        for id in ids.prefix(Int(count)) {
            guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
            if (CFUUIDCreateString(nil, cfUUID) as String?) == uuid { return id }
        }
        return nil
    }
}
