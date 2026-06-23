// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ColorSync
import SwiftUI
import SpaceKit

/// A "Name … ✓/⚠ status" row used by the System-tab setup sections (AltTab,
/// Raycast/CLI/npm): a green check or orange warning, or a spinner while the
/// probe is still running. One definition, shared by every setup row.
@ViewBuilder
func statusLine(_ title: String, ok: Bool, pending: Bool = false, text: String) -> some View {
    HStack {
        Text(title)
        Spacer()
        if pending {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
        }
        Text(text).foregroundStyle(.secondary)
    }
}

/// The full preferences window content: an "Advanced" switch at the top-right
/// (off = Basic), over seven grouped tabs (Dock, Icons, Effects, Windows, Behavior,
/// Strategies, System). Each tab is bound to `Preferences` (UI prefs) or
/// `StrategySettingsController` (launch strategies). The System tab gathers the
/// settings about how Powerspaces sits on the Mac — the macOS Dock, the Raycast
/// extension, the menu-bar icon / login item / Accessibility, and Uninstall. Every
/// numeric setting is a preset dropdown that reveals a slider on "Custom…", and every
/// control has a `.help` tooltip. In **Basic** mode only the most common controls show;
/// switching to **Advanced** reveals the rest (colors, speeds, widths, niche options) —
/// all seven tabs stay visible either way.
struct PreferencesView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var strategies: StrategySettingsController
    /// Settings-search query and the selected tab (so a result can jump to its tab).
    @State private var query = ""
    @State private var selectedTab = 0

    /// Whether to reveal the advanced (fine-tuning) controls.
    private var advanced: Bool { prefs.detailLevel == .advanced }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search settings", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 240)
                Spacer()
                Toggle("Advanced", isOn: Binding(
                    get: { prefs.detailLevel == .advanced },
                    set: { prefs.detailLevel = $0 ? .advanced : .basic }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Off shows the most common settings. On reveals every setting.")
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 6)
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                TabView(selection: $selectedTab) {
                    dockTab.tabItem { Label("Dock", systemImage: "dock.rectangle") }.tag(0)
                    iconsTab.tabItem { Label("Icons", systemImage: "square.grid.2x2") }.tag(1)
                    effectsTab.tabItem { Label("Effects", systemImage: "wand.and.stars") }.tag(2)
                    windowsTab.tabItem { Label("Windows", systemImage: "macwindow") }.tag(3)
                    behaviorTab.tabItem { Label("Behavior", systemImage: "gearshape") }.tag(4)
                    strategyTab.tabItem { Label("New windows", systemImage: "arrow.up.forward.app") }.tag(5)
                    systemTab.tabItem { Label("System", systemImage: "menubar.dock.rectangle") }.tag(6)
                }
                .padding([.horizontal, .bottom], 20)
            } else {
                searchResults
            }
        }
        .frame(minWidth: 560, minHeight: 560)
    }

    // A two-way binding into the shared Preferences object.
    private func bind<T>(_ keyPath: ReferenceWritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { prefs[keyPath: keyPath] }, set: { prefs[keyPath: keyPath] = $0 })
    }

    /// Confirm, then reset every appearance/behavior setting to its default. Cancel
    /// is the default button, so a stray Return can't wipe settings.
    private func confirmResetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings to defaults?"
        alert.informativeText = "Every appearance and behavior setting goes back to its default. "
            + "Your pinned apps, recents, and per-app launch rules are kept."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset")
        alert.buttons.last?.hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn { prefs.resetAllToDefaults() }
    }

    /// The settings-search results. Clicking a match reveals every control (so it's
    /// visible) and jumps to its tab.
    @ViewBuilder private var searchResults: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = PreferencesView.settingsIndex.filter {
            $0.name.lowercased().contains(q) || $0.keywords.contains(q)
        }
        if matches.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.tertiary)
                Text("No settings match “\(query)”").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        } else {
            List(matches) { entry in
                Button {
                    prefs.detailLevel = .advanced // reveal every control so the match shows
                    selectedTab = entry.tab
                    query = ""
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: PreferencesView.tabSymbols[entry.tab])
                            .foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name)
                            Text(PreferencesView.tabNames[entry.tab])
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding([.horizontal, .bottom], 20)
        }
    }

    /// One searchable setting: its display name, the tab it lives on, and extra
    /// keywords (synonyms) to match against.
    private struct SettingEntry: Identifiable {
        let name: String
        let tab: Int
        let keywords: String
        var id: String { name }
    }
    private static let tabNames = ["Dock", "Icons", "Effects", "Windows", "Behavior", "New windows", "System"]
    private static let tabSymbols = ["dock.rectangle", "square.grid.2x2", "wand.and.stars",
                                     "macwindow", "gearshape", "arrow.up.forward.app", "menubar.dock.rectangle"]
    private static let settingsIndex: [SettingEntry] = [
        .init(name: "Dock position", tab: 0, keywords: "edge top bottom left right side"),
        .init(name: "Material / blur", tab: 0, keywords: "vibrancy translucency hud"),
        .init(name: "Dock height", tab: 0, keywords: "thickness size"),
        .init(name: "Corner radius", tab: 0, keywords: "rounded"),
        .init(name: "Gap from screen edge", tab: 0, keywords: "margin"),
        .init(name: "Show dock on (screens)", tab: 0, keywords: "monitor display multiple"),
        .init(name: "Dock color / tint", tab: 0, keywords: "tint colour background"),
        .init(name: "Dock outline", tab: 0, keywords: "border"),
        .init(name: "Auto-hide the dock", tab: 0, keywords: "hide reveal"),
        .init(name: "Dock on full-screen apps", tab: 0, keywords: "fullscreen full screen hide show auto-hide"),
        .init(name: "Current-desktop indicator", tab: 0, keywords: "badge number space"),
        .init(name: "Icon size", tab: 1, keywords: "big small"),
        .init(name: "Icon spacing", tab: 1, keywords: "gap"),
        .init(name: "Running indicator", tab: 1, keywords: "dim box outline running"),
        .init(name: "Hover effect", tab: 2, keywords: "magnify highlight"),
        .init(name: "Icon animation", tab: 2, keywords: "add remove poof slide fade"),
        .init(name: "Show an icon per window", tab: 3, keywords: "windows multiple"),
        .init(name: "Show window titles", tab: 3, keywords: "label taskbar title"),
        .init(name: "Show hidden apps", tab: 3, keywords: "hidden"),
        .init(name: "Show apps with no windows", tab: 3, keywords: "windowless running"),
        .init(name: "App Launcher", tab: 3, keywords: "launchpad grid apps"),
        .init(name: "Open App Launcher shortcut", tab: 4, keywords: "hotkey keyboard"),
        .init(name: "Middle-click action", tab: 4, keywords: "click mouse"),
        .init(name: "Force new window modifier", tab: 4, keywords: "shift option"),
        .init(name: "Quit on last window close", tab: 4, keywords: "close to quit experimental"),
        .init(name: "Refresh interval", tab: 4, keywords: "poll performance"),
        .init(name: "Faster desktop switch", tab: 4, keywords: "swipe instant space"),
        .init(name: "Warning banners", tab: 4, keywords: "hud notify"),
        .init(name: "New-window strategy", tab: 5, keywords: "launch open applescript"),
        .init(name: "Hide the macOS Dock", tab: 6, keywords: "apple dock"),
        .init(name: "Raycast extension", tab: 6, keywords: "raycast cli spotlight"),
        .init(name: "Per-desktop ⌘-Tab (AltTab)", tab: 6, keywords: "alttab cmd tab switcher"),
        .init(name: "Menu-bar icon", tab: 6, keywords: "glyph status"),
        .init(name: "Desktop number in menu bar", tab: 6, keywords: "number"),
        .init(name: "Launch at login", tab: 6, keywords: "startup login"),
        .init(name: "Accessibility permission", tab: 6, keywords: "permission reset"),
        .init(name: "Reset all settings", tab: 6, keywords: "defaults reset"),
        .init(name: "Uninstall", tab: 6, keywords: "remove delete"),
    ]

    private func enumPicker<E: CaseIterable & Identifiable & Hashable>(
        _ title: String, help: String, _ binding: Binding<E>, label: @escaping (E) -> String
    ) -> some View {
        Picker(title, selection: binding) {
            ForEach(Array(E.allCases)) { Text(label($0)).tag($0) }
        }
        .help(help)
    }

    /// A connected display offered for the "Selected screens" dock list, identified
    /// by the same UUID string the window server uses for that display.
    struct ConnectedDisplay: Identifiable {
        let uuid: String
        let name: String
        var id: String { uuid }
    }

    /// The currently attached displays (friendly name + UUID), for the multi-select
    /// "Show dock on" list. Displays whose UUID can't be read are skipped.
    static func connectedDisplays() -> [ConnectedDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let uuid = screen.displayUUID else { return nil }
            return ConnectedDisplay(uuid: uuid, name: screen.localizedName)
        }
    }

    // MARK: Dock — the bar's geometry, outline, and auto-hide

    private var dockTab: some View {
        Form {
            Section("Layout") {
                enumPicker("Position", help: "Which screen edge the bar sits on.",
                           bind(\.barPosition)) { $0.label }
                enumPicker("Material / blur", help: "The bar's translucency and blur style.",
                           bind(\.barMaterial)) { $0.label }
                NumericRow(title: "Dock height",
                           help: "How thick the bar is, in points. The smallest setting hugs "
                               + "the icons exactly; larger values add padding around them.",
                           spec: Preferences.dockHeightSpec,
                           value: bind(\.dockHeight), isCustom: bind(\.dockHeightCustom))
                if advanced {
                    NumericRow(title: "Corner radius", help: "How rounded the bar's corners are, in points.",
                               spec: Preferences.cornerRadiusSpec,
                               value: bind(\.cornerRadius), isCustom: bind(\.cornerRadiusCustom))
                    NumericRow(title: "Gap from screen edge",
                               help: "Distance between the bar and the screen edge, in points.",
                               spec: Preferences.edgeGapSpec,
                               value: bind(\.edgeGap), isCustom: bind(\.edgeGapCustom))
                }
            }
            Section {
                Toggle("Show current-desktop indicator", isOn: bind(\.desktopIndicatorEnabled))
                    .help("Show a small \u{201C}Desktop N\u{201D} badge so you can always see which "
                          + "desktop you are on.")
                if prefs.desktopIndicatorEnabled {
                    enumPicker("Position", help: "Where the badge sits: above the bar, or inside "
                               + "it at the start, end, or middle of the icons.",
                               bind(\.desktopIndicatorPosition)) { $0.label }
                }
            } header: {
                Text("Current desktop")
            } footer: {
                Text("macOS does not number desktops on screen, so this badge shows which one you "
                     + "are on.")
            }
            Section {
                enumPicker("Show dock on",
                           help: "Put a dock on every screen, or only the screens you pick. Each "
                               + "screen's dock is independent. It shows and acts on that screen.",
                           bind(\.dockScreensMode)) { $0.label }
                if prefs.dockScreensMode == .selectedScreens {
                    let displays = PreferencesView.connectedDisplays()
                    if displays.isEmpty {
                        Text("No displays detected.").foregroundStyle(.secondary)
                    } else {
                        ForEach(displays) { display in
                            Toggle(display.name, isOn: Binding(
                                get: { prefs.dockScreenIDs.contains(display.uuid) },
                                set: { on in
                                    var ids = prefs.dockScreenIDs.filter { $0 != display.uuid }
                                    if on { ids.append(display.uuid) }
                                    prefs.dockScreenIDs = ids
                                }))
                        }
                        if prefs.dockScreenIDs.isEmpty {
                            Text("No screens selected. No dock will show until you pick one.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Screens")
            } footer: {
                Text("Each screen gets its own dock showing that screen's windows, so two screens "
                     + "behave like two desktops. Clicking a screen's dock opens windows on that "
                     + "screen.")
            }
            Section {
                Toggle("Tint the dock", isOn: bind(\.dockTintEnabled))
                    .help("Overlay a color of your choosing on the bar. Off keeps the plain "
                          + "material / blur look.")
                if prefs.dockTintEnabled {
                    ColorPicker("Dock color", selection: Binding(
                        get: { Color(nsColor: prefs.dockTintColor) },
                        set: { prefs.dockTintColor = NSColor($0) }
                    ), supportsOpacity: true)
                        .help("The default dock color and opacity, used on every desktop without "
                              + "its own override. Lower the opacity to let the blur show through.")
                }
                Button("Reset custom Dock colors") { prefs.resetDockTintOverrides() }
                    .disabled(!prefs.hasDockTintOverrides)
                    .help("Clear the per-desktop dock colors you've set by right-clicking the "
                          + "dock. Every desktop goes back to the default above.")
            } header: {
                Text("Color")
            } footer: {
                Text("Sets the default dock color. To give one desktop its own color, right-click "
                     + "the dock and choose “Change dock color (this desktop)”.")
            }
            if advanced {
                Section("Outline") {
                    NumericRow(title: "Dock outline",
                               help: "Thickness of a border drawn around the whole bar, in points "
                                   + "(None leaves the bar borderless). Separate from the running-app box.",
                               spec: Preferences.dockOutlineWidthSpec,
                               value: bind(\.dockOutlineWidth), isCustom: bind(\.dockOutlineWidthCustom))
                    if prefs.dockOutlineWidth > 0 {
                        ColorPicker("Dock outline color", selection: Binding(
                            get: { Color(nsColor: prefs.dockOutlineColor) },
                            set: { prefs.dockOutlineColor = NSColor($0) }
                        ), supportsOpacity: true)
                            .help("Color of the border drawn around the whole dock bar.")
                    }
                }
            }
            Section {
                Toggle("Hide the dock automatically", isOn: bind(\.autoHideEnabled))
                    .help("Tuck the bar off its screen edge when the pointer is away, and "
                          + "reveal it when the pointer returns to that edge.")
                if advanced {
                    enumPicker("Animation",
                               help: "How the bar hides and reveals: slide off the edge, fade in "
                                   + "place, or both.",
                               bind(\.autoHideAnimation)) { $0.label }
                        .disabled(!prefs.autoHideEnabled)
                    NumericRow(title: "Hide after",
                               help: "How long the pointer must be away from the bar before it hides. "
                                   + "Instant hides as soon as the pointer leaves.",
                               spec: Preferences.autoHideDelaySpec,
                               value: bind(\.autoHideDelay), isCustom: bind(\.autoHideDelayCustom))
                        .disabled(!prefs.autoHideEnabled)
                    NumericRow(title: "Hide speed",
                               help: "How long the hide animation takes. Instant snaps it away.",
                               spec: Preferences.autoHideSpeedSpec,
                               value: bind(\.autoHideSpeed), isCustom: bind(\.autoHideSpeedCustom))
                        .disabled(!prefs.autoHideEnabled)
                    NumericRow(title: "Show speed",
                               help: "How long the reveal animation takes. Instant shows it immediately.",
                               spec: Preferences.autoShowSpeedSpec,
                               value: bind(\.autoShowSpeed), isCustom: bind(\.autoShowSpeedCustom))
                        .disabled(!prefs.autoHideEnabled)
                }
            } header: {
                Text("Auto-hide")
            } footer: {
                Text("Move the pointer to the screen edge the bar hugs (bottom, top, left, or "
                     + "right, matching its Position) to bring it back.")
            }
            Section {
                enumPicker("On full-screen apps",
                           help: "What the per-desktop dock does on a screen that's showing a "
                               + "full-screen app. Hide removes the bar (it can't be revealed); "
                               + "Auto-hide tucks it away but reveals it when the pointer reaches "
                               + "the edge; Show keeps it floating over the app.",
                           bind(\.fullscreenDockBehavior)) { $0.label }
            } header: {
                Text("Full-screen apps")
            } footer: {
                Text("Applies only on a screen whose current desktop is a full-screen app "
                     + "(or a Split View pair). Normal desktops always show the bar.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Icons — size, spacing, and the running-app indicator

    private var iconsTab: some View {
        Form {
            Section("Size & spacing") {
                NumericRow(title: "Icon size", help: "How big each app icon is, in points.",
                           spec: Preferences.iconSizeSpec,
                           value: bind(\.iconSize), isCustom: bind(\.iconSizeCustom))
                NumericRow(title: "Icon spacing", help: "Gap between adjacent icons, in points.",
                           spec: Preferences.iconSpacingSpec,
                           value: bind(\.iconSpacing), isCustom: bind(\.iconSpacingCustom))
            }
            Section {
                enumPicker("Running indicator",
                           help: "How running apps are told apart from pinned-but-not-running "
                               + "shortcuts: dim the not-running ones, or box the running ones.",
                           bind(\.runningIndicator)) { $0.label }
                if advanced {
                    if prefs.runningIndicator == .dimmed {
                        NumericRow(title: "Dim pinned / not-running",
                                   help: "Opacity of pinned apps that aren't running (lower = fainter).",
                                   spec: Preferences.dimLevelSpec,
                                   value: bind(\.dimLevel), isCustom: bind(\.dimLevelCustom))
                    } else {
                        NumericRow(title: "Outline gap",
                                   help: "How far the running-app outline floats out from the icon, in "
                                       + "points (0 hugs the icon).",
                                   spec: Preferences.boxGapSpec,
                                   value: bind(\.boxGap), isCustom: bind(\.boxGapCustom))
                        NumericRow(title: "Outline width",
                                   help: "Thickness of the running-app outline, in points.",
                                   spec: Preferences.boxOutlineWidthSpec,
                                   value: bind(\.boxOutlineWidth), isCustom: bind(\.boxOutlineWidthCustom))
                        ColorPicker("Outline color", selection: Binding(
                            get: { Color(nsColor: prefs.boxOutlineColor) },
                            set: { prefs.boxOutlineColor = NSColor($0) }
                        ), supportsOpacity: true)
                            .help("Color of the outline drawn around each running app.")
                        ColorPicker("Highlight color", selection: Binding(
                            get: { Color(nsColor: prefs.boxHighlightColor) },
                            set: { prefs.boxHighlightColor = NSColor($0) }
                        ), supportsOpacity: true)
                            .help("Color tinting the inside of each running app's box. Lower its "
                                  + "opacity to keep the icon visible through it.")
                    }
                }
            } header: {
                Text("Running indicator")
            } footer: {
                Text("“Dim not-running” fades pinned apps that aren't open; “Box running” frames "
                     + "open apps with a colored outline instead.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Effects — hover, and the add/remove icon animation

    private var effectsTab: some View {
        Form {
            Section {
                Toggle("Enable hover effect", isOn: bind(\.hoverEnabled))
                    .help("Master switch for the magnify + highlight when you point at an icon.")
                if advanced {
                    NumericRow(title: "Magnification", help: "How much an icon grows on hover (1.0× = no growth).",
                               spec: Preferences.hoverScaleSpec,
                               value: bind(\.hoverScale), isCustom: bind(\.hoverScaleCustom))
                        .disabled(!prefs.hoverEnabled)
                    NumericRow(title: "Highlight", help: "Opacity of the highlight behind a hovered icon.",
                               spec: Preferences.hoverHighlightSpec,
                               value: bind(\.hoverHighlight), isCustom: bind(\.hoverHighlightCustom))
                        .disabled(!prefs.hoverEnabled)
                    NumericRow(title: "Animation speed", help: "How long the hover magnify/highlight takes.",
                               spec: Preferences.hoverAnimationSpec,
                               value: bind(\.hoverAnimation), isCustom: bind(\.hoverAnimationCustom))
                        .disabled(!prefs.hoverEnabled)
                }
            } header: {
                Text("Hover")
            } footer: {
                Text("The magnify + highlight when you point at an icon. Off disables it entirely.")
            }
            Section {
                Toggle("Animate when an app is added", isOn: bind(\.animateOnAdd))
                    .help("When an app joins the dock (launched, pinned, or its first window "
                          + "opens here), grow the bar to open a slot and let the icon appear.")
                Toggle("Animate when an app is removed", isOn: bind(\.animateOnRemove))
                    .help("When an app leaves the dock (quit, unpinned, or its last window here "
                          + "closes), play the icon out and shrink the bar to close the gap.")
                if advanced {
                    enumPicker("Style", help: "How an icon appears and disappears.",
                               bind(\.iconAnimationStyle)) { $0.label }
                        .disabled(!prefs.animateOnAdd && !prefs.animateOnRemove)
                    NumericRow(title: "Speed",
                               help: "How long each beat (the slot open/close and the icon "
                                   + "appear/disappear) takes. Instant skips the animation.",
                               spec: Preferences.iconAnimationSpeedSpec,
                               value: bind(\.iconAnimationSpeed), isCustom: bind(\.iconAnimationSpeedCustom))
                        .disabled(!prefs.animateOnAdd && !prefs.animateOnRemove)
                }
            } header: {
                Text("Icon animation")
            } footer: {
                Text("Plays when an app joins or leaves the dock, not when you switch desktops. "
                     + "Style and speed are shared by both directions.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Windows — per-window icons, titles, and the App Launcher

    private var windowsTab: some View {
        Form {
            Section {
                Toggle("Show an icon per open window", isOn: bind(\.showIconPerWindow))
                    .help("Duplicate an app's icon for each window it has on this desktop.")
                Toggle("Show window titles (wide items)", isOn: bind(\.showWindowLabels))
                    .help("Make each window a wider item with its title in white text, like the "
                          + "Windows taskbar. Titles are read live via Accessibility (for a browser "
                          + "that's the page title; the literal URL isn't available).")
                if advanced {
                    enumPicker("Show titles for",
                               help: "Label every app's window, or only apps that have more than one "
                                   + "window open here (single-window apps stay a plain icon).",
                               bind(\.windowLabelScope)) { $0.label }
                        .disabled(!prefs.showWindowLabels)
                    ColorPicker("Title text color", selection: Binding(
                        get: { Color(nsColor: prefs.windowLabelTextColor) },
                        set: { prefs.windowLabelTextColor = NSColor($0) }
                    ), supportsOpacity: true)
                        .help("Color of the window-title text shown in each wide item.")
                        .disabled(!prefs.showWindowLabels)
                    NumericRow(title: "Window item width",
                               help: "How wide each labeled window item is, in points.",
                               spec: Preferences.windowLabelWidthSpec,
                               value: bind(\.windowLabelWidth), isCustom: bind(\.windowLabelWidthCustom))
                        .disabled(!prefs.showWindowLabels)
                }
            } header: {
                Text("Windows")
            } footer: {
                Text("Per-window icons: an app with two windows on this desktop appears twice. "
                     + "Window titles widens each item and labels it with that window's title, so "
                     + "you can tell windows apart at a glance.")
            }
            Section {
                Toggle("Show hidden apps", isOn: bind(\.showHiddenWindows))
                    .help("Keep an app in the dock after you ⌘-hide it (its windows go "
                          + "off-screen), like its tile in macOS's Dock, so you can click it "
                          + "back. Off drops hidden apps from the dock until you unhide them.")
                Toggle("Show apps with no open windows", isOn: bind(\.showWindowlessApps))
                    .help("Keep a running app in the dock even when it has no open window, "
                          + "like macOS's Dock keeps its icon after you close its last window, so"
                          + "a click reopens a window. Off hides such apps until they have a window. "
                          + "These show on every desktop (nothing ties them to one); only regular "
                          + "apps qualify, never background helpers.")
            } header: {
                Text("Hidden & window-less apps")
            } footer: {
                Text("Whether ⌘-hidden apps and running apps with no open window still appear in "
                     + "the dock. Both on by default, matching macOS's own Dock.")
            }
            Section {
                Toggle("Show the App Launcher", isOn: bind(\.appLauncherEnabled))
                    .help("Add a Launchpad-style tile to the bar that opens a grid of every "
                          + "installed app.")
                if advanced {
                    ColorPicker("Icon color", selection: Binding(
                        get: { Color(nsColor: prefs.launcherIconColor) },
                        set: { prefs.launcherIconColor = NSColor($0) }
                    ))
                        .help("Base color of the App Launcher's tile. The tile's subtle "
                              + "gradient is derived from this color.")
                        .disabled(!prefs.appLauncherEnabled)
                    ColorPicker("Outline color", selection: Binding(
                        get: { Color(nsColor: prefs.launcherOutlineColor) },
                        set: { prefs.launcherOutlineColor = NSColor($0) }
                    ), supportsOpacity: true)
                        .help("Color of the ring drawn around the selected app in the launcher.")
                        .disabled(!prefs.appLauncherEnabled)
                    ColorPicker("Highlight color", selection: Binding(
                        get: { Color(nsColor: prefs.launcherHighlightColor) },
                        set: { prefs.launcherHighlightColor = NSColor($0) }
                    ), supportsOpacity: true)
                        .help("Color filling the selected app's tile. Lower its opacity to keep "
                              + "the icon visible through it.")
                        .disabled(!prefs.appLauncherEnabled)
                }
            } header: {
                Text("App Launcher")
            } footer: {
                Text("Adds a tile (leftmost by default, drag to move it) that opens a searchable "
                     + "grid of all your Applications. Click an app to launch it on this desktop, "
                     + "or drag one onto the bar to pin it. Use the arrow keys to move the "
                     + "selection; Return launches the selected app.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Behavior — clicks, refresh, faster switch, and warnings

    private var behaviorTab: some View {
        Form {
            Section {
                enumPicker("Open App Launcher",
                           help: "A keyboard shortcut that opens the App Launcher from anywhere, "
                               + "even when Powerspaces is not in front. Off by default so it will "
                               + "not clash with your other shortcuts.",
                           bind(\.launcherHotkey)) { $0.label }
                Button("Keyboard Shortcuts…") { ShortcutsWindowController.show() }
                    .help("Show every Powerspaces shortcut and dock gesture.")
            } header: {
                Text("Keyboard shortcut")
            } footer: {
                Text("Opens the searchable app grid from any app. Pick a combo that is free on "
                     + "your Mac.")
            }
            Section("Clicks") {
                enumPicker("Middle-click action",
                           help: "What clicking a dock icon with the middle mouse button does.",
                           bind(\.middleClickAction)) { $0.label }
                if advanced {
                    enumPicker("Force new window with", help: "Which modifier forces a brand-new window on click.",
                               bind(\.forceNewModifier)) { $0.label }
                }
            }
            Section {
                Toggle("Quit an app when its last window closes", isOn: bind(\.quitOnLastWindowClose))
                    .help("Close-to-quit: closing an app's last window quits that app instead "
                          + "of leaving it running with no windows. Stops background copies from "
                          + "piling up when you summon an app to many desktops (e.g. Claude). "
                          + "Experimental: it overrides an app's own behavior and can discard "
                          + "unsaved work, so it's off by default.")
            } header: {
                Text("Closing windows (experimental)")
            } footer: {
                Text("When on, closing the last window of an app quits it, so it leaves ⌘-Tab "
                     + "and frees memory instead of lingering invisibly. Acts per app instance; "
                     + "minimizing never quits.")
            }
            if advanced {
                Section("Performance") {
                    NumericRow(title: "Refresh interval",
                               help: "How often the dock re-scans windows (lower = snappier, more CPU).",
                               spec: Preferences.pollIntervalSpec,
                               value: bind(\.pollInterval), isCustom: bind(\.pollIntervalCustom))
                }
            }
            Section {
                Toggle("Swipe (four-finger)", isOn: bind(\.fasterDesktopSwitch))
                    .help("Replace the trackpad swipe between desktops with an instant jump, where "
                          + "the slide animation is skipped. Keeps your normal swipe; needs Accessibility.")
                Toggle("Keyboard shortcut", isOn: bind(\.fasterKeyboardSwitch))
                    .help("Also make your “Move left/right a space” keyboard shortcut instant. "
                          + "Takes over whatever you've bound it to (e.g. ⌘⌥←/→) by temporarily "
                          + "disabling the system shortcut while Powerspaces runs; it's restored "
                          + "when you turn this off or quit. Needs Accessibility.")
            } header: {
                Text("Faster desktop switch")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Switch desktops instantly, with no slide animation. Needs Accessibility.")
                    Text("Changed your “Move left/right a space” shortcut? Restart Powerspaces to pick it up.")
                        .foregroundStyle(.secondary)
                    Link("Based on InstantSpaceSwitcher ↗",
                         destination: URL(string: "https://github.com/jurplel/InstantSpaceSwitcher")!)
                }
            }
            Section {
                Toggle("Show warning banners", isOn: bind(\.warningsEnabled))
                    .help("Show the ⚠︎ banner when an app is already open on another desktop.")
                if advanced {
                    WarningDurationRow(help: "How long the banner stays before it auto-dismisses.")
                        .disabled(!prefs.warningsEnabled)
                    enumPicker("Position", help: "Where on screen the banner appears.",
                               bind(\.hudPosition)) { $0.label }
                        .disabled(!prefs.warningsEnabled)
                }
            } header: {
                Text("Warnings")
            } footer: {
                Text("The “⚠︎ already open on another desktop” banner. Off hides it entirely.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: System — macOS Dock, Raycast, menu-bar / login / Accessibility, and uninstall

    private var systemTab: some View {
        Form {
            Section {
                Toggle("Hide the macOS Dock", isOn: bind(\.hideAppleDock))
                    .help("Force Apple's built-in Dock to stay hidden so the Powerspaces "
                          + "bar can stand in for it. Turn off to bring it back.")
            } header: {
                Text("macOS Dock")
            } footer: {
                Text("Keeps Apple's Dock from ever sliding into view, so only the "
                     + "Powerspaces bar shows. The Dock process keeps running, so "
                     + "Mission Control and ⌘-Tab still work. Turning this off (or "
                     + "quitting Powerspaces) brings the Dock back; it re-hides on "
                     + "the next launch while this stays on.")
            }
            Section {
                RaycastSetupRow()
            } header: {
                Text("Raycast (experimental)")
            } footer: {
                Text("Lets you search any app in Raycast and open it on the desktop you're "
                     + "on. “Install CLI” adds the powerspaces command (~/.local/bin, no admin); "
                     + "“Set Up” also imports the bundled extension. It needs the Raycast app "
                     + "and Node.js (npm), and opens Terminal once to finish.")
            }
            Section {
                AltTabSetupRow()
            } header: {
                Text("Per-desktop ⌘-Tab (AltTab)")
            } footer: {
                Text("macOS ⌘-Tab cycles windows from every desktop at once. Powerspaces uses "
                     + "AltTab (a free, open-source switcher) to scope ⌘-Tab to the current "
                     + "desktop. Install it (Homebrew if detected, else “Get AltTab”), then "
                     + "“Configure” sets AltTab to show windows from the active Space only. "
                     + "Making ⌘-Tab the trigger is a one-time manual step in AltTab's own "
                     + "settings (AltTab stores shortcuts in a format only it can write). "
                     + "AltTab is a separate app with its own "
                     + "Accessibility permission.")
            }
            Section {
                if advanced {
                    enumPicker("Menu-bar icon",
                               help: "The glyph shown in the menu bar. Invisible keeps a blank but "
                                   + "clickable item; Hidden removes the item entirely.",
                               bind(\.menuGlyph)) { $0.label }
                    if prefs.menuGlyph == .hidden {
                        Label("With no menu-bar icon you can't open Preferences from the menu bar. "
                              + "To get back here, right-click anywhere on the Powerspaces dock and "
                              + "choose “Open Preferences”.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Color.orange)
                    }
                    Toggle("Show desktop number in the menu bar", isOn: bind(\.menuBarShowsDesktopNumber))
                        .help("Show the number of the desktop you are on next to the menu-bar icon.")
                }
                LoginItemToggle()
                if advanced {
                    AccessibilityResetRow()
                }
                HStack {
                    Text("Powerspaces")
                    Spacer()
                    Button("Quit Powerspaces") { NSApp.terminate(nil) }
                }
                .help("Quit Powerspaces. If you've hidden the macOS Dock, it returns when "
                      + "Powerspaces quits.")
                HStack {
                    Text("Reset all settings")
                    Spacer()
                    Button("Reset to Defaults…") { confirmResetAll() }
                }
                .help("Reset every appearance and behavior setting to its default. Your pinned "
                      + "apps and launch rules are kept.")
            } header: {
                Text("General")
            } footer: {
                if advanced {
                    Text("If you've enabled Accessibility for Powerspaces but window actions "
                         + "still say it's missing (common after rebuilding or reinstalling the "
                         + "app), Reset clears the stale macOS permission so you can grant it fresh.")
                }
            }
            Section {
                UninstallRow()
            } header: {
                Text("Uninstall")
            } footer: {
                Text("Removes Powerspaces and the powerspaces CLI from your Mac, then quits, and "
                     + "you choose whether to keep or delete your settings. Apple's Dock and your "
                     + "space-switch shortcut are restored on quit. If you set up the Raycast "
                     + "extension, also remove “Powerspaces” from Raycast's own Extensions list, as "
                     + "it was imported in developer mode and can't be removed from here.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Strategies

    private var strategyTab: some View {
        Form {
            Section {
                Picker("New-window strategy", selection: Binding(
                    get: { strategies.effectiveDefault() },
                    set: { strategies.setDefault($0) }
                )) {
                    ForEach(SingleInstance.defaultChoices, id: \.self) { Text($0.label).tag($0) }
                }
                .help("How to make a new window for apps that don't have their own rule.")
            } header: {
                Text("Default for unknown apps")
            } footer: {
                Text("How to make a new window for apps that don't have their own rule. "
                     + "Set a per-app rule from an icon's right-click menu → "
                     + "“When open elsewhere”. Saved to ~/.config/powerspaces/config.json.")
            }
            if advanced {
                Section {
                    ForEach(SingleInstance.apps) { app in
                        Picker(app.name, selection: Binding(
                            get: { strategies.effectiveStrategy(for: app.bundleID) },
                            set: { _ = strategies.setStrategy($0, forBundleID: app.bundleID, name: app.name) }
                        )) {
                            Text("Show a warning").tag(StrategyKind.warn)
                            Text("Quit there and reopen here").tag(StrategyKind.quitReopen)
                        }
                        .help("What to do when \(app.name) is already open on another desktop.")
                    }
                } header: {
                    Text("Single-window apps open on another desktop")
                } footer: {
                    Text("These apps can't be given a second window on the desktop you're on "
                         + "because macOS doesn't allow it. Default is to show a warning. "
                         + "“Quit there and reopen here” quits the app and relaunches it here, "
                         + "which works but loses anything unsaved or playing.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A numeric setting: a preset dropdown plus a "Custom…" entry that reveals a
/// slider. In non-custom mode the value always equals a preset, so the dropdown
/// reflects it; "Custom…" keeps the current value as the slider's starting point.
private struct NumericRow: View {
    let title: String
    let help: String
    let spec: NumericSpec
    @Binding var value: Double
    @Binding var isCustom: Bool

    var body: some View {
        Picker(title, selection: selection) {
            ForEach(spec.presets.indices, id: \.self) { i in
                Text(spec.presets[i].label).tag(i)
            }
            Text("Custom…").tag(spec.presets.count)
        }
        .help(help)
        if isCustom {
            HStack(spacing: 10) {
                Slider(value: $value, in: spec.range, step: spec.step)
                // An editable field for an exact value, clamped to the slider's range.
                TextField("value", value: Binding(
                    get: { value },
                    set: { value = min(max($0, spec.range.lowerBound), spec.range.upperBound) }
                ), format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)
            }
            .help(help)
        }
    }

    /// Maps the value/isCustom pair to/from the dropdown's selected index. The
    /// custom entry is the index just past the last preset.
    private var selection: Binding<Int> {
        Binding(
            get: {
                if isCustom { return spec.presets.count }
                return spec.presets.firstIndex { abs($0.value - value) < 0.0001 } ?? spec.presets.count
            },
            set: { idx in
                if idx == spec.presets.count {
                    isCustom = true
                } else {
                    isCustom = false
                    value = spec.presets[idx].value
                }
            }
        )
    }
}

/// Warning-banner duration: presets + "Until clicked" + a custom seconds slider.
private struct WarningDurationRow: View {
    @ObservedObject var prefs = Preferences.shared
    let help: String

    var body: some View {
        Picker("Stays up for", selection: Binding(
            get: { prefs.warningMode }, set: { prefs.warningMode = $0 }
        )) {
            ForEach(WarningMode.allCases) { Text($0.label).tag($0) }
        }
        .help(help)
        if prefs.warningMode == .custom {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { prefs.warningCustomSeconds },
                                      set: { prefs.warningCustomSeconds = $0 }),
                       in: Preferences.warningCustomSpec.range,
                       step: Preferences.warningCustomSpec.step)
                TextField("seconds", value: Binding(
                    get: { prefs.warningCustomSeconds },
                    set: { prefs.warningCustomSeconds = min(max($0, Preferences.warningCustomSpec.range.lowerBound),
                                                            Preferences.warningCustomSpec.range.upperBound) }
                ), format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)
            }
            .help(help)
        }
    }
}

/// Launch-at-login toggle: a first-class preference (`launchAtLogin`) applied live
/// through `LoginItem` (the `SMAppService` wrapper). The preference is the desired
/// state; we keep it in step with the real OS registration so the toggle never shows
/// a state we couldn't apply, and surface an error (e.g. when run from a non-bundled
/// `swift run`, where there's no `.app` to register).
private struct LoginItemToggle: View {
    @ObservedObject var prefs = Preferences.shared
    @State private var error: String?

    var body: some View {
        Toggle("Launch at login", isOn: Binding(get: { prefs.launchAtLogin }, set: { setEnabled($0) }))
            .help("Start Powerspaces automatically when you log in.")
        if let error {
            Text(error).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setEnabled(_ on: Bool) {
        do {
            try LoginItem.setEnabled(on)
            prefs.launchAtLogin = on // persist the desired state once the OS accepted it
            error = nil
        } catch {
            // Couldn't change the OS registration — sync the stored preference back to
            // reality so the toggle doesn't claim a state we couldn't apply.
            prefs.launchAtLogin = LoginItem.isEnabled
            self.error = "Couldn't change this (needs a bundled .app): \(error.localizedDescription)"
        }
    }
}

/// The per-desktop Cmd-Tab row: detects the third-party AltTab app (like the npm
/// probe), links to its install, and offers a one-click "configure for Powerspaces"
/// (⌘-Tab + active-Space-only). Mirrors `RaycastSetupRow`: a live status indicator
/// plus action buttons. The manual setting is always shown so the integration
/// degrades gracefully if AltTab changes its preference format.
private struct AltTabSetupRow: View {
    @State private var probe: AltTabSetup.Probe?
    @State private var checked = false
    @State private var working = false

    private var installed: Bool { probe?.installed ?? false }
    private var hasHomebrew: Bool { probe?.hasHomebrew ?? false }

    var body: some View {
        statusLine("AltTab", ok: installed, pending: !checked,
                   text: checked ? (probe?.statusText ?? "Not installed") : "Checking…")
            .help("Whether AltTab is installed. Powerspaces uses it for the per-desktop "
                  + "⌘-Tab switcher; it's a free, open-source app you install separately.")
        HStack {
            installButton
            Spacer()
            if working { ProgressView().controlSize(.small) }
            Button("Configure AltTab") { configure() }
                .disabled(!installed || working)
                .help("Set AltTab to show only the current desktop's windows. Making ⌘-Tab "
                      + "the trigger is then a one-time step in AltTab's own settings.")
        }
        if hasHomebrew && !installed {
            Text("Homebrew detected. “Install with Homebrew” runs "
                 + "`\(AltTabSetup.homebrewInstallCommand)` in Terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text("Manual setup (or if the button can't): in AltTab ▸ Settings ▸ Controls, set "
             + "“Show windows from” to “Active Space”, and set the hold shortcut to ⌘ to "
             + "replace the macOS ⌘-Tab.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .task {
                if !checked {
                    probe = await Task.detached { AltTabSetup.probe() }.value
                    checked = true
                }
            }
    }

    /// Install affordance: one `brew install --cask alt-tab` click when Homebrew is
    /// present (simplest), otherwise a link to AltTab's download page. While the probe
    /// is still running we default to the website link.
    @ViewBuilder
    private var installButton: some View {
        if hasHomebrew {
            Button("Install with Homebrew") { installWithHomebrew() }
                .help("Run “\(AltTabSetup.homebrewInstallCommand)” in a Terminal window.")
        } else {
            Button("Get AltTab") { AltTabSetup.openDownloadPage() }
                .help("Open alt-tab.app to download and install AltTab (free, open source).")
        }
    }

    /// Kick off `brew install --cask alt-tab` in Terminal; explain + fall back to the
    /// website if it couldn't even start.
    private func installWithHomebrew() {
        do {
            try AltTabSetup.installViaHomebrew()
        } catch {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Couldn't start the Homebrew install"
            a.informativeText = error.localizedDescription
                + "\n\nYou can install AltTab manually from https://alt-tab.app"
            a.runModal()
        }
    }

    /// Confirm what we'll change in AltTab, do it (quit → write → relaunch), then
    /// report success — or, on any failure, fall back to the manual instructions.
    private func configure() {
        let alert = NSAlert()
        alert.messageText = "Configure AltTab for Powerspaces?"
        alert.informativeText = """
            This sets AltTab to show only the windows on the desktop you're on (the active \
            Space). AltTab quits and relaunches to apply it.

            To make ⌘-Tab open it (replacing the macOS app switcher), there's one manual \
            step AltTab only lets you set in its own settings: AltTab ▸ Settings ▸ Controls \
            → set the hold shortcut to ⌘. Powerspaces can't set that for you reliably, since it's \
            stored in a format only AltTab can write.
            """
        alert.addButton(withTitle: "Configure")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        working = true
        Task {
            do {
                try await AltTabSetup.configure()
                working = false
                probe = AltTabSetup.probe()
                let ok = NSAlert()
                ok.messageText = "AltTab now shows the current desktop only"
                ok.informativeText = """
                    Last step to replace ⌘-Tab, do it once in AltTab:
                    AltTab ▸ Settings ▸ Controls → set the hold shortcut to ⌘.

                    AltTab disables the system ⌘-Tab for you when you do. (Leave it on its \
                    default ⌥ if you'd rather keep the macOS ⌘-Tab as-is.)
                    """
                ok.addButton(withTitle: "Open AltTab")
                ok.addButton(withTitle: "Done")
                if ok.runModal() == .alertFirstButtonReturn { AltTabSetup.openApp() }
            } catch {
                working = false
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = "Couldn't fully configure AltTab"
                a.informativeText = error.localizedDescription
                    + "\n\nYou can set it manually in AltTab ▸ Settings ▸ Controls: "
                    + "“Show windows from” → “Active Space”, and the hold shortcut → ⌘."
                a.runModal()
            }
        }
    }
}

/// The (experimental) Raycast-extension setup row: shows whether the CLI and
/// Node.js (npm) are present, links to the Node.js download, and runs the one-time
/// setup (CLI install + `npm install` + import) in a Terminal window. Mirrors
/// `AccessibilityResetRow`: live status indicators plus action buttons.
private struct RaycastSetupRow: View {
    @State private var installedLocation = RaycastSetup.installedLocation
    @State private var npm: String?
    @State private var npmChecked = false

    var body: some View {
        statusLine("powerspaces CLI", ok: installedLocation != nil, text: cliStatusText)
            .help("Whether the powerspaces binary the extension calls is installed. "
                  + "“Install CLI” puts it in ~/.local/bin with no admin needed.")
        statusLine("Node.js (npm)", ok: npm != nil, pending: !npmChecked,
                   text: npmChecked ? (npm.map { "Found (v\($0))" } ?? "Not detected") : "Checking…")
            .help("Node.js provides npm, which builds and imports the Raycast extension.")
        HStack {
            Button("Get Node.js") { RaycastSetup.openNodeDownload() }
                .help("Open nodejs.org to download Node.js (it includes npm).")
            Button("Install CLI") { installCLI() }
                .help("Install the powerspaces CLI to ~/.local/bin. No admin, no Terminal.")
            Spacer()
            Button("Set Up Raycast Extension…") { setUp() }
                .help("Install the CLI and import the Raycast extension (opens Terminal once).")
        }
        Button("Install system-wide…") { installSystemWide() }
            .buttonStyle(.link)
            .font(.caption)
            .help("Optional: also install to /usr/local/bin so `powerspaces` works in every "
                  + "shell without editing PATH. This one asks for an admin password.")
            .task {
                installedLocation = RaycastSetup.installedLocation
                if !npmChecked {
                    npm = await Task.detached { RaycastSetup.npmVersion() }.value
                    npmChecked = true
                }
            }
    }

    private var cliStatusText: String {
        switch installedLocation {
        case .userLocal: return "Installed (~/.local/bin)"
        case .systemWide: return "Installed (/usr/local/bin)"
        case nil: return "Not installed"
        }
    }


    /// Install just the CLI to the per-user location — no admin, no Terminal.
    private func installCLI() {
        do {
            let dest = try RaycastSetup.installCLIToUserLocal()
            installedLocation = RaycastSetup.installedLocation
            let ok = NSAlert()
            ok.messageText = "powerspaces CLI installed"
            ok.informativeText = """
                Installed to \(dest.path). No admin needed. The Raycast extension finds it automatically.

                To also run `powerspaces` in a terminal, add this to ~/.zshrc:
                    export PATH="$HOME/.local/bin:$PATH"
                """
            ok.runModal()
        } catch {
            presentError("Couldn't install the CLI", error)
        }
    }

    /// Optional system-wide install (every shell's PATH) — opens Terminal for sudo.
    private func installSystemWide() {
        do { try RaycastSetup.installCLISystemWide() }
        catch { presentError("Couldn't start the install", error) }
    }

    /// Confirm what setup will do, run it, and surface any "not bundled" error.
    private func setUp() {
        let alert = NSAlert()
        alert.messageText = "Set up the Raycast extension?"
        var info = """
            This will:
            • Install the powerspaces CLI to \(RaycastSetup.defaultCLILocation.path) (no admin needed).
            • Open Terminal to run “npm install” and import the extension into Raycast.

            The Terminal window runs the steps automatically and stops on its own. When it shows the “DONE, safe to close” box, you can close it. No Terminal is needed after that.
            """
        if npmChecked && npm == nil {
            info = "Node.js (npm) wasn't detected. It's required. If you haven't installed it, "
                + "click “Get Node.js” first.\n\n" + info
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try RaycastSetup.runSetup()
            installedLocation = RaycastSetup.installedLocation
        } catch {
            presentError("Couldn't start setup", error)
        }
    }

    private func presentError(_ title: String, _ error: Error) {
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = title
        a.informativeText = error.localizedDescription
        a.runModal()
    }
}

/// Shows the live Accessibility-trust state and offers the stale-permission fix:
/// reset the macOS grant and relaunch so it can be re-approved cleanly. Aimed at
/// the "I enabled it but it still says missing" case that frequent rebuilds cause.
private struct AccessibilityResetRow: View {
    @State private var trusted = AccessibilityPermission.isTrusted

    var body: some View {
        HStack {
            Text("Accessibility")
            Spacer()
            Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(trusted ? Color.green : Color.orange)
            Text(trusted ? "Granted" : "Not granted")
                .foregroundStyle(.secondary)
        }
        .help("Whether macOS currently lets Powerspaces control windows. Needed to "
              + "close or minimize windows and read window titles.")
        HStack {
            Button("Open Settings…") { AccessibilityPermission.openSettings() }
                .help("Open System Settings ▸ Privacy & Security ▸ Accessibility.")
            Spacer()
            Button("Reset Permission…") { AccessibilityPermission.confirmResetAndRelaunch() }
                .help("Clear Powerspaces' Accessibility permission and relaunch, so a stale "
                      + "grant left by an earlier build can be re-approved.")
        }
    }
}

/// The destructive "uninstall" action: a single button that confirms, lists exactly
/// what will be deleted, then hands off to `Uninstaller` (revert system state, delete
/// all artifacts, quit). Mirrors `AccessibilityResetRow`'s confirm-then-act pattern,
/// but styled as a destructive action since it can't be undone.
private struct UninstallRow: View {
    var body: some View {
        HStack {
            Text("Remove Powerspaces from this Mac")
            Spacer()
            Button("Uninstall…", role: .destructive) { confirmUninstall() }
                .help("Remove Powerspaces, the CLI, and (optionally) your settings, then quit.")
        }
    }

    /// Confirm with the user — spelling out what's removed, and offering to keep or
    /// delete the settings — before doing anything irreversible. The three-way choice
    /// (Keep / Delete / Cancel) doubles as the "are you sure?" check.
    private func confirmUninstall() {
        var bullets: [String] = []
        if let app = Uninstaller.appBundle { bullets.append("  •  Powerspaces.app: \(app.path)") }
        for cli in Uninstaller.presentCLIPaths { bullets.append("  •  powerspaces CLI: \(cli)") }
        let removed = bullets.isEmpty ? "" : "\n\nRemoved from your Mac:\n" + bullets.joined(separator: "\n")

        var info = """
            This uninstalls Powerspaces and quits.\(removed)

            Quitting restores Apple's Dock and your “Move left/right a space” shortcut, and \
            removes the login item and the Accessibility permission.

            Your settings (preferences, pinned apps, and per-app rules) live at \
            \(PowerspacesPaths.configDir.path):
              •  Keep My Settings: leaves them there, so reinstalling Powerspaces restores \
            everything exactly as it is now.
              •  Delete Everything: also erases that folder. ⚠︎ Your preferences are deleted, \
            and this can't be undone.
            """
        // The CLI / app can need admin either way; check the full-delete case so the
        // password note appears whenever it could be relevant.
        if Uninstaller.needsAdmin(keepPreferences: false) {
            info += "\n\nSome items live in a system location, so macOS will ask for your "
                + "password to remove them."
        }
        info += "\n\nIf you set up the Raycast extension, also remove “Powerspaces” from "
            + "Raycast's Extensions list, as it was imported in developer mode and can't be "
            + "removed from here."

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Uninstall Powerspaces?"
        alert.informativeText = info
        // Cancel is added first, so it's the rightmost button and the Return/Escape
        // default — a stray Return can't uninstall. The two actions sit to its left.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Keep My Settings")
        alert.addButton(withTitle: "Delete Everything")
        alert.buttons.last?.hasDestructiveAction = true
        switch alert.runModal() {
        case .alertSecondButtonReturn: Uninstaller.run(keepPreferences: true)
        case .alertThirdButtonReturn: Uninstaller.run(keepPreferences: false)
        default: break // Cancel, or the window was dismissed — do nothing.
        }
    }
}
