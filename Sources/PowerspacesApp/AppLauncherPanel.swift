// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// A floating, Spotlight-style panel that hosts the App Launcher grid. Borderless
/// with a blurred, rounded body; becomes key so the search field accepts typing,
/// but never adds a Dock tile (the agent stays `.accessory`). Dismisses on Escape,
/// on a click in another app, or when an app is launched — but stays put while the
/// user drags a tile onto the bar to pin it (that drag never leaves our process,
/// so the "click outside" monitor doesn't fire).
final class AppLauncherPanel: NSPanel {
    /// Launch a chosen app — set by the app layer to route through smart-launch.
    /// The `Bool` is `forceNew`: ⌘ held opens a new window on the current space.
    var onLaunch: ((InstalledApp, Bool) -> Void)?

    private var clickOutsideMonitor: Any?
    private var keyMonitor: Any?
    /// Selection state shared with the hosted grid; recreated per open so each
    /// session starts with the first app highlighted.
    private var keyboard: LauncherKeyboard?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        // Must stay false: a window-background drag handler swallows the mouse-down
        // before SwiftUI's `.onDrag` on a tile can begin, so dragging an app icon
        // would move the whole panel instead of starting the drag-to-pin. The panel
        // opens centered and doesn't need to be hand-moved (Spotlight-style).
        isMovableByWindowBackground = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    // Borderless panels don't become key by default; the search field needs it.
    override var canBecomeKey: Bool { true }

    /// Toggle from the launcher tile: open if hidden, close if already showing.
    /// `screen` is the screen to open on — the clicked dock's display, so the grid
    /// appears on the desktop the user is looking at. nil (the global hotkey) falls
    /// back to the active screen.
    func toggle(on screen: NSScreen? = nil) { isVisible ? close() : present(on: screen) }

    private func present(on screen: NSScreen? = nil) {
        // Rebuild the content each open so the app list and search box are fresh,
        // and start a fresh keyboard selection (first app highlighted).
        let keyboard = LauncherKeyboard()
        self.keyboard = keyboard
        // Selection colors are read fresh each open (the panel takes key focus, so
        // they can't change while it's up). They mirror the running-app box colors.
        let prefs = Preferences.shared
        let store = InstalledAppsStore.shared
        store.reload() // refresh in the background; the cached list shows instantly
        let root = AppLauncherView(
            store: store,
            keyboard: keyboard,
            outlineColor: Color(nsColor: prefs.launcherOutlineColor),
            highlightColor: Color(nsColor: prefs.launcherHighlightColor)
        ) { [weak self] app, forceNew in
            self?.onLaunch?(app, forceNew)
            self?.close()
        }
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 16
        hosting.layer?.masksToBounds = true
        contentView = hosting

        center(on: screen)
        installMonitors()
        // Bring the agent forward (without a Dock tile — policy stays .accessory)
        // so the borderless panel can take keyboard focus for the search field.
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        invalidateShadow()
    }

    override func close() {
        removeMonitors()
        super.close()
    }

    private func center(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                               y: visible.midY - frame.height / 2))
    }

    // MARK: - Dismissal monitors

    private func installMonitors() {
        removeMonitors()
        // Escape closes; the arrow keys move the grid selection (swallowed so the
        // search field doesn't also move its text cursor); everything else
        // (typing in search, Return → onSubmit) passes through.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            switch event.keyCode {
            case 53: self.close(); return nil              // Escape
            case 123: self.keyboard?.move(.left);  return nil
            case 124: self.keyboard?.move(.right); return nil
            case 125: self.keyboard?.move(.down);  return nil
            case 126: self.keyboard?.move(.up);    return nil
            default: return event
            }
        }
        // A click in another app (or the desktop) dismisses. Global monitors don't
        // fire for our own windows, so clicking inside the panel — or starting a
        // drag-to-pin from a tile — won't trip this.
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickOutsideMonitor { NSEvent.removeMonitor(clickOutsideMonitor) }
        keyMonitor = nil
        clickOutsideMonitor = nil
    }
}
