// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

#ifndef POWERSPACES_CSPACESWITCH_H
#define POWERSPACES_CSPACESWITCH_H

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    PSWSwitchReady, PSWSwitchAccessibility, PSWSwitchUnsupported,
    PSWSwitchEventFailure, PSWSwitchHotkeyFailure, PSWSwitchTransitionFailure,
    PSWSwitchPostEventAccess, PSWSwitchTapFailure
} psw_switch_status;
psw_switch_status psw_switch_status_current(void);
bool psw_switch_access_granted(void);
/// Read-only: Ready, Accessibility, or PostEventAccess. Never prompts.
psw_switch_status psw_switch_access_status(void);
void psw_set_switch_failure_handler(void (*handler)(void));
void psw_check_switch_health(void);
bool psw_space_hotkeys_need_restore(void);
bool psw_recover_space_hotkeys(bool legacyRecovery);

/// Pure confirmation policy; notification receipt alone cannot confirm a switch.
static const double kPSWConfirmationDeadline = 0.75; // seconds from the first posted phase
typedef enum { PSWTransitionWaiting, PSWTransitionConfirmed, PSWTransitionFailed } psw_transition_action;
psw_transition_action psw_transition_decision(uint64_t start, uint64_t expected,
    uint64_t current, bool valid, double elapsed);

/// Pure gesture policy, shared with the dependency-free regression runner.
typedef struct { bool tracking, bypass, fired; } psw_gesture_state;
typedef enum {
    PSWGesturePass, PSWGestureSuppress, PSWGestureLeft, PSWGestureRight
} psw_gesture_action;
psw_gesture_action psw_gesture_decision(psw_gesture_state *state, int phase,
                                       double progress, double velocity, bool nativeActive);

/**
 * @brief Enable or disable "faster desktop switch".
 *
 * When enabled, a session-level CGEvent tap intercepts the real horizontal
 * trackpad space-switch swipe and replaces it with an accelerated synthetic
 * switch in the same direction. macOS 27 may retain a short slide animation.
 * The user's swipe gesture is
 * unchanged — it just lands immediately.
 *
 * Enabling installs the event tap, which requires the host process to be trusted
 * for Accessibility and event posting. Returns true if the requested state was
 * reached. A false result may mean missing permission, unsupported event format,
 * or unavailable display state. Disabling stops new interception; the shared tap
 * remains while keyboard interception or an intercepted gesture still needs it.
 * Call on the main thread (the tap is driven by the main run loop).
 */
bool psw_set_swipe_override_enabled(bool enabled);

/**
 * @brief Enable or disable the keyboard override.
 *
 * When enabled, the system "Move left/right a space" symbolic hotkeys (IDs
 * 79/80/81/82) are disabled (and their prior state restored on disable), and the
 * event tap swallows a key-down whose virtual keycode + modifier mask match
 * @c leftKeyCode/leftModifiers (→ switch left) or @c rightKeyCode/rightModifiers
 * (→ switch right), firing an instant switch instead. Modifier masks use
 * CGEventFlags bits (command/option/control/shift); only those bits are compared.
 *
 * Disabling the native hotkey first is what makes this reliable: the key-down is
 * then an ordinary event the tap can suppress, with no competing animated switch.
 *
 * Returns true if the requested state was reached. Disabling may return false if
 * shortcut restoration failed; its durable recovery journal is kept for retry.
 */
bool psw_set_keyboard_override_enabled(bool enabled,
                                       unsigned short leftKeyCode,
                                       unsigned long long leftModifiers,
                                       unsigned short rightKeyCode,
                                       unsigned long long rightModifiers);

#endif /* POWERSPACES_CSPACESWITCH_H */
