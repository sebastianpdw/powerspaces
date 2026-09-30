// Powerspaces
// Payload layout adapted from jurplel/InstantSpaceSwitcher, macos-27 bf32cf9 (MIT).
// Copyright (c) 2026 jurplel. See THIRD-PARTY-NOTICES.md.
// SPDX-License-Identifier: (GPL-3.0-only AND MIT)
#include "EventSerialization.h"
#include <CoreFoundation/CoreFoundation.h>
#include <float.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

// The enclosing CGEvent tag is big endian; Apple's IOHID structures are native
// little endian on all supported Macs. Assert every packed record size.
#pragma pack(push, 1)
typedef struct { uint32_t size, type, options; uint8_t depth, reserved[3]; } HIDBase;
typedef struct {
    HIDBase base; int32_t x, y, z; uint32_t swipeMask;
    uint16_t motion, flavor; int32_t progress;
} HIDFluid;
typedef struct { HIDBase base; int32_t x, y, z; } HIDVelocity;
typedef struct { uint64_t timestamp, sender; uint32_t options, attributes, count; } HIDHeader;
typedef struct { HIDHeader header; HIDFluid fluid; HIDVelocity velocity; } HIDPayload;
#pragma pack(pop)
_Static_assert(sizeof(HIDBase) == 16, "IOHID base layout changed");
_Static_assert(sizeof(HIDFluid) == 40, "IOHID fluid layout changed");
_Static_assert(sizeof(HIDVelocity) == 28, "IOHID velocity layout changed");
_Static_assert(sizeof(HIDHeader) == 28, "IOHID header layout changed");
static const int64_t kPSWMarker = INT64_C(0x5053575357495045);
static CGEventTimestamp next_timestamp(void) {
    static mach_timebase_info_data_t base;
    static CGEventTimestamp previous;
    if (!base.denom) mach_timebase_info(&base);
    CGEventTimestamp now = (CGEventTimestamp)((long double)mach_absolute_time() * base.numer / base.denom);
    previous = now > previous ? now : previous + 1;
    return previous;
}
void psw_stamp_event(CGEventRef event) {
    if (event) CGEventSetTimestamp(event, next_timestamp());
}
double psw_monotonic_time(void) {
    mach_timebase_info_data_t base; mach_timebase_info(&base);
    return (double)((long double)mach_continuous_time() * base.numer / base.denom / 1e9);
}

int psw_backend_for_major(int major) {
    if (major >= 14 && major <= 26) return PSWBackendLegacy;
    return major == 27 ? PSWBackendModern : PSWBackendUnsupported;
}
int psw_current_backend(void) {
    char version[32] = {0}; size_t size = sizeof(version); int major = 0;
    if (sysctlbyname("kern.osproductversion", version, &size, NULL, 0) != 0
        || sscanf(version, "%d", &major) != 1) return PSWBackendUnsupported;
    return psw_backend_for_major(major);
}
static int32_t fixed1616(double value) {
    if (!isfinite(value)) return 0;
    double scaled = value * 65536.0;
    if (scaled >= INT32_MAX) return INT32_MAX;
    if (scaled <= INT32_MIN) return INT32_MIN;
    int32_t result = (int32_t)scaled;
    return result == 0 && value != 0 ? (value > 0 ? 1 : -1) : result;
}
static CGEventRef augment_event(CGEventRef event) {
    HIDPayload payload = {0};
    int phase = (int)CGEventGetIntegerValueField(event, kFieldGesturePhase);
    double vx = CGEventGetDoubleValueField(event, kFieldSwipeVelocityX);
    double vy = CGEventGetDoubleValueField(event, kFieldSwipeVelocityY);
    bool velocity = vx != 0 || vy != 0 || phase == kPhaseEnded;
    size_t payloadLength = sizeof(HIDHeader) + sizeof(HIDFluid)
        + (velocity ? sizeof(HIDVelocity) : 0);
    payload.header.timestamp = CGEventGetTimestamp(event);
    if (!payload.header.timestamp) payload.header.timestamp = mach_absolute_time();
    payload.header.count = velocity ? 2 : 1;
    payload.fluid.base = (HIDBase){.size = sizeof(HIDFluid), .type = kIOHIDEventTypeDockSwipe,
                                  .options = (uint32_t)phase << 24};
    payload.fluid.x = fixed1616(CGEventGetDoubleValueField(event, kFieldSwipePositionX));
    payload.fluid.motion = 1; payload.fluid.flavor = 3;
    payload.fluid.progress = fixed1616(CGEventGetDoubleValueField(event, kFieldSwipeProgress));
    if (velocity) {
        payload.velocity.base = (HIDBase){.size = sizeof(HIDVelocity), .type = 9, .depth = 1};
        payload.velocity.x = fixed1616(vx); payload.velocity.y = fixed1616(vy);
    }
    CFDataRef data = CGEventCreateData(NULL, event);
    if (!data) return NULL;
    CFIndex length = CFDataGetLength(data); const uint8_t *bytes = CFDataGetBytePtr(data);
    if (length < 4 || bytes[0] || bytes[1] || bytes[2] || bytes[3] != 2
        || length > LONG_MAX - 4 - (CFIndex)payloadLength) { CFRelease(data); return NULL; }
    size_t total = (size_t)length + 4 + payloadLength;
    uint8_t *buffer = malloc(total);
    if (!buffer) { CFRelease(data); return NULL; }
    memcpy(buffer, bytes, (size_t)length);
    buffer[length] = (uint8_t)(payloadLength >> 8); buffer[length + 1] = (uint8_t)payloadLength;
    buffer[length + 2] = (uint8_t)(4205 >> 8); buffer[length + 3] = (uint8_t)4205;
    memcpy(buffer + length + 4, &payload, payloadLength);
    CFRelease(data);
    CFDataRef augmented = CFDataCreate(NULL, buffer, (CFIndex)total); free(buffer);
    if (!augmented) return NULL;
    CGEventRef result = CGEventCreateFromData(NULL, augmented); CFRelease(augmented);
    return result;
}
bool psw_event_is_marked(CGEventRef event) {
    return event && CGEventGetIntegerValueField(event, kCGEventSourceUserData) == kPSWMarker;
}
CGEventRef psw_create_swipe_event(bool modern, int phase, bool right, bool neutral,
                                bool naturalScrolling, psw_event_factory factory) {
    CGEventRef event = factory(NULL); if (!event) return NULL;
    double sign = right ? 1 : -1;
    // macOS 27 interprets synthetic output relative to Natural Scrolling.
    // Hardware input already reflects that setting; only output needs this.
    if (modern && !naturalScrolling) sign = -sign;
    // Near-zero progress can leave macOS 27 surfaces black even when all phases
    // are paced. Complete travel is the conservative rendering baseline; it
    // may retain a short animation. Keep the pre-27 format unchanged.
    double progress = neutral ? 0 : modern ? -sign : sign * FLT_TRUE_MIN;
    double velocity = neutral ? 0 : sign * 2000;
    CGEventSetIntegerValueField(event, kFieldEventType, kCGSEventDockControl);
    CGEventSetIntegerValueField(event, kFieldGestureHIDType, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(event, kFieldGesturePhase, phase);
    CGEventSetIntegerValueField(event, kFieldSwipeMotion, kMotionHorizontal);
    CGEventSetDoubleValueField(event, kFieldSwipeProgress, progress);
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, kPSWMarker);
    if (modern) {
        CGEventSetIntegerValueField(event, kFieldGesturePhaseAlias, phase);
        CGEventSetDoubleValueField(event, kFieldGestureZoomDeltaY, 3);
        CGEventSetDoubleValueField(event, kFieldSourceUnixProcessIDAlias, (double)mach_absolute_time());
        CGEventSetDoubleValueField(event, kFieldSwipePositionX, 0.1);
        if (phase == kPhaseEnded) CGEventSetDoubleValueField(event, kFieldSwipeVelocityX, -velocity);
        CGEventRef augmented = augment_event(event); CFRelease(event); event = augmented;
        // CGEventCreateFromData drops source metadata on macOS 27. Reapply the
        // marker to the reconstructed event instead of assuming it survived.
        if (event) CGEventSetIntegerValueField(event, kCGEventSourceUserData, kPSWMarker);
        // Never intercept input if the serialized event loses our recursion marker.
        if (event && !psw_event_is_marked(event)) { CFRelease(event); event = NULL; }
    } else {
        CGEventSetDoubleValueField(event, kFieldSwipeVelocityX, velocity);
        CGEventSetDoubleValueField(event, kFieldSwipeVelocityY, velocity);
    }
    // Source/timestamp metadata belongs on the reconstructed CGEvent. The IOHID
    // header keeps the upstream Mach timestamp, rather than an outer ns value.
    if (event) CGEventSetTimestamp(event, next_timestamp());
    return event;
}
void psw_release_sequence(psw_event_sequence *sequence) {
    for (int i = 0; i < PSWSequenceCapacity; i++)
        if (sequence->events[i]) CFRelease(sequence->events[i]);
    *sequence = (psw_event_sequence){0};
}
bool psw_create_sequence(psw_event_sequence *out, bool modern, bool right, bool naturalScrolling,
                         psw_event_factory factory) {
    *out = (psw_event_sequence){.modern = modern, .naturalScrolling = naturalScrolling};
    const int phases[] = {kPhaseBegan, kPhaseChanged, kPhaseEnded};
    for (int i = 0; i < 3; i++) {
        out->events[i * 2] = psw_create_swipe_event(modern, phases[i], right, false, naturalScrolling, factory);
        if (!out->events[i * 2]) goto failed;
        if (modern) {
            CGEventRef companion = factory(NULL);
            if (!companion) goto failed;
            CGEventSetIntegerValueField(companion, kFieldEventType, kCGSEventGesture);
            CGEventSetIntegerValueField(companion, kCGEventSourceUserData, kPSWMarker);
            CGEventSetTimestamp(companion, next_timestamp());
            out->events[i * 2 + 1] = companion;
        }
    }
    return true;
failed:
    psw_release_sequence(out); return false;
}
