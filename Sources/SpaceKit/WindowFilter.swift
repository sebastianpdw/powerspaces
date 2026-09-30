// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics

/// Decides which window-server entries are real, user-facing application windows.
/// The per-Space dock shows one entry per real window, so every surface that is
/// wrongly counted becomes a ghost icon.
///
/// Two steps, both pure data in, data out (unit-testable without a window server):
///
/// 1. `isRealWindow` — a geometry pass over the raw window list. It drops what no
///    application window looks like: other layers, fully transparent overlays and
///    toolbar-sized strips. What passes is a *candidate*.
/// 2. `judge` — **Accessibility decides which candidates are real; the window
///    server only says where they are.** Geometry cannot tell a window from a
///    full-size helper surface, a hover preview, an inactive tab, a launch
///    placeholder or the leftover of a closed window. Accessibility can: it lists
///    an app's actual windows and nothing else.
public enum WindowFilter {
    /// A window's identity between scans. The owner is part of it, so a recycled
    /// window id under another process is a different window.
    public struct Key: Hashable, Sendable {
        public let pid: pid_t
        public let windowID: CGWindowID

        public init(_ window: WindowInfo) {
            pid = window.pid
            windowID = window.windowID
        }
    }

    /// What Accessibility reports about one window it lists.
    public struct AXKind: Equatable, Sendable {
        public let role: String?
        public let subrole: String?
        public let isModal: Bool?
        public let isMinimized: Bool

        public init(role: String?, subrole: String?, isModal: Bool?, isMinimized: Bool = false) {
            self.role = role
            self.subrole = subrole
            self.isModal = isModal
            self.isMinimized = isMinimized
        }

        var isRestorable: Bool {
            WindowFilter.isRestorableWindow(role: role, subrole: subrole, isModal: isModal, isMinimized: isMinimized)
        }
    }

    /// What Accessibility said about one app during a scan.
    public enum Accessibility: Equatable, Sendable {
        /// No permission (yet): only window-server facts are available.
        case untrusted
        /// Permitted, but the app gave no complete answer (time budget, AX error).
        case unanswered
        /// The kinds of the candidates the app lists, by window id. An AX element
        /// that maps to no candidate is simply absent.
        case listed([CGWindowID: AXKind])
    }

    /// Why a candidate is, or is not, in the snapshot. The names are what the
    /// scan log prints.
    public enum Verdict: String, Sendable {
        /// Accessibility lists it as a window. The only verdict that is remembered.
        case confirmed
        /// Confirmed by an earlier scan and shown while Accessibility is silent.
        case held
        /// On a hidden desktop, where Accessibility never lists windows.
        case elsewhere
        /// No Accessibility permission, or no answer: shown on window-server facts alone.
        case unverified
        /// Accessibility lists it as a sheet, dialog or other non-window.
        case notWindow
        /// Claims a visible desktop, but the app does not list it.
        case notListed
        /// On no desktop at all: the leftover of a closed or background window.
        case noSpace
        /// Off screen, Accessibility gave no answer and no earlier scan confirmed it.
        case noAnswer

        public var isReal: Bool {
            switch self {
            case .confirmed, .held, .elsewhere, .unverified: return true
            case .notWindow, .notListed, .noSpace, .noAnswer: return false
            }
        }
    }

    public typealias Judged = (window: WindowInfo, verdict: Verdict)

    /// Judges ONE app's candidates. Per candidate:
    ///
    /// 1. **Accessibility lists it** — real if it is an ordinary window
    ///    (`isRestorableWindow`), otherwise not (sheet, dialog, scroll area, hover
    ///    preview). *Never strip an app's last window:* when none of the listed
    ///    candidates is ordinary, the listed non-modal `AXWindow`s stand in, so a
    ///    dialog-style single-window app keeps its icon.
    /// 2. **Accessibility answered but omits it** — a window confirmed earlier and
    ///    still on screen is held (a desktop slide, a one-scan hiccup). A window on
    ///    hidden desktops only is kept: Accessibility never lists those, and the
    ///    launcher must know the app has a window elsewhere. Anything else is not
    ///    real — a helper surface, or a closed window the app keeps alive.
    /// 3. **Accessibility gave no answer** — hold what was confirmed earlier, show
    ///    what is on screen (unverified, so never remembered) and keep windows on
    ///    hidden desktops. Running out of time never adds an off-screen window:
    ///    those are the helper surfaces and leftovers.
    /// 4. **No Accessibility permission** — window-server facts only: on screen,
    ///    ⌘-hidden, or on hidden desktops only.
    ///
    /// `remembered` holds the windows confirmed by earlier scans (see
    /// `remembered(after:previously:)`); `visibleSpaces` the desktop visible on
    /// each display.
    public static func judge(_ candidates: [WindowInfo], accessibility: Accessibility,
                             visibleSpaces: Set<SpaceID>, remembered: Set<Key>) -> [Judged] {
        var kinds: [CGWindowID: AXKind] = [:]
        if case let .listed(listed) = accessibility { kinds = listed }
        let listsOrdinaryWindow = candidates.contains { kinds[$0.windowID]?.isRestorable == true }

        func verdict(_ window: WindowInfo) -> Verdict {
            if let kind = kinds[window.windowID] {
                let standsIn = !listsOrdinaryWindow && kind.role == "AXWindow" && kind.isModal != true
                return kind.isRestorable || standsIn ? .confirmed : .notWindow
            }
            let wasConfirmed = remembered.contains(Key(window))
            switch accessibility {
            case .listed: if wasConfirmed, window.isOnscreen { return .held }
            case .unanswered: if wasConfirmed { return .held } else if window.isOnscreen { return .unverified }
            case .untrusted: if window.isOnscreen || window.isHidden { return .unverified }
            }
            if !window.spaceIDs.isEmpty, visibleSpaces.isDisjoint(with: window.spaceIDs) { return .elsewhere }
            if window.spaceIDs.isEmpty, window.spaceMembershipKnown { return .noSpace }
            if case .listed = accessibility { return .notListed }
            return .noAnswer
        }
        return candidates.map { ($0, verdict($0)) }
    }

    /// The only state kept between scans: the windows Accessibility has confirmed
    /// and that are still in the snapshot. Rebuilt from each scan's own results, so
    /// it cannot grow and a closed window leaves it.
    public static func remembered(after judged: [Judged], previously: Set<Key>) -> Set<Key> {
        Set(judged.compactMap { window, verdict in
            let key = Key(window)
            return verdict == .confirmed || (verdict.isReal && previously.contains(key)) ? key : nil
        })
    }

    /// For the unified log: the apps whose number of real windows differs from the
    /// previous scan, each with its old and new count and how its candidates were
    /// judged. `line` is nil when no count changed. App identifiers and counts
    /// only — no window titles, frames or desktop ids.
    public static func changeLog(_ judged: [Judged], previousCounts: [String: Int])
        -> (counts: [String: Int], line: String?) {
        var counts: [String: Int] = [:]
        var verdicts: [String: [String: Int]] = [:]
        for (window, verdict) in judged {
            let app = window.bundleID ?? "unknown"
            if verdict.isReal { counts[app, default: 0] += 1 }
            verdicts[app, default: [:]][verdict.rawValue, default: 0] += 1
        }
        let changes = Set(counts.keys).union(previousCounts.keys).sorted().compactMap { app -> String? in
            let old = previousCounts[app, default: 0], new = counts[app, default: 0]
            guard old != new else { return nil }
            let breakdown = verdicts[app, default: [:]].sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            return "app=\(app) real=\(old)->\(new) " + (breakdown.isEmpty ? "no-candidates" : breakdown.joined(separator: " "))
        }
        return (counts, changes.isEmpty ? nil : "Window inventory changed: " + changes.joined(separator: "; "))
    }

    /// Positive evidence of an ordinary window, shared by `judge` and focus
    /// recovery. macOS can expose a minimized document as a nonmodal AXDialog
    /// (observed in Safari). A missing kind is unknown, not evidence of a window.
    public static func isRestorableWindow(role: String?, subrole: String?, isModal: Bool?,
                                          isMinimized: Bool = false) -> Bool {
        role == "AXWindow" && isModal != true
            && (subrole == "AXStandardWindow" || (isMinimized && subrole == "AXDialog"))
    }

    /// Smallest width *and* height (points) a real top-level window is assumed to
    /// have. Comfortably above the tallest observed accessory window (61pt) and
    /// well below the smallest real one (~237pt).
    public static let minRealWindowSize: CGFloat = 100

    /// The geometry pass. Apps create helper windows at the *same* layer as their
    /// real ones: toolbar/tab-bar strips, the hover-URL status overlay, transparent
    /// event-catchers. In the observed data every one of those was either fully
    /// transparent or at most 64pt on its short side (Safari's tallest, an 865×61
    /// bar, is the extreme), while the smallest real window was ~237pt. Surfaces
    /// that look like a window but are not one are `judge`'s concern.
    public static func isRealWindow(
        layer: Int, alpha: Double, width: CGFloat, height: CGFloat
    ) -> Bool {
        guard layer == 0 else { return false }      // normal app-window layer only
        guard alpha > 0 else { return false }       // fully transparent → not user-visible
        return width >= minRealWindowSize && height >= minRealWindowSize
    }
}
