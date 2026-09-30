// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// Portions adapted from InstantSpaceSwitcher (Benjamin Owad / jurplel), used under
// the MIT license — see the attribution below and THIRD-PARTY-NOTICES.md.
// SPDX-License-Identifier: (GPL-3.0-only AND MIT)

// CSpaceSwitch — instant macOS Space switching.
//
// It replaces a Space switch with a *synthetic*, high-velocity "Dock swipe"
// CGEvent with a version-specific payload. Older versions use near-zero progress
// to skip the slide; macOS 27 uses complete travel to protect desktop rendering.
// Two independent
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
#include "EventSerialization.h"
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <os/log.h>

// All engine state and callbacks run on the main run loop.
extern int CGSMainConnectionID(void) __attribute__((weak_import));
extern CFArrayRef CGSCopyManagedDisplaySpaces(int) __attribute__((weak_import));
extern CFStringRef CGSCopyActiveMenuBarDisplayIdentifier(int) __attribute__((weak_import));
extern CGError CGSSetSymbolicHotKeyEnabled(int, bool) __attribute__((weak_import));
extern bool CGSIsSymbolicHotKeyEnabled(int) __attribute__((weak_import));
static const int kSpaceHotkeyIDs[] = {79, 80, 81, 82};
static const uint64_t kModMask = kCGEventFlagMaskShift | kCGEventFlagMaskControl
    | kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand;
static const CFStringRef kJournalDomain = CFSTR("nl.sebastianpdw.powerspaces");
static const CFStringRef kJournalKey = CFSTR("PSWOriginalSpaceHotkeys");
enum { QueueCapacity = 8 };

typedef struct { CFStringRef display; uint64_t current, left, right; CGPoint location; } SpaceContext;
typedef struct {
    psw_event_sequence sequence;
    CGEventRef cancel;
    CFStringRef display;
    bool right;
} SwitchRequest;
static uint64_t space_id(CFDictionaryRef space) {
    const void *value = CFDictionaryGetValue(space, CFSTR("ManagedSpaceID"));
    if (!value) value = CFDictionaryGetValue(space, CFSTR("id64"));
    int64_t result = 0;
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()
        || !CFNumberGetValue(value, kCFNumberSInt64Type, &result) || result <= 0) return 0;
    return (uint64_t)result;
}
static CGPoint point_on_display(CGPoint point, CGRect bounds) {
    return CGRectContainsPoint(bounds, point) ? point
        : CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
}
static bool event_location_for_display(CFStringRef identifier, CGPoint *out) {
    CGEventRef probe = CGEventCreate(NULL);
    if (!probe) return false;
    CGPoint point = CGEventGetLocation(probe); CFRelease(probe);
    if (!isfinite(point.x) || !isfinite(point.y)) return false;
    if (CFEqual(identifier, CFSTR("Main"))) {
        CGDirectDisplayID display; uint32_t count = 0;
        if (CGGetDisplaysWithPoint(point, 1, &display, &count) != kCGErrorSuccess || !count) return false;
        *out = point; return true; // Shared desktops use the physical cursor display.
    }
    uint32_t count = 0;
    if (CGGetActiveDisplayList(0, NULL, &count) != kCGErrorSuccess || !count) return false;
    CGDirectDisplayID *ids = calloc(count, sizeof(*ids));
    if (!ids) return false;
    bool found = false;
    if (CGGetActiveDisplayList(count, ids, &count) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < count && !found; i++) {
            CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(ids[i]);
            CFStringRef name = uuid ? CFUUIDCreateString(NULL, uuid) : NULL;
            if (name && CFEqual(name, identifier)) {
                CGRect bounds = CGDisplayBounds(ids[i]);
                if (!CGRectIsEmpty(bounds) && !CGRectIsInfinite(bounds)) {
                    *out = point_on_display(point, bounds); found = true;
                }
            }
            if (name) CFRelease(name);
            if (uuid) CFRelease(uuid);
        }
    }
    free(ids); return found;
}
static bool read_space_context(CFStringRef wantedDisplay, bool cursor, SpaceContext *out) {
    *out = (SpaceContext){0};
    if (!CGSMainConnectionID || !CGSCopyManagedDisplaySpaces) return false;
    int connection = CGSMainConnectionID();
    if (!connection) return false;
    CFStringRef selected = wantedDisplay ? CFRetain(wantedDisplay) : NULL;
    if (!selected && cursor) {
        CGEventRef probe = CGEventCreate(NULL);
        if (!probe) return false;
        CGPoint point = CGEventGetLocation(probe); CFRelease(probe);
        CGDirectDisplayID display = 0; uint32_t count = 0;
        if (CGGetDisplaysWithPoint(point, 1, &display, &count) == kCGErrorSuccess && count) {
            CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
            if (uuid) { selected = CFUUIDCreateString(NULL, uuid); CFRelease(uuid); }
        }
    } else if (!selected && CGSCopyActiveMenuBarDisplayIdentifier) {
        selected = CGSCopyActiveMenuBarDisplayIdentifier(connection);
    }
    CFArrayRef displays = CGSCopyManagedDisplaySpaces(connection);
    bool ok = false;
    if (!displays || CFGetTypeID(displays) != CFArrayGetTypeID()) goto finished;
    CFIndex count = CFArrayGetCount(displays);
    for (CFIndex i = 0; i < count; i++) {
        const void *raw = CFArrayGetValueAtIndex(displays, i);
        if (CFGetTypeID(raw) != CFDictionaryGetTypeID()) continue;
        CFDictionaryRef display = raw;
        const void *identifier = CFDictionaryGetValue(display, CFSTR("Display Identifier"));
        if (!identifier || CFGetTypeID(identifier) != CFStringGetTypeID()) continue;
        bool matches = selected && CFEqual(identifier, selected);
        // Shared Spaces are represented by a single "Main" display. Never guess
        // another display when confirming an already captured request.
        bool shared = !wantedDisplay && count == 1 && CFEqual(identifier, CFSTR("Main"));
        if (!matches && !shared && !(count == 1 && !selected)) continue;
        const void *current = CFDictionaryGetValue(display, CFSTR("Current Space"));
        const void *spaces = CFDictionaryGetValue(display, CFSTR("Spaces"));
        if (!current || CFGetTypeID(current) != CFDictionaryGetTypeID()
            || !spaces || CFGetTypeID(spaces) != CFArrayGetTypeID()) continue;
        uint64_t active = space_id(current); CFIndex n = CFArrayGetCount(spaces);
        for (CFIndex j = 0; active && j < n; j++) {
            const void *candidate = CFArrayGetValueAtIndex(spaces, j);
            if (CFGetTypeID(candidate) != CFDictionaryGetTypeID()) break;
            if (space_id(candidate) != active) continue;
            const void *left = j > 0 ? CFArrayGetValueAtIndex(spaces, j - 1) : NULL;
            const void *right = j + 1 < n ? CFArrayGetValueAtIndex(spaces, j + 1) : NULL;
            if ((left && CFGetTypeID(left) != CFDictionaryGetTypeID())
                || (right && CFGetTypeID(right) != CFDictionaryGetTypeID())) break;
            out->current = active; out->left = left ? space_id(left) : 0;
            out->right = right ? space_id(right) : 0;
            if ((left && !out->left) || (right && !out->right)) break;
            out->display = CFRetain(identifier); ok = true; break;
        }
        break;
    }
finished:
    if (selected) CFRelease(selected);
    if (displays) CFRelease(displays);
    if (ok && !wantedDisplay && !event_location_for_display(out->display, &out->location)) {
        CFRelease(out->display); *out = (SpaceContext){0}; ok = false;
    }
    return ok;
}
// The only native interaction that diverts a switch. Dock-owned surfaces are no
// signal: on macOS 27 one lingers long after Mission Control has closed.
static bool mouse_drag_active(void) {
    return CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft);
}
static bool accessibility_trusted(void) {
    return AXIsProcessTrusted() != 0;
}
static bool natural_scrolling_enabled(void) {
    Boolean valid = false;
    Boolean enabled = CFPreferencesGetAppBooleanValue(CFSTR("com.apple.swipescrolldirection"),
        kCFPreferencesAnyApplication, &valid);
    return valid ? enabled : true; // macOS default when the preference is absent
}
// -1 is absent; -2 is corrupt. Keep corrupt journals for diagnosis, never guess.
static int read_journal(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(kJournalKey, kJournalDomain);
    if (!value) return -1;
    int mask = -2;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberIntType, &mask);
    CFRelease(value); return mask >= 0 && mask <= 15 ? mask : -2;
}
static bool write_journal(int mask) {
    CFNumberRef value = mask < 0 ? NULL : CFNumberCreate(NULL, kCFNumberIntType, &mask);
    if (mask >= 0 && !value) return false;
    CFPreferencesSetAppValue(kJournalKey, value, kJournalDomain);
    if (value) CFRelease(value);
    return CFPreferencesAppSynchronize(kJournalDomain);
}
// A small host seam lets the regression runner exercise failures without
// posting desktop events, changing shortcuts, or touching real preferences.
static bool ensure_tap(void);
static struct {
    bool (*accessibility)(void);
    bool (*postAccess)(void);
    bool (*enableTap)(void);
    bool (*context)(CFStringRef, bool, SpaceContext *);
    void (*post)(CGEventTapLocation, CGEventRef);
    int (*readJournal)(void);
    bool (*writeJournal)(int);
    CGError (*setHotkey)(int, bool);
    bool (*getHotkey)(int);
    bool (*naturalScrolling)(void);
    bool (*dragActive)(void);
    int (*backend)(void);
} gHost = {accessibility_trusted, CGPreflightPostEventAccess, ensure_tap, read_space_context,
           CGEventPost, read_journal, write_journal, CGSSetSymbolicHotKeyEnabled, CGSIsSymbolicHotKeyEnabled,
           natural_scrolling_enabled, mouse_drag_active, psw_current_backend};
static psw_event_factory gEventFactory = CGEventCreate;
static CFMachPortRef gTap;
static CFRunLoopSourceRef gSource;
static CFRunLoopTimerRef gTimer;
static bool gSwipeEnabled, gKeyboardEnabled, gHotkeysDisabledByUs;
static uint16_t gLeftKey, gRightKey;
static uint64_t gLeftMods, gRightMods;
static psw_gesture_state gGesture;
static psw_switch_status gStatus = PSWSwitchReady;
static void (*gFailureHandler)(void);
static SwitchRequest gQueue[QueueCapacity], gFlight, gSwipeLeft, gSwipeRight;
static unsigned gQueueCount, gNextPhase;
static uint64_t gStartSpace, gExpectedSpace;
static CFAbsoluteTime gStarted, gLastPhase, gLastCheck;
static CGEventRef gSwipeTerminal, gSwipeCompanion;
static CGEventRef gDeferredTerminals[QueueCapacity * 2];
static unsigned gDeferredCount;
static os_log_t gSwitchLog;
static os_log_t switch_log(void) {
    if (!gSwitchLog) gSwitchLog = os_log_create("nl.sebastianpdw.powerspaces", "desktop-switch");
    return gSwitchLog;
}
// CGEvent delivery can lose the source PID. The explicit marker is primary;
// exact recently posted timestamp/type pairs provide a bounded second check.
static struct { CGEventTimestamp time; int64_t type; CFAbsoluteTime expires; } gPosted[64];
static unsigned gPostedIndex;
static void destroy_tap(void);
static void release_swipe_terminal(void);

psw_switch_status psw_switch_status_current(void) { return gStatus; }
psw_switch_status psw_switch_access_status(void) {
    if (!gHost.accessibility()) return PSWSwitchAccessibility;
    if (!gHost.postAccess()) return PSWSwitchPostEventAccess;
    return PSWSwitchReady;
}
bool psw_switch_access_granted(void) { return psw_switch_access_status() == PSWSwitchReady; }
bool psw_space_hotkeys_need_restore(void) { return gHost.readJournal() != -1; }
void psw_set_switch_failure_handler(void (*handler)(void)) { gFailureHandler = handler; }
static bool restore_space_hotkeys_internal(void) {
    int mask = gHost.readJournal();
    if (mask == -1) { gHotkeysDisabledByUs = false; return true; }
    if (mask < 0 || !gHost.getHotkey || !gHost.setHotkey) return false;
    bool ok = true;
    for (int i = 0; i < 4; i++) {
        bool enabled = (mask & (1 << i)) != 0;
        if (gHost.setHotkey(kSpaceHotkeyIDs[i], enabled) != kCGErrorSuccess
            || gHost.getHotkey(kSpaceHotkeyIDs[i]) != enabled) ok = false;
    }
    if (ok) { gHotkeysDisabledByUs = false; ok = gHost.writeJournal(-1); }
    return ok;
}
bool psw_recover_space_hotkeys(bool legacyRecovery) {
    if (gHost.readJournal() != -1) {
        bool ok = restore_space_hotkeys_internal();
        if (!ok) gStatus = PSWSwitchHotkeyFailure;
        return ok;
    }
    if (!legacyRecovery) return true;
    // The old version stored only a boolean. This one-time migration cannot
    // recover the missing original states; new runs always save an exact mask.
    // Persist the legacy all-enabled recovery intent, so a failed migration can
    // still be retried after the old boolean has been retired.
    bool ok = gHost.writeJournal(15) && restore_space_hotkeys_internal();
    if (!ok) gStatus = PSWSwitchHotkeyFailure;
    return ok;
}
static bool disable_space_hotkeys(void) {
    if (gHotkeysDisabledByUs) return true;
    if (!gHost.getHotkey || !gHost.setHotkey || !restore_space_hotkeys_internal()) return false;
    int mask = 0;
    for (int i = 0; i < 4; i++) if (gHost.getHotkey(kSpaceHotkeyIDs[i])) mask |= 1 << i;
    if (!gHost.writeJournal(mask)) return false; // durable backup before mutation
    for (int i = 0; i < 4; i++) {
        if (gHost.setHotkey(kSpaceHotkeyIDs[i], false) != kCGErrorSuccess
            || gHost.getHotkey(kSpaceHotkeyIDs[i])) {
            (void)restore_space_hotkeys_internal(); return false;
        }
    }
    gHotkeysDisabledByUs = true; return true;
}
static void release_request(SwitchRequest *request) {
    psw_release_sequence(&request->sequence);
    if (request->cancel) CFRelease(request->cancel);
    if (request->display) CFRelease(request->display);
    *request = (SwitchRequest){0};
}
static void post_event(CGEventRef event) {
    if (!event || !gHost.postAccess()) return;
    // Queued phases and deferred terminals were created earlier. Their outer
    // delivery timestamps must follow posting order, not allocation order.
    psw_stamp_event(event);
    gPosted[gPostedIndex++ % 64] = (typeof(gPosted[0])){
        CGEventGetTimestamp(event), CGEventGetIntegerValueField(event, kFieldEventType),
        psw_monotonic_time() + 1.0};
    gHost.post(kCGSessionEventTap, event);
}
static bool own_event(CGEventRef event) {
    if (psw_event_is_marked(event)) return true;
    CFAbsoluteTime now = psw_monotonic_time();
    CGEventTimestamp time = CGEventGetTimestamp(event);
    int64_t type = CGEventGetIntegerValueField(event, kFieldEventType);
    for (unsigned i = 0; i < 64; i++)
        if (time && gPosted[i].expires > now && gPosted[i].time == time && gPosted[i].type == type) return true;
    return CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID) != 0;
}
static void flush_terminals(void) {
    for (unsigned i = 0; i < gDeferredCount; i++) {
        post_event(gDeferredTerminals[i]); CFRelease(gDeferredTerminals[i]); gDeferredTerminals[i] = NULL;
    }
    gDeferredCount = 0;
}
static void stop_timer(void) {
    if (gTimer) { CFRunLoopTimerInvalidate(gTimer); CFRelease(gTimer); gTimer = NULL; }
}
static void clear_requests(void) {
    if (gGesture.tracking) gGesture.fired = true;
    if (gFlight.display && gNextPhase > 0 && gNextPhase < 3) {
        post_event(gFlight.cancel); post_event(gFlight.sequence.events[1]);
    }
    release_request(&gFlight); gNextPhase = 0; stop_timer();
    for (unsigned i = 0; i < gQueueCount; i++) release_request(&gQueue[i]);
    gQueueCount = 0; release_request(&gSwipeLeft); release_request(&gSwipeRight);
    flush_terminals();
}
static void fail_switch_at(psw_switch_status reason, const char *function, unsigned line) {
    // A missed/stale Space observation is a request failure, not an input-handler
    // failure. Permission loss still stops interception, even if discovered here.
    if (reason == PSWSwitchTransitionFailure) {
        psw_switch_status access = psw_switch_access_status();
        if (access != PSWSwitchReady) reason = access;
    }
    bool requestOnly = reason == PSWSwitchTransitionFailure;
    // Capture the failure BEFORE clearing requests. This deliberately logs no
    // keyboard input, app/window titles, or event payloads.
    SpaceContext spaces = {0};
    bool valid = gFlight.display && gHost.context(gFlight.display, false, &spaces);
    os_log_with_type(switch_log(), requestOnly ? OS_LOG_TYPE_INFO : OS_LOG_TYPE_ERROR,
        "Fast switch %{public}s: reason=%{public}d site=%{public}s:%{public}u flight=%{public}d start=%{public}llu expected=%{public}llu current=%{public}llu snapshot=%{public}d phases=%{public}u elapsed=%{public}.3f queued=%{public}u ax=%{public}d post=%{public}d",
        requestOnly ? "request cancelled" : "stopped", reason, function, line, gFlight.display != NULL,
        (unsigned long long)(gFlight.display ? gStartSpace : 0),
        (unsigned long long)(gFlight.display ? gExpectedSpace : 0),
        (unsigned long long)(valid ? spaces.current : 0), valid, gNextPhase,
        gFlight.display ? psw_monotonic_time() - gStarted : 0, gQueueCount,
        gHost.accessibility(), gHost.postAccess());
    if (valid) CFRelease(spaces.display);
    clear_requests();
    if (requestOnly) { gStatus = PSWSwitchReady; return; }
    gSwipeEnabled = gKeyboardEnabled = false;
    // Finish suppressing an already intercepted hardware gesture. Passing its
    // remainder through would hand Dock a gesture with a missing beginning.
    // clear_requests has already marked that remainder for suppression.
    if (!restore_space_hotkeys_internal()) reason = PSWSwitchHotkeyFailure;
    gStatus = reason;
    if (gFailureHandler) gFailureHandler();
}
#define fail_switch(reason) fail_switch_at((reason), __func__, __LINE__)
void psw_check_switch_health(void) {
    if (!gSwipeEnabled && !gKeyboardEnabled) {
        if (!gGesture.tracking) destroy_tap();
        return;
    }
    if (!psw_switch_access_granted()) {
        fail_switch(psw_switch_access_status());
        gGesture = (psw_gesture_state){0}; release_swipe_terminal(); destroy_tap();
        return;
    }
    (void)gHost.enableTap(); // A no-op on a healthy tap; re-arms one left disabled.
    // A shortcut pressed during a drag hands the keys back to macOS, and while
    // macOS owns them the tap cannot count on seeing the next press. Take them
    // back here once the drag has ended.
    if (gKeyboardEnabled && !gHost.dragActive() && !disable_space_hotkeys())
        fail_switch(PSWSwitchHotkeyFailure);
}
static bool prepare_request(SwitchRequest *out, CFStringRef display, bool right, CGPoint location) {
    *out = (SwitchRequest){.right = right};
    bool modern = gHost.backend() == PSWBackendModern;
    bool naturalScrolling = !modern || gHost.naturalScrolling();
    if (!psw_create_sequence(&out->sequence, modern, right, naturalScrolling, gEventFactory)) return false;
    out->cancel = psw_create_swipe_event(modern, kPhaseCancelled, right, true, naturalScrolling, gEventFactory);
    if (!out->cancel) { release_request(out); return false; }
    // Preserve one physical destination through all phases, queueing and
    // cancellation, even if the cursor crosses to another display meanwhile.
    for (unsigned i = 0; i < PSWSequenceCapacity; i++)
        if (out->sequence.events[i]) CGEventSetLocation(out->sequence.events[i], location);
    CGEventSetLocation(out->cancel, location);
    out->display = CFRetain(display); return true;
}
static void transition_tick(CFRunLoopTimerRef timer, void *context);
static bool start_request(SwitchRequest *request) {
    if (!request->display || !request->sequence.events[0]) {
        fail_switch(PSWSwitchEventFailure); return false;
    }
    SpaceContext spaces;
    if (!gHost.context(request->display, false, &spaces)) { fail_switch(PSWSwitchTransitionFailure); return false; }
    uint64_t expected = request->right ? spaces.right : spaces.left;
    CFRelease(spaces.display);
    if (!expected) { release_request(request); return true; } // desktop boundary
    if (!psw_switch_access_granted()) { fail_switch(psw_switch_access_status()); return false; }
    if (gHost.dragActive()) { fail_switch(PSWSwitchTransitionFailure); return false; }
    CFRunLoopTimerContext context = {0};
    gTimer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 0.01, 0.01, 0, 0, transition_tick, &context);
    if (!gTimer) { fail_switch(PSWSwitchEventFailure); return false; }
    gFlight = *request; *request = (SwitchRequest){0};
    gStartSpace = spaces.current; gExpectedSpace = expected; gNextPhase = 0;
    gStarted = gLastPhase = gLastCheck = psw_monotonic_time();
    CGPoint location = CGEventGetLocation(gFlight.sequence.events[0]);
    char displayName[128] = "";
    CFStringGetCString(gFlight.display, displayName, sizeof(displayName), kCFStringEncodingUTF8);
    os_log_info(switch_log(), "Fast switch started: backend=%{public}d start=%{public}llu expected=%{public}llu queued=%{public}u right=%{public}d natural=%{public}d progress=%{public}.3f display=%{public}s x=%{public}.1f y=%{public}.1f",
        psw_current_backend(), (unsigned long long)gStartSpace,
        (unsigned long long)gExpectedSpace, gQueueCount, gFlight.right,
        gFlight.sequence.naturalScrolling,
        CGEventGetDoubleValueField(gFlight.sequence.events[0], kFieldSwipeProgress), displayName, location.x, location.y);
    CFRunLoopAddTimer(CFRunLoopGetMain(), gTimer, kCFRunLoopCommonModes);
    post_event(gFlight.sequence.events[0]); post_event(gFlight.sequence.events[1]); gNextPhase = 1;
    if (!gFlight.sequence.modern) {
        for (unsigned i = 1; i < 3; i++) post_event(gFlight.sequence.events[i * 2]);
        gNextPhase = 3;
    }
    return true;
}
static void start_next(void) {
    if (gFlight.display || gGesture.tracking) return;
    while (gQueueCount && !gFlight.display) {
        SwitchRequest request = gQueue[0];
        memmove(gQueue, gQueue + 1, (--gQueueCount) * sizeof(gQueue[0]));
        gQueue[gQueueCount] = (SwitchRequest){0};
        (void)start_request(&request); release_request(&request);
    }
}
static bool submit_request(SwitchRequest *request) {
    if (!gFlight.display && !gQueueCount) return start_request(request);
    if (gQueueCount == QueueCapacity) { fail_switch(PSWSwitchTransitionFailure); return false; }
    gQueue[gQueueCount++] = *request; *request = (SwitchRequest){0}; return true;
}
static void transition_tick(CFRunLoopTimerRef timer, void *context) {
    (void)timer; (void)context;
    if (!gFlight.display) { stop_timer(); return; }
    CFAbsoluteTime now = psw_monotonic_time();
    if (gNextPhase < 3) {
        if (now - gStarted >= kPSWConfirmationDeadline) { fail_switch(PSWSwitchTransitionFailure); return; }
        if (gHost.dragActive()) { fail_switch(PSWSwitchTransitionFailure); return; }
        if (now - gLastPhase < 0.01) return;
        post_event(gFlight.sequence.events[gNextPhase * 2]);
        post_event(gFlight.sequence.events[gNextPhase * 2 + 1]); gNextPhase++; gLastPhase = now;
        if (gNextPhase == 3) flush_terminals();
        return;
    }
    if (now - gLastCheck < 0.05 && now - gStarted < kPSWConfirmationDeadline) return;
    gLastCheck = now; SpaceContext spaces;
    bool valid = gHost.context(gFlight.display, false, &spaces);
    psw_transition_action action = psw_transition_decision(gStartSpace, gExpectedSpace,
        valid ? spaces.current : 0, valid, now - gStarted);
    if (valid) CFRelease(spaces.display);
    if (action == PSWTransitionFailed) { fail_switch(PSWSwitchTransitionFailure); return; }
    if (action != PSWTransitionConfirmed) return;
    os_log_info(switch_log(), "Fast switch confirmed: start=%{public}llu current=%{public}llu elapsed=%{public}.3f queued=%{public}u",
        (unsigned long long)gStartSpace, (unsigned long long)spaces.current,
        now - gStarted, gQueueCount);
    release_request(&gFlight); stop_timer(); gNextPhase = 0;
    start_next();
}
static void release_swipe_terminal(void) {
    if (gSwipeTerminal) CFRelease(gSwipeTerminal);
    if (gSwipeCompanion) CFRelease(gSwipeCompanion);
    gSwipeTerminal = gSwipeCompanion = NULL;
}
static psw_switch_status prepare_swipe(void) {
    release_request(&gSwipeLeft); release_request(&gSwipeRight); release_swipe_terminal();
    SpaceContext spaces;
    if (!gHost.context(NULL, true, &spaces)) return PSWSwitchTransitionFailure;
    bool ok = prepare_request(&gSwipeLeft, spaces.display, false, spaces.location)
        && prepare_request(&gSwipeRight, spaces.display, true, spaces.location);
    CFRelease(spaces.display);
    if (ok && gSwipeLeft.sequence.modern) {
        gSwipeTerminal = psw_create_swipe_event(true, kPhaseEnded, false, true,
            gSwipeLeft.sequence.naturalScrolling, gEventFactory);
        if (!gSwipeTerminal) ok = false;
        else {
            CGEventSetLocation(gSwipeTerminal, spaces.location);
            gSwipeCompanion = (CGEventRef)CFRetain(gSwipeLeft.sequence.events[1]);
        }
    }
    if (!ok) { release_request(&gSwipeLeft); release_request(&gSwipeRight); release_swipe_terminal(); }
    return ok ? PSWSwitchReady : PSWSwitchEventFailure;
}
static void finish_swipe(void) {
    if (gSwipeTerminal) {
        // A fresh neutral event has zero motion in BOTH the outer CGEvent and
        // embedded IOHID payload; changing just the outer fields is insufficient.
        if (gFlight.display && gNextPhase < 3 && gDeferredCount + 2 <= QueueCapacity * 2) {
            gDeferredTerminals[gDeferredCount++] = gSwipeTerminal;
            gDeferredTerminals[gDeferredCount++] = gSwipeCompanion;
            gSwipeTerminal = gSwipeCompanion = NULL;
        } else { post_event(gSwipeTerminal); post_event(gSwipeCompanion); release_swipe_terminal(); }
    }
    release_request(&gSwipeLeft); release_request(&gSwipeRight); start_next();
}
static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy; (void)refcon;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        // Re-arm if the system disabled our tap (e.g. it was momentarily too slow),
        // leaving nothing half-posted. Only lost permission stops interception.
        if (psw_switch_access_granted()) { clear_requests(); (void)gHost.enableTap(); }
        else fail_switch(psw_switch_access_status());
        gGesture = (psw_gesture_state){0}; release_swipe_terminal();
        return event;
    }
    int64_t eventType = CGEventGetIntegerValueField(event, kFieldEventType);
    if ((eventType == kCGSEventGesture || eventType == kCGSEventDockControl) && own_event(event)) return event;
    // A new non-horizontal hardware Dock gesture is an explicit interruption.
    if (eventType == kCGSEventDockControl && gFlight.display && gNextPhase < 3
        && CGEventGetIntegerValueField(event, kFieldGesturePhase) == kPhaseBegan
        && CGEventGetIntegerValueField(event, kFieldSwipeMotion) != kMotionHorizontal) {
        fail_switch(PSWSwitchTransitionFailure); return event;
    }
    if (type == kCGEventKeyDown) {
        if (!gKeyboardEnabled) return event;
        uint16_t key = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        uint64_t mods = CGEventGetFlags(event) & kModMask;
        bool left = key == gLeftKey && mods == gLeftMods;
        bool right = key == gRightKey && mods == gRightMods;
        if (!left && !right) return event;
        if (!psw_switch_access_granted()) { fail_switch(psw_switch_access_status()); return event; }
        if (gHost.dragActive()) {
            if (gFlight.display || gQueueCount) clear_requests();
            if (!restore_space_hotkeys_internal()) fail_switch(PSWSwitchHotkeyFailure);
            return event;
        }
        if (CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)) return NULL;
        SpaceContext spaces; SwitchRequest request = {0};
        if (!gHost.context(NULL, false, &spaces)) { fail_switch(PSWSwitchTransitionFailure); return event; }
        bool ok = prepare_request(&request, spaces.display, right, spaces.location); CFRelease(spaces.display);
        if (!ok || !disable_space_hotkeys()) {
            release_request(&request); fail_switch(ok ? PSWSwitchHotkeyFailure : PSWSwitchEventFailure); return event;
        }
        ok = submit_request(&request); release_request(&request);
        return ok ? NULL : event;
    }
    if (!gSwipeEnabled && !gGesture.tracking) return event;
    if (eventType == kCGSEventDockControl) {
        if (CGEventGetIntegerValueField(event, kFieldGestureHIDType) != kIOHIDEventTypeDockSwipe
            || CGEventGetIntegerValueField(event, kFieldSwipeMotion) != kMotionHorizontal) return event;
        int phase = (int)CGEventGetIntegerValueField(event, kFieldGesturePhase);
        bool wasTracking = gGesture.tracking;
        bool check = phase == kPhaseBegan || (gGesture.tracking && !gGesture.fired);
        bool drag = check && gHost.dragActive();
        bool access = !check || psw_switch_access_granted();
        bool bypass = drag || !access;
        if (phase == kPhaseBegan && bypass)
            os_log_info(switch_log(), "Fast swipe passed to macOS: drag=%{public}d access=%{public}d", drag, access);
        if (phase == kPhaseBegan && !bypass) {
            psw_switch_status preparation = prepare_swipe();
            if (preparation != PSWSwitchReady) { fail_switch(preparation); bypass = true; }
        }
        psw_gesture_action action = psw_gesture_decision(&gGesture, phase,
            CGEventGetDoubleValueField(event, kFieldSwipeProgress),
            CGEventGetDoubleValueField(event, kFieldSwipeVelocityX), bypass);
        if (action == PSWGestureLeft || action == PSWGestureRight) {
            SwitchRequest *request = action == PSWGestureRight ? &gSwipeRight : &gSwipeLeft;
            (void)submit_request(request); // submission reports its own failure
            release_request(&gSwipeLeft); release_request(&gSwipeRight);
        }
        if ((phase == kPhaseEnded || phase == kPhaseCancelled) && wasTracking) finish_swipe();
        return action == PSWGesturePass ? event : NULL;
    }
    if (eventType == kCGSEventGesture && gGesture.tracking) return NULL;
    return event;
}
static bool ensure_tap(void) {
    if (gTap && CGEventTapIsEnabled(gTap)) return true;
    if (gTap) CGEventTapEnable(gTap, true);
    else {
        CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | (1ULL << kCGSEventGesture) | (1ULL << kCGSEventDockControl);
        gTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
            kCGEventTapOptionDefault, mask, tap_callback, NULL);
        if (!gTap) return false;
        gSource = CFMachPortCreateRunLoopSource(NULL, gTap, 0);
        if (!gSource) { CFRelease(gTap); gTap = NULL; return false; }
        CFRunLoopAddSource(CFRunLoopGetMain(), gSource, kCFRunLoopCommonModes);
        CGEventTapEnable(gTap, true);
    }
    return CGEventTapIsEnabled(gTap);
}
static void destroy_tap(void) {
    if (!gTap) return;
    CGEventTapEnable(gTap, false);
    if (gSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), gSource, kCFRunLoopCommonModes);
        CFRelease(gSource); gSource = NULL;
    }
    CFMachPortInvalidate(gTap); CFRelease(gTap); gTap = NULL;
}
static bool enable_failed(psw_switch_status reason, const char *stage) {
    gStatus = reason;
    os_log_error(switch_log(), "Fast switch enable refused: reason=%{public}d stage=%{public}s backend=%{public}d ax=%{public}d post=%{public}d",
        reason, stage, psw_current_backend(), gHost.accessibility(), gHost.postAccess());
    return false;
}
static bool can_enable(bool cursor) {
    (void)switch_log(); // prepare logging before installing the input callback
    if (gHost.backend() == PSWBackendUnsupported) return enable_failed(PSWSwitchUnsupported, "unsupported-os");
    gStatus = psw_switch_access_status();
    if (gStatus != PSWSwitchReady) return enable_failed(gStatus, "permission");
    // Do not intercept input or disable native shortcuts until the display
    // snapshot needed to confirm a switch is available.
    SpaceContext spaces;
    if (!gHost.context(NULL, cursor, &spaces)) return enable_failed(PSWSwitchTransitionFailure, "display-snapshot");
    CFRelease(spaces.display);
    psw_event_sequence probe;
    if (!psw_create_sequence(&probe, gHost.backend() == PSWBackendModern, false,
        gHost.naturalScrolling(), gEventFactory)) {
        return enable_failed(PSWSwitchEventFailure, "event-builder");
    }
    psw_release_sequence(&probe);
    if (!gHost.enableTap()) {
        gStatus = psw_switch_access_status();
        if (gStatus == PSWSwitchReady) gStatus = PSWSwitchTapFailure;
        return enable_failed(gStatus, "event-tap");
    }
    gStatus = PSWSwitchReady; return true;
}
bool psw_set_swipe_override_enabled(bool enabled) {
    if (enabled && !can_enable(true)) { gSwipeEnabled = false; return false; }
    gSwipeEnabled = enabled;
    if (!enabled) {
        clear_requests();
        if (!gGesture.tracking) release_swipe_terminal();
        if (!gKeyboardEnabled && !gGesture.tracking) destroy_tap();
    }
    return true;
}
bool psw_set_keyboard_override_enabled(bool enabled, unsigned short leftKeyCode,
    unsigned long long leftModifiers, unsigned short rightKeyCode, unsigned long long rightModifiers) {
    if (enabled) {
        if (!can_enable(false)) {
            gKeyboardEnabled = false;
            if (!restore_space_hotkeys_internal()) gStatus = PSWSwitchHotkeyFailure;
            return false;
        }
        gLeftKey = leftKeyCode; gRightKey = rightKeyCode;
        gLeftMods = leftModifiers & kModMask; gRightMods = rightModifiers & kModMask;
        if (!gHost.dragActive() && !disable_space_hotkeys()) { fail_switch(PSWSwitchHotkeyFailure); return false; }
        gKeyboardEnabled = true; return true;
    }
    gKeyboardEnabled = false; clear_requests();
    bool ok = restore_space_hotkeys_internal();
    if (!ok) gStatus = PSWSwitchHotkeyFailure;
    if (!gSwipeEnabled) destroy_tap();
    return ok;
}
