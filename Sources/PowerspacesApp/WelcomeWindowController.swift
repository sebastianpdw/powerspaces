// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Combine
import SwiftUI

/// The first-run welcome window. It explains what Powerspaces does and why it needs
/// Accessibility *before* the system permission prompt appears, so the user grants
/// it with context instead of meeting a cold OS dialog. Shown once (gated by
/// `Preferences.hasSeenWelcome`); the "Grant Accessibility" button triggers the
/// prompt, and a live status row turns green the moment permission is granted.
final class WelcomeWindowController: ActivatingWindowController {
    private static var shared: WelcomeWindowController?

    static func show() {
        if let existing = shared { existing.bringToFront(); return }
        let controller = WelcomeWindowController()
        shared = controller
        controller.bringToFront()
    }

    private init() {
        super.init(title: "Welcome to Powerspaces",
                   styleMask: [.titled, .closable, .resizable],
                   content: NSHostingController(rootView: WelcomeView(
                       onGrant: { AccessibilityPermission.prompt() },
                       onOpenSettings: { AccessibilityPermission.openSettings() },
                       onClose: { WelcomeWindowController.shared?.close() })))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didClose() { WelcomeWindowController.shared = nil }
}

/// The welcome window's content: the app icon, a one-line description, what the two
/// permissions are (and that Screen Recording is not one of them), a live
/// Accessibility status row, and the grant/continue buttons.
private struct WelcomeView: View {
    let onGrant: () -> Void
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    @State private var trusted = AccessibilityPermission.isTrusted
    // Poll trust once a second so the status flips to granted without a relaunch.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: AppIcon.image(side: 96))
                .resizable()
                .frame(width: 96, height: 96)
            Text("Welcome to Powerspaces")
                .font(.title2).bold()
            Text("Powerspaces makes your macOS desktops work like Windows virtual desktops. "
                 + "Each desktop gets its own dock, and opening an app brings it to the desktop "
                 + "you are on instead of jumping you away.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Label("Each desktop gets its own dock, showing only the apps on it.",
                      systemImage: "dock.rectangle")
                    .fixedSize(horizontal: false, vertical: true)
                Label("Opening an app brings it to the desktop you're on, instead of jumping away.",
                      systemImage: "arrow.up.forward.app")
                    .fixedSize(horizontal: false, vertical: true)
                Label("A searchable App Launcher opens any app, one shortcut away.",
                      systemImage: "square.grid.2x2")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label("Powerspaces needs Accessibility to focus, close, and read the titles of "
                      + "windows.", systemImage: "lock.shield")
                    .fixedSize(horizontal: false, vertical: true)
                Label("It does not need Screen Recording. The dock uses app icons, never "
                      + "screenshots.", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(trusted ? Color.green : Color.orange)
                Text(trusted ? "Accessibility is on." : "Accessibility is off.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            HStack {
                Button("Open System Settings") { onOpenSettings() }
                Spacer()
                Button(trusted ? "Done" : "Grant Accessibility") {
                    if trusted { onClose() } else { onGrant() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 440)
        .onReceive(tick) { _ in trusted = AccessibilityPermission.isTrusted }
    }
}
