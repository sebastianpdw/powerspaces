// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation

/// Pure geometry for "put this window on the screen the user is actually on."
///
/// On a multi-display Mac, opening a *new window* of an already-running app
/// (e.g. `firefox --new-window`) lets the app decide which screen to use — it
/// usually reuses whichever screen it last had a window on, or the primary
/// display. That can be a different monitor than the one the user is looking at,
/// so the fresh window appears on the "wrong" desktop even though powerspaces
/// asked for it on the current one. macOS then files that window under whatever
/// display it landed on, which is exactly why it shows up on another Space.
///
/// The decision is a pure function of rectangles so it's unit-testable without a
/// live window server. All rects are in the global, top-left-origin coordinate
/// space shared by `CGDisplayBounds` and the Accessibility position attribute.
public enum DisplayPlacement {
    /// Where the window should move to so it sits on the active display, or `nil`
    /// if it's already there (its center is inside `active`).
    ///
    /// The window keeps its size and its *relative* position: it's translated by
    /// the offset between the display it's currently on and the active one (so a
    /// window near the top-left of screen B reappears near the top-left of screen
    /// A), then clamped so it stays fully on the active display.
    public static func reposition(window: CGRect, displays: [CGRect], active: CGRect) -> CGRect? {
        let center = CGPoint(x: window.midX, y: window.midY)
        // Already on the active display → nothing to do.
        if active.contains(center) { return nil }

        // Which display is the window currently on? Prefer the one containing its
        // center; fall back to the one it overlaps most (partially off-screen
        // windows), and finally to its own origin if it overlaps nothing.
        let current = displays.first(where: { $0.contains(center) })
            ?? displays.max(by: { overlap($0, window) < overlap($1, window) })
        let originX = current?.minX ?? window.minX
        let originY = current?.minY ?? window.minY

        let moved = window.offsetBy(dx: active.minX - originX, dy: active.minY - originY)
        return clamp(moved, into: active)
    }

    /// Area of the intersection of two rects (0 if they don't overlap).
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    /// Shift `rect` so it lies fully inside `bounds`. If `rect` is larger than
    /// `bounds` in a dimension, its origin is pinned to the bounds' origin on
    /// that axis (top-left wins over bottom-right).
    static func clamp(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var origin = rect.origin
        origin.x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - rect.width))
        origin.y = min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - rect.height))
        return CGRect(origin: origin, size: rect.size)
    }
}
