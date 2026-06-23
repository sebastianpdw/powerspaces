// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// Base for the app's reused singleton windows (the Preferences window and the
/// per-desktop dock-color editor). Owns the plumbing both share: build a titled,
/// non-released window that follows the user to the *current* desktop on reopen,
/// become a regular (activatable) app while it's open via `AppActivation`, and
/// drop back to a menu-bar accessory once it closes. Subclasses keep their own
/// `static shared` instance and supply the title, style, and hosted content.
class ActivatingWindowController: NSWindowController, NSWindowDelegate {
    init(title: String, styleMask: NSWindow.StyleMask, content: NSViewController) {
        let window = NSWindow(contentViewController: content)
        window.title = title
        window.styleMask = styleMask
        window.isReleasedWhenClosed = false
        // Reused singleton window: on reopen, come to the desktop the user is on
        // rather than dragging them back to the desktop it was first shown on
        // (`makeKeyAndOrderFront` otherwise switches Spaces to follow the window).
        // For the dock-color editor this is also what makes the picked color land
        // on the desktop they're looking at (the reported "wrong desktop" bug).
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        super.init(window: window)
        window.delegate = self
        AppActivation.enter() // become a regular app so the window can take focus
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Activate the app and bring the single window forward.
    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Subclass hook to clear its `static shared` reference; called on close.
    func didClose() {}

    func windowWillClose(_ notification: Notification) {
        didClose()
        AppActivation.leave()
    }
}

/// Hosts the SwiftUI `PreferencesView` in a standard titled window. A single
/// shared controller keeps one window around and just brings it forward on repeat
/// opens (so the menu item never spawns duplicates).
final class PreferencesWindowController: ActivatingWindowController {
    private static var shared: PreferencesWindowController?

    static func show(strategies: StrategySettingsController) {
        if let existing = shared {
            existing.bringToFront()
            return
        }
        let controller = PreferencesWindowController(strategies: strategies)
        shared = controller
        controller.bringToFront()
    }

    private init(strategies: StrategySettingsController) {
        super.init(title: "Powerspaces Preferences",
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   content: NSHostingController(rootView: PreferencesView(strategies: strategies)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didClose() { PreferencesWindowController.shared = nil }
}

/// Reference-counts the windows that need the app to behave as a regular
/// (Dock-present, activatable) app rather than a menu-bar accessory. The
/// Preferences window and the per-desktop dock-color window both `enter()` on open
/// and `leave()` on close; the app only drops back to `.accessory` once the last
/// one closes — so closing one while the other is open doesn't strand the survivor
/// as an inactive, focus-less window.
@MainActor
enum AppActivation {
    private static var count = 0

    static func enter() {
        count += 1
        NSApp.setActivationPolicy(.regular)
        // Put our icon on the Dock tile. When run unbundled (`swift run`) the tile
        // otherwise shows the generic "exec" icon and ignores applicationIconImage,
        // so we also draw the icon into the tile's content view, which the Dock
        // always honors. A bundled .app (scripts/make-app.sh) gets its icon from
        // Info.plist and doesn't need this, but it's harmless.
        let icon = AppIcon.image()
        NSApp.applicationIconImage = icon
        let tileView = NSImageView(image: icon)
        tileView.imageScaling = .scaleProportionallyUpOrDown
        NSApp.dockTile.contentView = tileView
        NSApp.dockTile.display()
        NSApp.activate(ignoringOtherApps: true)
    }

    static func leave() {
        count = max(0, count - 1)
        if count == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}
