// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

#ifndef POWERSPACES_CSPACESWITCH_H
#define POWERSPACES_CSPACESWITCH_H

#include <stdbool.h>

/**
 * @brief Enable or disable "faster desktop switch".
 *
 * When enabled, a session-level CGEvent tap intercepts the real horizontal
 * trackpad space-switch swipe and replaces it with an instant (no slide
 * animation) synthetic switch in the same direction. The user's swipe gesture is
 * unchanged — it just lands immediately.
 *
 * Enabling installs the event tap, which requires the host process to be trusted
 * for Accessibility. Returns true if the requested state was reached, false only
 * if enabling failed (typically because the tap couldn't be created without
 * Accessibility). Disabling always succeeds and removes the tap.
 *
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
 * Returns true if the requested state was reached; false only if enabling failed
 * because the event tap couldn't be created (typically missing Accessibility).
 */
bool psw_set_keyboard_override_enabled(bool enabled,
                                       unsigned short leftKeyCode,
                                       unsigned long long leftModifiers,
                                       unsigned short rightKeyCode,
                                       unsigned long long rightModifiers);

/**
 * @brief Force-enable the space-switch symbolic hotkeys (IDs 79/80/81/82).
 *
 * Crash recovery: call once on launch if a prior run disabled them for the
 * keyboard override but didn't get to restore them (e.g. it crashed).
 */
void psw_restore_space_hotkeys(void);

#endif /* POWERSPACES_CSPACESWITCH_H */
