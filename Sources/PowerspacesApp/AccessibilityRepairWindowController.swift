// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// Shown at launch when a "faster desktop switch" override is on in preferences but
/// macOS doesn't actually trust the app (`AXIsProcessTrusted()` is false). That's the
/// stale-TCC-grant case — common after reinstalling or updating an unsigned build:
/// `preferences.json` survives, but the old Accessibility approval no longer matches
/// the new binary, so System Settings can still show the toggle on while the grant is
/// dead. The narrow "faster switch needs Accessibility" warning understates it (with no
/// Accessibility, *nothing* works), so the launch path turns the overrides off and
/// shows this instead: a focused explainer whose primary action resets the stale grant
/// and relaunches for a clean re-grant. A sibling of `WelcomeWindowController`, single
/// shared instance so it can't stack.
final class AccessibilityRepairWindowController: ActivatingWindowController {
    private static var shared: AccessibilityRepairWindowController?

    static func show() {
        if let existing = shared { existing.bringToFront(); return }
        let controller = AccessibilityRepairWindowController()
        shared = controller
        controller.bringToFront()
    }

    private init() {
        super.init(title: "Accessibility needs re-granting",
                   styleMask: [.titled, .closable],
                   content: NSHostingController(rootView: AccessibilityRepairView(
                       onReset: { AccessibilityPermission.performResetAndRelaunch() },
                       onOpenSettings: { AccessibilityPermission.openSettings() },
                       onClose: { AccessibilityRepairWindowController.shared?.close() })))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didClose() { AccessibilityRepairWindowController.shared = nil }
}

/// The repair window's content: the app icon, a short explanation of the stale grant,
/// a note that the faster switch was turned off, and the reset / settings / dismiss
/// buttons. No live status row — Reset & Relaunch quits the app, so there's nothing to
/// keep watching here.
private struct AccessibilityRepairView: View {
    let onReset: () -> Void
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: AppIcon.image(side: 96))
                .resizable()
                .frame(width: 96, height: 96)
            Text("Accessibility needs re-granting")
                .font(.title2).bold()
            Text("Powerspaces shows as allowed for Accessibility, but macOS isn't actually "
                 + "granting it. This usually happens after you reinstall or update the app — "
                 + "the old approval no longer matches the new copy. Reset it and Powerspaces "
                 + "reopens so you can switch it back on cleanly.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label("We turned the faster desktop switch off for now. Turn it back on in "
                  + "Preferences once Accessibility is working.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("Open System Settings") { onOpenSettings() }
                Spacer()
                Button("Not now") { onClose() }
                Button("Reset & Relaunch") { onReset() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 440)
    }
}
