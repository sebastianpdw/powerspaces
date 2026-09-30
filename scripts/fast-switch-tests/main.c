// Tests include the implementation to access its private host seam. This keeps
// test hooks out of the public Swift/C API and tests the actual coordinator.
#include "../../Sources/CSpaceSwitch/EventSerialization.c"
#include "../../Sources/CSpaceSwitch/CSpaceSwitch.c"
#include <stdio.h>

static unsigned assertions, failures, posts, factoryCalls;
static int failAllocation, journal = -1, failHotkey = -1;
static bool trusted = true, postAccess = true, journalWritable = true, autoComplete = true;
static bool contextAvailable = true, tapAvailable = true;
static bool naturalScrolling = true;
static bool dragActive;
static unsigned tapAttempts, accessChecks, contextCalls, failContextCall, failureCallbacks;
static bool hotkeys[4];
static uint64_t current = 2;
static uint64_t secondaryCurrent = 12;
static bool cursorOnSecondary;
static CGPoint factoryLocation = {100, 100}, postedLocations[128];
static CGEventTimestamp lastPostedTimestamp;
static int phases[128];
static CFAbsoluteTime postTimes[128];
#define CHECK(condition) do { assertions++; if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); failures++; } } while (0)
static bool fake_trusted(void) { accessChecks++; return trusted; }
static bool fake_post_access(void) { return postAccess; }
static bool fake_enable_tap(void) { tapAttempts++; return tapAvailable; }
static void fake_failure_handler(void) { failureCallbacks++; }
static bool fake_natural_scrolling(void) { return naturalScrolling; }
static bool fake_drag_active(void) { return dragActive; }
static int fake_backend(void) { return PSWBackendModern; }
static int fake_read_journal(void) { return journal; }
static bool fake_write_journal(int mask) {
    if (!journalWritable) return false;
    journal = mask; return true;
}
static bool fake_get_hotkey(int id) { return hotkeys[id - 79]; }
static CGError fake_set_hotkey(int id, bool enabled) {
    if (id == failHotkey) return kCGErrorFailure;
    hotkeys[id - 79] = enabled; return kCGErrorSuccess;
}
static bool fake_context(CFStringRef display, bool cursor, SpaceContext *out) {
    contextCalls++;
    if (!contextAvailable || (failContextCall && contextCalls == failContextCall)) return false;
    bool secondary = display ? CFEqual(display, CFSTR("second-display")) : cursor && cursorOnSecondary;
    if (display && !secondary && !CFEqual(display, CFSTR("test-display"))) return false;
    uint64_t space = secondary ? secondaryCurrent : current, first = secondary ? 11 : 1, last = secondary ? 13 : 3;
    *out = (SpaceContext){.display = CFRetain(secondary ? CFSTR("second-display") : CFSTR("test-display")), .current = space,
        .left = space > first ? space - 1 : 0, .right = space < last ? space + 1 : 0,
        .location = secondary ? CGPointMake(-1000, 200) : CGPointMake(100, 100)};
    return true;
}
static CGEventRef fake_create(CGEventSourceRef source) {
    factoryCalls++;
    CGEventRef event = failAllocation > 0 && factoryCalls == (unsigned)failAllocation ? NULL : CGEventCreate(source);
    if (event) CGEventSetLocation(event, factoryLocation);
    return event;
}
static void fake_post(CGEventTapLocation location, CGEventRef event) {
    (void)location;
    int type = (int)CGEventGetIntegerValueField(event, (CGEventField)55);
    int phase = (int)CGEventGetIntegerValueField(event, (CGEventField)132);
    double progress = CGEventGetDoubleValueField(event, (CGEventField)124);
    if (posts < 128) {
        phases[posts] = type == 30 ? phase : 0; postTimes[posts] = CFAbsoluteTimeGetCurrent();
        postedLocations[posts] = CGEventGetLocation(event);
    }
    CHECK(CGEventGetTimestamp(event) > lastPostedTimestamp);
    lastPostedTimestamp = CGEventGetTimestamp(event);
    posts++;
    CHECK(own_event(event)); // Recursion guard must work even with source PID zero.
    if (autoComplete && type == 30 && phase == 4 && progress != 0) {
        bool modern = CGEventGetIntegerValueField(event, (CGEventField)134) == 4;
        bool right = modern ? progress < 0 : progress > 0;
        if (modern && !gFlight.sequence.naturalScrolling) right = !right;
        uint64_t *space = CGEventGetLocation(event).x < 0 ? &secondaryCurrent : &current;
        *space = right ? *space + 1 : *space - 1;
    }
}
static void reset(void) {
    clear_requests(); release_swipe_terminal(); gGesture = (psw_gesture_state){0};
    gSwipeEnabled = gKeyboardEnabled = gHotkeysDisabledByUs = false;
    gStatus = PSWSwitchReady; gFailureHandler = NULL;
    memset(gPosted, 0, sizeof(gPosted)); gPostedIndex = 0;
    posts = factoryCalls = 0; failAllocation = 0; journal = failHotkey = -1;
    trusted = postAccess = contextAvailable = tapAvailable = journalWritable = autoComplete = true;
    tapAttempts = accessChecks = contextCalls = failContextCall = failureCallbacks = 0;
    current = 2; secondaryCurrent = 12; cursorOnSecondary = false;
    factoryLocation = CGPointMake(100, 100); lastPostedTimestamp = 0;
    naturalScrolling = true;
    dragActive = false;
    for (int i = 0; i < 4; i++) hotkeys[i] = (i % 2 == 0);
    gHost.accessibility = fake_trusted; gHost.postAccess = fake_post_access;
    gHost.enableTap = fake_enable_tap; gHost.dragActive = fake_drag_active;
    gHost.context = fake_context; gHost.post = fake_post;
    gHost.readJournal = fake_read_journal; gHost.writeJournal = fake_write_journal;
    gHost.setHotkey = fake_set_hotkey; gHost.getHotkey = fake_get_hotkey;
    gHost.naturalScrolling = fake_natural_scrolling;
    gHost.backend = fake_backend; // Coordinator tests must also run on older macOS hosts.
    gEventFactory = fake_create;
}
static HIDPayload parsed_payload(CGEventRef event, size_t *size) {
    HIDPayload result = {0}; CFDataRef data = CGEventCreateData(NULL, event);
    CHECK(data != NULL); *size = 0;
    if (!data) return result;
    const uint8_t *bytes = CFDataGetBytePtr(data); size_t length = (size_t)CFDataGetLength(data);
    for (size_t i = 4; i + 4 + sizeof(HIDHeader) + sizeof(HIDFluid) <= length; i++) {
        size_t recordLength = ((size_t)bytes[i] << 8) | bytes[i + 1];
        if (bytes[i + 2] != (4205 >> 8) || bytes[i + 3] != (uint8_t)4205
            || (recordLength != 68 && recordLength != 96) || i + 4 + recordLength > length) continue;
        memcpy(&result, bytes + i + 4, recordLength); *size = recordLength; break;
    }
    CFRelease(data); CHECK(*size != 0); return result;
}
static void complete_tick(void) {
    gLastPhase = gLastCheck = 0;
    transition_tick(NULL, NULL);
}
static CGEventRef hardware_swipe(void) {
    CGEventRef event = CGEventCreate(NULL);
    CGEventSetIntegerValueField(event, (CGEventField)55, 30);
    CGEventSetIntegerValueField(event, (CGEventField)110, 23);
    CGEventSetIntegerValueField(event, (CGEventField)123, 1);
    CGEventSetIntegerValueField(event, kCGEventSourceUnixProcessID, 0);
    return event;
}
static CGEventRef swipe(CGEventRef event, int phase, double progress) {
    CGEventSetIntegerValueField(event, (CGEventField)132, phase);
    CGEventSetDoubleValueField(event, (CGEventField)124, progress);
    return tap_callback(NULL, (CGEventType)30, event, NULL);
}
static void test_events(void) {
    CHECK(psw_backend_for_major(13) == PSWBackendUnsupported);
    CHECK(psw_backend_for_major(14) == PSWBackendLegacy);
    CHECK(psw_backend_for_major(15) == PSWBackendLegacy);
    CHECK(psw_backend_for_major(26) == PSWBackendLegacy);
    CHECK(psw_backend_for_major(27) == PSWBackendModern);
    CHECK(psw_backend_for_major(28) == PSWBackendUnsupported);
    CHECK(fixed1616(0.000016) == 1 && fixed1616(-0.000016) == -1);
    CHECK(fixed1616(INFINITY) == 0 && fixed1616(1e30) == INT32_MAX);
    for (int modern = 0; modern < 2; modern++) for (int right = 0; right < 2; right++)
    for (int natural = 0; natural < 2; natural++) {
        psw_event_sequence sequence;
        CHECK(psw_create_sequence(&sequence, modern, right, natural, fake_create));
        CHECK(sequence.naturalScrolling == (bool)natural);
        int outputSign = right ? 1 : -1;
        if (modern && natural) outputSign = -outputSign;
        for (int i = 0; i < 3; i++) {
            CGEventRef event = sequence.events[i * 2]; CHECK(psw_event_is_marked(event));
            int phase = (int[]){1, 2, 4}[i];
            CHECK(CGEventGetIntegerValueField(event, (CGEventField)132) == phase);
            double progress = CGEventGetDoubleValueField(event, (CGEventField)124);
            CHECK(outputSign > 0 ? progress > 0 : progress < 0);
            CHECK(!modern || fabs(progress) == 1.0); // outer progress must agree with complete IOHID travel
            if (modern) {
                size_t size; HIDPayload payload = parsed_payload(event, &size);
                CHECK(payload.header.count == (i == 2 ? 2u : 1u));
                CHECK(payload.header.timestamp != 0 && payload.header.timestamp <= mach_absolute_time());
                CHECK(CGEventGetTimestamp(event) != 0);
                CHECK(size == (i == 2 ? 96u : 68u));
                CHECK(payload.fluid.base.size == 40 && payload.fluid.base.type == 23);
                CHECK(payload.fluid.base.options == (uint32_t)phase << 24);
                CHECK(payload.fluid.motion == 1 && payload.fluid.flavor == 3);
                CHECK(payload.fluid.progress == outputSign * 65536);
                CHECK(CGEventGetIntegerValueField(sequence.events[i * 2 + 1], (CGEventField)55) == 29);
                if (i == 2) {
                    CHECK(payload.velocity.base.size == 28 && payload.velocity.base.type == 9);
                    CHECK(payload.velocity.base.depth == 1 && payload.velocity.y == 0);
                    CHECK(payload.velocity.x == outputSign * 2000 * 65536);
                }
            } else CHECK(sequence.events[i * 2 + 1] == NULL);
        }
        psw_release_sequence(&sequence);
        for (int i = 0; i < 6; i++) CHECK(sequence.events[i] == NULL);
    }
    CGEventRef neutral = psw_create_swipe_event(true, 4, false, true, false, fake_create);
    CHECK(neutral != NULL);
    if (neutral) {
        size_t size; HIDPayload payload = parsed_payload(neutral, &size);
        CHECK(payload.fluid.progress == 0 && payload.velocity.x == 0 && payload.velocity.y == 0);
        CFRelease(neutral);
    }
    for (int failure = 1; failure <= 6; failure++) {
        factoryCalls = 0; failAllocation = failure; psw_event_sequence sequence;
        CHECK(!psw_create_sequence(&sequence, true, true, true, fake_create));
        for (int i = 0; i < 6; i++) CHECK(sequence.events[i] == NULL);
        CHECK(posts == 0);
    }
    failAllocation = 0;
}
static void test_hotkeys(void) {
    reset(); CHECK(disable_space_hotkeys()); CHECK(journal == 5);
    for (int i = 0; i < 4; i++) CHECK(!hotkeys[i]);
    // Simulate a new process: original states must come from the journal.
    gHotkeysDisabledByUs = false; CHECK(psw_recover_space_hotkeys(false));
    CHECK(journal == -1); for (int i = 0; i < 4; i++) CHECK(hotkeys[i] == (i % 2 == 0));
    reset(); journalWritable = false; CHECK(!disable_space_hotkeys());
    for (int i = 0; i < 4; i++) CHECK(hotkeys[i] == (i % 2 == 0));
    reset(); failHotkey = 81; CHECK(!disable_space_hotkeys()); CHECK(journal == 5);
    failHotkey = -1; CHECK(psw_recover_space_hotkeys(false)); CHECK(journal == -1);
    reset(); CHECK(disable_space_hotkeys()); failHotkey = 79;
    CHECK(!psw_recover_space_hotkeys(false)); CHECK(journal == 5);
    failHotkey = -1; CHECK(psw_recover_space_hotkeys(false));
    reset(); journal = -2; CHECK(!disable_space_hotkeys()); CHECK(journal == -2);
    reset(); CHECK(psw_recover_space_hotkeys(false)); CHECK(!hotkeys[1] && !hotkeys[3]);
    CHECK(psw_recover_space_hotkeys(true)); for (int i = 0; i < 4; i++) CHECK(hotkeys[i]);
}
static void test_permissions(void) {
    for (int ax = 0; ax < 2; ax++) for (int post = 0; post < 2; post++) {
        reset(); trusted = ax; postAccess = post;
        psw_switch_status expected = !ax ? PSWSwitchAccessibility : !post ? PSWSwitchPostEventAccess : PSWSwitchReady;
        CHECK(psw_switch_access_status() == expected);
        CHECK(psw_switch_access_granted() == (ax && post));
        CHECK(posts == 0 && tapAttempts == 0 && journal == -1); // preflight is read-only
        CHECK(psw_set_swipe_override_enabled(true) == (ax && post));
        CHECK(gStatus == expected);
        CHECK(psw_set_keyboard_override_enabled(true, 123, kCGEventFlagMaskControl,
            124, kCGEventFlagMaskControl) == (ax && post));
        CHECK(gStatus == expected && posts == 0);
        if (!ax || !post) {
            CHECK(tapAttempts == 0 && journal == -1 && !gSwipeEnabled && !gKeyboardEnabled);
            for (int i = 0; i < 4; i++) CHECK(hotkeys[i] == (i % 2 == 0));
        }
        CHECK(psw_set_keyboard_override_enabled(false, 0, 0, 0, 0));
        CHECK(psw_set_swipe_override_enabled(false));
        CHECK(journal == -1);
    }
    reset(); contextAvailable = false;
    CHECK(!psw_set_keyboard_override_enabled(true, 123, 0, 124, 0));
    CHECK(gStatus == PSWSwitchTransitionFailure && tapAttempts == 0 && journal == -1);
    for (int i = 0; i < 4; i++) CHECK(hotkeys[i] == (i % 2 == 0));
    reset(); tapAvailable = false;
    CHECK(!psw_set_keyboard_override_enabled(true, 123, 0, 124, 0));
    CHECK(gStatus == PSWSwitchTapFailure && tapAttempts == 1 && journal == -1);
    CHECK(psw_switch_access_granted()); // a tap failure is not a missing permission
    reset(); CHECK(psw_set_keyboard_override_enabled(true, 123, 0, 124, 0));
    postAccess = false; psw_check_switch_health();
    CHECK(gStatus == PSWSwitchPostEventAccess && !gKeyboardEnabled && journal == -1 && posts == 0);
    for (int i = 0; i < 4; i++) CHECK(hotkeys[i] == (i % 2 == 0));
    // A transient desktop lookup must not conceal genuine permission loss.
    for (int loseAX = 0; loseAX < 2; loseAX++) {
        reset(); gFailureHandler = fake_failure_handler;
        CHECK(psw_set_swipe_override_enabled(true));
        CHECK(psw_set_keyboard_override_enabled(true, 123, 0, 124, 0));
        SwitchRequest blocked = {0};
        CHECK(prepare_request(&blocked, CFSTR("test-display"), true, CGPointMake(100, 100)));
        contextAvailable = false;
        if (loseAX) trusted = false; else postAccess = false;
        CHECK(!submit_request(&blocked)); release_request(&blocked);
        CHECK(gStatus == (loseAX ? PSWSwitchAccessibility : PSWSwitchPostEventAccess));
        CHECK(!gSwipeEnabled && !gKeyboardEnabled && failureCallbacks == 1 && posts == 0);
        CHECK(journal == -1 && !gHotkeysDisabledByUs);
        for (int i = 0; i < 4; i++) CHECK(hotkeys[i] == (i % 2 == 0));
    }
    reset(); gFailureHandler = fake_failure_handler;
    CHECK(psw_set_swipe_override_enabled(true));
    CHECK(psw_set_keyboard_override_enabled(true, 123, 0, 124, 0));
    unsigned attempts = tapAttempts;
    psw_check_switch_health(); // With permission granted the poll never stops the engine.
    CHECK(gStatus == PSWSwitchReady && gSwipeEnabled && gKeyboardEnabled && failureCallbacks == 0);
    CHECK(tapAttempts == attempts + 1); // It re-arms a tap that a failed re-arm left disabled.
    CHECK(journal == 5 && gHotkeysDisabledByUs);
    reset(); SwitchRequest request = {.display = CFRetain(CFSTR("test-display")), .right = true};
    CHECK(psw_create_sequence(&request.sequence, false, true, false, fake_create));
    request.cancel = psw_create_swipe_event(false, 8, true, true, false, fake_create);
    CHECK(request.cancel != NULL); CHECK(submit_request(&request));
    CHECK(posts == 3 && gNextPhase == 3 && current == 3); // older OS delivery stays immediate
    complete_tick(); CHECK(!gTimer && !gFlight.display);
}
static void test_display_delivery(void) {
    CGPoint firstPoint = CGPointMake(100, 100), secondPoint = CGPointMake(-1000, 200);
    CGRect primary = CGRectMake(0, 0, 1920, 1080), secondary = CGRectMake(-1600, 0, 1600, 900);
    CHECK(CGPointEqualToPoint(point_on_display(firstPoint, primary), firstPoint));
    CHECK(CGPointEqualToPoint(point_on_display(firstPoint, secondary), CGPointMake(-800, 450)));
    CHECK(CGPointEqualToPoint(point_on_display(secondPoint, secondary), secondPoint));
    reset(); SwitchRequest first = {0}, second = {0};
    factoryLocation = secondPoint; // Factory cursor differs from the captured destination.
    CHECK(prepare_request(&first, CFSTR("test-display"), true, firstPoint));
    factoryLocation = firstPoint;
    CHECK(prepare_request(&second, CFSTR("second-display"), true, secondPoint));
    // Stale construction times and cursor movement must not leak into dispatch.
    for (unsigned i = 0; i < PSWSequenceCapacity; i++) {
        CGEventSetTimestamp(first.sequence.events[i], 1);
        CGEventSetTimestamp(second.sequence.events[i], 1);
    }
    CHECK(submit_request(&first)); CHECK(submit_request(&second));
    cursorOnSecondary = true; factoryLocation = secondPoint;
    for (int i = 0; i < 6; i++) complete_tick();
    CHECK(current == 3 && secondaryCurrent == 13 && posts == 12 && !gFlight.display && !gQueueCount);
    for (unsigned i = 0; i < posts && i < 128; i++)
        CHECK(CGPointEqualToPoint(postedLocations[i], i < 6 ? firstPoint : secondPoint));

    reset(); CHECK(prepare_request(&first, CFSTR("test-display"), true, firstPoint));
    CHECK(submit_request(&first)); factoryLocation = secondPoint;
    dragActive = true; complete_tick();
    CHECK(posts == 4 && current == 2 && secondaryCurrent == 12 && !gFlight.display);
    for (unsigned i = 0; i < posts && i < 128; i++) CHECK(CGPointEqualToPoint(postedLocations[i], firstPoint));

    reset(); cursorOnSecondary = true;
    CHECK(prepare_swipe() == PSWSwitchReady); CHECK(submit_request(&gSwipeRight));
    cursorOnSecondary = false; factoryLocation = firstPoint;
    finish_swipe(); // Hardware terminal is deferred behind the synthetic phases.
    CHECK(gDeferredCount == 2);
    complete_tick(); complete_tick(); complete_tick();
    CHECK(posts == 8 && current == 2 && secondaryCurrent == 13 && !gDeferredCount);
    for (unsigned i = 0; i < posts && i < 128; i++) CHECK(CGPointEqualToPoint(postedLocations[i], secondPoint));

    reset(); CHECK(prepare_request(&first, CFSTR("test-display"), true, firstPoint));
    CHECK(prepare_request(&second, CFSTR("test-display"), false, firstPoint));
    CHECK(submit_request(&first)); CHECK(submit_request(&second));
    complete_tick(); complete_tick(); CHECK(current == 3);
    gStarted -= 1; complete_tick(); // Timer delayed after the desktop already changed.
    CHECK(posts == 8 && gFlight.display && gExpectedSpace == 2);
    complete_tick(); complete_tick(); complete_tick();
    CHECK(current == 2 && !gFlight.display && !gQueueCount);
}
static void test_coordinator(void) {
    reset(); SwitchRequest first = {0}, second = {0};
    CHECK(prepare_request(&first, CFSTR("test-display"), true, CGPointMake(100, 100)));
    CHECK(prepare_request(&second, CFSTR("test-display"), false, CGPointMake(100, 100)));
    CHECK(submit_request(&first)); CHECK(posts == 2 && gNextPhase == 1);
    transition_tick(NULL, NULL); CHECK(posts == 2); // no back-to-back phase
    CHECK(submit_request(&second)); CHECK(gQueueCount == 1 && posts == 2);
    complete_tick(); CHECK(posts == 4); complete_tick(); CHECK(current == 3 && posts == 6);
    complete_tick(); CHECK(gFlight.display && gStartSpace == 3 && posts == 8 && gQueueCount == 0);
    complete_tick(); complete_tick(); complete_tick(); CHECK(current == 2 && !gFlight.display && !gTimer);
    reset(); autoComplete = false; gFailureHandler = fake_failure_handler;
    CHECK(psw_set_swipe_override_enabled(true));
    CHECK(psw_set_keyboard_override_enabled(true, 123, 0, 124, 0));
    CHECK(prepare_request(&first, CFSTR("test-display"), true, CGPointMake(100, 100))); CHECK(submit_request(&first));
    CHECK(prepare_request(&second, CFSTR("test-display"), true, CGPointMake(100, 100))); CHECK(submit_request(&second));
    complete_tick(); complete_tick(); complete_tick(); CHECK(gFlight.display); gStarted -= 1; complete_tick();
    CHECK(gStatus == PSWSwitchReady && gSwipeEnabled && gKeyboardEnabled);
    CHECK(!gTimer && !gFlight.display && !gQueueCount && failureCallbacks == 0);
    CHECK(journal == 5 && gHotkeysDisabledByUs && current == 2 && posts == 6);
    for (int i = 0; i < 4; i++) CHECK(!hotkeys[i]); // Keep shortcut takeover while override stays enabled.
    // The next independent input uses current state, not the discarded queue or
    // stale expected destination. No setting toggle or automatic replay is needed.
    autoComplete = true; current = 3;
    CHECK(prepare_request(&first, CFSTR("test-display"), false, CGPointMake(100, 100))); CHECK(submit_request(&first));
    CHECK(gStartSpace == 3 && gExpectedSpace == 2);
    complete_tick(); complete_tick(); complete_tick();
    CHECK(current == 2 && gStatus == PSWSwitchReady && !gTimer && !gFlight.display);
    CHECK(gSwipeEnabled && gKeyboardEnabled && failureCallbacks == 0);
    CHECK(psw_set_keyboard_override_enabled(false, 0, 0, 0, 0));
    CHECK(journal == -1 && hotkeys[0] && !hotkeys[1] && hotkeys[2] && !hotkeys[3]);
    CHECK(psw_set_swipe_override_enabled(false));
    reset(); CHECK(prepare_request(&first, CFSTR("test-display"), true, CGPointMake(100, 100))); CHECK(submit_request(&first));
    autoComplete = false; current = 1; complete_tick(); complete_tick(); complete_tick(); CHECK(gStatus == PSWSwitchReady);
    reset(); CHECK(prepare_request(&first, CFSTR("wrong-display"), true, CGPointMake(100, 100)));
    CHECK(!submit_request(&first)); CHECK(posts == 0); release_request(&first);
    // A real drag still cancels a partial sequence without disabling the feature.
    reset(); CHECK(prepare_request(&first, CFSTR("test-display"), true, CGPointMake(100, 100))); CHECK(submit_request(&first));
    dragActive = true; complete_tick(); CHECK(gStatus == PSWSwitchReady && current == 2);
    CHECK(posts == 4 && phases[2] == 8); // close partial synthetic gesture with Cancelled
    reset(); dragActive = true; CHECK(prepare_request(&first, CFSTR("test-display"), true, CGPointMake(100, 100)));
    CHECK(!submit_request(&first) && posts == 0); release_request(&first);
    for (int swipe = 0; swipe < 2; swipe++) {
        reset(); gSwipeEnabled = swipe; gKeyboardEnabled = !swipe;
        CHECK(prepare_request(&first, CFSTR("test-display"), true, CGPointMake(100, 100))); CHECK(submit_request(&first));
        CGEventRef overview = CGEventCreate(NULL);
        CGEventSetIntegerValueField(overview, (CGEventField)55, 30);
        CGEventSetIntegerValueField(overview, (CGEventField)132, 1);
        CGEventSetIntegerValueField(overview, (CGEventField)123, 2);
        CGEventSetIntegerValueField(overview, kCGEventSourceUnixProcessID, 0);
        CHECK(tap_callback(NULL, (CGEventType)30, overview, NULL) == overview);
        CHECK(gStatus == PSWSwitchReady && !gFlight.display && current == 2);
        CHECK(gSwipeEnabled == swipe && gKeyboardEnabled == !swipe);
        CHECK(posts == 4 && phases[2] == 8);
        CFRelease(overview);
    }
    reset(); current = 3; CHECK(prepare_request(&first, CFSTR("test-display"), true, CGPointMake(100, 100)));
    CHECK(submit_request(&first)); CHECK(posts == 0 && !gFlight.display); release_request(&first);
    // Permission is checked when a request starts and whenever an event is
    // posted, not again on every tick of the transition.
    reset(); CHECK(prepare_request(&first, CFSTR("test-display"), true, CGPointMake(100, 100))); CHECK(submit_request(&first));
    unsigned checks = accessChecks; complete_tick(); complete_tick(); complete_tick();
    CHECK(accessChecks == checks && current == 3 && !gFlight.display);
    // Lost permission still stops interception mid-flight: through the poll...
    reset(); gKeyboardEnabled = true;
    CHECK(prepare_request(&first, CFSTR("test-display"), true, CGPointMake(100, 100))); CHECK(submit_request(&first));
    CHECK(disable_space_hotkeys()); trusted = false; psw_check_switch_health();
    CHECK(gStatus == PSWSwitchAccessibility && journal == -1 && !gTimer && !gKeyboardEnabled);
    // ...and through the posting guard, which leaves the request unconfirmed.
    reset(); CHECK(prepare_request(&first, CFSTR("test-display"), true, CGPointMake(100, 100))); CHECK(submit_request(&first));
    CHECK(disable_space_hotkeys()); postAccess = false; complete_tick(); complete_tick(); complete_tick();
    CHECK(gFlight.display && posts == 2 && current == 2); // no further phase is posted
    gStarted -= 1; complete_tick();
    CHECK(gStatus == PSWSwitchPostEventAccess && journal == -1 && !gTimer && posts == 2);
    reset(); CHECK(prepare_request(&first, CFSTR("test-display"), true, CGPointMake(100, 100))); CHECK(submit_request(&first));
    for (int i = 0; i < QueueCapacity; i++) {
        CHECK(prepare_request(&second, CFSTR("test-display"), false, CGPointMake(100, 100))); CHECK(submit_request(&second));
    }
    CHECK(prepare_request(&second, CFSTR("test-display"), false, CGPointMake(100, 100))); CHECK(!submit_request(&second));
    release_request(&second); CHECK(!gQueueCount && !gTimer && !gFlight.display);
    reset(); CHECK(prepare_request(&first, CFSTR("test-display"), true, CGPointMake(100, 100))); CHECK(submit_request(&first));
    CFAbsoluteTime until = CFAbsoluteTimeGetCurrent() + 0.3;
    while (gTimer && CFAbsoluteTimeGetCurrent() < until) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
    CHECK(!gTimer && current == 3 && posts == 6);
    CHECK(postTimes[2] - postTimes[0] >= 0.009 && postTimes[4] - postTimes[2] >= 0.009);
    reset();
    for (int i = 0; i < 500; i++) {
        bool right = i % 2 == 0;
        CHECK(prepare_request(&first, CFSTR("test-display"), right, CGPointMake(100, 100))); CHECK(submit_request(&first));
        complete_tick(); complete_tick(); complete_tick();
        CHECK(current == (right ? 3u : 2u) && !gFlight.display && !gQueueCount && !gTimer);
    }
}
static void test_native_gesture(void) {
    reset(); gSwipeEnabled = true;
    CGEventRef event = hardware_swipe();
    // A gesture that begins during a mouse drag belongs to macOS as a whole.
    dragActive = true; CHECK(swipe(event, 1, 0) == event);
    dragActive = false; CHECK(swipe(event, 2, 1) == event && posts == 0);
    CHECK(swipe(event, 4, 1) == event);
    // Nothing else diverts a swipe: the host is only asked about a drag, so a
    // Dock-owned surface lingering after Mission Control cannot reach the engine.
    CHECK(swipe(event, 1, 0) == NULL);
    CGEventSetIntegerValueField(event, (CGEventField)132, 2); CGEventSetDoubleValueField(event, (CGEventField)124, 1);
    CHECK(tap_callback(NULL, (CGEventType)30, event, NULL) == NULL && posts == 2);
    CGEventSetIntegerValueField(event, (CGEventField)132, 4);
    CHECK(tap_callback(NULL, (CGEventType)30, event, NULL) == NULL && gDeferredCount == 2);
    complete_tick(); complete_tick(); complete_tick();
    CHECK(current == 3 && posts == 8 && !gDeferredCount && !gTimer && !gGesture.tracking);
    reset(); gSwipeEnabled = true; failContextCall = 2;
    gFailureHandler = fake_failure_handler;
    CGEventSetIntegerValueField(event, (CGEventField)132, 1); CGEventSetDoubleValueField(event, (CGEventField)124, 0);
    CHECK(tap_callback(NULL, (CGEventType)30, event, NULL) == NULL);
    CGEventSetIntegerValueField(event, (CGEventField)132, 2); CGEventSetDoubleValueField(event, (CGEventField)124, 1);
    CHECK(tap_callback(NULL, (CGEventType)30, event, NULL) == NULL);
    CHECK(gStatus == PSWSwitchReady && gSwipeEnabled && failureCallbacks == 0 && posts == 0);
    CGEventSetIntegerValueField(event, (CGEventField)132, 4);
    CHECK(tap_callback(NULL, (CGEventType)30, event, NULL) == NULL);
    // The next complete hardware gesture succeeds after the single failed
    // desktop lookup, without re-enabling the override or replaying old input.
    CGEventSetIntegerValueField(event, (CGEventField)132, 1); CGEventSetDoubleValueField(event, (CGEventField)124, 0);
    CHECK(tap_callback(NULL, (CGEventType)30, event, NULL) == NULL);
    CGEventSetIntegerValueField(event, (CGEventField)132, 2); CGEventSetDoubleValueField(event, (CGEventField)124, 1);
    CHECK(tap_callback(NULL, (CGEventType)30, event, NULL) == NULL);
    CGEventSetIntegerValueField(event, (CGEventField)132, 4);
    CHECK(tap_callback(NULL, (CGEventType)30, event, NULL) == NULL);
    complete_tick(); complete_tick(); complete_tick();
    CHECK(current == 3 && gSwipeEnabled && gStatus == PSWSwitchReady && failureCallbacks == 0);
    CHECK(!gTimer && !gFlight.display && !gQueueCount && !gGesture.tracking);
    reset(); gSwipeEnabled = true; contextAvailable = false;
    gFailureHandler = fake_failure_handler;
    CGEventSetIntegerValueField(event, (CGEventField)132, 1);
    CHECK(tap_callback(NULL, (CGEventType)30, event, NULL) == event);
    CHECK(gSwipeEnabled && gStatus == PSWSwitchReady && failureCallbacks == 0 && posts == 0);
    contextAvailable = true;
    CGEventSetIntegerValueField(event, (CGEventField)132, 4);
    CHECK(tap_callback(NULL, (CGEventType)30, event, NULL) == event);
    CFRelease(event);
    CHECK(psw_transition_decision(1, 2, 1, true, 0.1) == PSWTransitionWaiting);
    CHECK(psw_transition_decision(1, 2, 2, true, 0.1) == PSWTransitionConfirmed);
    CHECK(psw_transition_decision(1, 2, 3, true, 0.1) == PSWTransitionFailed);
    CHECK(psw_transition_decision(1, 2, 0, false, 0.1) == PSWTransitionWaiting);
    CHECK(psw_transition_decision(1, 2, 0, false, 0.75) == PSWTransitionFailed);
    CHECK(psw_transition_decision(1, 2, 2, true, 0.80) == PSWTransitionConfirmed);
    CHECK(psw_transition_decision(1, 2, 1, true, 0.80) == PSWTransitionFailed);
    CHECK(psw_transition_decision(1, 2, 3, true, 0.80) == PSWTransitionFailed);
}
static void test_keyboard(void) {
    // Only a mouse drag hands the shortcut back to macOS.
    reset(); dragActive = true; CHECK(psw_set_keyboard_override_enabled(true, 123, 0, 124, 0));
    CHECK(journal == -1 && !gHotkeysDisabledByUs);
    reset(); gKeyboardEnabled = true; gLeftKey = 123; gRightKey = 124;
    gLeftMods = gRightMods = kCGEventFlagMaskControl;
    CHECK(disable_space_hotkeys());
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, 124, true);
    CGEventSetFlags(event, kCGEventFlagMaskControl);
    CHECK(tap_callback(NULL, kCGEventKeyDown, event, NULL) == NULL && posts == 2);
    CGEventSetIntegerValueField(event, kCGKeyboardEventAutorepeat, 1);
    CHECK(tap_callback(NULL, kCGEventKeyDown, event, NULL) == NULL && posts == 2 && !gQueueCount);
    dragActive = true;
    CHECK(tap_callback(NULL, kCGEventKeyDown, event, NULL) == event);
    CHECK(!gFlight.display && !gTimer && journal == -1 && hotkeys[0] && !hotkeys[1]);
    // macOS owns the shortcut now, so the tap cannot count on seeing the next
    // press. The health check takes the keys back, but only after the drag.
    psw_check_switch_health(); CHECK(journal == -1 && !gHotkeysDisabledByUs);
    dragActive = false; psw_check_switch_health();
    CHECK(gHotkeysDisabledByUs && journal != -1 && !hotkeys[0] && gStatus == PSWSwitchReady);
    reset(); gKeyboardEnabled = true; CHECK(disable_space_hotkeys());
    CGEventSetIntegerValueField(event, kCGKeyboardEventAutorepeat, 0); failAllocation = 1;
    CHECK(tap_callback(NULL, kCGEventKeyDown, event, NULL) == event);
    CHECK(posts == 0 && journal == -1 && gStatus == PSWSwitchEventFailure);
    reset(); gKeyboardEnabled = true; CHECK(disable_space_hotkeys()); trusted = false;
    CHECK(tap_callback(NULL, kCGEventKeyDown, event, NULL) == event);
    CHECK(journal == -1 && gStatus == PSWSwitchAccessibility && !gKeyboardEnabled);
    CFRelease(event);
}
static void test_tap_rearm(void) {
    // macOS disables a tap that was momentarily slow. That must re-arm it and
    // drop anything half-posted, never switch the feature off.
    CGEventRef event = hardware_swipe();
    for (int userInput = 0; userInput < 2; userInput++) {
        reset(); gFailureHandler = fake_failure_handler;
        CHECK(psw_set_swipe_override_enabled(true));
        CHECK(psw_set_keyboard_override_enabled(true, 123, 0, 124, 0));
        CHECK(swipe(event, 1, 0) == NULL && swipe(event, 2, 1) == NULL && posts == 2);
        SwitchRequest queued = {0};
        CHECK(prepare_request(&queued, CFSTR("test-display"), true, CGPointMake(100, 100)));
        CHECK(submit_request(&queued) && gQueueCount == 1);
        unsigned attempts = tapAttempts;
        CGEventType disabled = userInput ? kCGEventTapDisabledByUserInput : kCGEventTapDisabledByTimeout;
        CHECK(tap_callback(NULL, disabled, event, NULL) == event);
        CHECK(tapAttempts == attempts + 1 && gStatus == PSWSwitchReady && failureCallbacks == 0);
        CHECK(gSwipeEnabled && gKeyboardEnabled && journal == 5 && gHotkeysDisabledByUs);
        CHECK(!gFlight.display && !gQueueCount && !gTimer && !gGesture.tracking);
        CHECK(posts == 4 && phases[2] == 8 && current == 2); // partial sequence closed with Cancelled
        CHECK(swipe(event, 1, 0) == NULL && swipe(event, 2, 1) == NULL && swipe(event, 4, 1) == NULL);
        complete_tick(); complete_tick(); complete_tick();
        CHECK(current == 3 && gStatus == PSWSwitchReady && !gFlight.display && !gTimer);
    }
    // Lost permission still stops interception and restores the shortcuts.
    reset(); gFailureHandler = fake_failure_handler;
    CHECK(psw_set_keyboard_override_enabled(true, 123, 0, 124, 0));
    trusted = false;
    CHECK(tap_callback(NULL, kCGEventTapDisabledByTimeout, event, NULL) == event);
    CHECK(gStatus == PSWSwitchAccessibility && !gKeyboardEnabled && journal == -1 && failureCallbacks == 1);
    CFRelease(event);
}
static void test_scrolling_directions(void) {
    // Exercise real input handling through confirmation, including a setting
    // change after preparation. No phase may switch its output convention.
    for (int natural = 0; natural < 2; natural++) for (int right = 0; right < 2; right++) {
        reset(); naturalScrolling = natural; gSwipeEnabled = true;
        CGEventRef event = CGEventCreate(NULL);
        CGEventSetIntegerValueField(event, (CGEventField)55, 30);
        CGEventSetIntegerValueField(event, (CGEventField)110, 23);
        CGEventSetIntegerValueField(event, (CGEventField)123, 1);
        CGEventSetIntegerValueField(event, kCGEventSourceUnixProcessID, 0);
        CGEventSetIntegerValueField(event, (CGEventField)132, 1);
        CHECK(tap_callback(NULL, (CGEventType)30, event, NULL) == NULL);
        naturalScrolling = !natural; // already prepared events retain the snapshot
        CGEventSetIntegerValueField(event, (CGEventField)132, 2);
        CGEventSetDoubleValueField(event, (CGEventField)124, right ? 0.1 : -0.1);
        CHECK(tap_callback(NULL, (CGEventType)30, event, NULL) == NULL);
        CHECK(gExpectedSpace == (right ? 3u : 1u));
        CHECK(gFlight.sequence.naturalScrolling == (bool)natural);
        double progress = CGEventGetDoubleValueField(gFlight.sequence.events[0], (CGEventField)124);
        CHECK(progress == (right == natural ? -1.0 : 1.0));
        CGEventSetIntegerValueField(event, (CGEventField)132, 4);
        CHECK(tap_callback(NULL, (CGEventType)30, event, NULL) == NULL);
        complete_tick(); complete_tick(); complete_tick();
        CHECK(current == (right ? 3u : 1u) && gStatus == PSWSwitchReady);
        CHECK(!gFlight.display && !gQueueCount && !gTimer && !gGesture.tracking);
        CFRelease(event);
    }
}
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--inspect-host") == 0) {
        printf("Read-only host probe: backend=%d Accessibility=%d postAccess=%d mouseDrag=%d naturalScrolling=%d\n",
            psw_current_backend(), gHost.accessibility(), gHost.postAccess(), gHost.dragActive(), gHost.naturalScrolling());
        for (int cursor = 0; cursor < 2; cursor++) {
            SpaceContext spaces; bool ok = gHost.context(NULL, cursor, &spaces);
            printf("%s display snapshot: available=%d", cursor ? "Cursor" : "Active", ok);
            if (ok) {
                char name[128] = "";
                CFStringGetCString(spaces.display, name, sizeof(name), kCFStringEncodingUTF8);
                printf(" current=%llu left=%llu right=%llu display=%s x=%.1f y=%.1f", (unsigned long long)spaces.current,
                    (unsigned long long)spaces.left, (unsigned long long)spaces.right, name, spaces.location.x, spaces.location.y);
                CFRelease(spaces.display);
            }
            printf("\n");
        }
        printf("No events posted, shortcuts changed, or preferences written.\n"); return 0;
    }
    reset(); test_events(); test_hotkeys(); test_permissions(); test_display_delivery(); test_coordinator(); test_native_gesture(); test_keyboard(); test_tap_rearm(); test_scrolling_directions(); reset();
    printf("Fast-switch regressions: %u assertions, %u failures (fake host; no desktop input posted)\n", assertions, failures);
    return failures ? 1 : 0;
}
