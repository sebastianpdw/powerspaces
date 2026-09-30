// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CSpaceSwitch

/// Thin Swift facade over the C `CSpaceSwitch` engine, so the private-CGEvent C
/// dependency is touched from exactly one place (the same way `CGSPrivate.swift`
/// isolates the private CGS bindings).
///
/// "Faster desktop switch" intercepts the real horizontal trackpad space-switch
/// swipe and replaces it with an accelerated synthetic switch in the same
/// direction. macOS 27 may retain a short slide to keep desktop rendering stable.
///
/// The instant-switch technique is adapted from InstantSpaceSwitcher (MIT):
/// https://github.com/jurplel/InstantSpaceSwitcher
enum FasterDesktopSwitch {
    static var awaitingPermission: Bool {
        let status = psw_switch_status_current()
        return status == PSWSwitchAccessibility || status == PSWSwitchPostEventAccess
    }
    static var hasAccess: Bool { psw_switch_access_granted() }
    static var hotkeysNeedRestore: Bool { psw_space_hotkeys_need_restore() }
    static var unavailableMessage: String {
        switch psw_switch_status_current() {
        case PSWSwitchAccessibility:
            return "Allow Powerspaces to control your Mac in System Settings ▸ Privacy & Security ▸ Accessibility. Then fast switching can resume."
        case PSWSwitchPostEventAccess:
            return "Accessibility is granted, but macOS has not allowed Powerspaces to send input events. Approve the macOS permission request; if denied, review Powerspaces in Privacy & Security."
        case PSWSwitchTapFailure:
            return "Fast switching could not start its input handler. Normal desktop switching is active; toggle fast switching to retry."
        case PSWSwitchUnsupported:
            return "Fast switching is unavailable on this macOS version. Normal desktop switching is active."
        case PSWSwitchHotkeyFailure:
            return "Fast switching could not update or restore the desktop shortcuts. Relaunch Powerspaces to retry recovery."
        case PSWSwitchEventFailure:
            return "Fast switching could not prepare compatible gesture events. Normal desktop switching is active."
        default:
            return "Fast switching could not start because desktop information is unavailable. Try enabling it again."
        }
    }

    static func installFailureHandler() {
        psw_set_switch_failure_handler {
            MainActor.assumeIsolated { HUD.show(FasterDesktopSwitch.unavailableMessage, force: true) }
        }
    }

    static func checkHealth() { psw_check_switch_health() }
    /// Enable or disable swipe interception. A failed enable leaves native
    /// switching active; `unavailableMessage` explains the reason.
    @discardableResult
    static func setSwipeEnabled(_ enabled: Bool) -> Bool {
        psw_set_swipe_override_enabled(enabled)
    }

    /// Enable or disable the **keyboard** override. When enabling, it reads the
    /// user's current "Move left/right a space" binding and adopts it (disabling
    /// the system shortcut while on). Recovery preserves the exact enabled states.
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

    /// Restore the exact saved states before taking over shortcuts again.
    /// Legacy runs recorded only a boolean; migrate that marker once.
    @discardableResult
    static func restoreSpaceHotkeys(legacyRecovery: Bool = false) -> Bool {
        psw_recover_space_hotkeys(legacyRecovery)
    }
}
