// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// The system accessibility-display settings the dock honors: **Reduce Motion** and
/// **Reduce Transparency**. macOS doesn't apply these for a custom AppKit surface
/// automatically, so the dock reads them here and adapts (skip animations, use an
/// opaque background). `AppDelegate` observes
/// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` so a change takes
/// effect live (see `AppDelegate.systemAppearanceChanged`).
@MainActor
enum SystemDisplay {
    /// True when the user asked the system to minimize animation. The dock then
    /// skips its join/leave, hover-magnify, lift, and auto-hide animations.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// True when the user asked the system to reduce translucency. The dock, HUD,
    /// and launcher then use an opaque background instead of vibrancy.
    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}
