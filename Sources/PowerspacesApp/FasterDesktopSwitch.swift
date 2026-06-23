// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CSpaceSwitch

/// Thin Swift facade over the C `CSpaceSwitch` engine, so the private-CGEvent C
/// dependency is touched from exactly one place (the same way `CGSPrivate.swift`
/// isolates the private CGS bindings).
///
/// "Faster desktop switch" intercepts the real horizontal trackpad space-switch
/// swipe and replaces it with an instant (no slide animation) synthetic switch in
/// the same direction — the user's gesture is unchanged, it just lands at once.
///
/// The instant-switch technique is adapted from InstantSpaceSwitcher (MIT):
/// https://github.com/jurplel/InstantSpaceSwitcher
enum FasterDesktopSwitch {
    /// Enable or disable the trackpad **swipe** override. Returns `false` only if
    /// *enabling* failed — almost always because Accessibility isn't granted yet,
    /// so the event tap couldn't be created. Disabling always succeeds.
    @discardableResult
    static func setSwipeEnabled(_ enabled: Bool) -> Bool {
        psw_set_swipe_override_enabled(enabled)
    }

    /// Enable or disable the **keyboard** override. When enabling, it reads the
    /// user's current "Move left/right a space" binding and adopts it (disabling
    /// the system shortcut while on). Returns `false` only if enabling failed
    /// (no Accessibility → no event tap). Disabling always succeeds.
    @discardableResult
    static func setKeyboardEnabled(_ enabled: Bool) -> Bool {
        guard enabled else {
            return psw_set_keyboard_override_enabled(false, 0, 0, 0, 0)
        }
        let left = SymbolicHotkeys.moveLeft
        let right = SymbolicHotkeys.moveRight
        return psw_set_keyboard_override_enabled(
            true, left.keyCode, left.modifiers, right.keyCode, right.modifiers)
    }

    /// Force the system space-switch hotkeys back on (crash recovery — see
    /// `psw_restore_space_hotkeys`).
    static func restoreSpaceHotkeys() {
        psw_restore_space_hotkeys()
    }
}
