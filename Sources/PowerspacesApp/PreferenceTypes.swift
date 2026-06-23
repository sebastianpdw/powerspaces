// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

// The value types behind the preferences UI: the `NumericSpec` descriptor for
// preset-or-custom numbers, and the non-numeric choice enums each dropdown binds
// to. Pure values with no dependency on the `Preferences` store — they're consumed
// by the dock, the app delegate, and the Preferences view — so they live apart from
// the store itself (see `Preferences.swift`).

// MARK: - Numeric setting descriptor

/// Describes a number the user normally picks from presets, but can also set to a
/// freeform value via a slider ("Custom…"). Used by the reusable `NumericRow`.
struct NumericSpec: Sendable {
    /// (dropdown label, value) pairs — these are the same presets as before.
    let presets: [(label: String, value: Double)]
    /// Slider bounds + granularity when "Custom…" is chosen.
    let range: ClosedRange<Double>
    let step: Double
    /// Formats the live value for the readout next to the slider. `@Sendable` so the
    /// static `…Spec` constants are concurrency-safe (the formatters are pure).
    let format: @Sendable (Double) -> String

    /// The default value (first matching the supplied default, else the middle preset).
    func presetValue(_ label: String) -> Double {
        presets.first { $0.label == label }?.value ?? presets[presets.count / 2].value
    }
}

// MARK: - Non-numeric choice enums (plain dropdowns)

enum BarPosition: String, CaseIterable, Identifiable {
    case bottom, top, left, right
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottom: return "Bottom"
        case .top: return "Top"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
    /// Left/right bars run along a vertical edge, so the dock lays its icons out
    /// top-to-bottom instead of left-to-right.
    var isVertical: Bool { self == .left || self == .right }
}

/// Which screens get their own powerspaces dock. `.allScreens` puts an
/// independent dock on every display (so two screens behave like two desktops);
/// `.selectedScreens` limits docks to the displays the user picked (by UUID).
enum DockScreensMode: String, CaseIterable, Identifiable {
    case allScreens, selectedScreens
    var id: String { rawValue }
    var label: String {
        switch self {
        case .allScreens: return "All screens"
        case .selectedScreens: return "Selected screens"
        }
    }
}

enum BarMaterial: String, CaseIterable, Identifiable {
    case hud, darker, lighter, solid
    var id: String { rawValue }
    var material: NSVisualEffectView.Material {
        switch self {
        case .hud: return .hudWindow
        case .darker: return .menu
        case .lighter: return .popover
        case .solid: return .windowBackground
        }
    }
    var label: String {
        switch self {
        case .hud: return "HUD (default)"
        case .darker: return "Darker"
        case .lighter: return "Lighter"
        case .solid: return "Solid"
        }
    }
}

enum HUDPosition: String, CaseIterable, Identifiable {
    case top, bottom, center
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// How running apps are told apart from pinned-but-not-running shortcuts.
enum RunningIndicator: String, CaseIterable, Identifiable {
    /// Dim the *not-running* (pinned) icons; running icons stay full opacity.
    case dimmed
    /// Frame each *running* icon with a rounded outline and tint its inside with a
    /// color; not-running icons stay plain (nothing is dimmed).
    case boxed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dimmed: return "Dim not-running"
        case .boxed: return "Box running"
        }
    }
}

enum ForceNewModifier: String, CaseIterable, Identifiable {
    case shiftOrOption, shift, option
    var id: String { rawValue }
    func isPressed(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .shiftOrOption: return flags.contains(.shift) || flags.contains(.option)
        case .shift: return flags.contains(.shift)
        case .option: return flags.contains(.option)
        }
    }
    var label: String {
        switch self {
        case .shiftOrOption: return "Shift or Option"
        case .shift: return "Shift only"
        case .option: return "Option only"
        }
    }
}

/// What a middle-click (button 3) on a dock icon does. The default opens a new
/// window; the rest mirror the right-click menu's quit/close actions, plus an
/// off switch.
enum MiddleClickAction: String, CaseIterable, Identifiable {
    case newWindow, quitThisDesktop, quitAllDesktops, closeWindow, doNothing
    var id: String { rawValue }
    var label: String {
        switch self {
        case .newWindow: return "Open a new window"
        case .quitThisDesktop: return "Quit (this desktop)"
        case .quitAllDesktops: return "Quit (all desktops)"
        case .closeWindow: return "Close this window"
        case .doNothing: return "Do nothing"
        }
    }
}

enum MenuGlyph: String, CaseIterable, Identifiable {
    case powerWindow, squareDotted, squareEmpty, overlap, invisible, hidden
    var id: String { rawValue }
    /// Whether this glyph renders as an image rather than a text title.
    var usesImage: Bool { self == .powerWindow }
    /// The SF Symbol for the square / overlap glyph options (nil for the custom
    /// power-window image and the blank / hidden items), so they render as crisp,
    /// auto-tinting template images rather than Unicode characters.
    var symbolName: String? {
        switch self {
        case .squareDotted: return "square.dashed"
        case .squareEmpty: return "square"
        case .overlap: return "square.on.square"
        default: return nil
        }
    }
    /// `.hidden` removes the status-bar item entirely (no clickable icon at all);
    /// every other glyph keeps a clickable item. `.invisible` keeps one too, but
    /// with a blank title so it's not visible — see `title`. With `.hidden` the
    /// only way back to Preferences is the dock's right-click menu.
    var hidesStatusItem: Bool { self == .hidden }
    /// The title shown on the status-bar item. `.invisible` uses a blank space so
    /// the item is visually invisible but still clickable. `.powerWindow` renders
    /// as a template image (see `AppIcon.menuBarImage`), so its title is empty.
    /// `.hidden` has no item at all (see `hidesStatusItem`), so its title is never used.
    var title: String {
        switch self {
        case .powerWindow: return ""
        case .squareDotted: return "▣"
        case .squareEmpty: return "▢"
        case .overlap: return "⧉"
        case .invisible: return " "
        case .hidden: return ""
        }
    }
    var label: String {
        switch self {
        case .powerWindow: return "Power window (icon)"
        case .squareDotted: return "Dashed square"
        case .squareEmpty: return "Empty square"
        case .overlap: return "Overlapping squares"
        case .invisible: return "Invisible (clickable)"
        case .hidden: return "Hidden (no icon)"
        }
    }
}

/// Warning-banner duration: presets, "until clicked", or a custom seconds value.
enum WarningMode: String, CaseIterable, Identifiable {
    case short, normal, long, untilClicked, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .short: return "2 seconds"
        case .normal: return "Default (4s)"
        case .long: return "6 seconds"
        case .untilClicked: return "Until clicked"
        case .custom: return "Custom…"
        }
    }
}

/// Which apps get the wide window-title treatment when window titles are on.
enum WindowLabelScope: String, CaseIterable, Identifiable {
    /// Every window item is labeled (one wide item per window, for every app).
    case all
    /// Only apps with more than one window here are labeled; single-window apps
    /// stay as a plain icon.
    case multipleWindows
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All apps"
        case .multipleWindows: return "Only apps with multiple windows"
        }
    }
}

/// How a dock icon animates as its app joins or leaves the dock. Each style is
/// symmetric: removing plays it forward (icon → gone), adding plays it in
/// reverse (gone → icon), so a quit and a launch feel like one motion run both
/// ways. The bar opens/closes the slot and grows/shrinks to match (see
/// `DockPanel`).
enum IconAnimationStyle: String, CaseIterable, Identifiable {
    /// Fade out where it sits; fade in once the slot is open.
    case fade
    /// Shrink toward center while fading out; grows back in (opaque) on arrival.
    case shrink
    /// The macOS "poof": puffs up larger while fading out; shrinks in (opaque) in reverse.
    case poof
    /// Slide off toward the screen edge the bar hugs while fading out; slides in
    /// from that edge (opaque) in reverse — visible for the on-screen part of the trip.
    case slideOff
    var id: String { rawValue }
    /// Labels name both directions (leave / join) so the menu reads as one motion
    /// run both ways, like "Shrink / grow".
    var label: String {
        switch self {
        case .fade: return "Fade out / in"
        case .shrink: return "Shrink / grow"
        case .poof: return "Poof out / in"
        case .slideOff: return "Slide off / in"
        }
    }
}

/// How the dock tucks away and comes back when auto-hide is on.
enum AutoHideAnimation: String, CaseIterable, Identifiable {
    /// Slide the bar off the screen edge it hugs (and back on).
    case slide
    /// Fade the bar out where it sits (and back in).
    case fade
    /// Slide and fade together.
    case slideFade
    var id: String { rawValue }
    var label: String {
        switch self {
        case .slide: return "Slide off edge"
        case .fade: return "Fade"
        case .slideFade: return "Slide + fade"
        }
    }
    /// Whether the bar moves off the edge (vs. staying put and only fading).
    var slides: Bool { self == .slide || self == .slideFade }
    /// Whether the bar's opacity animates to zero.
    var fades: Bool { self == .fade || self == .slideFade }
}

/// How the per-desktop dock behaves on a screen that's showing a full-screen app.
enum FullscreenDockBehavior: String, CaseIterable, Identifiable {
    /// Remove the bar entirely while a full-screen app owns the screen; it can't be
    /// revealed (the full-screen app gets the whole screen).
    case hide
    /// Tuck the bar off its screen edge, but still reveal it when the pointer reaches
    /// that edge. The default.
    case autoHide
    /// Keep the bar on screen, floating over the full-screen app.
    case show
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hide: return "Hide"
        case .autoHide: return "Auto-hide"
        case .show: return "Show"
        }
    }
}

/// How much of the preferences UI to show. `basic` reveals a curated subset of
/// the most common controls; `advanced` reveals every setting. This is purely a
/// preferences-window view state (it never changes the live dock), so toggling it
/// doesn't post `.preferencesDidChange`.
enum DetailLevel: String, CaseIterable, Identifiable {
    case basic, advanced
    var id: String { rawValue }
    var label: String {
        switch self {
        case .basic: return "Basic"
        case .advanced: return "Advanced"
        }
    }
}

/// A preset global shortcut for opening the App Launcher. A short list (rather than
/// a free recorder) keeps it consistent with the app's other preset dropdowns and
/// avoids a fragile key-capture control. Defaults to `.off` so it never collides
/// with a shortcut the user already relies on. The key codes and modifier masks
/// below are Carbon values (see `GlobalHotkey`), kept as plain numbers so this file
/// needs no Carbon import.
enum LauncherHotkey: String, CaseIterable, Identifiable {
    case off
    case optionSpace
    case commandOptionSpace
    case controlOptionSpace
    case commandOptionL
    case controlOptionL
    var id: String { rawValue }

    // Carbon virtual key codes: Space = 49, L = 37.
    var keyCode: UInt32? {
        switch self {
        case .off: return nil
        case .optionSpace, .commandOptionSpace, .controlOptionSpace: return 49
        case .commandOptionL, .controlOptionL: return 37
        }
    }

    // Carbon modifier masks: cmdKey = 256, optionKey = 2048, controlKey = 4096.
    var carbonModifiers: UInt32 {
        switch self {
        case .off: return 0
        case .optionSpace: return 2048
        case .commandOptionSpace, .commandOptionL: return 256 + 2048
        case .controlOptionSpace, .controlOptionL: return 4096 + 2048
        }
    }

    var label: String {
        switch self {
        case .off: return "Off"
        case .optionSpace: return "⌥Space"
        case .commandOptionSpace: return "⌘⌥Space"
        case .controlOptionSpace: return "⌃⌥Space"
        case .commandOptionL: return "⌘⌥L"
        case .controlOptionL: return "⌃⌥L"
        }
    }
}

/// Where the current-desktop indicator sits relative to the dock.
enum DesktopIndicatorPosition: String, CaseIterable, Identifiable {
    /// Just off the bar, on its inner side (a small pill above a bottom bar, below a
    /// top bar, or beside a side bar).
    case aboveDock
    /// Inside the bar, before the first icon.
    case dockLeading
    /// Inside the bar, after the last icon.
    case dockTrailing
    /// Inside the bar, in the middle of the icons.
    case dockCenter
    var id: String { rawValue }
    /// True for the three positions that live in the icon row itself (so the dock
    /// reserves a slot for the indicator instead of floating it off the bar).
    var isInsideDock: Bool { self != .aboveDock }
    var label: String {
        switch self {
        case .aboveDock: return "Above the dock"
        case .dockLeading: return "In the dock, at the start"
        case .dockTrailing: return "In the dock, at the end"
        case .dockCenter: return "In the dock, centered"
        }
    }
}
