// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Busy-wait until `condition` holds or `timeout` elapses, re-checking every
/// `interval`. Returns whether the condition was met before the deadline.
///
/// The launcher's "do a thing, then wait for the window world to catch up" flows
/// (relaunch, new-window placement, Finder warm-up) otherwise hand-roll the same
/// `usleep` + deadline loop with bespoke interval/attempt constants. This is the
/// one place that timing lives. Synchronous by design — callers run it off the
/// main thread (the launcher queue), so the brief wait can't freeze the UI.
@discardableResult
func pollUntil(timeout: TimeInterval, interval: useconds_t, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        usleep(interval)
    } while Date() < deadline
    return false
}
