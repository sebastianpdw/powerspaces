// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SpaceKit

/// A floating, always-visible bar whose contents are filtered to the current
/// Space (running apps + this desktop's / all-desktops' pinned apps).
final class DockPanel: NSPanel {
    /// A click on an icon: activate the app. Passes the whole `DockApp` (not just
    /// the target) so a per-window icon (the "Windows" feature) can carry its
    /// specific `windowID`. `forceNew` is set when the force-new modifier is held.
    var onSelect: ((DockApp, Bool) -> Void)?
    var onPinHere: ((DockApp) -> Void)?
    var onPinEverywhere: ((DockApp) -> Void)?
    /// "Unpin (this desktop)" on an all-desktops pin: hide it on this desktop only
    /// (or show it here again if already hidden), leaving the other desktops alone.
    var onToggleHereForEverywhere: ((DockApp) -> Void)?
    var onCloseThisDesktop: ((DockApp) -> Void)?
    var onCloseAllDesktops: ((DockApp) -> Void)?
    /// Close just the one window a per-window icon stands for (app.windowID).
    var onCloseWindow: ((DockApp) -> Void)?
    /// An .app was dropped onto the bar: pin `bundleID` to this desktop and save
    /// `order` — the full left-to-right arrangement with the new app already
    /// placed in the slot the user opened for it.
    var onDropApp: ((_ bundleID: String, _ order: [String]) -> Void)?
    /// Reports the new left-to-right arrangement (a list of `orderKey`s) after
    /// the user finishes dragging an icon, so it can be persisted.
    var onReorder: (([String]) -> Void)?
    /// Right-click → "When open elsewhere": flip an app between warn and move-here.
    var onSetStrategy: ((DockApp, StrategyKind) -> Void)?
    /// Supplies an app's current new-window strategy so the submenu can tick it.
    var currentStrategy: ((DockApp) -> StrategyKind)?
    /// The App Launcher tile was clicked: open (or toggle) the all-apps grid.
    var onOpenLauncher: (() -> Void)?
    /// Right-click → "Hide App Launcher": turn the launcher tile off.
    var onDisableLauncher: (() -> Void)?
    /// Right-click → "Open Preferences…": open the Preferences window. Offered both
    /// on icon menus and on the empty-bar menu, so it works wherever you right-click
    /// the dock — the fallback in when the menu-bar item is set to Hidden.
    var onOpenPreferences: (() -> Void)?
    /// Right-click → "Change Dock Color (this desktop)": open the per-desktop dock
    /// color editor (color + opacity, with its own reset-to-default).
    var onEditDockColor: (() -> Void)?

    private let container = DockDropView()
    private let stack = NSStackView()
    private let effect = NSVisualEffectView()
    /// A non-interactive color wash over the blur — the dock's tint. When the dock
    /// is tinted its layer holds the chosen color and `effect`'s opacity is dropped
    /// to the tint's alpha, so the *whole* bar (blur included) fades with the
    /// opacity — a 0% opacity bar is fully transparent, not a grey blur. Sits above
    /// the blur but below the icon stack, so only the bar background is tinted.
    private let tintOverlay = PassthroughView()
    /// The persistent UUID of the desktop the bar is currently showing on, set by
    /// `AppDelegate` so the per-desktop dock color override can be looked up. Re-tints
    /// the bar whenever it changes (e.g. on a Space switch).
    var spaceUUID: String? {
        didSet { if spaceUUID != oldValue { applyDockTint() } }
    }
    private var apps: [DockApp] = []
    /// The current desktop's 1-based number, shown by the indicator badge. Set by
    /// `AppDelegate` each refresh; updating it refreshes the badge live even when the
    /// app list is unchanged (two desktops can hold the same apps).
    var desktopNumber: Int? {
        didSet { if desktopNumber != oldValue { updateDesktopIndicator() } }
    }
    /// The "Desktop N" badge. `layOutDesktopIndicator` homes it inside the icon row
    /// or floats it just off the bar, per the user's chosen position.
    private let desktopIndicator = DesktopIndicatorView()
    /// Cross-axis room reserved for a floating ("above the dock") indicator so it
    /// isn't clipped at the window edge. 0 for the in-row placements.
    private var indicatorReserve: CGFloat = 0
    /// The visible bar's two cross-/along-axis size constraints, swapped when the
    /// bar's orientation changes (see `applyBarFrame`). The bar hugs the window's
    /// outer edge (see `effectCross`), so the extra room `panelSize` leaves for
    /// hover spill sits on the inner side.
    private var effectAlong: NSLayoutConstraint?
    private var effectThickness: NSLayoutConstraint?
    /// Pins the bar to the window's outer edge (the screen edge it hugs); set per
    /// orientation in `applyBarFrame` so hover headroom stays on the inner side.
    private var effectCross: NSLayoutConstraint?
    /// Centers the bar along its own length (x for a horizontal bar, y for a
    /// vertical one). Orientation-dependent, so it lives with the other bar frames.
    private var effectAlongCenter: NSLayoutConstraint?
    /// The icon stack's two along-axis edge constraints (to the window) and its
    /// cross-axis *center* constraint (to the bar). The stack fills the window along
    /// the bar and centers on the bar's cross axis, so icons sit centered on the
    /// visible bar even when "Dock height" makes the bar thicker than an icon. Set
    /// per orientation in `applyBarFrame` alongside the bar's own frame.
    private var stackAlongStart: NSLayoutConstraint?
    private var stackAlongEnd: NSLayoutConstraint?
    private var stackCrossCenter: NSLayoutConstraint?

    /// True while an icon is mid-drag. Suppresses the background poll's rebuilds
    /// so the buttons aren't torn out from under the drag. (Internal, not private,
    /// so the auto-hide extension's `hide()` can defer while a drag is in flight.)
    var isReordering = false
    /// True while an external .app is being dragged over the bar (a slot is
    /// open). Like `isReordering`, this freezes the poll's rebuilds so the open
    /// slot survives until the drop or cancel.
    var isExternalDragging = false
    /// The invisible spacer wedged between icons to "make space" for an app being
    /// dragged in, plus the along-axis size constraint that animates it open and
    /// shut (width for a horizontal bar, height for a vertical one).
    private var dragGap: NSView?
    private var dragGapSize: NSLayoutConstraint?
    /// True while a join/leave icon animation is playing. Like the drag flags, it
    /// freezes the poll's rebuilds so the animating icons aren't torn out from
    /// under the animation. (Internal for the auto-hide extension's `hide()`.)
    var isAnimating = false
    /// The freshest app list requested while an animation was running, applied
    /// once it finishes so changes that arrived mid-animation aren't lost.
    private var pendingApps: [DockApp]?
    /// Set for the single update that follows an external .app drop, so the
    /// just-dropped icon isn't re-animated in — the drag already opened its slot.
    private var suppressAddAnimationOnce = false
    /// Transparent room (per cross side) added to the window only while a join/leave
    /// animation runs, so an icon that spills outside its slot (poof grows, slide
    /// translates) is actually drawn instead of clipped at the window's edge. The
    /// visible bar and icons stay centered and never move when this changes (see
    /// `panelSize` / `origin(forSize:)`), so applying it is visually seamless.
    private var animationCrossPad: CGFloat = 0

    /// The display this dock is bound to (its `CGDirectDisplayID`). All positioning
    /// and pointer-tracking is relative to this screen, so several docks — one per
    /// display — don't fight over `NSScreen.main`.
    let boundDisplayID: CGDirectDisplayID

    /// The live `NSScreen` for `boundDisplayID`, re-resolved each use so it survives
    /// display reconfiguration (NSScreen objects are recreated then). Returns nil — so
    /// callers SKIP positioning — when the bound display is momentarily missing (e.g.
    /// `NSScreen.screens` is still being rebuilt while waking from sleep or attaching
    /// a monitor). It must NOT fall back to `NSScreen.main`: that would place this
    /// display's dock on the main screen ("two docks on one screen"), and nothing
    /// pulls it back until relaunch. When the display returns, the follow-up
    /// screen-change event repositions the dock onto it.
    var boundScreen: NSScreen? {
        NSScreen.screens.first { $0.displayID == boundDisplayID }
    }

    init(screen: NSScreen) {
        self.boundDisplayID = screen.displayID
        super.init(contentRect: NSRect(x: 0, y: 0, width: 120, height: 64),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        let prefs = Preferences.shared
        effect.material = prefs.barMaterial.material
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = CGFloat(prefs.cornerRadius)
        effect.translatesAutoresizingMaskIntoConstraints = false
        applyDockOutline()

        stack.spacing = CGFloat(prefs.iconSpacing)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.onDragMoved = { [weak self] location in self?.updateDragSlot(at: location) }
        container.onDragLeft = { [weak self] in self?.closeDragSlot() }
        container.onDropApp = { [weak self] bundleID in self?.dropApp(bundleID) }
        // Right-click on empty bar background shows the dock's own menu (Open
        // Preferences / Quit). A right-click on an icon is handled by the button.
        container.dockMenu = { [weak self] in self?.makeDockMenu() }
        container.addSubview(effect)
        // The tint wash is framed to exactly cover the blur (its rounded corners
        // come from `applyDockTint`). It's a *sibling* of `effect`, inserted between
        // `effect` and `stack`, so it sits above the material but below the icons —
        // and, crucially, isn't faded when we drop `effect`'s opacity for the tint's
        // own opacity (a subview would inherit that fade and double up).
        tintOverlay.translatesAutoresizingMaskIntoConstraints = false
        tintOverlay.wantsLayer = true
        container.addSubview(tintOverlay)
        NSLayoutConstraint.activate([
            tintOverlay.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            tintOverlay.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            tintOverlay.topAnchor.constraint(equalTo: effect.topAnchor),
            tintOverlay.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        container.addSubview(stack)
        // The blur (visible bar) hugs the window's OUTER edge — the screen edge the
        // bar sits against — with all hover headroom on the inner side; its cross
        // position and size are set per orientation in `applyBarFrame`. The icon
        // stack fills the window along the bar and is *centered on the bar's cross
        // axis* (see `applyBarFrame`), so icons sit centered on the visible bar; a
        // hovered icon still magnifies INWARD (see `DockButton.edgeAnchoredScale`)
        // into the spare room `panelSize` leaves on the inner side — never outward
        // past the screen edge onto a vertically-stacked neighbouring display. The
        // stack's own constraints are (re)built per orientation in `applyBarFrame`.
        contentView = container
        applyOrientation() // needs `effect` in the container (frames the bar + stack)
        applyDockTint()
    }

    func show() {
        orderFrontRegardless()
        reposition()
        applyAutoHide() // install the pointer monitor + start the countdown if enabled
    }

    /// Re-apply preference-driven appearance to the live panel (material, corner
    /// radius, spacing, orientation) and invalidate the rebuild cache so the next
    /// `update` picks up new icon sizes / dimming too.
    func applyAppearance() {
        let prefs = Preferences.shared
        effect.material = prefs.barMaterial.material
        effect.layer?.cornerRadius = CGFloat(prefs.cornerRadius)
        applyDockOutline()
        applyDockTint() // tint + corner radius (default, override, or reset may have changed)
        stack.spacing = CGFloat(prefs.iconSpacing)
        applyOrientation()
        apps = [] // force update() to rebuild rather than treat contents as unchanged
        applyAutoHide() // the auto-hide settings may have changed
    }

    /// Draws (or clears) the outline around the whole bar. A `borderWidth` of 0
    /// leaves the bar borderless; the border follows the bar's corner radius. This
    /// is the bar's own outline — separate from each running app's box outline.
    private func applyDockOutline() {
        let prefs = Preferences.shared
        effect.layer?.borderWidth = CGFloat(prefs.dockOutlineWidth)
        effect.layer?.borderColor = prefs.dockOutlineColor.cgColor
    }

    /// Paint the dock's background tint for the current desktop. When the dock is
    /// tinted (a per-desktop override, or the default tint switched on) the bar
    /// becomes the chosen color and `effect`'s opacity is set to that color's alpha,
    /// so the opacity fades the *whole* bar — the frosted blur included — and 0%
    /// opacity is fully transparent rather than a grey blur. Untinted, the bar shows
    /// its plain material at full opacity. The overlay tracks the bar's corner radius
    /// so the tint stays inside the rounded bar.
    private func applyDockTint() {
        let prefs = Preferences.shared
        tintOverlay.layer?.cornerRadius = CGFloat(prefs.cornerRadius)
        tintOverlay.layer?.masksToBounds = true
        // Reduce Transparency: cover the blur with a solid fill so the bar reads
        // fully opaque. Use the user's tint colour at full opacity if they set one,
        // else the standard window background.
        if SystemDisplay.reduceTransparency {
            effect.alphaValue = 1
            let base = prefs.isDockTinted(forSpace: spaceUUID)
                ? prefs.effectiveDockTint(forSpace: spaceUUID)
                : NSColor.windowBackgroundColor
            tintOverlay.layer?.backgroundColor = (base.usingColorSpace(.sRGB) ?? base)
                .withAlphaComponent(1).cgColor
            return
        }
        if prefs.isDockTinted(forSpace: spaceUUID) {
            let color = prefs.effectiveDockTint(forSpace: spaceUUID)
            effect.alphaValue = color.alphaComponent
            tintOverlay.layer?.backgroundColor = color.cgColor
        } else {
            effect.alphaValue = 1
            tintOverlay.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    /// Sets the icon stack's axis (and matching insets) from the current bar
    /// position: horizontal for top/bottom, vertical for left/right.
    private func applyOrientation() {
        let vertical = Preferences.shared.barPosition.isVertical
        stack.orientation = vertical ? .vertical : .horizontal
        // Pad only along the bar's length (the ends); the thickness comes entirely
        // from "Dock height" so the smallest setting can hug the icons with zero
        // cross padding. Cross axis = top/bottom for a horizontal bar, left/right
        // for a vertical one.
        stack.edgeInsets = vertical
            ? NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
            : NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        // Center icons across the bar so they stay centered when "Dock height" (or
        // the hover headroom in `panelSize`) makes the bar/window thicker than an
        // icon. The stack is pinned to the bar's cross *center* (not the window's) in
        // `applyBarFrame`, so "centered" means centered on the visible bar — which
        // hugs the screen edge — rather than on the taller window. A hovered icon
        // still magnifies inward via `DockButton.edgeAnchoredScale`, so it never
        // grows past the screen edge.
        stack.alignment = vertical ? .centerX : .centerY
        applyBarFrame()
    }

    /// The stack's size across the bar: the icon height for a horizontal bar, or
    /// the widest item (a labeled pill can be wider than an icon) for a vertical
    /// one. This is the smallest the bar can be without clipping its contents.
    private func contentCross() -> CGFloat {
        let fitting = stack.fittingSize
        return Preferences.shared.barPosition.isVertical ? fitting.width : fitting.height
    }

    /// The visible bar's thickness: the user's "Dock height", but never thinner
    /// than its contents, so the smallest setting hugs the icons exactly.
    private func barThickness() -> CGFloat {
        max(CGFloat(Preferences.shared.dockHeight), contentCross())
    }

    /// Frames the blur to `barThickness` across and the full window length along
    /// its axis, pinned to the window's OUTER edge so any spare window room (hover
    /// headroom) sits on the inner side and the bar never overhangs the screen edge.
    /// Also (re)builds the icon stack's constraints: it fills the window along the
    /// bar and is centered on the bar's cross axis, so icons sit centered on the
    /// visible bar even when the bar is thicker than an icon.
    private func applyBarFrame() {
        let pos = Preferences.shared.barPosition
        let vertical = pos.isVertical
        effectAlong?.isActive = false
        effectAlongCenter?.isActive = false
        effectThickness?.isActive = false
        effectCross?.isActive = false
        stackAlongStart?.isActive = false
        stackAlongEnd?.isActive = false
        stackCrossCenter?.isActive = false
        if vertical {
            effectAlong = effect.heightAnchor.constraint(equalTo: container.heightAnchor)
            effectAlongCenter = effect.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            effectThickness = effect.widthAnchor.constraint(equalToConstant: barThickness())
            // Stack fills the window top→bottom (along the bar) and centers on the
            // bar's width, so its icons sit centered on the visible bar.
            stackAlongStart = stack.topAnchor.constraint(equalTo: container.topAnchor)
            stackAlongEnd = stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            stackCrossCenter = stack.centerXAnchor.constraint(equalTo: effect.centerXAnchor)
        } else {
            effectAlong = effect.widthAnchor.constraint(equalTo: container.widthAnchor)
            effectAlongCenter = effect.centerXAnchor.constraint(equalTo: container.centerXAnchor)
            effectThickness = effect.heightAnchor.constraint(equalToConstant: barThickness())
            stackAlongStart = stack.leadingAnchor.constraint(equalTo: container.leadingAnchor)
            stackAlongEnd = stack.trailingAnchor.constraint(equalTo: container.trailingAnchor)
            stackCrossCenter = stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor)
        }
        // Pin the bar to the window's OUTER edge so all hover headroom falls on the
        // inner side and the window (placed by `origin`) never crosses the screen's
        // outer edge onto a vertically-stacked neighbouring display.
        switch pos {
        case .bottom: effectCross = effect.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        case .top:    effectCross = effect.topAnchor.constraint(equalTo: container.topAnchor)
        case .left:   effectCross = effect.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        case .right:  effectCross = effect.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        }
        effectAlong?.isActive = true
        effectAlongCenter?.isActive = true
        effectThickness?.isActive = true
        effectCross?.isActive = true
        stackAlongStart?.isActive = true
        stackAlongEnd?.isActive = true
        stackCrossCenter?.isActive = true
    }

    /// The window size for the current stack. Along the bar it fits the icons; the
    /// cross axis (the "height") is the bar thickness, but widened to leave room
    /// for a hovered icon to magnify past a snug bar instead of being clipped at
    /// the window edge. When the bar is already taller than the magnified icon this
    /// adds nothing. The visible bar itself stays `barThickness` (see `applyBarFrame`).
    private func panelSize() -> NSSize {
        let prefs = Preferences.shared
        let bar = barThickness()
        // The bar's own cross size, before any reserves. With hover off there's
        // nothing to spill, so the window hugs the bar exactly.
        let baseCross: CGFloat
        var size: NSSize
        if prefs.hoverEnabled {
            // Icons rest centered on the bar, so a resting icon's outer edge sits
            // `(bar - content)/2` in from the window's outer edge and the magnify
            // grows inward from there (`DockButton.edgeAnchoredScale`). Reserve that
            // offset plus the magnified height, and a little extra past the pure
            // magnified size so the icon's inner edge isn't flush against the window
            // (which would nip its anti-aliasing).
            let content = contentCross()
            let restOffset = max(0, (bar - content) / 2)
            let hoverThickness = restOffset + content * CGFloat(prefs.hoverScale) + DockPanel.hoverHeadroom
            baseCross = max(bar, hoverThickness)
            size = stack.fittingSize
        } else {
            baseCross = bar
            size = barSizedWindow(bar)
        }
        // Symmetric reserve keeps the bar centered while giving a floating ("above
        // the dock") desktop indicator room; 0 for the in-row placements.
        let windowCross = baseCross + 2 * indicatorReserve
        if prefs.barPosition.isVertical {
            size.width = windowCross
        } else {
            size.height = windowCross
        }
        return padded(size)
    }

    // MARK: - Current-desktop indicator

    /// Place the "Desktop N" badge per the user's chosen position: as a reserved slot
    /// inside the icon row (start / end / centered), or floated just off the bar's
    /// inner edge ("above the dock"). Called from `rebuild` so the badge re-homes
    /// after the row is torn down and rebuilt. Removes the badge entirely when the
    /// indicator is turned off.
    private func layOutDesktopIndicator() {
        desktopIndicator.removeFromSuperview() // also drops its old constraints
        indicatorReserve = 0
        let prefs = Preferences.shared
        guard prefs.desktopIndicatorEnabled else { return }
        desktopIndicator.translatesAutoresizingMaskIntoConstraints = false
        if prefs.desktopIndicatorPosition.isInsideDock {
            let count = stack.arrangedSubviews.count
            let index: Int
            switch prefs.desktopIndicatorPosition {
            case .dockLeading: index = 0
            case .dockTrailing: index = count
            case .dockCenter: index = count / 2
            case .aboveDock: index = count // unreachable: isInsideDock is false here
            }
            stack.insertArrangedSubview(desktopIndicator, at: min(index, count))
            updateDesktopIndicator()
            return
        }
        // Floating ("above the dock"): pin it just off the bar's inner edge and
        // reserve cross-axis room so it isn't clipped at the window edge.
        container.addSubview(desktopIndicator)
        let gap: CGFloat = 6
        let constraints: [NSLayoutConstraint]
        switch prefs.barPosition {
        case .bottom:
            constraints = [desktopIndicator.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
                           desktopIndicator.bottomAnchor.constraint(equalTo: effect.topAnchor, constant: -gap)]
        case .top:
            constraints = [desktopIndicator.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
                           desktopIndicator.topAnchor.constraint(equalTo: effect.bottomAnchor, constant: gap)]
        case .left:
            constraints = [desktopIndicator.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
                           desktopIndicator.leadingAnchor.constraint(equalTo: effect.trailingAnchor, constant: gap)]
        case .right:
            constraints = [desktopIndicator.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
                           desktopIndicator.trailingAnchor.constraint(equalTo: effect.leadingAnchor, constant: -gap)]
        }
        NSLayoutConstraint.activate(constraints)
        updateDesktopIndicator() // set text first so its intrinsic size is known
        let extent = prefs.barPosition.isVertical
            ? desktopIndicator.intrinsicContentSize.width
            : desktopIndicator.intrinsicContentSize.height
        indicatorReserve = extent + gap
    }

    /// Refresh the badge's text for the current desktop and placement.
    private func updateDesktopIndicator() {
        desktopIndicator.setNumber(desktopNumber,
                                   compact: Preferences.shared.desktopIndicatorPosition.isInsideDock)
    }

    /// When the dock would otherwise be empty (no apps, no launcher tile, no in-row
    /// indicator), show a faint hint instead of a bare sliver, so a new desktop
    /// doesn't look broken and the pin gesture is discoverable. Cleared on the next
    /// rebuild like any other item.
    private func addEmptyHintIfNeeded() {
        guard stack.arrangedSubviews.isEmpty else { return }
        let hint = NSTextField(labelWithString: "Drag an app here to pin it")
        hint.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.isEditable = false
        hint.isSelectable = false
        stack.addArrangedSubview(hint)
    }

    /// Adds the transient `animationCrossPad` to the cross axis. The window's outer
    /// edge is pinned at the edge gap (see `origin(forSize:)`), so this extra room
    /// grows on the INNER side — it never pushes the bar past the screen edge.
    private func padded(_ size: NSSize) -> NSSize {
        guard animationCrossPad > 0 else { return size }
        var size = size
        if Preferences.shared.barPosition.isVertical { size.width += 2 * animationCrossPad }
        else { size.height += 2 * animationCrossPad }
        return size
    }

    /// A window exactly `thickness` across (no hover headroom), fitting the icons
    /// along its length.
    private func barSizedWindow(_ thickness: CGFloat) -> NSSize {
        var size = stack.fittingSize
        if Preferences.shared.barPosition.isVertical { size.width = thickness }
        else { size.height = thickness }
        return size
    }

    /// Slack added around a magnified icon so its edge isn't flush with the window.
    private static let hoverHeadroom: CGFloat = 6

    /// Push the latest desired contents to the bar. `animateChanges` plays the
    /// join/leave animation for any icon that's arriving or departing — a whole app
    /// (launched / quit / pinned / unpinned) or, with the "Windows" feature on, a
    /// single per-window copy as the app gains or loses a window; the caller turns
    /// it off on a Space switch, where the whole list changes at once and a per-icon
    /// animation would be wrong.
    func update(apps: [DockApp], animateChanges: Bool = true) {
        // Don't rebuild out from under an in-progress drag (reorder or drag-in) —
        // we'll pick up the saved order on the refresh that follows the drop.
        guard !isReordering, !isExternalDragging else { return }
        // An animation is mid-flight: remember the latest target and apply it on
        // completion rather than rebuilding the bar out from under it.
        if isAnimating { pendingApps = apps; return }
        // The 2s poll calls this constantly. Rebuilding the buttons every time
        // tears down the one under the cursor mid-hover, restarting its magnify
        // animation. Only rebuild when the contents actually changed.
        guard apps != self.apps else { return }
        let prefs = Preferences.shared
        // Consume the one-shot drop suppression (a just-dropped app brought its own
        // slot-open animation from the drag, so don't re-animate it in).
        let suppressAdd = suppressAddAnimationOnce
        suppressAddAnimationOnce = false
        // Animate only genuine arrivals/departures, never the initial populate or
        // a Space switch (the whole list changing at once).
        let canAnimate = animateChanges && !self.apps.isEmpty && prefs.iconAnimationSpeed > 0.001
            && !SystemDisplay.reduceMotion // skip join/leave animation under Reduce Motion
        // Leaving wins when both happen at once: play the departures out, then the
        // follow-up rebuild brings any arrivals in (without animating them).
        if canAnimate, prefs.animateOnRemove {
            let leaving = removedButtons(forNewApps: apps)
            if !leaving.isEmpty {
                animateRemoval(of: leaving, then: apps)
                return
            }
        }
        // Apps *joining* the dock: build the new layout, then open their slots and
        // let the icons appear — the bar grows to fit.
        if canAnimate, prefs.animateOnAdd, !suppressAdd {
            let entering = enteringKeys(forNewApps: apps)
            if !entering.isEmpty {
                rebuild(apps: apps, animatingIn: entering)
                return
            }
        }
        rebuild(apps: apps)
    }

    /// Tear down and rebuild the icon stack for `apps`, then resize the window to
    /// fit. When `animatingIn` lists arriving `slotKey`s, their buttons start
    /// collapsed + hidden and `animateAddition` opens them instead of resizing
    /// instantly. The plain (un-animated) path otherwise; the removal animation
    /// also calls it last.
    private func rebuild(apps: [DockApp], animatingIn entering: Set<String> = []) {
        let prefs = Preferences.shared
        let side = CGFloat(prefs.iconSize)
        let dim = CGFloat(prefs.dimLevel)
        // Two ways to flag running apps (mutually exclusive): dim the not-running
        // ones, or box the running ones. Boxed style does no dimming.
        let boxed = prefs.runningIndicator == .boxed
        // Snapshot the outgoing icons' widths by `slotKey` *before* the teardown,
        // so an icon that survives a window-count change — e.g. it widens into a
        // labeled pill when its app gains a second window — can animate from its
        // old width instead of snapping to the new one.
        let oldWidths = Dictionary(
            stack.arrangedSubviews.compactMap { view -> (String, CGFloat)? in
                guard let button = view as? DockButton, let key = button.slotKey,
                      let width = button.widthConstraint?.constant else { return nil }
                return (key, width)
            }, uniquingKeysWith: { first, _ in first })
        self.apps = apps
        let keys = slotKeys(of: apps)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var entered: [DockButton] = []
        // Survivors whose width changes this rebuild (paired with the width they
        // start from), animated alongside an arrival so the bar grows smoothly.
        var morphs: [(button: DockButton, from: CGFloat)] = []
        for (app, slotKey) in zip(apps, keys) {
            // Wide window-label mode: a labeled item is a wider pill with the
            // window's title in white next to a smaller icon (like the Windows
            // taskbar). Decided per app, so "multiple windows" scope can mix wide
            // labeled items with plain single-window icons. The launcher tile is
            // never labeled (it stands for no window) and never dimmed (it's not a
            // running/pinned app — it's always live).
            let labeled = !app.isLauncher && prefs.showsWindowLabel(windowCount: app.windowCount)
            let width = labeled ? CGFloat(prefs.windowLabelWidth) : side
            let button = DockButton()
            button.isBordered = false
            // Own our layer from birth (the window is only *implicitly* layer-backed
            // via the blur view). `allowsImplicitAnimation` animates a view's layer
            // only when the view owns it, so a button that first gains layer-backing
            // inside the leave animation's group would snap rather than animate. Set
            // it here — a full poll/runloop before any removal — so the layer is
            // realised and the disappear (fade / shrink / poof / slide) actually plays.
            button.wantsLayer = true
            button.imageScaling = .scaleProportionallyUpOrDown
            button.image = icon(for: app)
            button.toolTip = tooltip(for: app)
            // Dimmed style fades pinned shortcuts; boxed style frames the running
            // apps instead and leaves everyone at full opacity. The launcher tile
            // is always live (not a running/pinned app), so it's never dimmed and
            // never gets a running box.
            button.alphaValue = (boxed || app.isLauncher || app.isRunning) ? 1.0 : dim
            if boxed {
                button.setRunningBox(active: app.isRunning,
                                     gap: CGFloat(prefs.boxGap),
                                     outlineWidth: CGFloat(prefs.boxOutlineWidth),
                                     outlineColor: prefs.boxOutlineColor,
                                     highlightColor: prefs.boxHighlightColor)
            }
            button.app = app
            button.slotKey = slotKey
            if labeled { applyLabel(to: button, app: app, side: side) }
            // A window-count badge for an app with several windows here — but only
            // when we're not already showing one icon per window (which would make
            // the count redundant), and never on the launcher tile.
            let perWindow = prefs.showIconPerWindow || prefs.showWindowLabels
            if !perWindow, !app.isLauncher, app.windowCount > 1 {
                button.setWindowBadge(count: app.windowCount)
            }
            button.onActivate = { [weak self] app, forceNew in
                if app.isLauncher { self?.onOpenLauncher?() } else { self?.onSelect?(app, forceNew) }
            }
            button.onRightClick = { [weak self] in self?.showMenu(for: app, from: button) }
            button.onMiddleClick = { [weak self] in self?.handleMiddleClick(app) }
            button.onBeginDrag = { [weak self] in self?.beginReorder($0) }
            button.onDragMove = { [weak self] in self?.updateReorder($0, at: $1) }
            button.onEndDrag = { [weak self] in self?.endReorder($0) }
            button.translatesAutoresizingMaskIntoConstraints = false
            let wc = button.widthAnchor.constraint(equalToConstant: width)
            let hc = button.heightAnchor.constraint(equalToConstant: side)
            wc.isActive = true
            hc.isActive = true
            button.widthConstraint = wc
            button.heightConstraint = hc
            stack.addArrangedSubview(button)
            if entering.contains(slotKey) {
                entered.append(button)
            } else if let from = oldWidths[slotKey], abs(from - width) > 0.5 {
                // A surviving icon that changed width (e.g. an app's first icon
                // morphing into a labeled pill as a second window opens).
                morphs.append((button, from))
            }
        }
        layOutDesktopIndicator() // (re)home the "Desktop N" badge for this layout
        addEmptyHintIfNeeded() // a gentle hint when the desktop's dock is otherwise empty
        layoutIfNeeded()
        effectThickness?.constant = barThickness() // now that the icons set the content size
        // Arrivals: open their slots and let them appear (the bar grows to fit).
        // Otherwise size the window to the finished layout right away.
        if entered.isEmpty {
            setContentSize(panelSize())
            reposition()
            // The window now has transparent margin around a centered bar;
            // recompute the shadow so it hugs the bar instead of the full window.
            invalidateShadow()
        } else {
            animateAddition(of: entered, morphing: morphs)
        }
    }

    // MARK: - Join / leave animation

    /// A per-icon identity for the join/leave diff: an app's `orderKey` plus which
    /// of its windows the icon stands for (`#0` for the first / only one). Per-window
    /// copies (the "Windows" feature) share an `orderKey`, so the trailing ordinal is
    /// what distinguishes "a second window just opened" (one icon joins) from "the
    /// app just launched" (the whole app arrives). The `#0` icon keeps a stable key
    /// across a window-count change, so the original icon *morphs into* it rather
    /// than vanishing and reappearing when a second window opens.
    private func slotKeys(of apps: [DockApp]) -> [String] {
        var seen: [String: Int] = [:]
        return apps.map { app in
            let n = seen[app.orderKey, default: 0]
            seen[app.orderKey] = n + 1
            return "\(app.orderKey)#\(n)"
        }
    }

    /// The live buttons whose icon has no counterpart in `newApps` — its app left
    /// the dock (quit, unpin, last window closed), or one of the app's per-window
    /// copies went away because a window closed. Keyed on `slotKey`, so a window
    /// closing animates just the icon that left instead of rebuilding silently.
    private func removedButtons(forNewApps newApps: [DockApp]) -> [DockButton] {
        let surviving = Set(slotKeys(of: newApps))
        return stack.arrangedSubviews
            .compactMap { $0 as? DockButton }
            .filter { button in
                guard let key = button.slotKey else { return false }
                return !surviving.contains(key)
            }
    }

    /// The `slotKey`s of icons that are *new* to the dock — present in `newApps`
    /// but not currently shown. A whole app arriving brings all its icons; an app
    /// opening a second window brings just the one new per-window copy.
    private func enteringKeys(forNewApps newApps: [DockApp]) -> Set<String> {
        let current = Set(slotKeys(of: apps))
        return Set(slotKeys(of: newApps)).subtracting(current)
    }

    /// Each icon's width for `apps`, keyed by `slotKey`: a labeled pill is wider
    /// than a plain icon. Lets the removal animation ease a surviving icon to the
    /// width it will have once the layout settles (e.g. a two-window app's pill
    /// narrowing back to a plain icon as it drops to one window).
    private func widthsBySlot(for apps: [DockApp]) -> [String: CGFloat] {
        let prefs = Preferences.shared
        let side = CGFloat(prefs.iconSize)
        var result: [String: CGFloat] = [:]
        for (app, key) in zip(apps, slotKeys(of: apps)) {
            let labeled = !app.isLauncher && prefs.showsWindowLabel(windowCount: app.windowCount)
            result[key] = labeled ? CGFloat(prefs.windowLabelWidth) : side
        }
        return result
    }

    /// The squared distance from `point` to a button's center — enough to compare
    /// which surviving icon a leaving one is closest to, without the `sqrt`.
    private func squaredDistance(from point: CGPoint, to button: DockButton) -> CGFloat {
        let dx = button.frame.midX - point.x, dy = button.frame.midY - point.y
        return dx * dx + dy * dy
    }

    /// Play the leave-the-dock animation for `buttons`, then rebuild to `apps`.
    /// Two beats: the icons disappear in place (per `iconAnimationStyle`), then
    /// the bar closes the gap and shrinks to fit. The poll is frozen throughout
    /// (`isAnimating`) so it can't rebuild mid-animation.
    private func animateRemoval(of buttons: [DockButton], then apps: [DockApp]) {
        isAnimating = true
        let prefs = Preferences.shared
        let duration = prefs.iconAnimationSpeed
        let style = prefs.iconAnimationStyle
        let slide = slideOffVector()
        // Surviving icons that change width once the leaving ones are gone — e.g. an
        // app dropping from two windows to one, its labeled pill narrowing back to a
        // plain icon. Eased to their settled width during the shrink so they don't
        // snap when the follow-up rebuild swaps them out.
        let leaving = Set(buttons.map(ObjectIdentifier.init))
        let settledWidths = widthsBySlot(for: apps)
        let survivorMorphs: [(button: DockButton, to: CGFloat)] = stack.arrangedSubviews.compactMap { view in
            guard let button = view as? DockButton, !leaving.contains(ObjectIdentifier(button)),
                  let key = button.slotKey, let to = settledWidths[key],
                  let from = button.widthConstraint?.constant, abs(from - to) > 0.5 else { return nil }
            return (button, to)
        }
        // A per-window icon leaving (a window closed but its app keeps another icon)
        // folds into the nearest surviving icon of the same app instead of sliding
        // off-screen. Map each such leaver to the offset toward that sibling, taken
        // now while every slot is still open and at its resting position.
        let survivors = stack.arrangedSubviews.compactMap { $0 as? DockButton }
            .filter { !leaving.contains(ObjectIdentifier($0)) }
        let mergeOffsets: [ObjectIdentifier: CGVector] = Dictionary(
            uniqueKeysWithValues: buttons.compactMap { button -> (ObjectIdentifier, CGVector)? in
                guard let key = button.app?.orderKey else { return nil }
                let center = CGPoint(x: button.frame.midX, y: button.frame.midY)
                let sibling = survivors
                    .filter { $0.app?.orderKey == key }
                    .min { squaredDistance(from: center, to: $0) < squaredDistance(from: center, to: $1) }
                guard let sibling else { return nil }
                return (ObjectIdentifier(button),
                        CGVector(dx: sibling.frame.midX - center.x, dy: sibling.frame.midY - center.y))
            })
        // Pure per-window removal (every leaver folds into a surviving sibling): do
        // it in a *single* beat — shrink + fade each leaver while its slot closes and
        // the survivors slide/morph — so the neighbours move in sync with the fold.
        // The two-beat path below (disappear in place, then close the gap) would
        // instead leave the right-hand neighbour still during beat 1 and lurch it
        // over in beat 2. Whole-app departures keep that two-beat path.
        if !buttons.isEmpty, buttons.allSatisfy({ mergeOffsets[ObjectIdentifier($0)] != nil }) {
            let vertical = prefs.barPosition.isVertical
            let along: (DockButton) -> NSLayoutConstraint? = { vertical ? $0.heightConstraint : $0.widthConstraint }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                buttons.forEach { button in
                    button.playMerge(toward: .zero) // shrink + fade in place...
                    along(button)?.constant = 0     // ...as its slot closes, folding it toward the sibling
                }
                for morph in survivorMorphs { morph.button.widthConstraint?.constant = morph.to }
                self.layoutIfNeeded()
                self.effectThickness?.constant = self.barThickness()
                self.sizeWindowToStack()
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isAnimating = false
                    let target = self.pendingApps ?? apps
                    self.pendingApps = nil
                    self.rebuild(apps: target)
                }
            })
            return
        }
        // Open transparent room (seamlessly — the bar doesn't move) so a poof's
        // growth or a slide's travel is drawn instead of clipped at the window edge.
        animationCrossPad = CGFloat(prefs.iconSize)
        setContentSize(panelSize())
        reposition()
        invalidateShadow()
        // Beat 1: the leaving icons disappear where they sit (their slots stay open).
        // A per-window copy folds into its surviving sibling; a whole-app departure
        // uses the user's chosen disappear style.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            buttons.forEach { button in
                if let offset = mergeOffsets[ObjectIdentifier(button)] {
                    button.playMerge(toward: offset)
                } else {
                    button.playDisappear(style: style, slideOff: slide)
                }
            }
        }, completionHandler: { [weak self] in
            // Animation completion fires on the main actor.
            MainActor.assumeIsolated {
                guard let self else { return }
                // Beat 2: drop them from the layout so the neighbors slide together and
                // the bar shrinks to fit — all animated. Closing the pad here lets the
                // window shrink back to its snug size in the same motion.
                buttons.forEach { $0.removeFromSuperview() }
                self.animationCrossPad = 0
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = duration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    ctx.allowsImplicitAnimation = true
                    for morph in survivorMorphs { morph.button.widthConstraint?.constant = morph.to }
                    self.layoutIfNeeded()
                    self.effectThickness?.constant = self.barThickness()
                    self.sizeWindowToStack()
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.isAnimating = false
                        // Rebuild to the freshest target so anything that changed during
                        // the animation lands. For a plain quit this matches what's already
                        // on screen, so it's a seamless (invisible) rebuild.
                        let target = self.pendingApps ?? apps
                        self.pendingApps = nil
                        self.rebuild(apps: target)
                    }
                })
            }
        })
    }

    /// Play the join-the-dock animation for freshly built `buttons` (already in
    /// the stack at full size). Mirror of `animateRemoval`: beat 1 collapses their
    /// slots to nothing and reopens them — neighbours slide apart and the bar
    /// grows — then beat 2 materialises the icons in the opened slots. The poll is
    /// frozen throughout (`isAnimating`).
    private func animateAddition(of buttons: [DockButton], morphing morphs: [(button: DockButton, from: CGFloat)] = []) {
        isAnimating = true
        let prefs = Preferences.shared
        let duration = prefs.iconAnimationSpeed
        let style = prefs.iconAnimationStyle
        let slide = slideOffVector()
        // Open transparent room (seamlessly — the bar doesn't move) so an arriving
        // icon's poof / slide-in is drawn instead of clipped at the window edge. It's
        // folded into every window size below and closed again when the animation ends.
        animationCrossPad = CGFloat(prefs.iconSize)
        let vertical = prefs.barPosition.isVertical
        // The slot opens along the bar's layout axis: width for a horizontal bar,
        // height for a vertical one.
        let along: (DockButton) -> NSLayoutConstraint? = { vertical ? $0.heightConstraint : $0.widthConstraint }
        let targets = buttons.map { along($0)?.constant ?? 0 }
        // A surviving icon that widens into a labeled pill as the newcomer arrives:
        // capture its settled width, then roll it back to its old width so the bar
        // grows from the true pre-change size and eases out (rather than snapping
        // wide) alongside the slot opening.
        let morphTargets = morphs.map { $0.button.widthConstraint?.constant ?? 0 }
        for morph in morphs { morph.button.widthConstraint?.constant = morph.from }
        // Start collapsed + hidden, and size the window as if the newcomers weren't
        // there yet (so it grows from the pre-arrival size).
        for button in buttons {
            button.wantsLayer = true
            button.layer?.opacity = 0
            along(button)?.constant = 0
        }
        layoutIfNeeded()
        effectThickness?.constant = barThickness()
        setContentSize(panelSize())
        reposition()
        invalidateShadow()
        // Beat 1: open the slots and grow the bar to fit.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            for (button, target) in zip(buttons, targets) { along(button)?.constant = target }
            for (morph, target) in zip(morphs, morphTargets) { morph.button.widthConstraint?.constant = target }
            self.layoutIfNeeded()
            self.sizeWindowToStack()
        }, completionHandler: { [weak self] in
            // Animation completion fires on the main actor.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.layoutIfNeeded() // settle the now-open slots so bounds are full-size
                // Beat 2: the icons appear in place (now that their slots are open).
                buttons.forEach { $0.prepareToAppear(style: style, slideOff: slide) }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = duration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    ctx.allowsImplicitAnimation = true
                    buttons.forEach { $0.playAppear() }
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.isAnimating = false
                        // Close the transparent room back to the snug fit (the bar doesn't
                        // move, so this is invisible).
                        self.animationCrossPad = 0
                        self.setContentSize(self.panelSize())
                        self.reposition()
                        self.invalidateShadow()
                        // Apply anything that arrived mid-animation; otherwise the stack
                        // already matches `self.apps`, so there's nothing more to do.
                        if let target = self.pendingApps {
                            self.pendingApps = nil
                            if target != self.apps { self.rebuild(apps: target) }
                        }
                    }
                })
            }
        })
    }

    /// Unit direction a `.slideOff` icon flies — toward the screen edge the bar
    /// hugs. View coordinates are unflipped (y grows upward), so a bottom bar
    /// slides its leaving icons downward.
    private func slideOffVector() -> CGVector {
        switch Preferences.shared.barPosition {
        case .bottom: return CGVector(dx: 0, dy: -1)
        case .top:    return CGVector(dx: 0, dy: 1)
        case .left:   return CGVector(dx: -1, dy: 0)
        case .right:  return CGVector(dx: 1, dy: 0)
        }
    }

    // MARK: - Drag-to-reorder

    private func beginReorder(_ button: DockButton) {
        isReordering = true
        button.setLifted(true)
    }

    /// Slides the dragged icon to the slot the cursor is over, shifting the
    /// others aside. Driven live as the pointer moves.
    private func updateReorder(_ button: DockButton, at locationInWindow: NSPoint) {
        guard let current = stack.arrangedSubviews.firstIndex(of: button) else { return }
        let target = slotIndex(forCursorAt: locationInWindow, ignoring: button)
        guard target != current else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.allowsImplicitAnimation = true
            stack.removeArrangedSubview(button)
            stack.insertArrangedSubview(button, at: target)
            layoutIfNeeded()
        }
    }

    private func endReorder(_ button: DockButton) {
        button.setLifted(false)
        let reordered = stack.arrangedSubviews.compactMap { ($0 as? DockButton)?.app }
        apps = reordered // keep our cache in step so the follow-up refresh is a no-op
        isReordering = false
        // With the "Windows" feature on, an app can occupy several adjacent
        // buttons; collapse them to one key per app (first occurrence wins) so
        // the saved arrangement stays one entry per app.
        onReorder?(reordered.map(\.orderKey).uniqued())
    }

    // MARK: - Drag-in (an .app dragged onto the bar)

    /// Animation duration for opening/moving/closing the slot — matched to the
    /// reorder slide so dragging in and reordering feel like one gesture.
    private static let slotAnimation: TimeInterval = 0.16

    /// Tracks the cursor of an incoming .app drag: opens an empty slot under it
    /// the first time, then slides that slot between icons as the cursor moves so
    /// the dragged app always has a place to land.
    private func updateDragSlot(at locationInWindow: NSPoint) {
        isExternalDragging = true
        let target = slotIndex(forCursorAt: locationInWindow, ignoring: dragGap)
        if dragGap == nil { openDragGap(at: target); return }
        moveDragGap(to: target)
    }

    /// Inserts a collapsed spacer at `index` and animates it (and the panel) open
    /// by one icon, so the existing icons part to reveal an empty slot. The spacer
    /// grows along the layout axis: width for a horizontal bar, height for a
    /// vertical one.
    private func openDragGap(at index: Int) {
        let side = CGFloat(Preferences.shared.iconSize)
        let vertical = Preferences.shared.barPosition.isVertical
        let gap = NSView()
        gap.translatesAutoresizingMaskIntoConstraints = false
        // `grow` opens the slot along the axis; the cross-axis stays one icon wide.
        let grow = (vertical ? gap.heightAnchor : gap.widthAnchor).constraint(equalToConstant: 0)
        let cross = (vertical ? gap.widthAnchor : gap.heightAnchor).constraint(equalToConstant: side)
        NSLayoutConstraint.activate([grow, cross])
        dragGap = gap
        dragGapSize = grow
        stack.insertArrangedSubview(gap, at: min(index, stack.arrangedSubviews.count))
        layoutIfNeeded() // settle collapsed before animating it open
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DockPanel.slotAnimation
            ctx.allowsImplicitAnimation = true
            grow.constant = side
            layoutIfNeeded()
            sizeWindowToStack()
        }
    }

    /// Slides the open slot to a new index (no resize — the panel already has
    /// room for the slot; only the icons on either side shift).
    private func moveDragGap(to index: Int) {
        guard let gap = dragGap, stack.arrangedSubviews.firstIndex(of: gap) != index else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DockPanel.slotAnimation
            ctx.allowsImplicitAnimation = true
            stack.removeArrangedSubview(gap)
            stack.insertArrangedSubview(gap, at: min(index, stack.arrangedSubviews.count))
            layoutIfNeeded()
        }
    }

    /// The drag left without dropping: animate the slot shut and shrink the panel
    /// back, then drop the spacer.
    private func closeDragSlot() {
        guard let gap = dragGap, let size = dragGapSize else { isExternalDragging = false; return }
        dragGap = nil
        dragGapSize = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DockPanel.slotAnimation
            ctx.allowsImplicitAnimation = true
            size.constant = 0
            layoutIfNeeded()
            sizeWindowToStack()
        }, completionHandler: { [weak self] in
            // Animation completion fires on the main actor.
            MainActor.assumeIsolated {
                gap.removeFromSuperview()
                // Stay frozen until the close finishes so a poll can't rebuild mid-shrink.
                self?.isExternalDragging = false
            }
        })
    }

    /// An .app was dropped: persist it into the slot that's open, then let the
    /// follow-up refresh rebuild the bar with the real icon already in place.
    private func dropApp(_ bundleID: String) {
        let keys = orderKeys(insertingBundleID: bundleID)
        dragGap?.removeFromSuperview()
        dragGap = nil
        dragGapSize = nil
        isExternalDragging = false
        // The drag already opened the slot; don't replay the join animation on the
        // refresh this triggers.
        suppressAddAnimationOnce = true
        onDropApp?(bundleID, keys)
    }

    /// The stack slot the cursor is over: the number of icons sitting ahead of it
    /// along the layout axis, skipping `excluded` (the dragged button while
    /// reordering, or the open gap during a drag-in). Horizontal: icons to the
    /// left. Vertical: icons above — the stack runs top-to-bottom but AppKit's y
    /// grows upward, so "above" is a larger midY than the cursor. Shared by
    /// `updateReorder` and the drag-in slot logic.
    private func slotIndex(forCursorAt locationInWindow: NSPoint, ignoring excluded: NSView?) -> Int {
        let vertical = Preferences.shared.barPosition.isVertical
        let cursor = stack.convert(locationInWindow, from: nil)
        var index = 0
        for view in stack.arrangedSubviews where view !== excluded {
            let ahead = vertical ? (cursor.y < view.frame.midY) : (cursor.x > view.frame.midX)
            if ahead { index += 1 } else { break }
        }
        return index
    }

    /// The full `orderKey` arrangement, in display order, with `bundleID` placed
    /// where the slot is currently open. An icon for the same app (already pinned or
    /// running) is dropped so the dragged-in copy is the only one — letting the
    /// user reposition an existing app by dragging its bundle back in.
    private func orderKeys(insertingBundleID bundleID: String) -> [String] {
        var keys: [String] = []
        for view in stack.arrangedSubviews {
            if view === dragGap {
                keys.append(bundleID)
            } else if let app = (view as? DockButton)?.app, app.orderKey != bundleID {
                keys.append(app.orderKey)
            }
        }
        if !keys.contains(bundleID) { keys.append(bundleID) } // no slot open: append
        return keys
    }

    /// Resizes the panel to exactly fit the stack (including the open slot),
    /// keeping it anchored to its screen edge and centered along the bar's axis —
    /// so a horizontal bar grows wider and a vertical bar grows taller. Animatable
    /// via the surrounding context.
    private func sizeWindowToStack() {
        guard let screen = boundScreen else { return }
        let size = panelSize()
        animator().setFrame(NSRect(origin: placedOrigin(forSize: size, on: screen), size: size),
                            display: true)
        invalidateShadow()
    }

    // MARK: - Rendering helpers

    private func tooltip(for app: DockApp) -> String {
        if app.isLauncher { return "App Launcher (all applications)" }
        // In a per-window mode each item already stands for a single window (and
        // a labeled item shows its full title below), so the "(2)" count would be
        // redundant/misleading on each copy.
        let prefs = Preferences.shared
        let perWindow = prefs.showIconPerWindow || prefs.showWindowLabels
        var text = (prefs.showsWindowLabel(windowCount: app.windowCount) ? app.title : nil) ?? app.name
        if app.windowCount > 1, !perWindow { text += " (\(app.windowCount))" }
        if app.isPinnedEverywhere {
            text += app.isExcludedHere ? " (pinned everywhere, hidden here)" : " (pinned everywhere)"
        } else if app.isPinnedHere { text += " (pinned)" }
        return text
    }

    /// Lay a button out as a wide window-label item: a smaller app icon on the
    /// left and the window's title in white to its right, truncated to fit. Falls
    /// back to the app name when no title is available (e.g. AX not granted). The
    /// active (forefront) window's title is drawn bold so it stands out among the
    /// bars; the rest stay at the regular medium weight.
    private func applyLabel(to button: DockButton, app: DockApp, side: CGFloat) {
        let text = app.title ?? app.name
        let weight: NSFont.Weight = app.isActive ? .bold : .medium
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: Preferences.shared.windowLabelTextColor,
            .font: NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: weight),
        ])
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.alignment = .left
        button.cell?.lineBreakMode = .byTruncatingTail
        button.toolTip = text // full title, in case it's truncated in the bar
        // A smaller icon than the item height, so the title has room beside it.
        if let sized = icon(for: app)?.copy() as? NSImage {
            sized.size = NSSize(width: side * 0.7, height: side * 0.7)
            button.image = sized
        }
    }

    private func icon(for app: DockApp) -> NSImage? {
        if app.isLauncher { return LauncherIcon.image(baseColor: Preferences.shared.launcherIconColor) }
        if let pid = app.pid, let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            return icon
        }
        if let bundleID = app.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(forFile: "/Applications")
    }

    /// Place the panel at its on-edge spot on `boundScreen`. Internal so the app
    /// delegate can re-place surviving docks after a display reconfiguration.
    func reposition() {
        guard let screen = boundScreen else { return }
        // `placedOrigin` keeps a tucked-away (auto-hidden) bar off-screen, so a
        // content rebuild from the poll doesn't yank it back into view.
        setFrameOrigin(placedOrigin(forSize: frame.size, on: screen))
    }

    /// Where the panel's origin goes for a given size, per bar position.
    /// Top/bottom bars center horizontally and hug a horizontal edge; left/right
    /// bars center vertically and hug a vertical edge. (visibleFrame already
    /// excludes the menu bar and the macOS Dock.) Internal so the auto-hide
    /// extension can compute the on-edge spot the bar slides away from.
    func origin(forSize size: NSSize, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        let gap = CGFloat(Preferences.shared.edgeGap)
        // The bar hugs the window's OUTER edge (`applyBarFrame`) with all hover
        // headroom on the inner side, so we anchor the window's outer edge at the
        // edge gap and let the window extend inward. It therefore never crosses the
        // screen's outer edge — which matters when another display is stacked
        // directly beyond it (vertically-aligned screens). The old code pulled the
        // window a `margin` past the edge, so the bar and its magnified icons spilled
        // onto the neighbouring screen.
        switch Preferences.shared.barPosition {
        case .bottom:
            return NSPoint(x: visible.midX - size.width / 2, y: visible.minY + gap)
        case .top:
            return NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - gap)
        case .left:
            return NSPoint(x: visible.minX + gap, y: visible.midY - size.height / 2)
        case .right:
            return NSPoint(x: visible.maxX - size.width - gap, y: visible.midY - size.height / 2)
        }
    }

    // MARK: - Auto-hide state
    //
    // The auto-hide *behaviour* lives in `DockPanel+AutoHide.swift`. Only its
    // stored state and the `deinit` teardown stay here, since a Swift extension
    // can hold neither stored properties nor a `deinit`. These are `internal`
    // (not `private`) so that extension can reach them.

    /// Whether the bar is currently tucked away. The geometry helpers and the
    /// poll's rebuilds consult this so a content refresh keeps a hidden bar hidden.
    enum HideState { case shown, hidden }
    var hideState: HideState = .shown
    /// Whether this bar's screen currently shows a full-screen app. Drives the
    /// full-screen dock behaviour (hide / auto-hide / show); refreshed each tick via
    /// `applyFullscreenState`.
    var fullscreenActive = false
    /// Counts down from the user's "Hide after" delay once the pointer leaves the
    /// bar; firing tucks it away. Scheduled in the default run-loop mode, so (like
    /// the poll) it never fires under an open context menu or mid-drag.
    /// `nonisolated(unsafe)`: installed/invalidated only on the main thread, but also
    /// torn down from the (nonisolated) `deinit`, where main-actor access isn't proven.
    nonisolated(unsafe) var hideTimer: Timer?
    /// Pointer-move taps used to reveal a hidden bar at the screen edge and to
    /// notice when the pointer leaves a shown one. Installed only while auto-hide
    /// is on. The global tap sees moves over other apps; the local one sees moves
    /// over our own bar.
    /// `nonisolated(unsafe)`: installed/removed only on the main thread, but also torn
    /// down from the (nonisolated) `deinit`, where main-actor access isn't proven.
    nonisolated(unsafe) var globalMouseMonitor: Any?
    nonisolated(unsafe) var localMouseMonitor: Any?
    /// Width (points) of the hot strip along the screen edge that reveals a hidden
    /// bar — a few points so a fast flick to the edge still lands inside it.
    static let revealThreshold: CGFloat = 3

    deinit {
        removeMouseMonitor()
        cancelHideTimer()
    }
}

/// A non-interactive overlay view: it never claims a hit, so right-clicks on the
/// bar background (the dock menu) and clicks on icons pass straight through the
/// dock's tint wash to the views beneath it.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
