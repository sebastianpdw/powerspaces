// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// A container that reports clicks, so the banner can be dismissed by clicking it
/// (used for the "until clicked" duration, and as a courtesy for the timed ones).
private final class HUDContainer: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// A small, self-dismissing banner — the "small warning" for single-instance apps
/// that are open on another desktop. Appearance and timing come from `Preferences`.
@MainActor
enum HUD {
    /// A banner currently on screen, paired with its message so duplicates can be
    /// suppressed (see the dedupe guard in `show`).
    private struct Banner { let panel: NSPanel; let message: String }
    private static var live: [Banner] = []

    /// Show the banner. `force` bypasses the "Show warning banners" toggle — that
    /// switch governs the routine "already open on another desktop" notice, but a
    /// few warnings (e.g. hiding the menu-bar icon) must always be seen because
    /// they explain how to undo an action the user just took.
    static func show(_ message: String, force: Bool = false, icon: NSImage? = nil) {
        let prefs = Preferences.shared
        guard force || prefs.warningsEnabled else { return } // warnings turned off entirely
        // Never stack two identical banners: a single warning is enough, and several
        // code paths can ask for the same one near-simultaneously (e.g. both faster-
        // switch overrides failing for the same missing-Accessibility reason). Distinct
        // messages (e.g. per-app "already open on another desktop" notices) still stack.
        guard !live.contains(where: { $0.message == message }) else { return }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 72),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let effect = NSVisualEffectView()
        effect.material = prefs.barMaterial.material
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = CGFloat(prefs.cornerRadius)
        effect.translatesAutoresizingMaskIntoConstraints = false

        // With an app icon the icon stands in for the ⚠︎ glyph; otherwise prefix it.
        let label = NSTextField(wrappingLabelWithString: icon == nil ? "⚠︎  " + message : message)
        label.alignment = icon == nil ? .center : .left
        label.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = HUDContainer()
        container.addSubview(effect)
        container.addSubview(label)
        var constraints: [NSLayoutConstraint] = [
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ]
        if let icon {
            let iconView = NSImageView(image: icon)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(iconView)
            constraints += [
                iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 28),
                iconView.heightAnchor.constraint(equalToConstant: 28),
                label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            ]
        } else {
            constraints.append(label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18))
        }
        NSLayoutConstraint.activate(constraints)
        container.onClick = { dismiss(panel) }
        panel.contentView = container

        // Reduce Transparency: hide the blur and give the banner a solid background,
        // so the message stays legible without vibrancy.
        if SystemDisplay.reduceTransparency {
            effect.isHidden = true
            container.wantsLayer = true
            container.layer?.cornerRadius = CGFloat(prefs.cornerRadius)
            container.layer?.masksToBounds = true
            container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let margin: CGFloat = 24
            let x = visible.midX - panel.frame.width / 2
            // Stack multiple banners instead of overlapping them: offset each new
            // one past those already on screen, away from its anchor edge.
            let step = panel.frame.height + 10
            let offset = CGFloat(live.count) * step
            let y: CGFloat
            switch prefs.hudPosition {
            case .top: y = visible.maxY - panel.frame.height - margin - offset
            case .bottom: y = visible.minY + margin + offset
            case .center: y = visible.midY - panel.frame.height / 2 - offset
            }
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
        live.append(Banner(panel: panel, message: message))

        if let seconds = prefs.warningDurationSeconds {
            // Self-dismiss after the timed duration. A main-actor `Task` (rather than
            // a `@Sendable` dispatch block) keeps both the non-Sendable panel capture
            // and the `dismiss` call cleanly on the main actor.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                dismiss(panel)
            }
        }
    }

    private static func dismiss(_ panel: NSPanel) {
        guard live.contains(where: { $0.panel === panel }) else { return } // already gone
        panel.orderOut(nil)
        live.removeAll { $0.panel === panel }
    }
}
