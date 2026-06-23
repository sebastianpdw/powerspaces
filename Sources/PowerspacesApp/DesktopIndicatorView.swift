// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// A small rounded "Desktop N" badge shown on the dock so the desktop you are on is
/// always glanceable (macOS doesn't number desktops on screen). It sizes to its
/// text, so the dock can place it inside the icon row (as a reserved slot) or float
/// it just off the bar. The number is set live by `DockPanel.desktopNumber`.
final class DesktopIndicatorView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Show the current desktop. `compact` (used inside the bar, where space is
    /// tight) shows just the number; the floating "above" placement shows the full
    /// "Desktop N". A nil/0 number degrades to a neutral label rather than nothing.
    func setNumber(_ number: Int?, compact: Bool) {
        if let number, number > 0 {
            label.stringValue = compact ? "\(number)" : "Desktop \(number)"
            toolTip = "Current desktop: \(number)"
        } else {
            label.stringValue = compact ? "•" : "Desktop"
            toolTip = "Current desktop"
        }
        invalidateIntrinsicContentSize()
    }

    /// Size to the label plus padding, so the badge hugs its text in any placement.
    override var intrinsicContentSize: NSSize {
        let text = label.intrinsicContentSize
        return NSSize(width: text.width + 14, height: text.height + 8)
    }
}
