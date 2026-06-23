// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// The dock bar's auto-hide behaviour: tuck the bar off its screen edge after an
/// idle delay, and reveal it again when the pointer reaches the hot strip at that
/// edge. The stored state (`hideState`, the timer, the mouse monitors) and the
/// `deinit` teardown live on `DockPanel` itself — a Swift extension can hold
/// neither — so only the logic moves here. `applyAutoHide` / `placedOrigin` /
/// `cancelHideTimer` / `removeMouseMonitor` are `internal` because `DockPanel`
/// calls them (on launch, during layout, and from `deinit`); the rest are private
/// to this file.
extension DockPanel {
    /// (Re)configure auto-hide from preferences. Installs or tears down the pointer
    /// monitor and either starts the hide countdown or fully reveals the bar.
    /// Called on launch (`show`) and on every preferences change (`applyAppearance`).
    func applyAutoHide() {
        // A screen showing a full-screen app with the "hide" preference removes the
        // bar entirely (it can't be revealed): tear down the auto-hide machinery.
        if fullyHidden {
            cancelHideTimer()
            removeMouseMonitor()
            if isVisible { orderOut(nil) }
            return
        }
        // Coming back from a fully-hidden state: put the bar back on screen before
        // (re)configuring.
        if !isVisible { orderFrontRegardless() }
        if autoHideActive {
            installMouseMonitor()
            // Re-assert the hidden geometry (in case the animation *type* changed
            // while hidden); otherwise start/refresh the countdown.
            if hideState == .hidden { applyHideGeometry(duration: 0) }
            else { scheduleHideIfIdle() }
        } else {
            removeMouseMonitor()
            reveal(animated: false)
        }
    }

    /// Auto-hide is in effect when the user turned it on globally, or when this screen
    /// shows a full-screen app and the full-screen dock behaviour is "auto-hide".
    var autoHideActive: Bool {
        Preferences.shared.autoHideEnabled
            || (fullscreenActive && Preferences.shared.fullscreenDockBehavior == .autoHide)
    }

    /// The bar is removed entirely (not just tucked) when a full-screen app owns this
    /// screen and the full-screen dock behaviour is "hide".
    var fullyHidden: Bool {
        fullscreenActive && Preferences.shared.fullscreenDockBehavior == .hide
    }

    /// React to this screen gaining or losing a full-screen app. Routes through the
    /// single `applyAutoHide` state machine so hide / auto-hide / show all settle the
    /// same way. A no-op when the state is unchanged (this is called every refresh).
    func applyFullscreenState(_ active: Bool) {
        guard active != fullscreenActive else { return }
        fullscreenActive = active
        applyAutoHide()
    }

    /// The window origin for `size` honoring the current hide state: the normal
    /// on-edge spot when shown (or when hiding only fades in place), or fully off
    /// the screen edge when hidden with a sliding animation.
    func placedOrigin(forSize size: NSSize, on screen: NSScreen) -> NSPoint {
        let shown = origin(forSize: size, on: screen)
        guard hideState == .hidden, Preferences.shared.autoHideAnimation.slides else { return shown }
        let f = screen.frame
        switch Preferences.shared.barPosition {
        case .bottom: return NSPoint(x: shown.x, y: f.minY - size.height)
        case .top:    return NSPoint(x: shown.x, y: f.maxY)
        case .left:   return NSPoint(x: f.minX - size.width, y: shown.y)
        case .right:  return NSPoint(x: f.maxX, y: shown.y)
        }
    }

    /// The window opacity for the current hide state (0 only when a fading hide is
    /// in effect). Position handles the slide; opacity is left "sticky" between
    /// calls, so a rebuild while hidden doesn't need to touch it.
    private func placedAlpha() -> CGFloat {
        (hideState == .hidden && Preferences.shared.autoHideAnimation.fades) ? 0 : 1
    }

    /// Animate the window to the position + opacity for the current hide state.
    /// A `duration` of 0 applies it immediately.
    private func applyHideGeometry(duration: TimeInterval, completion: (@Sendable () -> Void)? = nil) {
        guard let screen = boundScreen else { completion?(); return }
        // Reduce Motion: snap the bar in/out with no slide or fade animation.
        let duration = SystemDisplay.reduceMotion ? 0 : duration
        let target = NSRect(origin: placedOrigin(forSize: frame.size, on: screen), size: frame.size)
        let alpha = placedAlpha()
        guard duration > 0.001 else {
            setFrame(target, display: true)
            alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(target, display: true)
            animator().alphaValue = alpha
        }, completionHandler: completion)
    }

    /// Tuck the bar away — unless it's already hidden, the user is mid-interaction,
    /// or the pointer is still over it / on the hot edge (then retry after the delay).
    private func hide() {
        guard autoHideActive, hideState == .shown else { return }
        // Mid-interaction: retry after the delay (a drag/animation can end without
        // a pointer move to re-arm us).
        if isReordering || isExternalDragging || isAnimating { scheduleHide(); return }
        // Pointer still over the bar / hot edge: don't hide, and don't re-arm — the
        // move that takes the pointer away will start a fresh countdown.
        if pointerIsOverBar() { cancelHideTimer(); return }
        hideState = .hidden
        applyHideGeometry(duration: Preferences.shared.autoHideSpeed) { [weak self] in
            // Animation completion fires on the main actor.
            MainActor.assumeIsolated {
                guard let self, self.hideState == .hidden else { return }
                // A faded-in-place bar still occupies its frame; stop it swallowing
                // clicks meant for whatever is underneath.
                self.ignoresMouseEvents = true
            }
        }
    }

    /// Bring the bar back on-screen. Animated only when it was actually hidden, so
    /// a redundant reveal (e.g. on a settings change) doesn't replay the motion.
    private func reveal(animated: Bool) {
        cancelHideTimer()
        let wasHidden = hideState == .hidden
        hideState = .shown
        ignoresMouseEvents = false
        orderFrontRegardless()
        applyHideGeometry(duration: (animated && wasHidden) ? Preferences.shared.autoShowSpeed : 0)
    }

    private func scheduleHide() {
        cancelHideTimer()
        let delay = max(Preferences.shared.autoHideDelay, 0.001)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            // Fires on the main run loop (default mode), so we're already on the main actor.
            MainActor.assumeIsolated { self?.hide() }
        }
        timer.tolerance = 0.1
        hideTimer = timer
    }

    /// Start the hide countdown only when the bar is shown and the pointer isn't
    /// over it; otherwise cancel any pending one (the pointer is keeping it up).
    private func scheduleHideIfIdle() {
        guard autoHideActive, hideState == .shown else { return }
        if pointerIsOverBar() { cancelHideTimer() } else { scheduleHide() }
    }

    // `nonisolated` so the (nonisolated) `deinit` can call it. `Timer.invalidate()` is
    // not main-actor isolated, and the timer field is `nonisolated(unsafe)`.
    nonisolated func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func installMouseMonitor() {
        guard globalMouseMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.handlePointerMoved()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handlePointerMoved()
            return event
        }
    }

    // `nonisolated` so the (nonisolated) `deinit` can call it. `NSEvent`'s monitor
    // APIs aren't main-actor isolated, and the monitor fields are `nonisolated(unsafe)`.
    nonisolated func removeMouseMonitor() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
    }

    /// The pointer moved: reveal a hidden bar when it reaches the hot edge, or —
    /// when shown — keep it up while the pointer is over it and start the hide
    /// countdown once the pointer leaves.
    private func handlePointerMoved() {
        guard autoHideActive else { return }
        switch hideState {
        case .hidden:
            if pointerInRevealBand() { reveal(animated: true) }
        case .shown:
            if pointerIsOverBar() { cancelHideTimer() }
            else if hideTimer == nil { scheduleHide() }
        }
    }

    /// True when the pointer is within the hot strip along the screen edge the bar
    /// hugs — the gesture that brings a hidden bar back. Spans the whole edge.
    private func pointerInRevealBand() -> Bool {
        guard let screen = boundScreen else { return false }
        let f = screen.frame
        let p = NSEvent.mouseLocation
        let t = DockPanel.revealThreshold
        switch Preferences.shared.barPosition {
        case .bottom: return p.y <= f.minY + t && p.x >= f.minX && p.x <= f.maxX
        case .top:    return p.y >= f.maxY - t && p.x >= f.minX && p.x <= f.maxX
        case .left:   return p.x <= f.minX + t && p.y >= f.minY && p.y <= f.maxY
        case .right:  return p.x >= f.maxX - t && p.y >= f.minY && p.y <= f.maxY
        }
    }

    /// True while the pointer is over the shown bar or somewhere that should keep
    /// it up: still on the hot edge, or in the corridor between the screen edge and
    /// the floating bar (so crossing the edge-gap to reach the bar can't trigger a
    /// hide). Uses the *shown* frame so it's correct even while the bar is hidden.
    private func pointerIsOverBar() -> Bool {
        if pointerInRevealBand() { return true }
        guard let screen = boundScreen else { return false }
        let f = screen.frame
        var keep = NSRect(origin: origin(forSize: frame.size, on: screen), size: frame.size)
            .insetBy(dx: -2, dy: -2)
        // Stretch the bar's frame out to the screen edge it hugs, folding the
        // edge-gap into the keep region.
        switch Preferences.shared.barPosition {
        case .bottom: keep = NSRect(x: keep.minX, y: f.minY, width: keep.width, height: keep.maxY - f.minY)
        case .top:    keep = NSRect(x: keep.minX, y: keep.minY, width: keep.width, height: f.maxY - keep.minY)
        case .left:   keep = NSRect(x: f.minX, y: keep.minY, width: keep.maxX - f.minX, height: keep.height)
        case .right:  keep = NSRect(x: keep.minX, y: keep.minY, width: f.maxX - keep.minX, height: keep.height)
        }
        return keep.contains(NSEvent.mouseLocation)
    }
}
