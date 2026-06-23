// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// A discoverable cheat-sheet of every Powerspaces shortcut and dock gesture, so the
/// app's power is visible instead of having to be memorized (UX review Principle 7,
/// recognition over recall). Opened from the menu-bar menu and from Preferences. A
/// single shared window, like the other reused panels.
final class ShortcutsWindowController: ActivatingWindowController {
    private static var shared: ShortcutsWindowController?

    static func show() {
        if let existing = shared { existing.bringToFront(); return }
        let controller = ShortcutsWindowController()
        shared = controller
        controller.bringToFront()
    }

    private init() {
        super.init(title: "Keyboard Shortcuts",
                   styleMask: [.titled, .closable, .resizable],
                   content: NSHostingController(rootView: ShortcutsView()))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didClose() { ShortcutsWindowController.shared = nil }
}

/// The cheat-sheet content. Reads `Preferences` live, so the rows reflect the user's
/// actual launcher shortcut, force-new modifier, and middle-click action.
private struct ShortcutsView: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group("App Launcher", launcherRows)
                group("Dock", dockRows)
                group("Menu bar", menuRows)
            }
            .padding(20)
        }
        .frame(minWidth: 460, minHeight: 400)
    }

    private var launcherRows: [(String, String)] {
        let open = prefs.launcherHotkey == .off
            ? ("Not set", "Open the App Launcher (choose a shortcut in Preferences \u{25B8} Behavior)")
            : (prefs.launcherHotkey.label, "Open the App Launcher from anywhere")
        return [
            open,
            ("Type", "Search your apps"),
            ("\u{2191} \u{2193} \u{2190} \u{2192}", "Move the selection"),
            ("Return", "Open the selected app on this desktop"),
            ("\u{2318}Return", "Open it in a new window"),
            ("Esc", "Close the launcher"),
            ("Drag a tile to the bar", "Pin that app to this desktop"),
        ]
    }

    private var dockRows: [(String, String)] {
        [
            ("Click", "Open or focus the app on this desktop"),
            ("\(prefs.forceNewModifier.label)-click", "Open a new window on this desktop"),
            ("Middle-click", prefs.middleClickAction.label),
            ("Right-click", "App menu: pin, new-window rule, quit"),
            ("Hold, then drag", "Reorder the icons"),
            ("Drag an app onto the bar", "Pin it to this desktop"),
        ]
    }

    private var menuRows: [(String, String)] {
        [
            ("\u{2318}R", "Refresh the dock"),
            ("\u{2318},", "Open Preferences"),
            ("\u{2318}Q", "Quit Powerspaces"),
        ]
    }

    private func group(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(rows, id: \.0) { keys, desc in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(keys)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .frame(width: 150, alignment: .leading)
                    Text(desc)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
