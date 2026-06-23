// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

// Headless icon export for packaging: `PowerspacesApp --export-iconset <dir>`
// renders the app icon into a .iconset (used by scripts/make-app.sh) and exits
// before any UI is created.
if let idx = CommandLine.arguments.firstIndex(of: "--export-iconset"),
   idx + 1 < CommandLine.arguments.count {
    AppIcon.exportIconSet(to: CommandLine.arguments[idx + 1])
    exit(0)
}

// Headless single-PNG export: `PowerspacesApp --export-png <path> <px>` renders the
// colour app icon at one size (used to refresh the repo `icon.png` and the Raycast
// `extension-icon.png` from the same drawing) and exits.
if let idx = CommandLine.arguments.firstIndex(of: "--export-png"),
   idx + 2 < CommandLine.arguments.count,
   let px = Int(CommandLine.arguments[idx + 2]) {
    AppIcon.exportPNG(to: CommandLine.arguments[idx + 1], px: px)
    exit(0)
}

// powerspaces menu-bar agent: a per-Space dock that shows only the apps with a
// window on the desktop you're standing on, and routes clicks through the
// smart-launch engine. Runs as an accessory (no Dock tile of its own).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
