// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// Owns the menu-bar status item: its glyph, its menu, and the menu's toggle
/// actions. Most toggles just flip a `Preferences` flag (the app's
/// `preferencesDidChange` observer then applies it), so they live here outright;
/// the few that need the app to do more — refresh the dock, open Preferences,
/// close the App-Launcher grid — are injected as closures, so this controller
/// stays decoupled from `AppDelegate`.
///
/// `AppDelegate` holds the one instance strongly (menu items target it only
/// weakly) and calls `sync()` on launch and whenever a preference changes (the
/// menu glyph, hence the item itself, may have changed).
@MainActor
final class StatusItemController: NSObject, NSMenuItemValidation {
    private var statusItem: NSStatusItem?

    private let onRefresh: () -> Void
    private let onOpenPreferences: () -> Void
    private let onAppLauncherDisabled: () -> Void
    /// The current desktop number, shown next to the glyph when the user enables it.
    private var desktopNumber: Int?

    init(onRefresh: @escaping () -> Void,
         onOpenPreferences: @escaping () -> Void,
         onAppLauncherDisabled: @escaping () -> Void) {
        self.onRefresh = onRefresh
        self.onOpenPreferences = onOpenPreferences
        self.onAppLauncherDisabled = onAppLauncherDisabled
        super.init()
    }

    /// Create / remove / restyle the status item to match the menu-glyph
    /// preference. Called on launch and on every preferences change, so it must
    /// handle each transition (create when first needed, remove when switched to
    /// Hidden). With the `.hidden` glyph there's no item — it keeps a clickable
    /// item for every other glyph (blank for `.invisible`, a glyph/image otherwise).
    func sync() {
        if Preferences.shared.menuGlyph.hidesStatusItem {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
            return
        }
        let item: NSStatusItem
        if let existing = statusItem {
            item = existing
        } else {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem = item
        }
        item.menu = makeStatusMenu()
        applyMenuGlyph()
    }

    /// Update the desktop number shown next to the glyph (when that option is on).
    func updateDesktop(_ number: Int?) {
        guard number != desktopNumber else { return }
        desktopNumber = number
        if Preferences.shared.menuBarShowsDesktopNumber { applyMenuGlyph() }
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Refresh Dock", #selector(refreshAction), key: "r", symbol: "arrow.clockwise"))
        menu.addItem(menuItem("Preferences…", #selector(openPreferences), key: ",", symbol: "gearshape"))
        menu.addItem(menuItem("Keyboard Shortcuts…", #selector(showShortcuts), symbol: "keyboard"))
        menu.addItem(.separator())
        // The common toggles, surfaced here so they're reachable without opening
        // Preferences. `hide/show` items carry a checkmark for their current state,
        // refreshed each time the menu opens by `validateMenuItem`.
        menu.addItem(menuItem("Show App Launcher", #selector(toggleAppLauncher(_:)), symbol: "square.grid.2x2"))
        menu.addItem(menuItem("Hide macOS Dock", #selector(toggleAppleDock(_:)), symbol: "dock.rectangle"))
        menu.addItem(makeFasterSwitchItem())
        menu.addItem(.separator())
        menu.addItem(menuItem("Hide Menu-Bar Icon", #selector(hideMenuBarIcon(_:)), symbol: "eye.slash"))
        menu.addItem(menuItem("Reset Accessibility Permission…", #selector(resetPermissions(_:)), symbol: "arrow.counterclockwise"))
        menu.addItem(.separator())
        menu.addItem(menuItem("About Powerspaces", #selector(showAbout), symbol: "info.circle"))
        let quit = NSMenuItem(title: "Quit Powerspaces",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        menu.addItem(quit)
        return menu
    }

    /// A status-menu item targeting `self`, so `validateMenuItem` is consulted for
    /// its enabled state and checkmark. An optional SF Symbol gives the item a small
    /// leading glyph so the menu reads at a glance.
    private func menuItem(_ title: String, _ action: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    /// A submenu mirroring Preferences ▸ "Faster desktop switch": its two
    /// independent overrides (trackpad swipe and keyboard shortcut), each a
    /// checkmarked toggle, so the feature is reachable straight from the menu bar.
    /// The submenu items still target `self`, so `validateMenuItem` ticks them.
    private func makeFasterSwitchItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.addItem(menuItem("Swipe (four-finger)", #selector(toggleFasterSwipe(_:))))
        submenu.addItem(menuItem("Keyboard shortcut", #selector(toggleFasterKeyboard(_:))))
        let item = NSMenuItem(title: "Faster Desktop Switch", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "bolt", accessibilityDescription: nil)
        item.submenu = submenu
        return item
    }

    private func applyMenuGlyph() {
        guard let button = statusItem?.button else { return }
        let glyph = Preferences.shared.menuGlyph
        let suffix = (Preferences.shared.menuBarShowsDesktopNumber && (desktopNumber ?? 0) > 0)
            ? " \(desktopNumber!)" : ""
        if glyph.usesImage {
            // White-on-dark template glyph, optionally followed by the desktop number.
            button.image = AppIcon.menuBarImage()
            button.imagePosition = suffix.isEmpty ? .imageOnly : .imageLeading
            button.title = suffix
        } else if let symbol = glyph.symbolName {
            // An SF Symbol template (auto-tints to the menu bar), sized for the bar.
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Powerspaces")?
                .withSymbolConfiguration(config)
            button.imagePosition = suffix.isEmpty ? .imageOnly : .imageLeading
            button.title = suffix
        } else {
            button.image = nil
            button.title = glyph.title + suffix
        }
    }

    // MARK: - Status-menu toggles & actions

    @objc private func refreshAction() { onRefresh() }

    @objc private func openPreferences() { onOpenPreferences() }

    /// Open the keyboard-shortcuts cheat-sheet. Self-contained (no AppDelegate hop),
    /// so it just shows the shared window.
    @objc private func showShortcuts() { ShortcutsWindowController.show() }

    /// Open the "About Powerspaces" popup. Self-contained, like the shortcuts sheet.
    @objc private func showAbout() { AboutWindowController.show() }

    /// Show / hide Apple's built-in Dock. Just flips the preference; the
    /// `preferencesDidChange` observer drives `AppleDockController` to apply it.
    @objc private func toggleAppleDock(_ sender: NSMenuItem) {
        Preferences.shared.hideAppleDock.toggle()
    }

    /// Show / hide the App Launcher tile. Flipping the preference posts
    /// `preferencesDidChange`, which refreshes the dock to add/drop the tile; we
    /// also close the open grid when turning it off (matching the dock's own
    /// "Hide App Launcher").
    @objc private func toggleAppLauncher(_ sender: NSMenuItem) {
        let enabled = !Preferences.shared.appLauncherEnabled
        Preferences.shared.appLauncherEnabled = enabled
        if !enabled { onAppLauncherDisabled() }
    }

    /// Toggle the trackpad-swipe "faster desktop switch" override. Just flips the
    /// preference; the `preferencesDidChange` observer drives
    /// `applyFasterDesktopSwitch`, which installs / removes the swipe-override event
    /// tap (and warns via the HUD if Accessibility isn't granted yet).
    @objc private func toggleFasterSwipe(_ sender: NSMenuItem) {
        Preferences.shared.fasterDesktopSwitch.toggle()
    }

    /// Toggle the keyboard "faster desktop switch" override. Just flips the
    /// preference; the `preferencesDidChange` observer drives
    /// `applyFasterKeyboardSwitch`, which takes over / releases the "Move left/right
    /// a space" shortcut (and warns if Accessibility isn't granted yet).
    @objc private func toggleFasterKeyboard(_ sender: NSMenuItem) {
        Preferences.shared.fasterKeyboardSwitch.toggle()
    }

    /// Hide the menu-bar icon entirely (the `.hidden` glyph). Warn first — there's
    /// then no icon to click, so the user needs to know how to get back (it mirrors
    /// the inline note shown for the Hidden glyph in Preferences). `force` shows it
    /// even if warning banners are turned off. Deferred to the next runloop so we're
    /// not tearing down this very menu's status item from inside its own action.
    @objc private func hideMenuBarIcon(_ sender: NSMenuItem) {
        HUD.show("Menu-bar icon hidden. To open Preferences again, right-click the "
                 + "Powerspaces dock and choose “Open Preferences”.", force: true)
        DispatchQueue.main.async { Preferences.shared.menuGlyph = .hidden }
    }

    @objc private func resetPermissions(_ sender: NSMenuItem) {
        AccessibilityPermission.confirmResetAndRelaunch()
    }

    /// Check the hide/show toggles to reflect current state; everything else stays
    /// enabled. Called by AppKit before the menu opens.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleAppLauncher(_:)):
            menuItem.state = Preferences.shared.appLauncherEnabled ? .on : .off
        case #selector(toggleAppleDock(_:)):
            menuItem.state = Preferences.shared.hideAppleDock ? .on : .off
        case #selector(toggleFasterSwipe(_:)):
            menuItem.state = Preferences.shared.fasterDesktopSwitch ? .on : .off
        case #selector(toggleFasterKeyboard(_:)):
            menuItem.state = Preferences.shared.fasterKeyboardSwitch ? .on : .off
        default:
            break
        }
        return true
    }
}
