// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// The swipe handling in psw_gesture_decision was moved here from CSpaceSwitch.c,
// which is adapted from InstantSpaceSwitcher (MIT): see THIRD-PARTY-NOTICES.md.
// SPDX-License-Identifier: (GPL-3.0-only AND MIT)

#include "include/CSpaceSwitch.h"

psw_transition_action psw_transition_decision(uint64_t start, uint64_t expected,
    uint64_t current, bool valid, double elapsed) {
    if (!start || !expected || expected == start) return PSWTransitionFailed;
    // A delayed main-loop callback can observe success after the deadline.
    // Fresh evidence of the requested desktop takes precedence over elapsed time.
    if (valid && current == expected) return PSWTransitionConfirmed;
    if (elapsed >= kPSWConfirmationDeadline) return PSWTransitionFailed;
    if (!valid) return PSWTransitionWaiting;
    return current == start ? PSWTransitionWaiting : PSWTransitionFailed;
}

psw_gesture_action psw_gesture_decision(psw_gesture_state *state, int phase,
                                       double progress, double velocity, bool nativeActive) {
    switch (phase) {
    case 1: // began
        state->tracking = !nativeActive;
        state->bypass = nativeActive;
        state->fired = false;
        return nativeActive ? PSWGesturePass : PSWGestureSuppress;
    case 2: // changed
        if (state->bypass || !state->tracking) return PSWGesturePass;
        // If native interaction begins mid-gesture, suppress the intercepted
        // remainder without injecting a switch or passing a half-gesture.
        if (nativeActive) state->fired = true;
        if (!state->fired && progress != 0) {
            state->fired = true;
            return progress > 0 ? PSWGestureRight : PSWGestureLeft;
        }
        return PSWGestureSuppress;
    case 4: // ended
    case 8: { // cancelled
        psw_gesture_action action = state->tracking ? PSWGestureSuppress : PSWGesturePass;
        if (phase == 4 && state->tracking && !state->fired && !nativeActive && velocity != 0)
            action = velocity > 0 ? PSWGestureRight : PSWGestureLeft;
        *state = (psw_gesture_state){0};
        return action;
    }
    default:
        return state->tracking ? PSWGestureSuppress : PSWGesturePass;
    }
}
