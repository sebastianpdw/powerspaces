// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// The container view, which doubles as a drag-and-drop target: dropping an
/// .app pins it to the current desktop (issue 6). As an app is dragged across
/// the bar it reports the cursor position so the panel can open a slot for it.
final class DockDropView: NSView {
    /// The cursor moved over the bar during an .app drag (window coords). Drives
    /// the live "make space" slot that opens between the existing icons.
    var onDragMoved: ((NSPoint) -> Void)?
    /// The drag left the bar (or finished) without a drop: close the open slot.
    var onDragLeft: (() -> Void)?
    /// An .app was dropped: pin it into the slot that's currently open.
    var onDropApp: ((String) -> Void)?
    /// Supplies the dock's own right-click menu (Open Preferences / Quit), shown
    /// on a right-click over empty bar background — distinct from an icon's menu,
    /// which the button handles. This is the fallback way to reach Preferences
    /// when the menu-bar item is set to Hidden.
    var dockMenu: (() -> NSMenu?)?

    /// True only while a drag we actually accept (an .app bundle) is overhead, so
    /// stray file drags neither open a slot nor trigger the close-on-exit.
    private var accepting = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Empty-bar background was right-clicked (an icon's own right-click is caught
    /// by `DockButton`, which doesn't call super, so it never reaches here). Pop the
    /// dock menu at the click, in this view's coordinates.
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = dockMenu?() else { return super.rightMouseDown(with: event) }
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    /// The application bundle URLs carried by a drag (empty for anything else).
    private func appURLs(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: ["com.apple.application-bundle"],
        ]
        return sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepting = !appURLs(sender).isEmpty
        guard accepting else { return [] }
        onDragMoved?(sender.draggingLocation)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepting else { return [] }
        onDragMoved?(sender.draggingLocation)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if accepting { onDragLeft?() }
        accepting = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        // Cancel path (released off the bar). On a successful drop
        // performDragOperation has already cleared `accepting`, so this no-ops.
        if accepting { onDragLeft?() }
        accepting = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = appURLs(sender)
        guard !urls.isEmpty else { return false }
        var handled = false
        for url in urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier {
                onDropApp?(bundleID)
                handled = true
            }
        }
        // The drop itself tears down the open slot; suppress draggingEnded's close.
        accepting = false
        return handled
    }
}
