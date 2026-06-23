// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Combine
import SpaceKit

extension Notification.Name {
    /// Posted whenever any UI preference changes, so the live dock / HUD / timer
    /// can re-apply. Strategy (config.json) changes use their own path.
    static let preferencesDidChange = Notification.Name("powerspaces.preferencesDidChange")
}

// MARK: - Preferences store

/// Single source of truth for all UI preferences, backed by a JSON file at a
/// *fixed path* (`~/.config/powerspaces/preferences.json`) — see
/// `JSONPreferencesStore`. We use a file rather than `UserDefaults` so settings
/// live next to the strategy `config.json` and survive app reinstalls and the
/// unbundled→bundled identity switch (UserDefaults is keyed by bundle id, so it
/// silently resets when that identity changes).
/// Numeric settings are stored as a `Double` plus a `…Custom` flag (custom = the
/// slider is showing). Setting any property persists it and posts
/// `.preferencesDidChange` so the live dock/HUD/timer re-apply.
final class Preferences: ObservableObject {
    // The singleton is touched only from the main thread (the live dock, HUD, menu
    // and the SwiftUI preferences UI), so pin it to the main actor. That makes the
    // shared mutable state concurrency-safe without forcing `@MainActor` onto the
    // whole type (which would clash with the nonisolated `ObservableObject` witness).
    @MainActor static let shared = Preferences()

    // No @Published members (everything is computed over the store); drive
    // `objectWillChange` by hand from the setters.
    let objectWillChange = ObservableObjectPublisher()

    /// Where UI preferences live on disk — a fixed path (like the strategy
    /// `config.json`) so they don't depend on the app's bundle identity.
    static var preferencesURL: URL { PowerspacesPaths.preferencesFile }

    private let store = JSONPreferencesStore(url: Preferences.preferencesURL)

    /// Per-desktop dock color/opacity overrides live in their own file
    /// (`dock-colors.json`), keyed by Space UUID — not the flat preferences store,
    /// which only holds scalar settings. See `DockTintStore`.
    private let dockTints = DockTintStore(url: PowerspacesPaths.dockColorsFile)

    // MARK: Numeric specs (presets + slider bounds), shared with the UI

    static let hoverScaleSpec = NumericSpec(
        presets: [("Off (1.0×)", 1.0), ("Subtle (1.1×)", 1.10), ("Default (1.18×)", 1.18), ("Big (1.3×)", 1.30)],
        range: 1.0...2.0, step: 0.01, format: { String(format: "%.2f×", $0) })
    static let hoverHighlightSpec = NumericSpec(
        presets: [("None", 0.0), ("Default (16%)", 0.16), ("Stronger (28%)", 0.28)],
        range: 0...0.6, step: 0.01, format: { "\(Int(($0 * 100).rounded()))%" })
    static let hoverAnimationSpec = NumericSpec(
        presets: [("Instant", 0.0), ("Default (0.12s)", 0.12), ("Slow (0.2s)", 0.2)],
        range: 0...0.6, step: 0.01, format: { String(format: "%.2fs", $0) })
    static let iconSizeSpec = NumericSpec(
        presets: [("Small (36)", 36), ("Medium (48)", 48), ("Large (64)", 64)],
        range: 24...120, step: 1, format: { "\(Int($0)) px" })
    static let iconSpacingSpec = NumericSpec(
        presets: [("None (0)", 0), ("Tight (6)", 6), ("Default (10)", 10), ("Roomy (16)", 16)],
        range: 0...40, step: 1, format: { "\(Int($0)) px" })
    /// The bar's thickness (its "height" for a bottom/top bar). Applied as a
    /// *minimum*: the bar never shrinks below the icon size itself, but can be made
    /// as tall as the user likes. Any value at or below the icon size hugs the
    /// icons exactly (no padding) — that's what the "Snug" preset and the slider's
    /// 24 floor (the smallest icon size) are for.
    static let dockHeightSpec = NumericSpec(
        presets: [("Snug (fits icons)", 24), ("Default (64)", 64), ("Tall (88)", 88), ("Taller (120)", 120)],
        range: 24...600, step: 1, format: { "\(Int($0)) px" })
    static let edgeGapSpec = NumericSpec(
        presets: [("Flush (0)", 0), ("Default (12)", 12), ("Far (24)", 24)],
        range: 0...100, step: 1, format: { "\(Int($0)) px" })
    static let cornerRadiusSpec = NumericSpec(
        presets: [("Square (4)", 4), ("Rounded (16)", 16), ("Pill (28)", 28)],
        range: 0...40, step: 1, format: { "\(Int($0)) px" })
    /// Thickness (points) of the outline drawn around the whole dock bar. "None"
    /// (0) leaves the bar borderless, which is the default.
    static let dockOutlineWidthSpec = NumericSpec(
        presets: [("None (0)", 0), ("Thin (1)", 1), ("Default (2)", 2), ("Thick (3)", 3)],
        range: 0...8, step: 0.5, format: { String(format: "%g px", $0) })
    static let dimLevelSpec = NumericSpec(
        presets: [("Off (100%)", 1.0), ("Default (55%)", 0.55), ("Faint (35%)", 0.35)],
        range: 0.1...1.0, step: 0.05, format: { "\(Int(($0 * 100).rounded()))%" })
    /// Gap (points) between the running-app box outline and the icon: 0 hugs the
    /// icon, larger values float the outline out from it.
    static let boxGapSpec = NumericSpec(
        presets: [("Snug (0)", 0), ("Default (3)", 3), ("Roomy (6)", 6)],
        range: 0...20, step: 1, format: { "\(Int($0)) px" })
    /// Thickness (points) of the running-app box outline.
    static let boxOutlineWidthSpec = NumericSpec(
        presets: [("Thin (1)", 1), ("Default (2)", 2), ("Thick (3)", 3)],
        range: 0...8, step: 0.5, format: { String(format: "%g px", $0) })
    /// How long each beat of the icon join/leave animation runs (the slot
    /// open/close and the disappear/appear share it). "Instant" (0) skips it.
    static let iconAnimationSpeedSpec = NumericSpec(
        presets: [("Instant", 0.0), ("Fast (0.12s)", 0.12), ("Default (0.18s)", 0.18), ("Slow (0.3s)", 0.3)],
        range: 0...0.8, step: 0.01, format: { String(format: "%.2fs", $0) })
    static let pollIntervalSpec = NumericSpec(
        presets: [("Immediate (0.1s)", 0.1), ("Snappy (1s)", 1), ("Default (2s)", 2), ("Easy (5s)", 5)],
        range: 0.1...10, step: 0.1, format: { String(format: "%gs", $0) })
    static let warningCustomSpec = NumericSpec(
        presets: [], range: 1...60, step: 1, format: { "\(Int($0))s" })
    static let windowLabelWidthSpec = NumericSpec(
        presets: [("Compact (140)", 140), ("Default (180)", 180), ("Wide (240)", 240)],
        range: 80...400, step: 1, format: { "\(Int($0)) px" })
    /// How long the pointer must be away from the bar before it auto-hides.
    /// "Instant" (0) hides as soon as the pointer leaves.
    static let autoHideDelaySpec = NumericSpec(
        presets: [("Instant (0s)", 0.0), ("Short (0.5s)", 0.5), ("Default (1s)", 1.0), ("Long (2s)", 2.0)],
        range: 0...5, step: 0.1, format: { String(format: "%.1fs", $0) })
    /// How long the hide animation runs. "Instant" (0) snaps the bar away.
    static let autoHideSpeedSpec = NumericSpec(
        presets: [("Instant", 0.0), ("Fast (0.15s)", 0.15), ("Default (0.25s)", 0.25), ("Slow (0.4s)", 0.4)],
        range: 0...1, step: 0.01, format: { String(format: "%.2fs", $0) })
    /// How long the reveal animation runs. "Instant" (0) shows the bar at once.
    static let autoShowSpeedSpec = NumericSpec(
        presets: [("Instant", 0.0), ("Fast (0.12s)", 0.12), ("Default (0.2s)", 0.2), ("Slow (0.35s)", 0.35)],
        range: 0...1, step: 0.01, format: { String(format: "%.2fs", $0) })

    private enum K {
        static let hoverEnabled = "hoverEnabled"
        // These numeric settings used to be stored as enum *strings* (e.g.
        // "medium"). They're now Doubles, so they use fresh "…Number" keys —
        // otherwise `double(forKey:)` reads the old string as 0 and shadows the
        // registered default. Old keys are left orphaned; the defaults below win.
        static let hoverScale = "hoverScaleNumber"
        static let hoverHighlight = "hoverHighlightNumber"
        static let hoverAnimation = "hoverAnimationNumber"
        static let iconSize = "iconSizeNumber"
        static let iconSpacing = "iconSpacingNumber"
        static let dockHeight = "dockHeightNumber"
        static let edgeGap = "edgeGapNumber"
        static let cornerRadius = "barCornerRadiusNumber"
        static let dockOutlineWidth = "dockOutlineWidthNumber"
        static let dockOutlineColor = "dockOutlineColor"
        static let dockTintEnabled = "dockTintEnabled"
        static let dockTintColor = "dockTintColor"
        static let dimLevel = "dimLevelNumber"
        static let runningIndicator = "runningIndicator"
        static let boxGap = "boxGapNumber"
        static let boxOutlineWidth = "boxOutlineWidthNumber"
        static let boxColor = "boxHighlightColor"
        static let boxOutlineColor = "boxOutlineColor"
        // Storage keys kept as-is from when the animation was removal-only; they
        // now back the shared (add + remove) settings.
        static let animateOnRemove = "removalAnimationEnabled"
        static let animateOnAdd = "additionAnimationEnabled"
        static let iconAnimationStyle = "removalAnimationStyle"
        static let iconAnimationSpeed = "removalAnimationNumber"
        static let pollInterval = "pollInterval" // already a Double before — no collision
        static let warningCustom = "warningCustomSeconds"
        // Non-numeric
        static let barPosition = "barPosition"
        static let fullscreenDockBehavior = "fullscreenDockBehavior"
        // Which screens show a dock: "allScreens" or "selectedScreens" (then
        // dockScreenIDs lists the chosen display UUIDs).
        static let dockScreensMode = "dockScreensMode"
        static let dockScreenIDs = "dockScreenIDs"
        static let barMaterial = "barMaterial"
        static let warningsEnabled = "warningsEnabled"
        static let warningMode = "warningMode"
        static let hudPosition = "hudPosition"
        static let forceNewModifier = "forceNewModifier"
        static let middleClickAction = "middleClickAction"
        static let quitOnLastWindowClose = "experimentalQuitOnLastWindowClose"
        static let menuGlyph = "menuGlyph"
        static let menuBarShowsDesktopNumber = "menuBarShowsDesktopNumber"
        static let launchAtLogin = "launchAtLogin"
        static let hideAppleDock = "hideAppleDock"
        static let fasterDesktopSwitch = "fasterDesktopSwitch"
        static let fasterKeyboardSwitch = "fasterKeyboardSwitch"
        // Internal bookkeeping (not user-facing): set while we've disabled the
        // system space-switch hotkeys for the keyboard override, so the next launch
        // can restore them if a crash skipped the normal teardown.
        static let spaceHotkeysDisabledByUs = "spaceHotkeysDisabledByUs"
        // Internal backup of the user's com.apple.dock autohide value, captured the
        // first time we hide Apple's Dock so re-enabling restores exactly that.
        static let appleDockAutohideBackup = "appleDockAutohideBackup"
        static let appLauncherEnabled = "appLauncherEnabled"
        static let launcherHotkey = "launcherHotkey"
        static let desktopIndicatorEnabled = "desktopIndicatorEnabled"
        static let desktopIndicatorPosition = "desktopIndicatorPosition"
        static let launcherIconColor = "launcherIconColor"
        static let launcherOutlineColor = "launcherOutlineColor"
        static let launcherHighlightColor = "launcherHighlightColor"
        static let showIconPerWindow = "showIconPerWindow"
        static let showWindowLabels = "showWindowLabels"
        // Whether ⌘-hidden apps' windows, and running apps with no windows here,
        // still show in the dock. Both default on (show), matching macOS's own Dock.
        static let showHiddenWindows = "showHiddenWindows"
        static let showWindowlessApps = "showWindowlessApps"
        static let windowLabelScope = "windowLabelScope"
        static let windowLabelWidth = "windowLabelWidthNumber"
        static let windowLabelColor = "windowLabelColor"
        static let autoHideEnabled = "autoHideEnabled"
        static let autoHideAnimation = "autoHideAnimation"
        static let autoHideDelay = "autoHideDelayNumber"
        static let autoHideSpeed = "autoHideSpeedNumber"
        static let autoShowSpeed = "autoShowSpeedNumber"
        // Preferences-window view state (Basic vs Advanced); not a live dock setting.
        static let detailLevel = "detailLevel"
        // Internal: set once the first-run welcome window has been shown.
        static let hasSeenWelcome = "hasSeenWelcome"
        // Suffix for the per-number "custom slider showing" flag.
        static func custom(_ key: String) -> String { key + "Custom" }
    }

    private init() {
        store.register(defaults: [
            // Defaults below mirror the project's chosen default preferences,
            // with one deliberate
            // exception: the "Faster desktop switch" toggles (swipe + keyboard) ship
            // OFF, even though that file has them on. Three settings sit on freeform
            // (non-preset) values — icon size 39, dock height 45, box outline 0.5 — so
            // each one's `…Custom` flag is registered true too, which shows the slider
            // at that exact value instead of an empty "Custom…" dropdown.
            K.hoverEnabled: true,
            K.hoverScale: Preferences.hoverScaleSpec.presetValue("Subtle (1.1×)"),
            K.hoverHighlight: Preferences.hoverHighlightSpec.presetValue("Default (16%)"),
            K.hoverAnimation: Preferences.hoverAnimationSpec.presetValue("Default (0.12s)"),
            K.iconSize: 39,
            K.custom(K.iconSize): true,
            K.iconSpacing: Preferences.iconSpacingSpec.presetValue("Tight (6)"),
            K.dockHeight: 45,
            K.custom(K.dockHeight): true,
            K.edgeGap: Preferences.edgeGapSpec.presetValue("Flush (0)"),
            K.cornerRadius: Preferences.cornerRadiusSpec.presetValue("Rounded (16)"),
            K.dockOutlineWidth: Preferences.dockOutlineWidthSpec.presetValue("None (0)"),
            K.dockTintEnabled: false,
            K.dimLevel: Preferences.dimLevelSpec.presetValue("Default (55%)"),
            K.runningIndicator: RunningIndicator.boxed.rawValue,
            K.boxGap: Preferences.boxGapSpec.presetValue("Snug (0)"),
            K.boxOutlineWidth: 0.5,
            K.custom(K.boxOutlineWidth): true,
            K.animateOnRemove: true,
            K.animateOnAdd: true,
            K.iconAnimationStyle: IconAnimationStyle.slideOff.rawValue,
            K.iconAnimationSpeed: Preferences.iconAnimationSpeedSpec.presetValue("Default (0.18s)"),
            K.pollInterval: Preferences.pollIntervalSpec.presetValue("Immediate (0.1s)"),
            K.warningCustom: 4.0,
            K.barPosition: BarPosition.bottom.rawValue,
            K.fullscreenDockBehavior: FullscreenDockBehavior.autoHide.rawValue,
            // Default to a dock on every screen, so a multi-display setup gets the
            // per-screen behavior out of the box (a single-display Mac is
            // unaffected — that's just one dock, exactly as before).
            K.dockScreensMode: DockScreensMode.allScreens.rawValue,
            K.barMaterial: BarMaterial.hud.rawValue,
            K.warningsEnabled: true,
            K.warningMode: WarningMode.normal.rawValue,
            K.hudPosition: HUDPosition.top.rawValue,
            K.forceNewModifier: ForceNewModifier.shiftOrOption.rawValue,
            K.middleClickAction: MiddleClickAction.newWindow.rawValue,
            K.quitOnLastWindowClose: true,
            K.menuGlyph: MenuGlyph.powerWindow.rawValue,
            K.menuBarShowsDesktopNumber: false,
            K.launchAtLogin: true,
            K.hideAppleDock: true,
            K.fasterDesktopSwitch: false,
            K.fasterKeyboardSwitch: false,
            K.appLauncherEnabled: true,
            K.launcherHotkey: LauncherHotkey.off.rawValue,
            K.desktopIndicatorEnabled: false,
            K.desktopIndicatorPosition: DesktopIndicatorPosition.dockCenter.rawValue,
            K.showIconPerWindow: false,
            K.showWindowLabels: true,
            K.showHiddenWindows: true,
            K.showWindowlessApps: true,
            K.windowLabelScope: WindowLabelScope.multipleWindows.rawValue,
            K.windowLabelWidth: Preferences.windowLabelWidthSpec.presetValue("Compact (140)"),
            K.autoHideEnabled: false,
            K.autoHideAnimation: AutoHideAnimation.slideFade.rawValue,
            K.autoHideDelay: Preferences.autoHideDelaySpec.presetValue("Short (0.5s)"),
            K.autoHideSpeed: Preferences.autoHideSpeedSpec.presetValue("Default (0.25s)"),
            K.autoShowSpeed: Preferences.autoShowSpeedSpec.presetValue("Instant"),
            K.detailLevel: DetailLevel.advanced.rawValue,
            K.hasSeenWelcome: false,
        ])
    }

    // MARK: Generic accessors

    private func dbl(_ key: String) -> Double { store.double(key) }
    private func setDbl(_ v: Double, _ key: String) {
        objectWillChange.send(); store.set(v, key); changed()
    }
    private func bln(_ key: String) -> Bool { store.bool(key) }
    private func setBln(_ v: Bool, _ key: String) {
        objectWillChange.send(); store.set(v, key); changed()
    }
    private func raw<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
        guard let s = store.string(key), let v = T(rawValue: s) else { return fallback }
        return v
    }
    private func setRaw<T: RawRepresentable>(_ value: T, _ key: String) where T.RawValue == String {
        objectWillChange.send(); store.set(value.rawValue, key); changed()
    }
    /// Reads a color stored as sRGB components `"r,g,b,a"` (human-readable in the
    /// JSON), falling back to `fallback` when unset or malformed.
    private func color(_ key: String, default fallback: NSColor) -> NSColor {
        guard let s = store.string(key) else { return fallback }
        let p = s.split(separator: ",").compactMap { Double($0) }
        guard p.count == 4 else { return fallback }
        return NSColor(srgbRed: p[0], green: p[1], blue: p[2], alpha: p[3])
    }
    private func setColor(_ value: NSColor, _ key: String) {
        objectWillChange.send()
        let c = value.usingColorSpace(.sRGB) ?? value
        store.set("\(c.redComponent),\(c.greenComponent),\(c.blueComponent),\(c.alphaComponent)", key)
        changed()
    }

    // MARK: Numeric properties (value + "custom slider showing" flag)

    var hoverScale: Double { get { dbl(K.hoverScale) } set { setDbl(newValue, K.hoverScale) } }
    var hoverScaleCustom: Bool { get { bln(K.custom(K.hoverScale)) } set { setBln(newValue, K.custom(K.hoverScale)) } }
    var hoverHighlight: Double { get { dbl(K.hoverHighlight) } set { setDbl(newValue, K.hoverHighlight) } }
    var hoverHighlightCustom: Bool { get { bln(K.custom(K.hoverHighlight)) } set { setBln(newValue, K.custom(K.hoverHighlight)) } }
    var hoverAnimation: Double { get { dbl(K.hoverAnimation) } set { setDbl(newValue, K.hoverAnimation) } }
    var hoverAnimationCustom: Bool { get { bln(K.custom(K.hoverAnimation)) } set { setBln(newValue, K.custom(K.hoverAnimation)) } }
    var iconSize: Double { get { dbl(K.iconSize) } set { setDbl(newValue, K.iconSize) } }
    var iconSizeCustom: Bool { get { bln(K.custom(K.iconSize)) } set { setBln(newValue, K.custom(K.iconSize)) } }
    var iconSpacing: Double { get { dbl(K.iconSpacing) } set { setDbl(newValue, K.iconSpacing) } }
    var iconSpacingCustom: Bool { get { bln(K.custom(K.iconSpacing)) } set { setBln(newValue, K.custom(K.iconSpacing)) } }
    var dockHeight: Double { get { dbl(K.dockHeight) } set { setDbl(newValue, K.dockHeight) } }
    var dockHeightCustom: Bool { get { bln(K.custom(K.dockHeight)) } set { setBln(newValue, K.custom(K.dockHeight)) } }
    var edgeGap: Double { get { dbl(K.edgeGap) } set { setDbl(newValue, K.edgeGap) } }
    var edgeGapCustom: Bool { get { bln(K.custom(K.edgeGap)) } set { setBln(newValue, K.custom(K.edgeGap)) } }
    var cornerRadius: Double { get { dbl(K.cornerRadius) } set { setDbl(newValue, K.cornerRadius) } }
    var cornerRadiusCustom: Bool { get { bln(K.custom(K.cornerRadius)) } set { setBln(newValue, K.custom(K.cornerRadius)) } }
    /// Thickness (points) of the outline drawn around the whole dock bar (0 = off).
    var dockOutlineWidth: Double { get { dbl(K.dockOutlineWidth) } set { setDbl(newValue, K.dockOutlineWidth) } }
    var dockOutlineWidthCustom: Bool { get { bln(K.custom(K.dockOutlineWidth)) } set { setBln(newValue, K.custom(K.dockOutlineWidth)) } }
    var dimLevel: Double { get { dbl(K.dimLevel) } set { setDbl(newValue, K.dimLevel) } }
    var dimLevelCustom: Bool { get { bln(K.custom(K.dimLevel)) } set { setBln(newValue, K.custom(K.dimLevel)) } }
    /// Gap (points) between a running app's box outline and its icon (boxed style).
    var boxGap: Double { get { dbl(K.boxGap) } set { setDbl(newValue, K.boxGap) } }
    var boxGapCustom: Bool { get { bln(K.custom(K.boxGap)) } set { setBln(newValue, K.custom(K.boxGap)) } }
    /// Thickness (points) of the running-app box outline (boxed style).
    var boxOutlineWidth: Double { get { dbl(K.boxOutlineWidth) } set { setDbl(newValue, K.boxOutlineWidth) } }
    var boxOutlineWidthCustom: Bool { get { bln(K.custom(K.boxOutlineWidth)) } set { setBln(newValue, K.custom(K.boxOutlineWidth)) } }
    /// Duration (seconds) of each beat of the icon join/leave animation; 0 = instant.
    var iconAnimationSpeed: Double { get { dbl(K.iconAnimationSpeed) } set { setDbl(newValue, K.iconAnimationSpeed) } }
    var iconAnimationSpeedCustom: Bool { get { bln(K.custom(K.iconAnimationSpeed)) } set { setBln(newValue, K.custom(K.iconAnimationSpeed)) } }
    var pollInterval: Double { get { dbl(K.pollInterval) } set { setDbl(newValue, K.pollInterval) } }
    var pollIntervalCustom: Bool { get { bln(K.custom(K.pollInterval)) } set { setBln(newValue, K.custom(K.pollInterval)) } }
    var warningCustomSeconds: Double { get { dbl(K.warningCustom) } set { setDbl(newValue, K.warningCustom) } }

    // MARK: Non-numeric properties

    var hoverEnabled: Bool { get { bln(K.hoverEnabled) } set { setBln(newValue, K.hoverEnabled) } }
    var warningsEnabled: Bool { get { bln(K.warningsEnabled) } set { setBln(newValue, K.warningsEnabled) } }
    var barPosition: BarPosition { get { raw(K.barPosition, .bottom) } set { setRaw(newValue, K.barPosition) } }
    /// How the per-desktop dock behaves on a screen showing a full-screen app
    /// (hide / auto-hide / show). Defaults to auto-hide.
    var fullscreenDockBehavior: FullscreenDockBehavior { get { raw(K.fullscreenDockBehavior, .autoHide) } set { setRaw(newValue, K.fullscreenDockBehavior) } }
    /// Which screens show a dock (every screen, or only the chosen ones).
    var dockScreensMode: DockScreensMode {
        get { raw(K.dockScreensMode, .allScreens) } set { setRaw(newValue, K.dockScreensMode) }
    }
    /// The display UUIDs that should show a dock when `dockScreensMode` is
    /// `.selectedScreens`. Ignored in `.allScreens` mode.
    var dockScreenIDs: [String] {
        get { store.stringArray(K.dockScreenIDs) ?? [] }
        set { objectWillChange.send(); store.set(newValue, K.dockScreenIDs); changed() }
    }
    /// Whether the display with this UUID should show a dock under the current
    /// settings: always in `.allScreens`, else only if the user selected it.
    func showsDockOnDisplay(_ displayUUID: String) -> Bool {
        switch dockScreensMode {
        case .allScreens: return true
        case .selectedScreens: return dockScreenIDs.contains(displayUUID)
        }
    }
    var barMaterial: BarMaterial { get { raw(K.barMaterial, .hud) } set { setRaw(newValue, K.barMaterial) } }
    var warningMode: WarningMode { get { raw(K.warningMode, .normal) } set { setRaw(newValue, K.warningMode) } }
    var hudPosition: HUDPosition { get { raw(K.hudPosition, .top) } set { setRaw(newValue, K.hudPosition) } }
    var forceNewModifier: ForceNewModifier { get { raw(K.forceNewModifier, .shiftOrOption) } set { setRaw(newValue, K.forceNewModifier) } }
    /// What a middle-click on a dock icon does (default: open a new window).
    var middleClickAction: MiddleClickAction { get { raw(K.middleClickAction, .newWindow) } set { setRaw(newValue, K.middleClickAction) } }
    /// **Experimental — off by default.** Close-to-quit: when you close an app's
    /// *last* window, quit that app instance instead of leaving it running with no
    /// windows. Stops the background-instance pile-up (summoning an Electron app like
    /// Claude to many desktops otherwise leaves a fresh copy behind each time).
    /// Per-instance and debounced by a refresh tick (so a close→reopen swap isn't
    /// quit mid-flight), and it only acts on regular Dock-showing apps, never on
    /// Powerspaces. Opt-in because it overrides an app's own "keep running window-less"
    /// behaviour and could discard unsaved work. Acted on by `AppDelegate.refresh`.
    var quitOnLastWindowClose: Bool { get { bln(K.quitOnLastWindowClose) } set { setBln(newValue, K.quitOnLastWindowClose) } }
    var menuGlyph: MenuGlyph { get { raw(K.menuGlyph, .powerWindow) } set { setRaw(newValue, K.menuGlyph) } }
    /// Show the current desktop's number next to the menu-bar glyph. Off by default.
    var menuBarShowsDesktopNumber: Bool { get { bln(K.menuBarShowsDesktopNumber) } set { setBln(newValue, K.menuBarShowsDesktopNumber) } }
    /// Start Powerspaces automatically at login. The *desired* state, mirrored into
    /// the OS login-item registration (the real source of truth) by `LoginItem` — the
    /// toggle applies it live, and `AppDelegate.applyLoginItem` re-asserts it at startup
    /// (a reinstall clears the per-bundle registration). Off by default.
    var launchAtLogin: Bool { get { bln(K.launchAtLogin) } set { setBln(newValue, K.launchAtLogin) } }
    /// Master switch for hiding Apple's built-in Dock so the Powerspaces bar stands
    /// in for it. Toggling this is acted on by `AppleDockController` (driven from
    /// `AppDelegate`), which forces the Dock to stay auto-hidden / restores it.
    var hideAppleDock: Bool { get { bln(K.hideAppleDock) } set { setBln(newValue, K.hideAppleDock) } }
    /// "Faster desktop switch": intercept the trackpad space-switch swipe and jump
    /// instantly, skipping macOS's slide animation. Off by default — it changes how
    /// the swipe lands and uses private APIs. Acted on by `AppDelegate` (which
    /// installs/removes the swipe-override event tap via `FasterDesktopSwitch`).
    /// The instant-switch technique is adapted from InstantSpaceSwitcher (MIT).
    var fasterDesktopSwitch: Bool { get { bln(K.fasterDesktopSwitch) } set { setBln(newValue, K.fasterDesktopSwitch) } }
    /// "Faster desktop switch" for the **keyboard** shortcut: take over the user's
    /// "Move left/right a space" shortcut (whatever they've bound) and make it
    /// instant. Independent of `fasterDesktopSwitch` (the swipe). Off by default —
    /// it temporarily disables the system shortcut while Powerspaces runs. Acted on
    /// by `AppDelegate` via `FasterDesktopSwitch.setKeyboardEnabled`.
    var fasterKeyboardSwitch: Bool { get { bln(K.fasterKeyboardSwitch) } set { setBln(newValue, K.fasterKeyboardSwitch) } }
    /// Internal bookkeeping (not user-facing): true while we've disabled the system
    /// space-switch symbolic hotkeys for the keyboard override. Lets the next launch
    /// restore them if a crash skipped the normal teardown. Written directly (no
    /// `objectWillChange` / `preferencesDidChange`) since it isn't a UI setting and
    /// must not trigger a live re-apply.
    var spaceHotkeysDisabledByUs: Bool {
        get { bln(K.spaceHotkeysDisabledByUs) }
        set { store.set(newValue, K.spaceHotkeysDisabledByUs) }
    }
    /// Internal bookkeeping (not user-facing): the user's `com.apple.dock autohide`
    /// value captured the first time we hid Apple's Dock, so re-enabling restores
    /// exactly what they had. `nil` means "no backup / nothing to restore". Written
    /// directly (no `objectWillChange` / `preferencesDidChange`) since it isn't a UI
    /// setting and must not trigger a live re-apply.
    var appleDockAutohideBackup: Bool? {
        get {
            guard let s = store.string(K.appleDockAutohideBackup) else { return nil }
            return s == "true"
        }
        set {
            if let newValue { store.set(newValue ? "true" : "false", K.appleDockAutohideBackup) }
            else { store.remove(K.appleDockAutohideBackup) }
        }
    }
    /// How running apps are distinguished: dim the not-running ones, or box the
    /// running ones with a colored outline.
    var runningIndicator: RunningIndicator { get { raw(K.runningIndicator, .boxed) } set { setRaw(newValue, K.runningIndicator) } }
    /// Animate an app *leaving* the dock (quit / unpinned / last window closed).
    /// When off, a leaving icon vanishes instantly.
    var animateOnRemove: Bool { get { bln(K.animateOnRemove) } set { setBln(newValue, K.animateOnRemove) } }
    /// Animate an app *joining* the dock (launched / pinned / first window here).
    /// When off, a new icon appears instantly.
    var animateOnAdd: Bool { get { bln(K.animateOnAdd) } set { setBln(newValue, K.animateOnAdd) } }
    /// Which effect a joining/leaving icon plays (see `IconAnimationStyle`).
    var iconAnimationStyle: IconAnimationStyle { get { raw(K.iconAnimationStyle, .fade) } set { setRaw(newValue, K.iconAnimationStyle) } }
    /// App Launcher feature: when on, a Launchpad-style tile is added to the bar.
    /// Clicking it opens a searchable grid of every installed app, from which apps
    /// can be launched or dragged onto the bar to pin them.
    var appLauncherEnabled: Bool { get { bln(K.appLauncherEnabled) } set { setBln(newValue, K.appLauncherEnabled) } }
    /// A global keyboard shortcut that opens the App Launcher from anywhere (a
    /// Carbon hotkey, so it needs no Accessibility permission). Off by default so it
    /// can't clash with a shortcut the user already uses. Applied by
    /// `AppDelegate.applyLauncherHotkey`.
    var launcherHotkey: LauncherHotkey { get { raw(K.launcherHotkey, .off) } set { setRaw(newValue, K.launcherHotkey) } }
    /// Show a small "Desktop N" indicator on the dock so the current desktop is
    /// always glanceable (UX review Principle 1). On by default.
    var desktopIndicatorEnabled: Bool { get { bln(K.desktopIndicatorEnabled) } set { setBln(newValue, K.desktopIndicatorEnabled) } }
    /// Where that indicator sits: above the bar, or inside it at the start / end /
    /// middle of the icons.
    var desktopIndicatorPosition: DesktopIndicatorPosition { get { raw(K.desktopIndicatorPosition, .dockLeading) } set { setRaw(newValue, K.desktopIndicatorPosition) } }
    /// "Windows" feature: when on, the dock shows one icon per open window on the
    /// current Space, so an app with two windows here appears twice.
    var showIconPerWindow: Bool { get { bln(K.showIconPerWindow) } set { setBln(newValue, K.showIconPerWindow) } }
    /// Wide window-label mode: each window gets a wider dock item with its title
    /// (read live via Accessibility) shown in white. Implies one item per window.
    var showWindowLabels: Bool { get { bln(K.showWindowLabels) } set { setBln(newValue, K.showWindowLabels) } }
    /// Which apps get the wide label when window titles are on: all of them, or
    /// only apps with more than one window open here.
    var windowLabelScope: WindowLabelScope { get { raw(K.windowLabelScope, .multipleWindows) } set { setRaw(newValue, K.windowLabelScope) } }
    /// Whether windows of ⌘-hidden apps still appear in the dock. On (default) keeps
    /// a hidden app visible — like its tile in macOS's Dock — so you can click it
    /// back; off drops hidden apps' windows from the dock until they're unhidden.
    var showHiddenWindows: Bool { get { bln(K.showHiddenWindows) } set { setBln(newValue, K.showHiddenWindows) } }
    /// Whether running apps that currently have **no open window** still appear in
    /// the dock. On (default) shows them — like macOS's Dock keeps a running app's
    /// icon after you close its last window — so a click reopens a window; off hides
    /// them until they have a window again. Window-less apps show on every desktop's
    /// dock (they have no window pinning them to one) and only regular, Dock-showing
    /// apps qualify (never background agents).
    var showWindowlessApps: Bool { get { bln(K.showWindowlessApps) } set { setBln(newValue, K.showWindowlessApps) } }
    /// Width (points) of a wide window-label item.
    var windowLabelWidth: Double { get { dbl(K.windowLabelWidth) } set { setDbl(newValue, K.windowLabelWidth) } }
    var windowLabelWidthCustom: Bool { get { bln(K.custom(K.windowLabelWidth)) } set { setBln(newValue, K.custom(K.windowLabelWidth)) } }
    /// Color of the window-title text. Stored as sRGB components `"r,g,b,a"` — a
    /// plain, human-readable string in the JSON; defaults to white. Used by the
    /// wide label.
    var windowLabelTextColor: NSColor {
        get { color(K.windowLabelColor, default: Preferences.defaultWindowLabelColor) }
        set { setColor(newValue, K.windowLabelColor) }
    }

    // MARK: Auto-hide

    /// Master switch: tuck the bar off its screen edge when the pointer is away,
    /// and reveal it when the pointer returns to that edge (bottom edge for a
    /// bottom bar, left edge for a left bar, etc. — matching `barPosition`).
    var autoHideEnabled: Bool { get { bln(K.autoHideEnabled) } set { setBln(newValue, K.autoHideEnabled) } }
    /// How the bar hides and reveals: slide off the edge, fade in place, or both.
    var autoHideAnimation: AutoHideAnimation { get { raw(K.autoHideAnimation, .slide) } set { setRaw(newValue, K.autoHideAnimation) } }
    /// Seconds the pointer must be away from the bar before it hides (0 = at once).
    var autoHideDelay: Double { get { dbl(K.autoHideDelay) } set { setDbl(newValue, K.autoHideDelay) } }
    var autoHideDelayCustom: Bool { get { bln(K.custom(K.autoHideDelay)) } set { setBln(newValue, K.custom(K.autoHideDelay)) } }
    /// Duration (seconds) of the hide animation; 0 = instant.
    var autoHideSpeed: Double { get { dbl(K.autoHideSpeed) } set { setDbl(newValue, K.autoHideSpeed) } }
    var autoHideSpeedCustom: Bool { get { bln(K.custom(K.autoHideSpeed)) } set { setBln(newValue, K.custom(K.autoHideSpeed)) } }
    /// Duration (seconds) of the reveal animation; 0 = instant.
    var autoShowSpeed: Double { get { dbl(K.autoShowSpeed) } set { setDbl(newValue, K.autoShowSpeed) } }
    var autoShowSpeedCustom: Bool { get { bln(K.custom(K.autoShowSpeed)) } set { setBln(newValue, K.custom(K.autoShowSpeed)) } }

    /// Internal bookkeeping (not user-facing): set once we've shown the first-run
    /// welcome window, so it appears only on the very first launch. Written directly
    /// (no `objectWillChange` / `.preferencesDidChange`) since it isn't a UI setting.
    var hasSeenWelcome: Bool {
        get { bln(K.hasSeenWelcome) }
        set { store.set(newValue, K.hasSeenWelcome) }
    }

    /// Basic vs Advanced view of the preferences window. Persisted so the choice
    /// sticks across opens, but it never touches the live dock — so the setter
    /// only nudges `objectWillChange` (to re-render the window) and skips
    /// `changed()`/`.preferencesDidChange`.
    var detailLevel: DetailLevel {
        get { raw(K.detailLevel, .basic) }
        set { objectWillChange.send(); store.set(newValue.rawValue, K.detailLevel) }
    }

    /// Color of the outline drawn around the whole dock bar (when its width > 0);
    /// independent of the running-app box's outline color. Defaults to mid grey.
    var dockOutlineColor: NSColor {
        get { color(K.dockOutlineColor, default: Preferences.defaultDockOutlineColor) }
        set { setColor(newValue, K.dockOutlineColor) }
    }
    /// The running-app box outline color (boxed style); defaults to dark grey.
    var boxOutlineColor: NSColor {
        get { color(K.boxOutlineColor, default: Preferences.defaultBoxOutlineColor) }
        set { setColor(newValue, K.boxOutlineColor) }
    }
    /// The inside-highlight (fill) color for the running-app box; defaults to a
    /// translucent light grey. Its alpha is honored as-is so the icon stays visible
    /// only as far as the user wants (see `DockButton`).
    var boxHighlightColor: NSColor {
        get { color(K.boxColor, default: Preferences.defaultBoxHighlightColor) }
        set { setColor(newValue, K.boxColor) }
    }
    /// The App Launcher tile's icon color — the grey base of the dock launcher
    /// button. The tile's subtle top-to-bottom gradient is derived from this single
    /// color (see `LauncherIcon`); defaults to the original slate grey.
    var launcherIconColor: NSColor {
        get { color(K.launcherIconColor, default: Preferences.defaultLauncherIconColor) }
        set { setColor(newValue, K.launcherIconColor) }
    }
    /// The App Launcher's selection-ring (outline) color — the analogue of the
    /// running-app box's outline. Defaults to a clearly-visible blue.
    var launcherOutlineColor: NSColor {
        get { color(K.launcherOutlineColor, default: Preferences.defaultLauncherOutlineColor) }
        set { setColor(newValue, K.launcherOutlineColor) }
    }
    /// The fill (highlight) behind the App Launcher's selected tile — the analogue
    /// of the running-app box's highlight. Its alpha is honored as-is, so lowering
    /// it keeps the app icon visible through the tint.
    var launcherHighlightColor: NSColor {
        get { color(K.launcherHighlightColor, default: Preferences.defaultLauncherHighlightColor) }
        set { setColor(newValue, K.launcherHighlightColor) }
    }
    static let defaultDockOutlineColor = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    // Box outline / highlight and the window-label text color come from the
    // project's default preferences: a soft-blue outline over a light-blue fill,
    // with near-black grey label text.
    static let defaultBoxOutlineColor = NSColor(srgbRed: 0.17990687489509583, green: 0.29203012585639954, blue: 0.8218111991882324, alpha: 0.2867943548387097)
    static let defaultBoxHighlightColor = NSColor(srgbRed: 0.6837188005447388, green: 0.8619992733001709, blue: 0.9875540137290955, alpha: 1.0)
    static let defaultWindowLabelColor = NSColor(srgbRed: 0.12755858898162842, green: 0.12755858898162842, blue: 0.12755858898162842, alpha: 1.0)
    // Launcher selection (from the project's default preferences): a translucent
    // black ring over a soft, translucent blue fill that the app icon still shows
    // through.
    static let defaultLauncherOutlineColor = NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.3922155017921148)
    static let defaultLauncherHighlightColor = NSColor(srgbRed: 0.6261407732963562, green: 0.7653085589408875, blue: 0.92977374792099, alpha: 0.6242999551971327)
    /// The App Launcher tile's base color — a blue, from the project's default
    /// preferences.
    static let defaultLauncherIconColor = NSColor(srgbRed: 0.0, green: 0.567995548248291, blue: 0.8244075179100037, alpha: 1.0)

    // MARK: Dock color / opacity

    /// Master switch for the default dock tint. Off (the default) keeps the bar's
    /// plain material/blur look; on overlays `dockTintColor` on the blur.
    var dockTintEnabled: Bool { get { bln(K.dockTintEnabled) } set { setBln(newValue, K.dockTintEnabled) } }
    /// The default dock color, painted on every desktop that has no override. Its
    /// alpha *is* the opacity, so the color picker's opacity slider controls how
    /// strongly the bar is tinted (0 = the bare material shows through).
    var dockTintColor: NSColor {
        get { color(K.dockTintColor, default: Preferences.defaultDockTintColor) }
        set { setColor(newValue, K.dockTintColor) }
    }
    /// An opaque medium grey — the starting point for the color picker and the
    /// fallback when a desktop has no override, so tinting begins from a solid grey
    /// dock (like the original look) rather than something transparent. Only seen
    /// once the user turns the tint on, since `dockTintEnabled` defaults to false.
    static let defaultDockTintColor = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)

    /// This desktop's custom dock color, or nil when it follows the default.
    func dockTintOverride(forSpace uuid: String) -> NSColor? { dockTints.color(forSpace: uuid) }
    /// Set (or, with nil, clear) one desktop's custom dock color. Posts
    /// `.preferencesDidChange` so the live bar re-tints.
    func setDockTintOverride(_ color: NSColor?, forSpace uuid: String) {
        objectWillChange.send()
        if let color { dockTints.setColor(color, forSpace: uuid) }
        else { dockTints.removeColor(forSpace: uuid) }
        changed()
    }
    /// Whether any desktop has a custom dock color (drives the Reset button).
    var hasDockTintOverrides: Bool { dockTints.hasOverrides }
    /// Clear every desktop's custom dock color — the "Reset custom Dock colors"
    /// action. Posts `.preferencesDidChange` so the live bar re-tints.
    func resetDockTintOverrides() {
        objectWillChange.send()
        dockTints.clearAll()
        changed()
    }

    /// Reset every appearance and behavior setting to its default (clears the JSON
    /// store and the per-desktop dock colors). Leaves pinned apps, recents, and
    /// launch strategies alone — those are data, not settings. Posts
    /// `.preferencesDidChange` so the live dock re-applies.
    func resetAllToDefaults() {
        objectWillChange.send()
        store.removeAll()
        dockTints.clearAll()
        changed()
    }
    /// Whether the dock is tinted on this desktop — it has its own override, or the
    /// default tint is switched on. When false the bar shows its plain material at
    /// full opacity; when true the bar takes on `effectiveDockTint` (whose alpha
    /// fades the whole bar, so a 0%-opacity tint is fully transparent).
    func isDockTinted(forSpace uuid: String?) -> Bool {
        if let uuid, dockTints.color(forSpace: uuid) != nil { return true }
        return dockTintEnabled
    }
    /// The color to paint on a desktop when it's tinted: its own override if set,
    /// else the default tint. Only meaningful when `isDockTinted` is true (it falls
    /// back to clear otherwise).
    func effectiveDockTint(forSpace uuid: String?) -> NSColor {
        if let uuid, let override = dockTints.color(forSpace: uuid) { return override }
        return dockTintEnabled ? dockTintColor : .clear
    }

    /// Whether a dock item for an app with this many windows on the current Space
    /// should show its window-title label, given the current mode and scope. The
    /// single source of truth shared by the title attach (`AppDelegate`) and the
    /// wide rendering (`DockPanel`) so they never disagree.
    func showsWindowLabel(windowCount: Int) -> Bool {
        guard showWindowLabels else { return false }
        switch windowLabelScope {
        case .all: return true
        case .multipleWindows: return windowCount > 1
        }
    }

    /// How long the warning banner stays up; nil = until clicked.
    var warningDurationSeconds: Double? {
        switch warningMode {
        case .short: return 2
        case .normal: return 4
        case .long: return 6
        case .untilClicked: return nil
        case .custom: return warningCustomSeconds
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
    }
}

// `JSONPreferencesStore` (the file-backed key/value backend) lives in
// `JSONPreferencesStore.swift`; the choice enums + `NumericSpec` in
// `PreferenceTypes.swift`.
