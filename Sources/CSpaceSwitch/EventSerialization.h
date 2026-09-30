// Powerspaces — portions adapted from jurplel/InstantSpaceSwitcher (MIT).
// SPDX-License-Identifier: (GPL-3.0-only AND MIT)
#ifndef PSW_EVENT_SERIALIZATION_H
#define PSW_EVENT_SERIALIZATION_H
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>

// Private/undocumented CGEvent fields (numbers observed empirically; see ISS).
// The macOS 27 additions (125, 134, 138, 169) keep upstream's names as they are.
static const CGEventField kFieldEventType                = (CGEventField)55;
static const CGEventField kFieldGestureHIDType           = (CGEventField)110;
static const CGEventField kFieldSwipeMotion              = (CGEventField)123;
static const CGEventField kFieldSwipeProgress            = (CGEventField)124;
static const CGEventField kFieldSwipePositionX           = (CGEventField)125;
static const CGEventField kFieldSwipeVelocityX           = (CGEventField)129;
static const CGEventField kFieldSwipeVelocityY           = (CGEventField)130;
static const CGEventField kFieldGesturePhase             = (CGEventField)132;
static const CGEventField kFieldGesturePhaseAlias        = (CGEventField)134;
static const CGEventField kFieldGestureZoomDeltaY        = (CGEventField)138;
static const CGEventField kFieldSourceUnixProcessIDAlias = (CGEventField)169;
enum { kIOHIDEventTypeDockSwipe = 23 };                    // IOHIDEventType (field 110)
enum { kCGSEventGesture = 29, kCGSEventDockControl = 30 }; // CGS event types (field 55)
enum { kPhaseBegan = 1, kPhaseChanged = 2, kPhaseEnded = 4, kPhaseCancelled = 8 }; // field 132
enum { kMotionHorizontal = 1 };                            // swipe motion (field 123)

enum { PSWSequenceCapacity = 6 };
typedef struct { CGEventRef events[PSWSequenceCapacity]; bool modern, naturalScrolling; } psw_event_sequence;
typedef CGEventRef (*psw_event_factory)(CGEventSourceRef);
enum { PSWBackendUnsupported, PSWBackendLegacy, PSWBackendModern };
int psw_backend_for_major(int major);
int psw_current_backend(void);
double psw_monotonic_time(void);
CGEventRef psw_create_swipe_event(bool modern, int phase, bool right, bool neutral,
                                bool naturalScrolling, psw_event_factory factory);
bool psw_create_sequence(psw_event_sequence *out, bool modern, bool right, bool naturalScrolling,
                         psw_event_factory factory);
void psw_release_sequence(psw_event_sequence *sequence);
bool psw_event_is_marked(CGEventRef event);
void psw_stamp_event(CGEventRef event);
#endif
