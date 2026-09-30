// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import ApplicationServices
import CoreGraphics
import Foundation

public enum WindowInventory {
    public static func confirmsEmpty(rawCount: Int?, axCount: Int?, trusted: Bool, nativeInteraction: Bool) -> Bool {
        trusted && !nativeInteraction && rawCount == 0 && axCount == 0
    }
    /// Positive confirmation from both independent inventories; missing AX/CG
    /// data is not proof of no windows. Called only after an explicit close.
    public static func confirmsNoWindows(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted(), !NativeInteraction.isActive,
              let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], 0)
                as? [[String: Any]],
              raw.allSatisfy({ $0[kCGWindowOwnerPID as String] is NSNumber }) else { return false }
        let rawCount = raw.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }.count
        guard rawCount == 0 else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        return confirmsEmpty(rawCount: rawCount, axCount: windows.count, trusted: AXIsProcessTrusted(),
                              nativeInteraction: NativeInteraction.isActive)
    }
}
