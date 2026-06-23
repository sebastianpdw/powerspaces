// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// Portions adapted from InstantSpaceSwitcher (Benjamin Owad / jurplel), used under
// the MIT license — see the attribution below and THIRD-PARTY-NOTICES.md.
// SPDX-License-Identifier: (GPL-3.0-only AND MIT)

// CSpaceSwitch — instant macOS Space switching.
//
// It replaces a Space switch with a *synthetic*, high-velocity "Dock swipe"
// CGEvent built with a near-zero `progress` (±FLT_TRUE_MIN), which makes macOS
// perform its own native switch but skip the slide animation. Two independent
// paths feed it, sharing one session event tap:
//
//   • Swipe override   — swallow the real horizontal trackpad swipe and post the
//                        instant one in its place.
//   • Keyboard override — disable the system "Move left/right a space" symbolic
//                        hotkeys (so they stop animating), then swallow a matching
//                        key-down and fire the instant switch instead. Disabling
//                        the native hotkey first is what makes interception
//                        reliable: the key-down is then an ordinary event.
//
// The instant-switch technique and the private CGEvent field numbers are adapted
// from InstantSpaceSwitcher by jurplel, used under the MIT license:
//   https://github.com/jurplel/InstantSpaceSwitcher
//   Copyright (c) 2026 jurplel — MIT License.
// (ISS does not intercept the keyboard shortcut; it registers its own hotkey. The
// disable-and-adopt keyboard path here is specific to Powerspaces.)

#include "include/CSpaceSwitch.h"

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <float.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

// Private/undocumented CGEvent fields (numbers observed empirically; see ISS).
static const CGEventField kFieldEventType      = (CGEventField)55;
static const CGEventField kFieldGestureHIDType = (CGEventField)110;
static const CGEventField kFieldSwipeMotion    = (CGEventField)123;
static const CGEventField kFieldSwipeProgress  = (CGEventField)124;
static const CGEventField kFieldSwipeVelocityX = (CGEventField)129;
static const CGEventField kFieldSwipeVelocityY = (CGEventField)130;
static const CGEventField kFieldGesturePhase   = (CGEventField)132;

// IOHIDEventType (IOHIDFamily): a horizontal three/four-finger "Dock swipe".
static const uint32_t kIOHIDEventTypeDockSwipe = 23;

// CGS event types (the value held in field 55).
enum {
    kCGSEventGesture     = 29,
    kCGSEventDockControl = 30,
};

// Gesture phases (field 132).
enum {
    kPhaseBegan     = 1,
    kPhaseChanged   = 2,
    kPhaseEnded     = 4,
    kPhaseCancelled = 8,
};

// Swipe motion (field 123).
enum { kMotionHorizontal = 1 };

typedef enum { DirLeft = 0, DirRight = 1 } Direction;

// The device-independent modifier bits we compare for keyboard matching. These
// CGEventFlags values match the modifier masks stored in com.apple.symbolichotkeys.
static const uint64_t kModMask = (uint64_t)(kCGEventFlagMaskShift | kCGEventFlagMaskControl
                                            | kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand);

// The "Move left/right a space" symbolic hotkey IDs (left = 79/80, right = 81/82).
static const int kSpaceHotkeyIDs[4] = {79, 80, 81, 82};

// Private CGS (SkyLight) symbolic-hotkey API. Bound weakly at load time from the
// already-loaded frameworks (same approach ISS uses for the CGS read calls); we
// null-check the address before every use.
typedef int CGSSymbolicHotKey;
extern CGError CGSSetSymbolicHotKeyEnabled(CGSSymbolicHotKey hotKey, bool isEnabled) __attribute__((weak_import));
extern bool CGSIsSymbolicHotKeyEnabled(CGSSymbolicHotKey hotKey) __attribute__((weak_import));

// ±FLT_TRUE_MIN progress with a high velocity makes the switch instant.
static const double kGestureSpeed = 2000.0;

static CFMachPortRef gTap = NULL;
static CFRunLoopSourceRef gSource = NULL;

static bool gSwipeEnabled = false;
static bool gTracking = false;  // inside a real swipe we're handling
static bool gFired = false;     // already posted the instant switch for this swipe

static bool gKeyboardEnabled = false;
static uint16_t gLeftKey = 0, gRightKey = 0;
static uint64_t gLeftMods = 0, gRightMods = 0;
static bool gHotkeysDisabledByUs = false;
static bool gPrevHotkeyEnabled[4] = {true, true, true, true};

static void post_dock_swipe(int phase, Direction dir) {
    const bool right = (dir == DirRight);
    const double progress = right ? (double)FLT_TRUE_MIN : -(double)FLT_TRUE_MIN;
    const double vel = right ? kGestureSpeed : -kGestureSpeed;

    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) return;
    CGEventSetIntegerValueField(ev, kFieldEventType, kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, kFieldGestureHIDType, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kFieldGesturePhase, phase);
    CGEventSetDoubleValueField(ev, kFieldSwipeProgress, progress);
    CGEventSetIntegerValueField(ev, kFieldSwipeMotion, kMotionHorizontal);
    CGEventSetDoubleValueField(ev, kFieldSwipeVelocityX, vel);
    CGEventSetDoubleValueField(ev, kFieldSwipeVelocityY, vel);
    CGEventPost(kCGSessionEventTap, ev);
    CFRelease(ev);
}

// Began → Changed → Ended; all three are required or the switch doesn't take.
static void perform_instant_switch(Direction dir) {
    post_dock_swipe(kPhaseBegan, dir);
    post_dock_swipe(kPhaseChanged, dir);
    post_dock_swipe(kPhaseEnded, dir);
}

// MARK: - Symbolic hotkey enable/disable (keyboard override)

static void disable_space_hotkeys(void) {
    if (gHotkeysDisabledByUs) return;
    if (&CGSSetSymbolicHotKeyEnabled == NULL) return;
    for (int i = 0; i < 4; i++) {
        gPrevHotkeyEnabled[i] =
            (&CGSIsSymbolicHotKeyEnabled != NULL) ? CGSIsSymbolicHotKeyEnabled(kSpaceHotkeyIDs[i]) : true;
        CGSSetSymbolicHotKeyEnabled(kSpaceHotkeyIDs[i], false);
    }
    gHotkeysDisabledByUs = true;
}

static void restore_space_hotkeys_internal(void) {
    if (!gHotkeysDisabledByUs) return;
    if (&CGSSetSymbolicHotKeyEnabled != NULL) {
        for (int i = 0; i < 4; i++) {
            CGSSetSymbolicHotKeyEnabled(kSpaceHotkeyIDs[i], gPrevHotkeyEnabled[i]);
        }
    }
    gHotkeysDisabledByUs = false;
}

void psw_restore_space_hotkeys(void) {
    if (&CGSSetSymbolicHotKeyEnabled != NULL) {
        for (int i = 0; i < 4; i++) CGSSetSymbolicHotKeyEnabled(kSpaceHotkeyIDs[i], true);
    }
    gHotkeysDisabledByUs = false;
}

// MARK: - Event tap

static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type,
                               CGEventRef event, void *refcon) {
    (void)proxy;
    (void)refcon;

    // Re-arm if the system disabled our tap (e.g. it was momentarily too slow).
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gTap) CGEventTapEnable(gTap, true);
        return event;
    }

    // Keyboard override: the native space hotkey is disabled while this is on, so
    // the key-down is an ordinary event we can match and swallow.
    if (type == kCGEventKeyDown) {
        if (!gKeyboardEnabled) return event;
        uint16_t key = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        uint64_t mods = (uint64_t)CGEventGetFlags(event) & kModMask;
        bool matchesLeft = (gLeftKey != 0 && key == gLeftKey && mods == gLeftMods);
        bool matchesRight = (gRightKey != 0 && key == gRightKey && mods == gRightMods);
        if (!matchesLeft && !matchesRight) return event;
        // Fire once per physical press; swallow autorepeats so the app sees nothing.
        if (CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) == 0) {
            perform_instant_switch(matchesLeft ? DirLeft : DirRight);
        }
        return NULL;
    }

    if (!gSwipeEnabled) return event;

    uint32_t evType = (uint32_t)CGEventGetIntegerValueField(event, kFieldEventType);

    // Let our own synthetic events through (real trackpad gestures come from the
    // HID kernel with sourcePid == 0; the ones we post have a nonzero pid), so we
    // don't intercept ourselves into a loop.
    if (evType == kCGSEventDockControl || evType == kCGSEventGesture) {
        pid_t pid = (pid_t)CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
        if (pid != 0) return event;
    }

    if (evType == kCGSEventDockControl) {
        uint32_t hid = (uint32_t)CGEventGetIntegerValueField(event, kFieldGestureHIDType);
        if (hid != kIOHIDEventTypeDockSwipe) return event;
        uint16_t motion = (uint16_t)CGEventGetIntegerValueField(event, kFieldSwipeMotion);
        if (motion != kMotionHorizontal) return event;

        int phase = (int)CGEventGetIntegerValueField(event, kFieldGesturePhase);
        switch (phase) {
        case kPhaseBegan:
            gTracking = true;
            gFired = false;
            return NULL;
        case kPhaseChanged:
            if (!gTracking) return event;
            if (!gFired) {
                double p = CGEventGetDoubleValueField(event, kFieldSwipeProgress);
                if (p != 0.0) {
                    gFired = true;
                    perform_instant_switch(p > 0 ? DirRight : DirLeft);
                }
            }
            return NULL;
        case kPhaseEnded:
            if (!gTracking) return event;
            if (!gFired) {
                double v = CGEventGetDoubleValueField(event, kFieldSwipeVelocityX);
                if (v != 0.0) {
                    gFired = true;
                    perform_instant_switch(v > 0 ? DirRight : DirLeft);
                }
            }
            gTracking = false;
            gFired = false;
            return NULL;
        case kPhaseCancelled:
            gTracking = false;
            gFired = false;
            return NULL;
        default:
            return gTracking ? NULL : event;
        }
    }

    // While handling a swipe, swallow its companion gesture events too.
    if (evType == kCGSEventGesture && gTracking) return NULL;

    return event;
}

static bool ensure_tap(void) {
    if (gTap) return true;
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown)
        | (1ULL << kCGSEventGesture) | (1ULL << kCGSEventDockControl);
    gTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                            kCGEventTapOptionDefault, mask, tap_callback, NULL);
    if (!gTap) return false;
    gSource = CFMachPortCreateRunLoopSource(NULL, gTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), gSource, kCFRunLoopCommonModes);
    CGEventTapEnable(gTap, true);
    return true;
}

static void destroy_tap(void) {
    if (!gTap) return;
    CGEventTapEnable(gTap, false);
    if (gSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), gSource, kCFRunLoopCommonModes);
        CFRelease(gSource);
        gSource = NULL;
    }
    CFRelease(gTap);
    gTap = NULL;
}

// Create the shared tap if either path needs it; tear it down when neither does.
static bool refresh_tap(void) {
    if (gSwipeEnabled || gKeyboardEnabled) return ensure_tap();
    destroy_tap();
    return true;
}

bool psw_set_swipe_override_enabled(bool enabled) {
    gSwipeEnabled = enabled;
    if (!enabled) {
        gTracking = false;
        gFired = false;
    }
    if (!refresh_tap()) {
        gSwipeEnabled = false;
        return !enabled; // disabling always "succeeds"
    }
    return true;
}

bool psw_set_keyboard_override_enabled(bool enabled,
                                       unsigned short leftKeyCode, unsigned long long leftModifiers,
                                       unsigned short rightKeyCode, unsigned long long rightModifiers) {
    if (enabled) {
        gLeftKey = leftKeyCode;
        gLeftMods = (uint64_t)leftModifiers & kModMask;
        gRightKey = rightKeyCode;
        gRightMods = (uint64_t)rightModifiers & kModMask;
        gKeyboardEnabled = true;
        if (!refresh_tap()) {
            gKeyboardEnabled = false;
            return false;
        }
        disable_space_hotkeys();
        return true;
    }
    gKeyboardEnabled = false;
    restore_space_hotkeys_internal();
    refresh_tap();
    return true;
}
