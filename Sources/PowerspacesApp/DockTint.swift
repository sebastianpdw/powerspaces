// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI
import SpaceKit

// MARK: - Per-desktop dock color store

/// Per-desktop dock color/opacity overrides, keyed by the Space's persistent
/// UUID and persisted to `~/.config/powerspaces/dock-colors.json`. A desktop with
/// an entry paints the dock in that color (its alpha is the opacity); a desktop
/// without one falls back to the default dock tint in `Preferences`. Mirrors
/// `PinStore`'s per-Space, file-backed model.
///
/// Colors are stored as human-readable sRGB components `"r,g,b,a"` — the same
/// format `Preferences` uses for its colors — so the JSON stays inspectable.
final class DockTintStore {
    private var colorsBySpace: [String: String]
    private let url: URL

    init(url: URL) {
        self.url = url
        self.colorsBySpace = JSONFileStore.read([String: String].self, from: url) ?? [:]
    }

    /// This desktop's custom color, or nil when it should follow the default.
    func color(forSpace uuid: String) -> NSColor? {
        colorsBySpace[uuid].flatMap(DockTintStore.color(from:))
    }

    /// Whether any desktop has a custom color (drives the Reset button's state).
    var hasOverrides: Bool { !colorsBySpace.isEmpty }

    func setColor(_ color: NSColor, forSpace uuid: String) {
        colorsBySpace[uuid] = DockTintStore.string(from: color)
        save()
    }

    func removeColor(forSpace uuid: String) {
        guard colorsBySpace[uuid] != nil else { return }
        colorsBySpace.removeValue(forKey: uuid)
        save()
    }

    /// Forget every desktop's custom color — the "Reset custom Dock colors" action.
    func clearAll() {
        guard !colorsBySpace.isEmpty else { return }
        colorsBySpace.removeAll()
        save()
    }

    private func save() { JSONFileStore.writeEncodable(colorsBySpace, to: url) }

    // MARK: sRGB "r,g,b,a" codec (matches Preferences' color storage)

    static func string(from color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return "\(c.redComponent),\(c.greenComponent),\(c.blueComponent),\(c.alphaComponent)"
    }

    static func color(from string: String) -> NSColor? {
        let p = string.split(separator: ",").compactMap { Double($0) }
        guard p.count == 4 else { return nil }
        return NSColor(srgbRed: p[0], green: p[1], blue: p[2], alpha: p[3])
    }
}

// MARK: - Per-desktop dock color editor window

/// The Space the editor is currently targeting. Held in an `ObservableObject` so a
/// reopen on a different desktop refreshes the bound `ColorPicker`.
@MainActor
final class DockColorModel: ObservableObject {
    @Published var spaceUUID: String
    init(spaceUUID: String) { self.spaceUUID = spaceUUID }
}

/// The "Change Dock Color (This Desktop)" editor: a `ColorPicker` (with opacity)
/// bound to the current desktop's override, plus a "Reset to Default" button that
/// drops the override and follows the default again. Setting the color writes
/// straight to `Preferences`, which posts `.preferencesDidChange` so the bar re-tints.
struct DockColorView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var model: DockColorModel

    var body: some View {
        Form {
            Section {
                ColorPicker("Dock color", selection: Binding(
                    // Start from this desktop's override, else the default color (an
                    // opaque grey) — so opening the editor fresh shows a solid grey
                    // dock, never a transparent swatch.
                    get: { Color(nsColor: prefs.dockTintOverride(forSpace: model.spaceUUID) ?? prefs.dockTintColor) },
                    set: { prefs.setDockTintOverride(NSColor($0), forSpace: model.spaceUUID) }
                ), supportsOpacity: true)
                    .help("The dock's color on this desktop. Lower the opacity to let more of "
                          + "the blurred background show through.")
                Button("Reset to Default") {
                    prefs.setDockTintOverride(nil, forSpace: model.spaceUUID)
                }
                .disabled(prefs.dockTintOverride(forSpace: model.spaceUUID) == nil)
                .help("Remove this desktop's custom color so it follows the default dock "
                      + "color from Preferences again.")
            } header: {
                Text("This desktop")
            } footer: {
                Text("Sets the dock's color and opacity for this desktop only, overriding the "
                     + "default in Preferences. Other desktops keep the default.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360, minHeight: 230)
    }
}

/// Hosts `DockColorView` in a small titled window. Like `PreferencesWindowController`,
/// a single shared controller keeps one window around and just retargets + brings it
/// forward on repeat opens — the shared singleton/activation plumbing lives in
/// `ActivatingWindowController`.
final class DockColorWindowController: ActivatingWindowController {
    private static var shared: DockColorWindowController?

    static func show(spaceUUID: String) {
        if let existing = shared {
            existing.model.spaceUUID = spaceUUID
            existing.bringToFront()
            return
        }
        let controller = DockColorWindowController(spaceUUID: spaceUUID)
        shared = controller
        controller.bringToFront()
    }

    private let model: DockColorModel

    private init(spaceUUID: String) {
        let model = DockColorModel(spaceUUID: spaceUUID)
        self.model = model
        super.init(title: "Dock color (this desktop)",
                   styleMask: [.titled, .closable, .resizable],
                   content: NSHostingController(rootView: DockColorView(model: model)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didClose() { DockColorWindowController.shared = nil }
}
