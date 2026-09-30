// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SpaceKit

/// Block real background work without blocking the UI run loop, to reproduce a
/// desktop event arriving while another app is not answering the sampler.
private final class SlowRefreshReads: @unchecked Sendable {
    let sampleRelease = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var samples = 0
    private var space: SpaceID = 1
    private var spaceOnArrival: SpaceID?
    var sampleCount: Int { lock.withLock { samples } }
    /// `onArrival` switches after the running scan's last read, before its result reaches main.
    func setSpace(_ space: SpaceID, onArrival: Bool = false) {
        lock.withLock { if onArrival { spaceOnArrival = space } else { self.space = space } }
    }
    func readDisplays() -> [DisplaySpaceInfo] {
        let space = lock.withLock { self.space }
        return [DisplaySpaceInfo(displayUUID: "screen", bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
            currentSpaceID: space, currentSpaceUUID: "space-\(space)", isActive: true)]
    }
    /// Like the real inventory, lists every desktop's windows: one app per desktop.
    func readSample(_ options: DockRefreshCoordinator.Options) -> DockRefreshSample {
        let start = readDisplays()
        lock.withLock { samples += 1 }
        _ = sampleRelease.wait(timeout: .now() + 10)
        let windows = (1...4).map { desktop in
            WindowInfo(windowID: CGWindowID(desktop), pid: pid_t(100 + desktop), ownerName: "App \(desktop)",
                       bundleID: "test.desktop\(desktop)", spaceIDs: [SpaceID(desktop)],
                       bounds: CGRect(x: 20, y: 20, width: 600, height: 500),
                       isOnscreen: SpaceID(desktop) == start[0].currentSpaceID)
        }
        let end = readDisplays()
        lock.withLock { if let next = spaceOnArrival { space = next; spaceOnArrival = nil } }
        return DockRefreshSample(snapshot: SpaceSnapshot(activeSpaceID: start[0].currentSpaceID, windows: windows),
            startDisplays: start, displays: end, titles: [:], active: options.frontmostPID.map { CGWindowID($0) })
    }
}

/// What a dock was told to show. In the fake world a desktop lists only its own app.
private struct Shown: Equatable {
    let source: String, request: CGWindowID?, space: SpaceID, apps: [String?], animate: Bool
    static func scan(_ request: CGWindowID, space: SpaceID, animate: Bool) -> Shown {
        Shown(source: "scan", request: request, space: space, apps: ["test.desktop\(space)"], animate: animate)
    }
    static func memo(space: SpaceID) -> Shown {
        Shown(source: "memo", request: nil, space: space, apps: ["test.desktop\(space)"], animate: false)
    }
    static func projection(space: SpaceID) -> Shown {
        Shown(source: "projection", request: nil, space: space, apps: ["test.desktop\(space)"], animate: false)
    }
}

@MainActor private func pump(until done: () -> Bool, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !done(), Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005)) }
    return done()
}

@MainActor func runDockRefreshTests(_ check: (Bool, String) -> Void) {
    let reads = SlowRefreshReads()
    let coordinator = DockRefreshCoordinator(readSample: { reads.readSample($0) }, readDisplays: { reads.readDisplays() })
    // Wired as AppDelegate wires it: a desktop change shows the memo, or on a first visit a
    // projection of the last validated inventory; a validated scan shows the fresh list.
    var memo = DockMemo()
    var latest: SpaceSnapshot?
    var shown: [Shown] = []
    var idleCount = 0
    func show(_ render: DockMemo.Render?, request: CGWindowID?, on info: DisplaySpaceInfo) {
        guard let render else { return }
        shown.append(Shown(source: render.source, request: request, space: info.currentSpaceID,
                           apps: render.apps.map(\.bundleID), animate: render.animate))
    }
    func apps(_ snapshot: SpaceSnapshot, on info: DisplaySpaceInfo) -> [DockApp] {
        DockModel.apps(onDisplay: info.bounds, snapshot: snapshot, visibleSpace: info.currentSpaceID)
    }
    coordinator.onDisplays = { displays in
        for info in displays {
            show(memo.recall(info) { latest.map { apps($0.placedWindowsOnly(), on: info) } }, request: nil, on: info)
        }
    }
    coordinator.onSample = { sample in
        guard let snapshot = sample.snapshot, !sample.displays.isEmpty else { return } // as in production
        latest = snapshot
        for info in sample.displays { show(memo.store(apps(snapshot, on: info), for: info), request: sample.active, on: info) }
    }
    coordinator.onIdle = { idleCount += 1 }
    func request(_ id: pid_t, desktopChanged: Bool = false) {
        coordinator.request(options: .init(labels: true, frontmostPID: id), desktopChanged: desktopChanged)
    }

    request(11, desktopChanged: true)
    check(shown.isEmpty, "A desktop change before the first inventory shows nothing")
    check(pump { reads.sampleCount == 1 }, "First scan starts off-main")
    for _ in 0..<50 { request(22) }
    reads.sampleRelease.signal()
    check(pump { reads.sampleCount == 2 }, "App notifications produce a single follow-up")
    check(shown == [.scan(11, space: 1, animate: false)], "App notification burst does not discard the completed scan")
    reads.sampleRelease.signal()
    check(pump { idleCount == 1 }, "One idle callback rearms polling after the coalesced scan")
    check(shown == [.scan(11, space: 1, animate: false), .scan(22, space: 1, animate: true)] && reads.sampleCount == 2,
          "No unbounded scan backlog; the follow-up uses the latest options")

    shown = []
    request(33)
    check(pump { reads.sampleCount == 3 }, "Slow scan starts on desktop 1")
    reads.setSpace(2)
    reads.sampleRelease.signal()
    check(pump { reads.sampleCount == 4 }, "A scan that straddles a desktop switch requests a rescan")
    check(shown.isEmpty && idleCount == 1, "A scan that started on desktop 1 and ended on desktop 2 is not rendered")
    reads.sampleRelease.signal()
    check(pump { idleCount == 2 }, "The rescan rearms polling")
    check(shown == [.scan(33, space: 2, animate: false)] && reads.sampleCount == 4,
          "Exactly one rescan renders the desktop now showing, without animation")

    shown = []
    reads.setSpace(3)
    request(44)
    check(pump { reads.sampleCount == 5 }, "Scan starts on desktop 3 before the desktop change is announced")
    request(55, desktopChanged: true)
    check(shown == [.projection(space: 3)],
          "First visit to a desktop shows the last inventory projected onto it, at once, without animation")
    reads.sampleRelease.signal()
    check(pump { reads.sampleCount == 6 }, "A desktop change during a scan produces a single follow-up")
    check(shown == [.projection(space: 3), .scan(44, space: 3, animate: false)],
          "A scan in flight during a desktop change replaces the projection once, without animation")
    reads.sampleRelease.signal()
    check(pump { idleCount == 3 }, "The follow-up rearms polling")
    check(shown == [.projection(space: 3), .scan(44, space: 3, animate: false), .scan(55, space: 3, animate: true)],
          "Later renders on the same desktop animate")

    shown = []
    reads.setSpace(1)
    request(66, desktopChanged: true)
    check(shown == [.memo(space: 1)],
          "Returning to a desktop shows its memo at once, before any scan completes, without animation")
    check(pump { reads.sampleCount == 7 }, "Scan starts on desktop 1")
    reads.setSpace(2, onArrival: true)
    reads.sampleRelease.signal()
    check(pump { reads.sampleCount == 8 }, "A scan overtaken by a desktop switch requests a rescan")
    check(shown == [.memo(space: 1)], "A scan of desktop 1 that arrives while desktop 2 is showing is not rendered")
    request(77, desktopChanged: true)
    check(shown == [.memo(space: 1), .memo(space: 2)], "Rapid switches show each desktop's own memo")
    reads.sampleRelease.signal()
    check(pump { reads.sampleCount == 9 }, "Burst produces one scan follow-up")
    reads.sampleRelease.signal()
    check(pump { idleCount == 4 }, "The last scan rearms polling")
    check(shown == [.memo(space: 1), .memo(space: 2),
                    .scan(66, space: 2, animate: false), .scan(77, space: 2, animate: true)],
          "The first validated render after a memo does not animate; later ones do")

    shown = []
    request(81)
    check(pump { reads.sampleCount == 10 }, "Scan starts on desktop 2")
    reads.setSpace(1)
    request(82, desktopChanged: true)
    reads.setSpace(2)
    request(83, desktopChanged: true)
    reads.sampleRelease.signal()
    check(pump { reads.sampleCount == 11 }, "A scan that straddles a round trip requests a rescan")
    check(shown == [.memo(space: 1), .memo(space: 2)],
          "A scan that starts and ends on desktop 2 but saw desktop 1 in between is not rendered")
    reads.sampleRelease.signal()
    check(pump { idleCount == 5 }, "The rescan after a round trip rearms polling")
    check(shown == [.memo(space: 1), .memo(space: 2), .scan(83, space: 2, animate: false)] && reads.sampleCount == 11,
          "Exactly one rescan renders the round trip's desktop, without animation")

    shown = []
    request(88)
    check(pump { reads.sampleCount == 12 }, "Sleep fixture starts its slow scan")
    request(99)
    coordinator.suspend()
    reads.sampleRelease.signal()
    _ = pump(until: { false }, timeout: 0.1)
    check(shown.isEmpty && reads.sampleCount == 12 && idleCount == 5,
          "Suspension discards a late result, pending work, and poll rearming")
    request(111, desktopChanged: true)
    check(pump { reads.sampleCount == 13 }, "Resume starts a fresh scan")
    reads.sampleRelease.signal()
    check(pump { shown == [.scan(111, space: 2, animate: true)] }, "Resume publishes again")
    check(pump { idleCount == 6 }, "Resume rearms polling")

    shown = []
    request(121)
    check(pump { reads.sampleCount == 14 }, "Scan starts before a short sleep")
    coordinator.suspend()
    request(122, desktopChanged: true)
    reads.sampleRelease.signal()
    check(pump { reads.sampleCount == 15 }, "A scan that ran through a suspension requests a rescan")
    check(shown.isEmpty, "A result from before a suspension is discarded even when it arrives after resume")
    reads.sampleRelease.signal()
    check(pump { shown == [.scan(122, space: 2, animate: true)] }, "The rescan after a short sleep publishes")
    coordinator.suspend()

    // The memo itself: the last validated list per display and desktop, titles included.
    let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
    let inventory = SpaceSnapshot(activeSpaceID: 1, windows: [
        WindowInfo(windowID: 1, pid: 101, ownerName: "Old", bundleID: "test.old", spaceIDs: [1],
                   bounds: CGRect(x: 20, y: 20, width: 600, height: 500)),
        WindowInfo(windowID: 2, pid: 102, ownerName: "New", bundleID: "test.new", spaceIDs: [2],
                   bounds: CGRect(x: 20, y: 20, width: 600, height: 500), isOnscreen: false),
        WindowInfo(windowID: 3, pid: 103, ownerName: "Right", bundleID: "test.right", spaceIDs: [9],
                   bounds: CGRect(x: 1020, y: 20, width: 600, height: 500)),
    ])
    func desktop(_ display: String, _ bounds: CGRect, _ space: SpaceID, uuid: String? = nil) -> DisplaySpaceInfo {
        DisplaySpaceInfo(displayUUID: display, bounds: bounds, currentSpaceID: space,
                         currentSpaceUUID: uuid ?? "space-\(space)", isActive: display == "left")
    }
    func scanned(_ info: DisplaySpaceInfo) -> [DockApp] {
        DockModel.apps(onDisplay: info.bounds, snapshot: inventory, visibleSpace: info.currentSpaceID)
            .map { $0.withTitle("Window of \($0.name)") }
    }
    let left1 = desktop("left", left, 1), left2 = desktop("left", left, 2), right9 = desktop("right", right, 9)
    var docks = DockMemo()
    var projections = 0 // how often a projection was asked for
    func recall(_ info: DisplaySpaceInfo, projecting apps: [DockApp]? = nil) -> DockMemo.Render? {
        docks.recall(info) { projections += 1; return apps }
    }
    check(recall(left1) == nil && recall(right9) == nil && projections == 2,
          "First visit to a desktop before there is an inventory shows nothing")
    var render = docks.store(scanned(left1), for: left1)
    check(render.apps.map(\.bundleID) == ["test.old"] && !render.animate && render.changed,
          "First render of a desktop is a change and does not animate")
    render = docks.store(scanned(left1), for: left1)
    check(render.animate && !render.changed, "An identical scan on the same desktop is not a change")
    render = docks.store([], for: left1)
    check(render.animate && render.changed, "A different list on the same desktop is a change and animates")
    _ = docks.store(scanned(left1), for: left1)
    render = docks.store(scanned(right9), for: right9)
    projections = 0
    check(render.apps.map(\.bundleID) == ["test.right"] && render.source == "scan"
          && recall(right9, projecting: scanned(left1)) == nil && projections == 0,
          "A display that stayed on its desktop has nothing to swap, memo or not")

    check(recall(left2) == nil, "A memo for desktop 1 is never returned for desktop 2")
    check(recall(desktop("right", right, 1)) == nil, "A memo is never returned for another display")
    _ = docks.store(scanned(right9), for: right9)
    render = docks.store(scanned(left2), for: left2)
    check(render.apps.map(\.bundleID) == ["test.new"] && !render.animate && render.changed,
          "The first validated render after a desktop change does not animate")
    check(docks.store(scanned(left2), for: left2).animate, "Later renders on that desktop animate")

    projections = 0
    let returning = recall(left1, projecting: [])
    check(returning?.apps == scanned(left1) && returning?.animate == false && returning?.changed == true
          && returning?.source == "memo" && projections == 0,
          "Returning to a desktop recalls exactly its last validated list, without animation")
    check(recall(right9) == nil && docks.store(scanned(right9), for: right9).animate,
          "Switching left desktop preserves the right display's dock")
    check(recall(left2)?.apps == scanned(left2) && !docks.store(scanned(left2), for: left2).animate,
          "Leaving and returning before a scan lands still suppresses that scan's animation")

    // A first visit: no memo, so the last inventory is projected onto the desktop. Provisional.
    let left3 = desktop("left", left, 3)
    let first = recall(left3, projecting: scanned(right9))
    check(first?.apps == scanned(right9) && first?.animate == false && first?.changed == true
          && first?.source == "projection", "A first visit shows the projection at once, without animation")
    check(recall(left1)?.source == "memo" && recall(left3) == nil
          && recall(left3, projecting: [])?.apps == [], "A projection is not stored: the next visit asks for one again")
    render = docks.store(scanned(left1), for: left3)
    check(render.apps == scanned(left1) && !render.animate && render.changed,
          "The validated scan replaces a projection without animation")
    check(docks.store(scanned(left1), for: left3).animate, "The scan after that one animates")
    _ = recall(left1)
    let second = recall(left3, projecting: [])
    check(second?.apps == scanned(left1) && second?.source == "memo",
          "Only the validated scan becomes the desktop's memo")

    let unnamed5 = desktop("left", left, 5, uuid: ""), unnamed6 = desktop("left", left, 6, uuid: "")
    _ = docks.store(scanned(left1), for: unnamed5)
    check(recall(unnamed6) == nil && recall(unnamed5)?.apps == scanned(left1),
          "Desktops without a UUID are told apart by their numeric id")

    docks.forget()
    check(recall(left1) == nil && recall(left2) == nil && recall(unnamed5) == nil,
          "A pin, preference or display change drops every memo")
    check(recall(left1, projecting: scanned(left1))?.source == "projection",
          "A desktop whose memo was dropped is projected like a first visit")
    check(docks.store(scanned(left2), for: left2).changed, "The scan after a dropped memo is a change")

    // The projection itself: the inventory read on desktop 1, shown on desktop 2.
    let seen = SpaceSnapshot(activeSpaceID: 1, windows: inventory.windows + [
        WindowInfo(windowID: 4, pid: 104, ownerName: "Minimized", bundleID: "test.min", spaceIDs: [2],
                   bounds: CGRect(x: 30, y: 30, width: 600, height: 500), isOnscreen: false, isMinimized: true),
        WindowInfo(windowID: 5, pid: 105, ownerName: "Unplaced", bundleID: "test.unplaced", spaceIDs: [],
                   bounds: CGRect(x: 30, y: 30, width: 600, height: 500), spaceMembershipKnown: false),
        WindowInfo(windowID: 6, pid: 106, ownerName: "Nowhere", bundleID: "test.nowhere", spaceIDs: [],
                   bounds: CGRect(x: 30, y: 30, width: 600, height: 500)),
    ], windowOwnerPIDs: [107])
    func listed(_ snapshot: SpaceSnapshot) -> [DockApp] {
        DockRefresher.displayApps(onDisplay: left, snapshot: snapshot, visibleSpace: 2, allDisplays: [left, right],
            pinnedHere: ["test.pin"], pinnedEverywhere: [], order: ["test.min", "test.pin", "test.new"],
            options: .init(expandPerWindow: true, shouldLabel: { _ in true }),
            nameForBundleID: { $0 }, titleForWindow: { id, _ in "Title \(id)" })
    }
    check(listed(seen).map(\.bundleID) == ["test.min", "test.pin", "test.new", "test.nowhere", "test.unplaced"],
          "Fixture: an old on-screen flag alone would put windows without a Space on desktop 2")
    let projected = listed(seen.placedWindowsOnly())
    check(projected.map(\.bundleID) == ["test.min", "test.pin", "test.new"],
          "A projection has the desktop's windows and its pins in the saved order, and no window without a Space")
    check(projected.map(\.title) == ["Title 4", nil, "Title 2"] && projected.map(\.windowID) == [4, nil, 2],
          "A projection keeps the titles of the last scan, per window")
    check(seen.placedWindowsOnly().windowOwnerPIDs == seen.windowOwnerPIDs && seen.windowOwnerPIDs.contains(107),
          "A projection does not make the owner of a window without a Space look window-less")

    // Actual AppKit animations, in hidden panels. Do not change user settings.
    let prefs = Preferences.shared
    let a = DockApp(bundleID: "test.a", name: "A", pid: nil, windowCount: 0)
    let b = DockApp(bundleID: "test.b", name: "B", pid: nil, windowCount: 0)
    let c = DockApp(bundleID: "test.c", name: "C", pid: nil, windowCount: 0)
    for addition in [false, true] {
        let dock = DockPanel(screen: NSScreen.screens.first!)
        dock.update(apps: [a], animateChanges: false)
        if !SystemDisplay.reduceMotion, prefs.iconAnimationSpeed > 0.001,
           addition ? prefs.animateOnAdd : prefs.animateOnRemove {
            dock.update(apps: addition ? [a, b] : [])
            check(dock.isAnimating, "Real \(addition ? "addition" : "removal") animation started")
        } else {
            dock.isAnimating = true
            print("Animation completion check skipped: animations disabled in current settings")
        }
        dock.update(apps: [a, b]) // pending update from the old desktop
        dock.update(apps: [c], animateChanges: false)
        check(!dock.isAnimating && buttons(in: dock.contentView!).map { $0.app?.name } == ["C"],
              "Desktop change interrupts old animation immediately")
        _ = pump(until: { false }, timeout: 2 * prefs.iconAnimationSpeed + 0.2)
        check(buttons(in: dock.contentView!).map { $0.app?.name } == ["C"],
              "Delayed animation completions cannot restore old desktop icons")
        check(!dock.isVisible, "Animation regression fixture stays hidden")
    }
    // A pinned app losing its last window, or launching, swaps its icon in place.
    let open = DockApp(bundleID: "test.pin", name: "Pin", pid: 100, windowCount: 1, isPinnedHere: true,
                       windowIDs: [7], windowID: 7)
    let idle = DockApp(bundleID: "test.pin", name: "Pin", pid: nil, windowCount: 0, isPinnedHere: true)
    if SystemDisplay.reduceMotion || prefs.iconAnimationSpeed <= 0.001 || !(prefs.animateOnAdd || prefs.animateOnRemove) {
        print("Pinned icon check cannot fail: animations disabled in current settings")
    }
    for (old, new) in [(open, idle), (idle, open)] {
        let dock = DockPanel(screen: NSScreen.screens.first!)
        dock.update(apps: [old], animateChanges: false)
        dock.update(apps: [new])
        check(!dock.isAnimating && buttons(in: dock.contentView!).map { $0.app } == [new],
              "Pinned icon stays in place when its app \(new.isRunning ? "launches" : "closes its last window")")
        check(!dock.isVisible, "Pinned icon fixture stays hidden")
    }
    // A neighbour quitting in the same refresh leaves alone, around the pinned icon.
    // (A hidden panel's animation does not complete here, so only its start is checked.)
    let windowless = DockApp(bundleID: "test.pin", name: "Pin", pid: 100, windowCount: 0, isPinnedHere: true)
    let dock = DockPanel(screen: NSScreen.screens.first!)
    dock.update(apps: [open, b], animateChanges: false)
    dock.update(apps: [windowless])
    check(buttons(in: dock.contentView!).first?.layer?.opacity == 1, "Pinned icon stays visible while a neighbour leaves")
    check(!dock.isVisible, "Pinned icon fixture stays hidden")
}
