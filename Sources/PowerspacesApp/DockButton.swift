// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SpaceKit

/// A non-interactive overlay (the window-count badge) that never claims a click, so
/// clicking it still activates the dock icon beneath.
private final class PassthroughBadgeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A dock icon button: reports right-clicks, shows a hover effect, and turns a
/// long-press into a left/right drag so the user can reorder the dock.
final class DockButton: NSButton {
    /// The app this icon stands for. Carried on the button (instead of an index
    /// tag) so it survives the live reordering of the stack view.
    var app: DockApp?
    /// This icon's identity for the join/leave diff: its app's `orderKey` plus
    /// which of the app's windows it stands for. The "Windows" feature duplicates
    /// an app into one icon per window (all sharing an `orderKey`), so this is what
    /// lets a single window opening or closing animate just the icon that changed
    /// instead of silently rebuilding the whole bar.
    var slotKey: String?
    var onRightClick: (() -> Void)?
    /// A middle-click (button 3): runs the user's configured middle-click action.
    var onMiddleClick: (() -> Void)?
    /// A plain click (short press, no drag): activate the app. `forceNew` is set
    /// when shift/option is held.
    var onActivate: ((DockApp, Bool) -> Void)?
    var onBeginDrag: ((DockButton) -> Void)?
    var onDragMove: ((DockButton, NSPoint) -> Void)?
    var onEndDrag: ((DockButton) -> Void)?
    /// The button's own size constraints (set when the dock builds it), held so
    /// the join animation can collapse the icon's slot to zero along the bar's
    /// layout axis and then animate it open.
    var widthConstraint: NSLayoutConstraint?
    var heightConstraint: NSLayoutConstraint?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private(set) var isLifted = false

    /// How long the button must be held before a drag starts: long enough that a
    /// quick click still launches the app, short enough to feel deliberate.
    private static let holdThreshold: TimeInterval = 0.3

    /// Distinguishes a click from a reorder: hold the icon down past
    /// `holdThreshold`, then slide left or right. A short press falls through to
    /// `onActivate`. We run our own event loop (instead of leaning on
    /// `mouseDragged:`) so a perfectly still long-press still "lifts" the icon.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let downTime = Date()
        var dragging = false

        // Periodic events keep the loop ticking even when the pointer never
        // moves, so we notice the hold threshold has elapsed.
        NSEvent.startPeriodicEvents(afterDelay: DockButton.holdThreshold, withPeriod: 0.04)
        defer { NSEvent.stopPeriodicEvents() }

        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .leftMouseDragged, .periodic]
        loop: while let next = window?.nextEvent(matching: mask) {
            switch next.type {
            case .leftMouseUp:
                if dragging { onEndDrag?(self) } else { activate(with: next) }
                break loop
            case .leftMouseDragged, .periodic:
                if !dragging, Date().timeIntervalSince(downTime) >= DockButton.holdThreshold {
                    dragging = true
                    onBeginDrag?(self)
                }
                if dragging, next.type == .leftMouseDragged {
                    onDragMove?(self, next.locationInWindow)
                }
            default:
                break
            }
        }
    }

    private func activate(with event: NSEvent) {
        guard let app else { return }
        let forceNew = Preferences.shared.forceNewModifier.isPressed(event.modifierFlags)
        // Acknowledge a launch / new-window click with a quick Dock-style bounce, so a
        // slow cold launch gives instant feedback. A click that just focuses a window
        // already on this desktop needs none (the window comes forward on its own).
        if !app.isLauncher, forceNew || app.windowCount == 0 { playLaunchFeedback() }
        onActivate?(app, forceNew)
    }

    /// A quick hop toward the screen center (like the macOS Dock's launch bounce),
    /// matching the bar's edge. Auto-reverses back to rest, so it never disturbs
    /// layout. Skipped under Reduce Motion.
    private func playLaunchFeedback() {
        guard !SystemDisplay.reduceMotion else { return }
        wantsLayer = true
        layer?.masksToBounds = false
        let keyPath: String
        let distance: CGFloat
        switch Preferences.shared.barPosition {
        case .bottom: (keyPath, distance) = ("transform.translation.y", 10)
        case .top:    (keyPath, distance) = ("transform.translation.y", -10)
        case .left:   (keyPath, distance) = ("transform.translation.x", 10)
        case .right:  (keyPath, distance) = ("transform.translation.x", -10)
        }
        let bounce = CABasicAnimation(keyPath: keyPath)
        bounce.fromValue = 0
        bounce.toValue = distance
        bounce.duration = 0.16
        bounce.autoreverses = true
        bounce.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(bounce, forKey: "launchBounce")
    }

    /// Visually picks the icon up off the bar while it's being dragged.
    func setLifted(_ on: Bool) {
        guard on != isLifted else { return }
        isLifted = on
        if on { isHovered = false } // re-arm hover bookkeeping for after the drop
        wantsLayer = true
        layer?.masksToBounds = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = SystemDisplay.reduceMotion ? 0 : 0.12 // instant lift under Reduce Motion
            ctx.allowsImplicitAnimation = true
            layer?.transform = on ? centeredScale(1.22) : CATransform3DIdentity
            layer?.backgroundColor = on ? NSColor.white.withAlphaComponent(0.22).cgColor
                                        : NSColor.clear.cgColor
            layer?.shadowOpacity = on ? 0.35 : 0
            layer?.shadowRadius = on ? 8 : 0
            layer?.shadowOffset = on ? CGSize(width: 0, height: -2) : .zero
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.inVisibleRect` lets AppKit keep the tracking region pinned to the
        // view's live bounds, so it stays stable while we're laid out near the
        // panel's edge instead of relying on a snapshot taken at one moment.
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }
    /// Button number 2 is the middle mouse button (0 = left, 1 = right); other
    /// extra buttons are ignored.
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onMiddleClick?() }
    }

    private func setHover(_ on: Bool) {
        // A lifted (being-dragged) icon owns its own larger transform; don't let
        // a stray enter/exit fight it.
        guard !isLifted else { return }
        // Idempotent: a repeated enter (e.g. cursor jittering on the boundary)
        // must not restart the magnify animation that's already running.
        guard on != isHovered else { return }
        isHovered = on
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = false
        let prefs = Preferences.shared
        guard prefs.hoverEnabled else {
            // Hover disabled (possibly mid-hover): make sure nothing is left
            // magnified or highlighted.
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.transform = CATransform3DIdentity
            return
        }
        let alpha = CGFloat(prefs.hoverHighlight)
        // Honor Reduce Motion: keep the (static) highlight, but skip the magnify and
        // apply it instantly so there's no animated scaling.
        let reduce = SystemDisplay.reduceMotion
        let scale = reduce ? 1.0 : CGFloat(prefs.hoverScale)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0 : prefs.hoverAnimation
            ctx.allowsImplicitAnimation = true
            layer?.backgroundColor = on ? NSColor.white.withAlphaComponent(alpha).cgColor : NSColor.clear.cgColor
            layer?.transform = on ? centeredScale(scale) : CATransform3DIdentity
        }
    }

    /// A scale anchored at the icon's center. NSView owns its backing layer's
    /// `anchorPoint` (effectively the bottom-left corner), so a plain
    /// `CATransform3DMakeScale` magnifies toward the top-right. Translating to
    /// the center, scaling, then translating back keeps it growing in place.
    private func centeredScale(_ factor: CGFloat) -> CATransform3D {
        let cx = bounds.midX, cy = bounds.midY
        var t = CATransform3DMakeTranslation(cx, cy, 0)
        t = CATransform3DScale(t, factor, factor, 1)
        return CATransform3DTranslate(t, -cx, -cy, 0)
    }

    /// A centered scale (like `centeredScale`) that also slides the icon's center
    /// by `offset` — so a shrunk copy lands on a neighbouring icon. Used by the
    /// per-window "fold into the sibling" leave animation.
    private func mergeScale(_ factor: CGFloat, toward offset: CGVector) -> CATransform3D {
        let cx = bounds.midX, cy = bounds.midY
        var t = CATransform3DMakeTranslation(offset.dx + cx, offset.dy + cy, 0)
        t = CATransform3DScale(t, factor, factor, 1)
        return CATransform3DTranslate(t, -cx, -cy, 0)
    }

    // MARK: - Join / leave animation

    /// The "not in the dock" layer state for `style`: the transform the icon
    /// animates from when appearing / to when leaving, plus an `opacity`. `slideOff`
    /// is the unit direction — in the view's unflipped coordinates — the icon flies
    /// toward the screen edge for `.slideOff`; other styles ignore it. Needs valid
    /// `bounds`, so call it once the icon is at full size.
    private func applyHiddenState(style: IconAnimationStyle, slideOff: CGVector, opacity: Float) {
        wantsLayer = true
        layer?.masksToBounds = false // poof / slide may spill past our bounds
        layer?.opacity = opacity
        switch style {
        case .fade:
            layer?.transform = CATransform3DIdentity
        case .shrink:
            layer?.transform = centeredScale(0.2)
        case .poof:
            layer?.transform = centeredScale(1.6)
        case .slideOff:
            let dist = bounds.height
            layer?.transform = CATransform3DMakeTranslation(slideOff.dx * dist, slideOff.dy * dist, 0)
        }
    }

    /// Animate this icon away as its app leaves the dock — it fades out as it
    /// transforms. Call inside an `NSAnimationContext` group with
    /// `allowsImplicitAnimation` (the caller owns the duration / timing).
    func playDisappear(style: IconAnimationStyle, slideOff: CGVector) {
        applyHiddenState(style: style, slideOff: slideOff, opacity: 0)
    }

    /// Animate this icon *folding into a sibling* as it leaves — used when one of an
    /// app's per-window icons goes away (a window closed) but the app keeps another
    /// icon. It shrinks and slides toward `offset` (the vector, in this view's
    /// coordinates, to the surviving icon's center) instead of sliding off-screen,
    /// so the closing window looks absorbed by its neighbour. Call inside an
    /// `NSAnimationContext` group with `allowsImplicitAnimation`.
    func playMerge(toward offset: CGVector) {
        wantsLayer = true
        layer?.masksToBounds = false // the icon slides toward its neighbour as it shrinks
        layer?.opacity = 0
        layer?.transform = mergeScale(0.1, toward: offset)
    }

    /// Snap this icon to its start-of-appear pose *before* the appear animation.
    /// Call instantly (outside an animation group) once the slot is open and the
    /// icon is at full size. Fade starts invisible (it fades in); the transform
    /// styles start *opaque* at their offset pose, so the motion (grow / poof /
    /// slide) is actually seen instead of being hidden behind an opacity ramp.
    func prepareToAppear(style: IconAnimationStyle, slideOff: CGVector) {
        applyHiddenState(style: style, slideOff: slideOff, opacity: style == .fade ? 0 : 1)
    }

    /// Animate this icon to its resting state as its app joins the dock. Call
    /// inside an `NSAnimationContext` group with `allowsImplicitAnimation`.
    func playAppear() {
        layer?.opacity = 1
        layer?.transform = CATransform3DIdentity
    }

    // MARK: - Running "box" indicator

    /// The "boxed" running style: a rounded `outlineColor` outline framing the
    /// icon, its inside tinted with `highlightColor`. Kept on its own sublayer so
    /// it composes with (and magnifies under) the hover transform without fighting
    /// the hover highlight, which lives on the button's own layer.
    private var boxLayer: CALayer?
    private var boxActive = false
    private var boxGap: CGFloat = 0
    private var boxOutlineWidth: CGFloat = 2
    private var boxOutlineColor: NSColor = .clear
    /// The inside-fill color, including its alpha: the user controls how translucent
    /// the highlight is via the color picker's opacity, so it's applied verbatim.
    private var boxHighlightColor: NSColor = .clear

    /// Show or hide the running box. `gap` is how far the outline floats out from
    /// the icon (0 = snug); the outline uses `outlineColor` at `outlineWidth`, and
    /// the inside is tinted with `highlightColor`.
    func setRunningBox(active: Bool, gap: CGFloat, outlineWidth: CGFloat,
                       outlineColor: NSColor, highlightColor: NSColor) {
        boxActive = active
        boxGap = gap
        boxOutlineWidth = outlineWidth
        boxOutlineColor = outlineColor
        boxHighlightColor = highlightColor
        wantsLayer = true
        layer?.masksToBounds = false // the box can sit slightly outside our bounds
        updateBoxLayer()
    }

    override func layout() {
        super.layout()
        updateBoxLayer() // bounds are only real once we've been laid out
    }

    // MARK: - Window-count badge

    private var badgeView: NSView?
    private var badgeLabel: NSTextField?

    /// Show a small count badge at the icon's top-right when an app has several
    /// windows on this desktop (count ≤ 1 removes it), so the user sees there's more
    /// than one without expanding the app into an icon per window. The badge is
    /// non-interactive, so clicking it still activates the icon beneath.
    func setWindowBadge(count: Int) {
        guard count > 1 else {
            badgeView?.removeFromSuperview(); badgeView = nil; badgeLabel = nil; return
        }
        wantsLayer = true
        layer?.masksToBounds = false
        if badgeView == nil {
            let v = PassthroughBadgeView()
            v.wantsLayer = true
            v.layer?.cornerRadius = 8
            v.layer?.masksToBounds = true
            v.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            v.layer?.borderWidth = 1.5
            v.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
            v.translatesAutoresizingMaskIntoConstraints = false
            let l = NSTextField(labelWithString: "")
            l.font = .systemFont(ofSize: 10, weight: .bold)
            l.textColor = .white
            l.alignment = .center
            l.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(l)
            addSubview(v)
            NSLayoutConstraint.activate([
                v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 3),
                v.topAnchor.constraint(equalTo: topAnchor, constant: -3),
                v.heightAnchor.constraint(equalToConstant: 16),
                v.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
                l.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                l.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                l.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 3),
                l.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -3),
            ])
            badgeView = v
            badgeLabel = l
        }
        badgeLabel?.stringValue = "\(count)"
    }

    private func updateBoxLayer() {
        guard boxActive else {
            boxLayer?.removeFromSuperlayer()
            boxLayer = nil
            return
        }
        let box = boxLayer ?? {
            let l = CALayer()
            layer?.insertSublayer(l, at: 0)
            boxLayer = l
            return l
        }()
        let frame = bounds.insetBy(dx: -boxGap, dy: -boxGap)
        // No implicit animation: the box should track layout/hover instantly, not
        // slide a frame behind every relayout pass.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.frame = frame
        box.cornerRadius = min(frame.width, frame.height) * 0.25
        box.borderWidth = boxOutlineWidth
        box.borderColor = boxOutlineColor.cgColor
        box.backgroundColor = boxHighlightColor.cgColor
        CATransaction.commit()
    }
}
