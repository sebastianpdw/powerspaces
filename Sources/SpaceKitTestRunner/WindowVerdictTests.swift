// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation
import SpaceKit

// Decision-table tests for `WindowFilter.judge`: Accessibility decides WHICH
// windows are real, the window server only says WHERE they are. Desktop 6 is the
// visible one unless a test says otherwise.

private typealias Kind = WindowFilter.AXKind
private typealias Key = WindowFilter.Key

private let standard = Kind(role: "AXWindow", subrole: "AXStandardWindow", isModal: false)
private let dialog = Kind(role: "AXWindow", subrole: "AXDialog", isModal: false)
private let modalDialog = Kind(role: "AXWindow", subrole: "AXDialog", isModal: true)
private let sheet = Kind(role: "AXSheet", subrole: nil, isModal: false)
private let suggestions = Kind(role: "AXScrollArea", subrole: nil, isModal: nil)
private let preview = Kind(role: "AXWindow", subrole: "AXUnknown", isModal: false)
private let floating = Kind(role: "AXWindow", subrole: "AXFloatingWindow", isModal: false)

private func window(_ id: CGWindowID, pid: pid_t = 500, bundle: String = "app", spaces: [SpaceID] = [6],
                    onscreen: Bool = true, minimized: Bool = false, hidden: Bool = false, known: Bool = true,
                    bounds: CGRect = CGRect(x: 0, y: 33, width: 1728, height: 1010)) -> WindowInfo {
    WindowInfo(windowID: id, pid: pid, ownerName: bundle, bundleID: bundle, spaceIDs: spaces, bounds: bounds,
               isOnscreen: onscreen, isMinimized: minimized, isHidden: hidden, spaceMembershipKnown: known)
}

private func judge(_ candidates: [WindowInfo], _ accessibility: WindowFilter.Accessibility,
                   visible: Set<SpaceID> = [6], remembered: [WindowInfo] = []) -> [WindowFilter.Judged] {
    WindowFilter.judge(candidates, accessibility: accessibility, visibleSpaces: visible,
                       remembered: Set(remembered.map(Key.init)))
}

private func verdicts(_ candidates: [WindowInfo], _ accessibility: WindowFilter.Accessibility,
                      visible: Set<SpaceID> = [6], remembered: [WindowInfo] = []) -> [CGWindowID: WindowFilter.Verdict] {
    Dictionary(judge(candidates, accessibility, visible: visible, remembered: remembered)
        .map { ($0.window.windowID, $0.verdict) }, uniquingKeysWith: { first, _ in first })
}

private func real(_ judged: [WindowFilter.Judged]) -> [CGWindowID] {
    judged.filter { $0.verdict.isReal }.map(\.window.windowID)
}

func runWindowVerdictTests(_ h: Harness) {
    print("Window verdicts — Accessibility decides which windows are real")

    h.test("rule 1: a window Accessibility lists is real only when it is an ordinary window") {
        h.eq(verdicts([window(1)], .listed([1: standard])), [1: .confirmed])
        h.eq(verdicts([window(1)], .listed([1: Kind(role: "AXWindow", subrole: "AXStandardWindow", isModal: nil)])),
             [1: .confirmed]) // An unreadable modal flag is not evidence of a dialog.
        // Which windows are real is Accessibility's call; where one is plays no part in it.
        for placed in [window(1, onscreen: false), window(1, spaces: [4], onscreen: false),
                       window(1, spaces: [], onscreen: false), window(1, spaces: [], known: false),
                       window(1, onscreen: false, hidden: true)] {
            h.eq(verdicts([placed], .listed([1: standard])), [1: .confirmed])
        }
        for kind in [sheet, modalDialog, dialog, suggestions, preview, floating,
                     Kind(role: "AXWindow", subrole: "AXSystemDialog", isModal: false),
                     Kind(role: "AXWindow", subrole: nil, isModal: false),
                     Kind(role: "AXWindow", subrole: "AXStandardWindow", isModal: true),
                     Kind(role: nil, subrole: nil, isModal: nil)] {
            h.eq(verdicts([window(1), window(2)], .listed([1: standard, 2: kind])),
                 [1: .confirmed, 2: .notWindow], "\(kind)")
        }
        // A sheet and a modal dialog next to a standard window: only the window is real.
        h.eq(real(judge([window(2), window(1), window(3)], .listed([1: standard, 2: sheet, 3: modalDialog]))), [1])
    }

    h.test("rule 1: a minimized document that reads as a non-modal AXDialog is real") {
        // Seen in Safari: minimized document 8162 reads as
        // AXDialog; stale surface 8166 claims the same desktop and is absent from AX.
        let document = window(8162, pid: 47591, spaces: [4], onscreen: false, minimized: true)
        let stale = window(8166, pid: 47591, spaces: [4], onscreen: false)
        for modal in [Optional<Bool>.none, false] {
            let kind = Kind(role: "AXWindow", subrole: "AXDialog", isModal: modal, isMinimized: true)
            h.eq(verdicts([stale, document], .listed([8162: kind]), visible: [4]),
                 [8162: .confirmed, 8166: .notListed])
            h.eq(verdicts([window(1), document], .listed([1: standard, 8162: kind]), visible: [4]),
                 [1: .confirmed, 8162: .confirmed])
        }
        // Being minimized does not turn a real dialog or a helper into a window.
        for kind in [Kind(role: "AXWindow", subrole: "AXDialog", isModal: true, isMinimized: true),
                     Kind(role: "AXWindow", subrole: "AXSystemDialog", isModal: false, isMinimized: true),
                     Kind(role: "AXScrollArea", subrole: "AXDialog", isModal: false, isMinimized: true),
                     Kind(role: "AXSheet", subrole: "AXStandardWindow", isModal: false, isMinimized: true)] {
            h.eq(verdicts([window(1), document], .listed([1: standard, 8162: kind]), visible: [4]),
                 [1: .confirmed, 8162: .notWindow], "\(kind)")
        }
    }

    h.test("last-window guarantee: an app whose only listed windows are dialog-style keeps its icon") {
        h.eq(verdicts([window(1)], .listed([1: dialog])), [1: .confirmed])
        h.eq(verdicts([window(1)], .listed([1: preview])), [1: .confirmed])
        h.eq(verdicts([window(1)], .listed([1: floating])), [1: .confirmed])
        h.eq(verdicts([window(1)], .listed([1: Kind(role: "AXWindow", subrole: nil, isModal: nil)])), [1: .confirmed])
        h.eq(verdicts([window(1), window(2)], .listed([1: dialog, 2: preview])), [1: .confirmed, 2: .confirmed])
        // The guarantee never admits a modal dialog or something that is not a window,
        // even as the app's last entry.
        for kind in [modalDialog, sheet, suggestions, Kind(role: nil, subrole: nil, isModal: nil),
                     Kind(role: "AXWindow", subrole: "AXStandardWindow", isModal: true)] {
            h.eq(verdicts([window(1)], .listed([1: kind])), [1: .notWindow], "\(kind)")
            h.eq(verdicts([window(1), window(2)], .listed([1: kind, 2: dialog])), [1: .notWindow, 2: .confirmed])
        }
        // It ends as soon as Accessibility lists an ordinary window.
        h.eq(verdicts([window(1), window(2)], .listed([1: dialog, 2: standard])), [1: .notWindow, 2: .confirmed])
        // Only listed candidates count: a window AX cannot see on another desktop
        // does not take the dialog-style app's icon away from this one.
        h.eq(verdicts([window(1), window(2, spaces: [4], onscreen: false)], .listed([1: dialog])),
             [1: .confirmed, 2: .elsewhere])
    }

    h.test("rule 2: the recorded Safari ghost yields exactly one window") {
        // macOS 27.0, desktop 6 visible. Helper 485 (873x161, off-screen, cgSpaces=[6])
        // is absent from AX. While another Safari window closed, AX returned two
        // elements of which one mapped to a window id (axCount=2 axIdentified=1) and
        // the helper became a second Safari icon for one scan. The document's id
        // is a fixture; the helper's facts are as recorded.
        let document = window(470, pid: 3923, bundle: "com.apple.Safari")
        let helper = window(485, pid: 3923, bundle: "com.apple.Safari", onscreen: false,
                            bounds: CGRect(x: 427, y: 85, width: 873, height: 161))
        for remembered in [[], [document]] {
            // The unmappable element has no window id: it reaches the rule as nothing.
            let judged = judge([document, helper], .listed([470: standard]), remembered: remembered)
            h.eq(real(judged), [470])
            h.eq(judged.map(\.verdict), [.confirmed, .notListed])
            let snapshot = SpaceSnapshot(activeSpaceID: 6, judged: judged)
            h.eq(DockModel.apps(onCurrentSpace: snapshot).first?.windowCount, 1)
            // Nor does an element that maps to something that is not a candidate.
            h.eq(real(judge([document, helper], .listed([470: standard, 9999: standard]), remembered: remembered)), [470])
        }
    }

    h.test("rule 2: Space-less leftovers are not windows") {
        // cgSpaces=[] and off-screen: surfaces of closed or background windows.
        let leftovers = ["app.a": 1, "app.b": 2, "app.c": 1, "app.d": 1, "app.e": 1, "app.f": 1, "app.g": 1]
        h.eq(leftovers.values.reduce(0, +), 8)
        var pid: pid_t = 600
        for (app, count) in leftovers.sorted(by: { $0.key < $1.key }) {
            pid += 1
            let surfaces = (0..<count).map {
                window(CGWindowID(Int(pid) * 10 + $0), pid: pid, bundle: app, spaces: [], onscreen: false)
            }
            let judged = judge(surfaces, .listed([:]))
            h.ok(real(judged).isEmpty, app)
            h.ok(judged.allSatisfy { $0.verdict == .noSpace }, app)
            // Having been a real window once does not keep a closed one alive.
            h.ok(real(judge(surfaces, .listed([:]), remembered: surfaces)).isEmpty, app)
            h.ok(real(judge(surfaces, .untrusted)).isEmpty, app)
            h.ok(real(judge(surfaces, .unanswered)).isEmpty, app)
        }
    }

    h.test("rule 2: a window on a hidden desktop is kept but not remembered") {
        // Recorded: cgSpaces=[4] while desktop 6 is active, AX says window-missing.
        // AX never lists windows on hidden desktops; that is not evidence of a ghost.
        let elsewhere = window(7, spaces: [4], onscreen: false)
        let judged = judge([elsewhere], .listed([:]))
        h.eq(judged.map(\.verdict), [.elsewhere])
        h.eq(real(judged), [7])
        h.ok(WindowFilter.remembered(after: judged, previously: []).isEmpty)
        // One confirmed while its desktop was visible stays remembered while away, so
        // it is held through the slide back to its desktop.
        h.eq(WindowFilter.remembered(after: judged, previously: [Key(elsewhere)]), [Key(elsewhere)])
        let snapshot = SpaceSnapshot(activeSpaceID: 6, judged: judged, runningBundleIDs: ["app"])
        h.eq(AppState.classify(target: AppTarget(bundleID: "app", name: nil), snapshot: snapshot), .windowElsewhere)
        // The desktop visible on a second display is visible too.
        h.eq(verdicts([elsewhere], .listed([:]), visible: [6, 4]), [7: .notListed])
        h.eq(verdicts([window(7, spaces: [4, 6], onscreen: false)], .listed([:])), [7: .notListed])
    }

    h.test("rule 2: a remembered on-screen window that Accessibility omits for one scan is held") {
        let document = window(1)
        let judged = judge([document], .listed([:]), remembered: [document])
        h.eq(judged.map(\.verdict), [.held])
        h.eq(WindowFilter.remembered(after: judged, previously: [Key(document)]), [Key(document)])
        h.eq(verdicts([document], .listed([:])), [1: .notListed]) // Never confirmed: nothing to hold.
        h.eq(verdicts([window(1, pid: 501)], .listed([:]), remembered: [document]), [1: .notListed])
        // Secondary displays can lack desktop membership; on screen is what holds it.
        h.eq(verdicts([window(1, spaces: [])], .listed([:]), remembered: [document]), [1: .held])
        h.eq(verdicts([window(1, spaces: [], known: false)], .listed([:]), remembered: [document]), [1: .held])
    }

    h.test("rule 2: a closed window that lingers on the visible desktop is not real") {
        // Remembered, now off-screen while still claiming desktop 6, and AX no longer lists it.
        let closed = window(1, onscreen: false)
        let judged = judge([closed], .listed([:]), remembered: [closed])
        h.eq(judged.map(\.verdict), [.notListed])
        h.ok(WindowFilter.remembered(after: judged, previously: [Key(closed)]).isEmpty)
        let snapshot = SpaceSnapshot(activeSpaceID: 6, judged: judged, runningBundleIDs: ["app"])
        h.ok(DockModel.apps(onCurrentSpace: snapshot).isEmpty)
        h.eq(AppState.classify(target: AppTarget(bundleID: "app", name: nil), snapshot: snapshot), .runningWindowless)
        h.eq(verdicts([window(1, onscreen: false, known: false)], .listed([:]), remembered: [closed]), [1: .notListed])
    }

    h.test("rule 3: an expired Accessibility budget holds the last verdict and adds only what is on screen") {
        // Recorded: 92 records marked ax=deadline in two minutes after launch.
        let first = window(1), second = window(2, onscreen: false), opened = window(4)
        let helper = window(3, onscreen: false, bounds: CGRect(x: 427, y: 85, width: 873, height: 161))
        let judged = judge([first, helper, second, opened], .unanswered, remembered: [first, second])
        h.eq(real(judged), [1, 2, 4])
        h.eq(judged.map(\.verdict), [.held, .noAnswer, .held, .unverified])
        h.eq(WindowFilter.remembered(after: judged, previously: [Key(first), Key(second)]), [Key(first), Key(second)])
        h.eq(verdicts([window(4, spaces: [])], .unanswered), [4: .unverified])
        h.eq(verdicts([window(4, onscreen: false, hidden: true)], .unanswered), [4: .noAnswer])
        h.eq(verdicts([window(4, pid: 501, onscreen: false)], .unanswered, remembered: [window(4)]), [4: .noAnswer])
        h.eq(verdicts([window(5, spaces: [4], onscreen: false)], .unanswered), [5: .elsewhere])
        h.eq(verdicts([window(6, spaces: [], onscreen: false)], .unanswered), [6: .noSpace])
    }

    h.test("rule 3: an app that never answers shows its on-screen window, not its off-screen leftover") {
        let shown = window(1), leftover = window(2, onscreen: false)
        var remembered: Set<Key> = []
        for _ in 0..<3 {
            let judged = WindowFilter.judge([leftover, shown], accessibility: .unanswered,
                                            visibleSpaces: [6], remembered: remembered)
            remembered = WindowFilter.remembered(after: judged, previously: remembered)
            h.eq(judged.map(\.verdict), [.noAnswer, .unverified])
            h.eq(real(judged), [1])
            h.ok(remembered.isEmpty)
            h.eq(DockModel.apps(onCurrentSpace: SpaceSnapshot(activeSpaceID: 6, judged: judged)).map(\.windowCount), [1])
        }
        // Not remembered, so nothing holds it once the app answers without it or it leaves the screen.
        h.eq(verdicts([shown], .listed([:])), [1: .notListed])
        h.eq(verdicts([window(1, onscreen: false)], .unanswered), [1: .noAnswer])
    }

    h.test("rule 4: without Accessibility permission only window-server facts decide") {
        h.eq(verdicts([window(1)], .untrusted), [1: .unverified])
        h.eq(verdicts([window(1, spaces: [])], .untrusted), [1: .unverified])
        h.eq(verdicts([window(2, onscreen: false, hidden: true)], .untrusted), [2: .unverified])
        h.eq(verdicts([window(3, spaces: [4], onscreen: false)], .untrusted), [3: .elsewhere])
        h.eq(verdicts([window(4, onscreen: false)], .untrusted), [4: .noAnswer])
        h.eq(verdicts([window(4, onscreen: false)], .untrusted, remembered: [window(4)]), [4: .noAnswer])
        h.eq(verdicts([window(5, spaces: [], onscreen: false)], .untrusted), [5: .noSpace])
        // Shown, but only Accessibility can confirm a window worth remembering.
        let judged = judge([window(1), window(3, spaces: [4], onscreen: false)], .untrusted)
        h.eq(real(judged), [1, 3])
        h.ok(WindowFilter.remembered(after: judged, previously: []).isEmpty)
    }

    h.test("recorded helper surfaces and hover previews never add a window") {
        // Firefox omitted its hover preview from AX, Safari listed
        // its preview as AXUnknown. Then hidden Safari helpers next to the
        // AX-confirmed browser window, on either display. Last: a confirmed helper.
        let cases: [(pid_t, CGWindowID, CGWindowID, SpaceID, Bool, Kind?)] = [
            (1789, 155, 12619, 6, true, nil), (47591, 11341, 12627, 4, true, preview),
            (3923, 27082, 27087, 5, false, nil), (3923, 25677, 25681, 389, false, nil),
            (3923, 33834, 33837, 4, false, nil), (47591, 8176, 8180, 4, false, suggestions)]
        for (pid, documentID, surfaceID, space, onscreen, kind) in cases {
            let document = window(documentID, pid: pid, spaces: [space])
            let surface = window(surfaceID, pid: pid, spaces: [space], onscreen: onscreen,
                                 bounds: CGRect(x: 292, y: 144, width: 280, height: 207))
            var listed = [documentID: standard]
            listed[surfaceID] = kind
            for remembered in [[], [document]] {
                let judged = judge([surface, document], .listed(listed), visible: [space, 99], remembered: remembered)
                h.eq(real(judged), [documentID])
                h.eq(DockModel.apps(onCurrentSpace: SpaceSnapshot(activeSpaceID: space, judged: judged)).first?.windowCount, 1)
            }
            // A confirmed non-window does not become one by being the app's last entry.
            if kind == suggestions { h.ok(real(judge([surface], .listed(listed), visible: [space])).isEmpty) }
        }
    }

    h.test("recorded Safari helper stays excluded through its parent's minimize and restore") {
        // Document 31288 minimizes (and reads as AXDialog while
        // minimized); hidden helper 31104 shares its desktop; 31105 is a separate
        // real window on the other display.
        let helper = window(31104, pid: 3923, spaces: [5], onscreen: false,
                            bounds: CGRect(x: 1051, y: 107, width: 926, height: 347))
        let other = window(31105, pid: 3923, spaces: [392], bounds: CGRect(x: 3078, y: 67, width: 1857, height: 1147))
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        var remembered: Set<Key> = []
        for (onscreen, minimized) in [(true, false), (true, true), (false, true), (true, false)] {
            let document = window(31288, pid: 3923, spaces: [5], onscreen: onscreen, minimized: minimized,
                                  bounds: CGRect(x: 615, y: 84, width: 1857, height: 1147))
            let kind = Kind(role: "AXWindow", subrole: minimized ? "AXDialog" : "AXStandardWindow",
                            isModal: false, isMinimized: minimized)
            let judged = WindowFilter.judge([helper, document, other], accessibility: .listed([31288: kind, 31105: standard]),
                                            visibleSpaces: [5, 392], remembered: remembered)
            remembered = WindowFilter.remembered(after: judged, previously: remembered)
            h.eq(real(judged), [31288, 31105])
            h.eq(remembered, [Key(document), Key(other)])
            let snapshot = SpaceSnapshot(activeSpaceID: 5, judged: judged)
            h.eq(snapshot.windows.first?.isMinimized, minimized)
            let dock = DockRefresher.displayApps(onDisplay: screen, snapshot: snapshot, visibleSpace: 5,
                pinnedHere: [], pinnedEverywhere: [], order: [],
                options: .init(expandPerWindow: true, shouldLabel: { _ in false }),
                nameForBundleID: { $0 }, titleForWindow: { _, _ in nil })
            h.eq(dock.map(\.windowID), [CGWindowID(31288)])
        }
    }

    h.test("the remembered set cannot grow: closed windows leave it and a recycled id is a stranger") {
        var remembered: Set<Key> = []
        func scan(_ candidates: [WindowInfo], _ accessibility: WindowFilter.Accessibility) -> [WindowFilter.Verdict] {
            let judged = WindowFilter.judge(candidates, accessibility: accessibility,
                                            visibleSpaces: [6], remembered: remembered)
            remembered = WindowFilter.remembered(after: judged, previously: remembered)
            return judged.map(\.verdict)
        }
        for id in CGWindowID(1)...100 {
            h.eq(scan([window(id)], .listed([id: standard])), [.confirmed])
            h.eq(remembered, [Key(window(id))])
            // Closed: gone from the window server, or left behind as a surface.
            h.eq(scan(id % 2 == 0 ? [] : [window(id, spaces: [], onscreen: false)], .listed([:])),
                 id % 2 == 0 ? [] : [.noSpace])
            h.ok(remembered.isEmpty)
        }
        // Silent scans hold what is remembered without adding to it, whatever they show.
        h.eq(scan([window(1), window(2)], .listed([1: standard, 2: standard])), [.confirmed, .confirmed])
        for _ in 0..<100 {
            h.eq(scan([window(1), window(2), window(3)], .unanswered), [.held, .held, .unverified])
            h.eq(remembered.count, 2)
        }
        // The same window id under another process was never confirmed.
        h.eq(scan([window(1, pid: 777, onscreen: false)], .unanswered), [.noAnswer])
        h.ok(remembered.isEmpty)
        h.eq(scan([window(1, pid: 777)], .listed([1: standard])), [.confirmed])
        h.eq(remembered, [Key(window(1, pid: 777))])
        h.ok(!remembered.contains(Key(window(1))))
    }

    h.test("an app whose only candidate is not a window still owns one: it is not window-less") {
        let leftover = window(9, pid: 900, bundle: "com.spotify.client", spaces: [], onscreen: false)
        let prompt = window(11, pid: 910, bundle: "dialog.only")
        let note = window(10, pid: 100, bundle: "com.apple.Notes")
        let judged = judge([leftover], .listed([:])) + judge([prompt], .listed([11: modalDialog]))
            + judge([note], .listed([10: standard]))
        h.eq(judged.map(\.verdict), [.noSpace, .notWindow, .confirmed])
        let snapshot = SpaceSnapshot(activeSpaceID: 6, judged: judged,
                                     runningBundleIDs: ["com.spotify.client", "dialog.only", "com.apple.Notes"])
        h.eq(snapshot.windows.map(\.windowID), [10])
        h.eq(snapshot.windowOwnerPIDs, [900, 910, 100])
        h.eq(snapshot.droppingHiddenWindows().windowOwnerPIDs, [900, 910, 100])
        h.eq(DockModel.apps(onCurrentSpace: snapshot).map(\.name), ["com.apple.Notes"])
        // Launching it reuses the running instance instead of treating a leftover as a window.
        h.eq(AppState.classify(target: AppTarget(bundleID: "com.spotify.client", name: nil), snapshot: snapshot),
             .runningWindowless)
        // Hand-built snapshots always count the owners of their windows.
        h.eq(SpaceSnapshot(activeSpaceID: 6, windows: [note]).windowOwnerPIDs, [100])
        h.eq(SpaceSnapshot(activeSpaceID: 6, windows: [note], windowOwnerPIDs: [900]).windowOwnerPIDs, [100, 900])
    }

    h.test("the scan log names only apps whose window count changed, without window content") {
        let safari = [window(470, bundle: "com.apple.Safari"),
                      window(485, bundle: "com.apple.Safari", onscreen: false)]
        let leftover = [window(9, pid: 900, bundle: "com.spotify.client", spaces: [], onscreen: false)]
        let judged = judge(safari, .listed([470: standard])) + judge(leftover, .listed([:]))
        let first = WindowFilter.changeLog(judged, previousCounts: [:])
        h.eq(first.counts, ["com.apple.Safari": 1])
        h.eq(first.line, "Window inventory changed: app=com.apple.Safari real=0->1 confirmed=1 notListed=1")
        let same = WindowFilter.changeLog(judged, previousCounts: first.counts)
        h.eq(same.counts, first.counts)
        h.ok(same.line == nil)
        // The recorded ghost scan would have read 1->2.
        let ghost = judge(safari, .listed([470: standard, 485: standard])) + judge(leftover, .untrusted)
        h.eq(WindowFilter.changeLog(ghost, previousCounts: first.counts).line,
             "Window inventory changed: app=com.apple.Safari real=1->2 confirmed=2")
        let gone = WindowFilter.changeLog(judge(leftover, .listed([:])), previousCounts: ["com.apple.Safari": 2, "b": 1])
        h.ok(gone.counts.isEmpty)
        h.eq(gone.line, "Window inventory changed: app=b real=1->0 no-candidates; app=com.apple.Safari real=2->0 no-candidates")
    }
}
