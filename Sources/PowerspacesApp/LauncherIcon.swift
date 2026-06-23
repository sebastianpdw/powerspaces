// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// Draws the App Launcher tile's icon — a rounded square with a 3×3 grid of dots,
/// the universal "all apps" / Launchpad motif. Built at runtime (like `AppIcon`)
/// rather than shipped as an asset, so it stays crisp at any size and matches the
/// app's drawn-icon aesthetic.
enum LauncherIcon {
    static func image(side: CGFloat = 256, baseColor: NSColor) -> NSImage {
        // Derive the gradient stops here, on the caller's main actor, so the drawing
        // handler (which may run off the main thread) captures only plain colors and
        // never reaches into the @MainActor `Preferences.shared` singleton.
        let top = scaled(baseColor, by: 1.24)
        let bottom = scaled(baseColor, by: 0.76)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            draw(side: side, top: top, bottom: bottom)
            return true
        }
    }

    private static func draw(side: CGFloat, top: NSColor, bottom: NSColor) {
        let canvas = NSRect(x: 0, y: 0, width: side, height: side)

        // Rounded-square background with a top-to-bottom slate gradient — distinct
        // from the blue app icon, so the tile reads as a system control, not an app.
        // The two stops are derived (by the caller) from the configurable base color,
        // so the tile keeps its depth at any color.
        let bg = canvas.insetBy(dx: side * 0.06, dy: side * 0.06)
        let bgRadius = bg.width * 0.235 // the macOS app-icon squircle proportion
        let bgPath = NSBezierPath(roundedRect: bg, xRadius: bgRadius, yRadius: bgRadius)
        let gradient = NSGradient(colors: [top, bottom])
        gradient?.draw(in: bgPath, angle: -90)

        // A 3×3 grid of small rounded white squares — the "all applications" glyph.
        NSColor.white.setFill()
        let area = bg.insetBy(dx: bg.width * 0.22, dy: bg.height * 0.22)
        let gap = area.width * 0.16
        let cell = (area.width - gap * 2) / 3
        let dotRadius = cell * 0.28
        for row in 0..<3 {
            for col in 0..<3 {
                let x = area.minX + CGFloat(col) * (cell + gap)
                let y = area.minY + CGFloat(row) * (cell + gap)
                let dot = NSRect(x: x, y: y, width: cell, height: cell)
                NSBezierPath(roundedRect: dot, xRadius: dotRadius, yRadius: dotRadius).fill()
            }
        }
    }

    /// Returns `color` with each RGB channel scaled by `factor` (clamped to 1).
    /// Scaling all channels equally changes brightness while preserving hue,
    /// saturation, and alpha — used to derive the tile's lighter top and darker
    /// bottom gradient stops from a single base color.
    private static func scaled(_ color: NSColor, by factor: CGFloat) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        return NSColor(srgbRed: min(1, c.redComponent * factor),
                       green: min(1, c.greenComponent * factor),
                       blue: min(1, c.blueComponent * factor),
                       alpha: c.alphaComponent)
    }
}
