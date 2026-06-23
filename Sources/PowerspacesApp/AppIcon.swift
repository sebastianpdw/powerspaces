// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// Builds the app's Dock / app-switcher icon and the menu-bar glyph at runtime.
///
/// powerspaces ships as an unbundled menu-bar agent, so it has no asset-catalog
/// app icon. Without one, macOS falls back to the generic executable icon
/// (labelled "exec") whenever the Preferences window brings the app forward.
///
/// The icon is a "power window": a rounded window frame with a lightning bolt,
/// on a violet squircle — launching apps (power) onto a Space (window). The same
/// drawing backs the Dock tile, the bundled `AppIcon.icns`, the menu-bar glyph
/// (monochrome), and the repo / Raycast PNGs, so there is one source of truth.
enum AppIcon {
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
    }

    /// The full-colour app icon (violet squircle + white power-window glyph).
    /// `side` is the drawing resolution in points; the Dock scales it down, so a
    /// generous value keeps it crisp on Retina displays.
    static func image(side: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            draw(side: side)
            return true
        }
    }

    /// A monochrome menu-bar version: just the window-and-bolt glyph on a
    /// transparent background, with no violet tile. Returned as a *template* image
    /// so macOS tints it to match the menu bar — i.e. white on a dark menu bar.
    static func menuBarImage(side: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let canvas = NSRect(x: 0, y: 0, width: side, height: side)
            // Fill most of the canvas (no tile to inset within); leave a hair of margin.
            let frame = canvas.insetBy(dx: side * 0.13, dy: side * 0.16)
            drawGlyph(in: frame, color: .black)   // template: only the alpha mask matters
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func draw(side: CGFloat) {
        let canvas = NSRect(x: 0, y: 0, width: side, height: side)

        // Rounded-square background with a top-to-bottom violet gradient, inset a
        // touch so the rounded corners aren't clipped by the canvas edge.
        let bg = canvas.insetBy(dx: side * 0.06, dy: side * 0.06)
        let bgRadius = bg.width * 0.2237   // the macOS app-icon squircle proportion
        let bgPath = NSBezierPath(roundedRect: bg, xRadius: bgRadius, yRadius: bgRadius)
        let gradient = NSGradient(colors: [
            rgb(0.55, 0.40, 0.98),
            rgb(0.34, 0.20, 0.80),
        ])
        gradient?.draw(in: bgPath, angle: -90)

        // White power-window glyph occupying the central ~58% of the tile.
        let frame = bg.insetBy(dx: bg.width * 0.21, dy: bg.height * 0.21)
        drawGlyph(in: frame, color: .white)
    }

    /// Draws the window frame + title bar + lightning bolt inside `frame`, in
    /// `color`. Shared by the colour tile (white on violet) and the menu-bar
    /// template glyph; every measurement is a fraction of the frame so it scales.
    private static func drawGlyph(in frame: NSRect, color: NSColor) {
        color.setStroke()
        color.setFill()
        let w = frame.width

        // Window outline.
        let framePath = NSBezierPath(roundedRect: frame, xRadius: w * 0.14, yRadius: w * 0.14)
        framePath.lineWidth = w * 0.063
        framePath.stroke()

        // Title-bar divider.
        let titleY = frame.maxY - frame.height * 0.22
        let bar = NSBezierPath()
        bar.move(to: NSPoint(x: frame.minX, y: titleY))
        bar.line(to: NSPoint(x: frame.maxX, y: titleY))
        bar.lineWidth = w * 0.051
        bar.stroke()

        // Lightning bolt, centred a touch below the window's middle.
        let cx = frame.midX, cy = frame.midY - frame.height * 0.06
        let s = w * 0.40
        let bolt = NSBezierPath()
        bolt.move(to: NSPoint(x: cx + s * 0.18, y: cy + s * 0.55))
        bolt.line(to: NSPoint(x: cx - s * 0.30, y: cy - s * 0.02))
        bolt.line(to: NSPoint(x: cx + s * 0.02, y: cy - s * 0.02))
        bolt.line(to: NSPoint(x: cx - s * 0.18, y: cy - s * 0.55))
        bolt.line(to: NSPoint(x: cx + s * 0.32, y: cy + s * 0.10))
        bolt.line(to: NSPoint(x: cx - s * 0.00, y: cy + s * 0.10))
        bolt.close()
        bolt.fill()
    }

    /// Renders the colour icon to a single PNG at `path`, `px`×`px`. Used by
    /// `PowerspacesApp --export-png <path> <px>` to refresh the repo / Raycast icons
    /// from this same drawing.
    static func exportPNG(to path: String, px: Int) {
        guard let rep = bitmapRep(px: px) else { return }
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Writes a macOS `.iconset` directory (every size `iconutil` expects) at
    /// `dir`. `scripts/make-app.sh` calls this (via `--export-iconset`) to build
    /// `AppIcon.icns`, so the bundled .app icon and the runtime icon come from
    /// this one drawing.
    static func exportIconSet(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // (point size, scale) → iconutil's required filenames.
        let variants: [(pt: Int, scale: Int)] = [
            (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
            (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
        ]
        for v in variants {
            let px = v.pt * v.scale
            guard let rep = bitmapRep(px: px) else { continue }
            let name = v.scale == 1 ? "icon_\(v.pt)x\(v.pt).png" : "icon_\(v.pt)x\(v.pt)@2x.png"
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
    }

    /// Renders `draw(side:)` into a fresh `px`×`px` bitmap.
    private static func bitmapRep(px: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(side: CGFloat(px))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
