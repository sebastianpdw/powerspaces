// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation

/// A keyboard combo (virtual keycode + modifier mask) for one direction. The
/// modifier mask uses `CGEventFlags` bits (command/option/control/shift) — the
/// same bits stored in `com.apple.symbolichotkeys`, so it's passed straight to
/// the C tap for matching.
struct SpaceSwitchCombo {
    let keyCode: UInt16
    let modifiers: UInt64
}

/// Reads the user's "Move left/right a space" keyboard shortcut out of the system
/// preference domain `com.apple.symbolichotkeys`, so the keyboard override adopts
/// whatever the user has actually bound (e.g. ⌘⌥←/→) rather than a fixed combo.
///
/// Symbolic hotkey IDs: left = 79 (fallback 80), right = 81 (fallback 82). When
/// nothing readable is bound we fall back to the macOS default Ctrl+←/→.
enum SymbolicHotkeys {
    // Only the device-independent modifier bits matter; they coincide for
    // CGEventFlags and the values stored in the symbolichotkeys plist.
    private static let modMask: UInt64 =
        UInt64(CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue
               | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue)
    private static let control = UInt64(CGEventFlags.maskControl.rawValue)
    private static let leftArrow: UInt16 = 123
    private static let rightArrow: UInt16 = 124

    static var moveLeft: SpaceSwitchCombo {
        combo(ids: [79, 80]) ?? SpaceSwitchCombo(keyCode: leftArrow, modifiers: control)
    }
    static var moveRight: SpaceSwitchCombo {
        combo(ids: [81, 82]) ?? SpaceSwitchCombo(keyCode: rightArrow, modifiers: control)
    }

    /// First enabled, parseable binding among `ids`. The plist entry looks like:
    /// `"79" = { enabled = 1; value = { parameters = ( ascii, keyCode, modifiers ); }; }`.
    private static func combo(ids: [Int]) -> SpaceSwitchCombo? {
        guard let raw = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString),
              let dict = raw as? [String: Any] else { return nil }
        for id in ids {
            guard let entry = dict[String(id)] as? [String: Any] else { continue }
            let enabled = (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? NSNumber)?.boolValue ?? false)
            guard enabled,
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [Any], params.count >= 3,
                  let keyCode = (params[1] as? NSNumber)?.intValue, keyCode >= 0,
                  let mods = (params[2] as? NSNumber)?.uint64Value else { continue }
            return SpaceSwitchCombo(keyCode: UInt16(keyCode), modifiers: mods & modMask)
        }
        return nil
    }
}
