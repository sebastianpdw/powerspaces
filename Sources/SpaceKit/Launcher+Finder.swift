// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CoreGraphics
import Foundation

/// Finder is the awkward special case for "open a new window here". Right after a
/// "quit (all desktops)" macOS auto-relaunches it window-less and it ignores the
/// first `make new Finder window` event until it has warmed up — so a single dock
/// click lands no window. These helpers automate the second click and fall back to
/// a permission-free folder-open that always lands a window on the current Space.
extension Launcher {
    /// Recovery when an app's "make new window" AppleScript can't run (usually
    /// because powerspaces hasn't been granted Automation control of it). Finder
    /// gets a fresh window by asking LaunchServices to open a folder — that's not
    /// an Apple event, so it needs no Automation permission and still lands a
    /// window on the current Space. Other scriptable apps have no generic
    /// no-Automation equivalent, so point the user at the permission instead of
    /// failing silently.
    func appleScriptFallback(_ target: AppTarget) {
        if target.bundleID == "com.apple.finder" {
            openNewFinderWindow()
            return
        }
        warn("couldn't make a new window for \(displayName(for: target)) via AppleScript. "
             + "Grant powerspaces Automation access in System Settings ▸ Privacy & "
             + "Security ▸ Automation, then try again.")
    }

    /// Open a Finder window the reliable way: ask LaunchServices to open a folder.
    /// That's not an Apple event, so it needs no Automation permission and — unlike
    /// `make new Finder window` — it works even against a Finder that was just
    /// auto-relaunched window-less after a "quit (all desktops)", which silently
    /// ignores the scripting event until it has warmed up. The window lands on the
    /// current Space.
    func openNewFinderWindow() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        runProcess(URL(fileURLWithPath: "/usr/bin/open"), [home.path], wait: true)
    }

    /// Get a Finder window onto the *current* Space, reliably, on the *first*
    /// dock click. Today the existing `make new Finder window` strategy needs a
    /// second click: right after a "quit (all desktops)" relaunch Finder ignores
    /// the first event and only honors it once it has warmed up (~1s later, which
    /// is exactly when the user clicks again). So we automate that second click —
    /// run the strategy, wait for the window to actually reach the current Space,
    /// and re-run it if it didn't — then fall back to the permission-free
    /// LaunchServices folder-open as a last resort.
    func makeNewFinderWindowHere(_ target: AppTarget) {
        let script = config.appleScript(for: target.bundleID)
        // Attempt 1 — what a single click does today; often a no-op on a cold,
        // just-relaunched Finder.
        if let script { runAppleScript(script) }
        activate(target)
        if waitForFinderWindowOnCurrentSpace(timeout: 1.0) { return }
        // Attempt 2 — Finder has warmed up now, just as it has by the user's
        // second click; this is the one that normally succeeds.
        if let script { runAppleScript(script) }
        activate(target)
        if waitForFinderWindowOnCurrentSpace(timeout: 1.0) { return }
        // Still nothing (Automation denied, or the event keeps missing) — recover
        // with the folder-open, which reliably lands a window on the current Space
        // with no Automation consent.
        openNewFinderWindow()
        _ = waitForFinderWindowOnCurrentSpace(timeout: 1.0)
        activate(target)
    }

    /// Poll (briefly) until Finder has a window on the current Space.
    private func waitForFinderWindowOnCurrentSpace(timeout: TimeInterval) -> Bool {
        let finder = AppTarget(bundleID: "com.apple.finder", name: "Finder")
        return pollUntil(timeout: timeout, interval: 80_000) {
            guard let snap = try? provider.snapshot() else { return false }
            return !snap.windows(of: finder, onSpace: snap.activeSpaceID).isEmpty
        }
    }
}
