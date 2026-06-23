// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CoreGraphics

extension NSScreen {
    /// This screen's `CGDirectDisplayID` (0 if its device description lacks the
    /// `NSScreenNumber` key). The one place the fiddly `deviceDescription` bridge
    /// lives — the dock, the app delegate, and the Preferences display list all
    /// read it through here instead of re-extracting it inline.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// This screen's stable display-UUID string (nil if it can't be resolved) — the
    /// same identifier the window server reports per display, so it matches
    /// `DisplaySpaceInfo.displayUUID` for screen↔display lookups.
    var displayUUID: String? {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let uuid = CFUUIDCreateString(nil, cf) as String? else { return nil }
        return uuid
    }
}
