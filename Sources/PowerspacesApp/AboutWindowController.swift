// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// The "About Powerspaces" popup, opened from the menu-bar menu. A small, fixed-size
/// window showing the app's own icon, its name and version, a one-line tagline, a
/// button to the GitHub page, and the license. A single shared window, like the other
/// reused panels (Welcome, Shortcuts).
final class AboutWindowController: ActivatingWindowController {
    private static var shared: AboutWindowController?

    static func show() {
        if let existing = shared { existing.bringToFront(); return }
        let controller = AboutWindowController()
        shared = controller
        controller.bringToFront()
    }

    private init() {
        super.init(title: "About Powerspaces",
                   styleMask: [.titled, .closable],
                   content: NSHostingController(rootView: AboutView()))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didClose() { AboutWindowController.shared = nil }
}

/// The About popup's content: the app's own icon art, its name and version (read from
/// the bundle's `CFBundleShortVersionString`, omitted when run unbundled via
/// `swift run`, where there's no Info.plist), a one-line tagline, a button to the
/// GitHub page, and the GPL-3.0 license line.
private struct AboutView: View {
    private static let repoURL = URL(string: "https://github.com/sebastianpdw/powerspaces")!
    private static let licenseURL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!

    /// "Version 1.0" from the bundle; nil when unbundled (so the line is dropped).
    private var versionText: String? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .map { "Version \($0)" }
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: AppIcon.image(side: 96))
                .resizable()
                .frame(width: 96, height: 96)
            Text("Powerspaces")
                .font(.title2).bold()
            if let versionText {
                Text(versionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Per-desktop docks and smart launching for macOS.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("View on GitHub") { NSWorkspace.shared.open(Self.repoURL) }
                .keyboardShortcut(.defaultAction)

            HStack(spacing: 4) {
                Text("Licensed under")
                    .foregroundStyle(.secondary)
                Link("GPL-3.0 ↗", destination: Self.licenseURL)
            }
            .font(.footnote)

            Text("Copyright © Sebastian Panman de Wit, 2026")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 340)
    }
}
