// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics

/// Decides whether a raw `CGWindowListCopyWindowInfo` entry is a real,
/// user-facing application window — as opposed to the many helper/accessory
/// windows apps create at the *same* window layer: toolbar/tab-bar strips, the
/// hover-URL status overlay, transparent event-catchers, and off-screen system
/// "remote view" placeholders.
///
/// This matters because the per-space dock counts one entry per window. Without
/// filtering, a single Safari window reads as several — its real window *plus* a
/// fully-transparent status overlay and a short accessory bar that share its
/// Space — so the dock shows phantom duplicate icons and opening a new tab (which
/// shuffles those accessory windows) looks like "a new window appeared". Finder
/// shows the same pattern (four full-width 33pt toolbar strips around one real
/// window). Pure data in, Bool out, so it's unit-testable without a window server.
///
/// The discriminators are deliberately conservative, picked from observed data
/// (see tmp-scripts/005, which dumped every layer-0 window on the machine):
/// every accessory window was either fully transparent or ≤ 64pt on its short
/// side (Safari's tallest, an 865×61 bar, is the extreme), while the smallest
/// *real* window was ~237pt — a wide, empty gap to place the threshold in.
public enum WindowFilter {
    /// Smallest width *and* height (points) a real top-level window is assumed to
    /// have. Comfortably above the tallest observed accessory window (61pt) and
    /// well below the smallest real one (~237pt).
    public static let minRealWindowSize: CGFloat = 100

    public static func isRealWindow(
        layer: Int, alpha: Double, width: CGFloat, height: CGFloat
    ) -> Bool {
        guard layer == 0 else { return false }      // normal app-window layer only
        guard alpha > 0 else { return false }       // fully transparent → not user-visible
        return width >= minRealWindowSize && height >= minRealWindowSize
    }

    /// The size/alpha pass above can't catch every phantom: apps also spawn
    /// *full-size* off-screen placeholder windows at default dimensions (500×500,
    /// 800×600) — the same geometry shows up across many unrelated apps — and
    /// these momentarily acquire the *current* Space when a window opens, so a
    /// single Safari window briefly reads as two, three or four. They are never
    /// actually displayed, so they report `onscreen == false`.
    ///
    /// A genuinely-present *visible* window reports onscreen on the active Space
    /// even when stacked behind others, so the rule is mostly safe: a window that
    /// *claims the active Space but isn't on screen* is a phantom. This applies
    /// only to the active Space — windows on other Spaces always report
    /// `onscreen == false`, and we must keep those so the launch engine still
    /// knows the app is "running elsewhere".
    ///
    /// The exceptions are a **minimized** or a **hidden** (⌘H) window: each sits
    /// off-screen with `onscreen == false` yet is a real, user-facing window on this
    /// Space. Drop a minimized one and a minimized-only app vanishes from the
    /// per-Space dock (the GitHub app, minimized, was the repro); drop a hidden one
    /// and ⌘-hiding an app makes it disappear from the dock entirely. So neither is
    /// a phantom — callers pass each window's live minimized state (read via
    /// Accessibility) and its app's hidden state (from `NSRunningApplication`).
    /// Placeholders are neither minimized nor owned by a hidden app, so they're
    /// still filtered out.
    public static func isActiveSpacePhantom(
        claimsActiveSpace: Bool, isOnscreen: Bool, isMinimized: Bool = false, isHidden: Bool = false
    ) -> Bool {
        claimsActiveSpace && !isOnscreen && !isMinimized && !isHidden
    }

    /// Whether an Accessibility window element is a **real, standalone application
    /// window** — one that earns its own per-Space dock icon — given its AX role,
    /// subrole, and modal flag. The raw window-server entries for the impostors
    /// below are full-size and opaque, indistinguishable from a real window by
    /// geometry alone (`isRealWindow`), so we read each window's *kind* via
    /// Accessibility and keep only genuine windows.
    ///
    /// A genuine window has `role == "AXWindow"` and isn't a dialog. Everything
    /// else is excluded — in the order the cases bit us:
    ///   - **Blocking dialogs**: a sheet (`role == "AXSheet"`) or a modal alert
    ///     panel (`subrole == "AXDialog"`/`"AXSystemDialog"`, or `modal == true`).
    ///     These are *attached to* a parent window — dismissing one returns you to
    ///     it — so they aren't a new window. (System Settings' slide-down popup is
    ///     a sheet; a sheet also never appears in an app's top-level window list, so
    ///     the caller drops it for that reason too and the role check is a backstop.)
    ///   - **Non-window accessory elements** that nonetheless surface as their own
    ///     window-server window. Safari's search-suggestions list forced this: while
    ///     you type in the smart-search field it appears as a top-level element whose
    ///     role is `"AXScrollArea"` (not `"AXWindow"`), on screen alongside the page
    ///     window — so without the role check the dock showed two Safari icons.
    ///
    /// Confirmed against live windows. We require only the *role* to be `"AXWindow"`,
    /// not a particular subrole, so floating/utility/full-screen windows still count.
    /// Pure data in, Bool out → unit-testable without a window server. A nil/blank
    /// role (AX couldn't answer) is treated as *not* a standalone window; the caller
    /// keeps all of an app's windows when it can find no standalone window at all, so
    /// this can never erase an app from the dock.
    public static func isStandaloneWindow(role: String?, subrole: String?, isModal: Bool) -> Bool {
        guard role == "AXWindow", !isModal else { return false }
        return subrole != "AXDialog" && subrole != "AXSystemDialog"
    }

    /// Whether an AX window element is a **blocking dialog** — a sheet or a modal
    /// alert panel, e.g. the "Save changes before quitting?" prompt an app raises
    /// when asked to quit with unsaved work. Used by "Quit (all desktops)" to spare
    /// such an app from a force-quit so the user can answer first.
    ///
    /// This is deliberately *not* the negation of `isStandaloneWindow`: a non-window
    /// accessory (a search-suggestions `AXScrollArea`) is neither a standalone window
    /// nor a dialog, and must not read as one — mistaking it for a save prompt would
    /// wrongly keep an app alive. So we match only the genuine dialog kinds: a sheet
    /// (`role == "AXSheet"`), a modal window, or a dialog subrole. Pure data in, Bool
    /// out → unit-testable without a window server.
    public static func isBlockingDialog(role: String?, subrole: String?, isModal: Bool) -> Bool {
        if role == "AXSheet" { return true }
        if isModal { return true }
        return subrole == "AXDialog" || subrole == "AXSystemDialog"
    }
}
