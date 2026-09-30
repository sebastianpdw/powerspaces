// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import CSpaceSwitch
import Foundation
import SpaceKit

private func scratch(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("powerspaces-repair-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private final class FakeQuit: QuitParticipant {
    var requests = 0
    var hasExited = false
    let accepts: Bool
    init(accepts: Bool) { self.accepts = accepts }
    func requestQuit() { requests += 1; hasExited = accepts }
}

func runRepairTests(_ h: Harness) {
    print("Repair regressions")
    h.test("Safari's minimized AXDialog is restorable but real dialogs and helpers remain excluded") {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let document = WindowInfo(windowID: 8162, pid: 47591, ownerName: "App", bundleID: "app",
            spaceIDs: [4], bounds: screen, isOnscreen: false, isMinimized: true)
        let stale = WindowInfo(windowID: 8166, pid: 47591, ownerName: "App", bundleID: "app",
            spaceIDs: [4], bounds: screen, isOnscreen: false)
        let context = LaunchContext(spaceID: 4, displayBounds: screen)
        for modal in [Optional<Bool>.none, false] {
            let restorable = WindowFilter.isRestorableWindow(role: "AXWindow", subrole: "AXDialog", isModal: modal, isMinimized: true)
            h.ok(restorable)
            let recovered = WindowFocusPolicy.recoveryWindow(for: stale,
                in: SpaceSnapshot(activeSpaceID: 4, windows: [stale, document]), context: context,
                verifiedAXIDs: restorable ? [8162] : [])
            h.eq(recovered?.windowID, 8162)
        }
        for (role, subrole, modal, minimized) in [
            ("AXWindow", "AXDialog", false, false),
            ("AXWindow", "AXDialog", true, true),
            ("AXWindow", "AXSystemDialog", false, true),
            ("AXScrollArea", "AXDialog", false, true),
            ("AXSheet", "AXStandardWindow", false, true)
        ] {
            h.ok(!WindowFilter.isRestorableWindow(role: role, subrole: subrole, isModal: modal, isMinimized: minimized))
        }
    }
    h.test("missing or uncertain windows never select quit and reopen") {
        let target = AppTarget(bundleID: "app", name: nil)
        let config = StrategyConfig(byBundleID: ["app": AppStrategy(bundleID: "app", strategy: .quitReopen)], defaultKind: .newInstance)
        for forceNew in [false, true] {
            h.eq(LaunchEngine.decide(state: .runningWindowless, config: config, target: target, forceNew: forceNew),
                 .launchApp)
            h.eq(LaunchEngine.decide(state: .windowUnknown, config: config, target: target, forceNew: forceNew), .warnUnknown)
        }
        h.eq(LaunchEngine.decide(state: .windowElsewhere, config: config, target: target, forceNew: false), .newWindow(.quitReopen))
        h.eq(LaunchEngine.decide(state: .windowHere(windowID: 41, pid: 88, mode: .minimized),
            config: config, target: target, forceNew: false), .focusWindow(windowID: 41, pid: 88))
    }
    h.test("no-window apps share ordinary opening regardless of their additional-window strategy") {
        let target = AppTarget(bundleID: "any.app", name: nil)
        for kind in StrategyKind.allCases {
            let config = StrategyConfig(byBundleID: ["any.app": AppStrategy(bundleID: "any.app", strategy: kind)], defaultKind: kind)
            for forceNew in [false, true] {
                for state in [AppState.notRunning, .runningWindowless] {
                    h.eq(LaunchEngine.decide(state: state, config: config, target: target, forceNew: forceNew), .launchApp,
                         "\(state.label) must open normally, not execute \(kind)")
                    h.eq(LaunchEngine.dockClick(state: state, config: config, target: target, forceNew: forceNew), .launch)
                }
                h.eq(LaunchEngine.decide(state: .windowElsewhere, config: config, target: target, forceNew: forceNew), .newWindow(kind))
                h.eq(LaunchEngine.decide(state: .windowUnknown, config: config, target: target, forceNew: forceNew), .warnUnknown)
                let here = AppState.windowHere(windowID: 41, pid: 88, mode: .inactive)
                h.eq(LaunchEngine.decide(state: here, config: config, target: target, forceNew: forceNew),
                     forceNew ? .newWindow(kind) : .focusWindow(windowID: 41, pid: 88))
            }
        }
        // After an app's last documents closed, only a spaceless 500x500 helper
        // remained. Opening must reuse/activate the existing app.
        let mail = AppTarget(bundleID: "mail.app", name: nil)
        let helper = WindowInfo(windowID: 300, pid: 200, ownerName: "Mail", bundleID: mail.bundleID,
            spaceIDs: [], bounds: CGRect(x: 0, y: 940, width: 500, height: 500), isOnscreen: false)
        let snapshot = SpaceSnapshot(activeSpaceID: 4, windows: [helper], runningBundleIDs: ["mail.app"])
        h.eq(AppState.classify(target: mail, snapshot: snapshot), .runningWindowless)
        h.eq(LaunchEngine.decide(target: mail, snapshot: snapshot, config: .defaults, forceNew: false), .launchApp)
    }
    h.test("shared Spaces map to physical displays and reject changed desktop or layout contexts") {
        let a = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let b = CGRect(x: -1600, y: 0, width: 1600, height: 900)
        let physical = [(uuid: "A", bounds: a), (uuid: "B", bounds: b)]
        func managed(_ display: String, _ space: Int, type: Int = 0) -> [String: Any] {
            let current: [String: Any] = ["ManagedSpaceID": space, "uuid": "S\(space)", "type": type]
            return ["Display Identifier": display, "Current Space": current, "Spaces": [current]]
        }
        let shared = CGSSpaceProvider.displaySpaces(managed: [managed("Main", 3)],
            physicalDisplays: physical, activeUUID: "B")
        h.eq(shared.map(\.displayUUID), ["A", "B"])
        h.eq(shared.map(\.bounds), [a, b])
        h.eq(shared.map(\.currentSpaceID), [3, 3])
        h.eq(shared.map(\.isActive), [false, true])
        h.eq(shared.map(\.spaceIndex), [1, 1])
        let snapshot = SpaceSnapshot(activeSpaceID: 3, windows: [])
        let context = LaunchContext(display: shared[1])
        h.ok(context.isCurrent(snapshot: snapshot, displays: shared))
        let moved = CGSSpaceProvider.displaySpaces(managed: [managed("Main", 4)], physicalDisplays: physical, activeUUID: "B")
        h.ok(!context.isCurrent(snapshot: snapshot, displays: moved))
        h.ok(!context.isCurrent(snapshot: snapshot, displays: Array(shared.prefix(1))))
        let shifted = CGSSpaceProvider.displaySpaces(managed: [managed("Main", 3)],
            physicalDisplays: [(uuid: "A", bounds: a), (uuid: "B", bounds: b.offsetBy(dx: 10, dy: 0))], activeUUID: "B")
        h.ok(!context.isCurrent(snapshot: snapshot, displays: shifted))
        let main = CGSSpaceProvider.displaySpaces(managed: [managed("Main", 3, type: 4)], physicalDisplays: physical, activeUUID: "Main")
        h.eq(main.map(\.isActive), [true, false])
        h.eq(main.map(\.isFullscreen), [true, true])
        let separate = CGSSpaceProvider.displaySpaces(managed: [managed("A", 3), managed("B", 7)], physicalDisplays: physical, activeUUID: "A")
        h.eq(separate.map(\.currentSpaceID), [3, 7])
        h.eq(separate.map(\.isActive), [true, false])
        h.ok(CGSSpaceProvider.displaySpaces(managed: [managed("unknown", 3)], physicalDisplays: physical, activeUUID: "A").isEmpty)
        h.ok(CGSSpaceProvider.displaySpaces(managed: [managed("Main", 3), managed("A", 3)], physicalDisplays: physical, activeUUID: "A").allSatisfy { $0.displayUUID == "A" })
        h.ok(CGSSpaceProvider.displaySpaces(managed: [managed("Main", 0)], physicalDisplays: physical, activeUUID: nil).isEmpty)
        h.ok(CGSSpaceProvider.displaySpaces(managed: [managed("Main", 3)], physicalDisplays: [], activeUUID: nil).isEmpty)
    }
    h.test("exact AX lookup tolerates unmappable entries and uses focused/main identity only when it matches") {
        var reads: [String] = []
        func lookup(_ windows: [String], focused: String?, main: String?, id: CGWindowID = 41) -> String? {
            WindowFocusPolicy.exactWindow(id: id, windows: windows,
                focused: { reads.append("focused"); return focused },
                main: { reads.append("main"); return main },
                identify: { ["target": CGWindowID(41), "other": CGWindowID(42)][$0] })
        }
        h.eq(lookup(["unmappable", "target"], focused: "other", main: "other"), "target")
        h.ok(reads.isEmpty)
        h.eq(lookup(["unmappable"], focused: "target", main: "other"), "target")
        h.eq(reads, ["focused"])
        reads = []
        h.eq(lookup([], focused: "other", main: "target"), "target")
        h.eq(reads, ["focused", "main"])
        h.eq(lookup(["other"], focused: "other", main: "other"), nil)
        h.eq(lookup([], focused: nil, main: nil), nil)
        h.eq(lookup(["target"], focused: "target", main: "target", id: 0), nil)
    }
    h.test("visible reorder preserves absent slots and round-trips when an app returns") {
        var pins = PinModel(orderBySpace: ["S": ["A", "B", "C"]])
        pins.reorderVisible(["C", "A", "C"], onSpace: "S")
        h.eq(pins.order(onSpace: "S"), ["C", "B", "A"])
        let apps = ["A", "B", "C"].enumerated().map {
            win(CGWindowID($0.offset + 1), name: $0.element, bundle: $0.element, spaces: [1])
        }
        h.eq(DockModel.apps(onCurrentSpace: SpaceSnapshot(activeSpaceID: 1, windows: apps),
                            pinnedHere: [], pinnedEverywhere: [], order: pins.order(onSpace: "S"),
                            nameForBundleID: { $0 }).map(\.orderKey), ["C", "B", "A"])
        pins.reorderVisible(["A", "D", "C"], onSpace: "S")
        h.eq(pins.order(onSpace: "S"), ["A", "B", "D", "C"])
        pins.reorderVisible([], onSpace: "S")
        h.eq(pins.order(onSpace: "S"), ["A", "B", "D", "C"])
        pins.setOrder([], onSpace: "S")
        h.eq(pins.order(onSpace: "S"), [])
    }
    h.test("each expanded window keeps its owner through pinned/excluded arrangement and labels") {
        let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
            win(10, 100, name: "A", bundle: "a", spaces: [1]),
            win(11, 200, name: "A", bundle: "a", spaces: [1])])
        for (here, everywhere, excluded) in [([], [], []), (["a"], [], []), ([], ["a"], ["a"])] {
            let apps = DockModel.apps(onCurrentSpace: snap, pinnedHere: here,
                                      pinnedEverywhere: everywhere, excludedHere: excluded,
                                      nameForBundleID: { $0 })
            let expanded = DockModel.expandingPerWindow(apps).map { $0.withTitle("pid:\($0.pid!)").withActive(true) }
            h.eq(expanded.map(\.pid), [pid_t(100), pid_t(200)])
            h.eq(expanded.map(\.title), ["pid:100", "pid:200"])
            h.eq(expanded.map(\.windowPIDs), [[10: pid_t(100), 11: pid_t(200)], [10: pid_t(100), 11: pid_t(200)]])
            let survivor = DockModel.expandingPerWindow(DockModel.apps(onCurrentSpace: SpaceSnapshot(activeSpaceID: 1, windows: [snap.windows[1]])))
            h.eq(survivor.first?.slotIdentity, expanded[1].slotIdentity)
        }
    }
    h.test("an app in both lists changes only by its icon count, so a pinned icon never leaves") {
        func icon(_ window: CGWindowID? = nil) -> DockApp {
            DockApp(bundleID: "b", name: "B", pid: window == nil ? nil : 7, windowCount: window == nil ? 0 : 1,
                    windowID: window)
        }
        func changes(_ old: [DockApp], _ new: [DockApp]) -> [[String]] {
            let changes = DockModel.slotChanges(from: old, to: new)
            return [changes.leaving.sorted(), changes.entering.sorted()]
        }
        h.eq(changes([icon(1)], [icon()]), [[], []], "last window closed, entry stays")
        h.eq(changes([icon()], [icon(1)]), [[], []], "window-less entry gains a window")
        h.eq(changes([icon(1), icon(2)], [icon(2)]), [["b:7:1"], []], "one of two windows closed")
        h.eq(changes([icon(1)], [icon(1), icon(2)]), [[], ["b:7:2"]], "second window opened")
        h.eq(changes([icon(1), icon(2)], [icon()]), [["b:7:2"], []], "close all with two windows")
        h.eq(changes([icon(1)], []), [["b:7:1"], []], "app left")
        h.eq(changes([], [icon(1)]), [[], ["b:7:1"]], "app arrived")
        // The real arrangement lists a pin in every state, and no step between them animates.
        let windowless = DockApp(bundleID: "b", name: "B", pid: 7, windowCount: 0)
        let states = [([win(1, 7, name: "B", bundle: "b", spaces: [1])], []), ([], [windowless]), ([], [])].map {
            DockModel.expandingPerWindow(DockModel.apps(
                onCurrentSpace: SpaceSnapshot(activeSpaceID: 1, windows: $0.0), pinnedHere: ["b"],
                pinnedEverywhere: [], windowlessApps: $0.1, nameForBundleID: { $0 }))
        }
        h.eq(states.map { $0.map(\.slotIdentity) }, [["b:7:1"], ["b"], ["b"]])
        h.ok(states.allSatisfy { $0.allSatisfy(\.isPinned) })
        for (old, new) in zip(states, states.dropFirst() + states.prefix(1)) {
            h.eq(changes(old, new), [[], []], "\(old.map(\.slotIdentity)) to \(new.map(\.slotIdentity))")
        }
    }
    h.test("group drag moves all copies and never splits another app; persisted preview agrees") {
        let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
            win(1, name: "A", bundle: "a", spaces: [1]), win(2, name: "A", bundle: "a", spaces: [1]),
            win(3, name: "B", bundle: "b", spaces: [1]), win(4, name: "B", bundle: "b", spaces: [1]),
            win(5, name: "C", bundle: "c", spaces: [1])])
        let apps = DockModel.expandingPerWindow(DockModel.apps(onCurrentSpace: snap))
        for index in -1...5 {
            let preview = DockModel.reorderingGroup(apps, key: "a", insertion: index)
            var pins = PinModel()
            pins.reorderVisible(preview.map(\.orderKey).uniqued(), onSpace: "S")
            let refreshed = DockModel.expandingPerWindow(DockModel.apps(onCurrentSpace: snap,
                pinnedHere: [], pinnedEverywhere: [], order: pins.order(onSpace: "S"), nameForBundleID: { $0 }))
            h.eq(refreshed.map(\.slotIdentity), preview.map(\.slotIdentity), "insertion \(index)")
        }
        h.eq(DockModel.reorderingGroup(apps, key: "a", insertion: 1).map(\.orderKey), ["b", "b", "a", "a", "c"])
    }
    h.test("desktop close requires positive membership even for minimized/hidden same-display windows") {
        let rect = CGRect(x: 10, y: 10, width: 700, height: 500)
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let cases = [dwin(1, name: "A", bundle: "a", rect: rect, spaces: [1]),
                     dwin(2, name: "A", bundle: "a", rect: rect, onscreen: false, minimized: true, spaces: [2]),
                     dwin(3, name: "A", bundle: "a", rect: rect, onscreen: false, hidden: true, spaces: [2]),
                     dwin(4, name: "A", bundle: "a", rect: rect, spaces: [])]
        h.eq(cases.filter { $0.canClose(onSpace: 1, display: display) }.map(\.windowID), [CGWindowID(1)])
        h.ok(!cases[0].canClose(onSpace: 1, display: CGRect(x: 1920, y: 0, width: 1920, height: 1080)))
    }
    h.test("onscreen unknown membership agrees in per-display render and classification; unscoped/hidden unknown warns") {
        let display = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let target = AppTarget(bundleID: "a", name: "A")
        let visible = dwin(1, 200, name: "A", bundle: "a", rect: CGRect(x: 2000, y: 100, width: 700, height: 500), spaces: [])
        let snap = SpaceSnapshot(activeSpaceID: 1, windows: [visible], runningBundleIDs: ["a"])
        h.eq(DockModel.apps(onDisplay: display, snapshot: snap, visibleSpace: 9).first?.windowIDs, [CGWindowID(1)])
        h.eq(AppState.classify(target: target, snapshot: snap, currentSpace: 9, display: display), .windowHere(windowID: 1, pid: 200, mode: .inactive))
        h.eq(AppState.classify(target: target, snapshot: snap), .windowUnknown)
        h.eq(LaunchEngine.decide(state: .windowUnknown, config: .defaults, target: target, forceNew: false), .warnUnknown)
        for minimized in [false, true] {
            let hidden = dwin(2, name: "A", bundle: "a", rect: visible.bounds, onscreen: false,
                              minimized: minimized, hidden: !minimized, spaces: [])
            let uncertain = SpaceSnapshot(activeSpaceID: 1, windows: [hidden], runningBundleIDs: ["a"])
            h.eq(AppState.classify(target: target, snapshot: uncertain, currentSpace: 9, display: display), .windowUnknown)
            h.eq(DockModel.apps(onDisplay: display, snapshot: uncertain, visibleSpace: 9).count, 0)
        }
    }
    h.test("click uses classified minimized/hidden modes and windowless Mail reopens instead of an elsewhere warning") {
        let target = AppTarget(bundleID: "com.apple.mail", name: "Mail")
        for mode in [AppState.WindowMode.minimized, .hidden, .inactive] {
            h.eq(LaunchEngine.dockClick(state: .windowHere(windowID: 1, pid: 100, mode: mode),
                                       config: .defaults, target: target, forceNew: false), .raise(windowID: 1, pid: 100))
        }
        h.eq(LaunchEngine.dockClick(state: .windowHere(windowID: 1, pid: 100, mode: .active),
                                   config: .defaults, target: target, forceNew: false), .minimize(windowID: 1, pid: 100))
        h.eq(LaunchEngine.decide(state: .runningWindowless, config: .defaults, target: target, forceNew: false), .launchApp)
        h.eq(LaunchEngine.decide(state: .windowElsewhere, config: .defaults, target: target, forceNew: false), .newWindow(.warn))
    }
    h.test("failed membership and unknown geometry cannot masquerade as windowless or a safe desktop close") {
        let target = AppTarget(bundleID: "a", name: "A")
        let failed = WindowInfo(windowID: 1, pid: 100, ownerName: "A", bundleID: "a", spaceIDs: [],
                                isOnscreen: false, spaceMembershipKnown: false)
        let snap = SpaceSnapshot(activeSpaceID: 1, windows: [failed], runningBundleIDs: ["a"])
        h.eq(snap.realWindows(of: target).count, 1)
        h.eq(AppState.classify(target: target, snapshot: snap), .windowUnknown)
        let unknownFrame = win(2, name: "A", bundle: "a", spaces: [1])
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        h.ok(!unknownFrame.canClose(onSpace: 1, display: display))
        h.eq(AppState.classify(target: target, snapshot: SpaceSnapshot(activeSpaceID: 1, windows: [unknownFrame]),
                               display: display), .windowUnknown)
    }
    h.test("secondary context survives menu-bar focus changes but cancels on space identity/layout/removal") {
        let bounds = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let display = DisplaySpaceInfo(displayUUID: "D", bounds: bounds, currentSpaceID: 9, currentSpaceUUID: "S", isActive: false)
        let context = LaunchContext(display: display)
        let changedActive = SpaceSnapshot(activeSpaceID: 2, windows: [])
        h.ok(context.isCurrent(snapshot: changedActive, displays: [display]))
        for (id, uuid, rect) in [(SpaceID(10), "S", bounds), (9, "replacement", bounds), (9, "S", CGRect.zero)] {
            let drift = DisplaySpaceInfo(displayUUID: "D", bounds: rect, currentSpaceID: id, currentSpaceUUID: uuid, isActive: false)
            h.ok(!context.isCurrent(snapshot: changedActive, displays: [drift]))
        }
        h.ok(!context.isCurrent(snapshot: changedActive, displays: []))
        h.ok(!LaunchContext(spaceID: 2, displayBounds: .zero).isCurrent(snapshot: changedActive, displays: []))
        h.ok(!LaunchContext(spaceID: 0).isCurrent(snapshot: SpaceSnapshot(activeSpaceID: 0, windows: []), displays: []))
    }
    h.test("queued tickets expire without refreshing intent and block native interaction") {
        let ticket = ActionTicket(context: LaunchContext(spaceID: 1), createdAt: 100)
        let snapshot = SpaceSnapshot(activeSpaceID: 1, windows: [])
        h.eq(ticket.rejectionReason(snapshot: snapshot, displays: [], now: 107.9, nativeInteraction: false), nil)
        h.eq(ticket.rejectionReason(snapshot: snapshot, displays: [], now: 108, nativeInteraction: false), .expired)
        h.eq(ticket.rejectionReason(snapshot: snapshot, displays: [], now: 101, nativeInteraction: true), .nativeInteraction)
        h.eq(ticket.rejectionReason(snapshot: SpaceSnapshot(activeSpaceID: 2, windows: []), displays: [], now: 101,
                                    nativeInteraction: false), .desktopChanged)
    }
    h.test("a dock click checks its desktop without scanning the window inventory") {
        final class CountingProvider: SpaceProviding {
            var scans = 0
            var scoped: [String] = []
            var space: SpaceID = 3
            func snapshot() throws -> SpaceSnapshot {
                scans += 1
                return SpaceSnapshot(activeSpaceID: space, windows: [])
            }
            func snapshot(of target: AppTarget) throws -> SpaceSnapshot {
                scoped.append(target.bundleID ?? "?")
                return SpaceSnapshot(activeSpaceID: space, windows: [])
            }
            func displays() -> [DisplaySpaceInfo] {
                [DisplaySpaceInfo(displayUUID: "screen", bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                  currentSpaceID: space, currentSpaceUUID: "space-\(space)", isActive: true)]
            }
        }
        let provider = CountingProvider()
        let launcher = Launcher(provider: provider, config: .defaults, warn: { _ in })
        let ticket = ActionTicket(context: LaunchContext(display: provider.displays()[0]),
                                  createdAt: ProcessInfo.processInfo.systemUptime)
        // The live mouse state also feeds this check, so only the desktop verdict is asserted.
        _ = launcher.rejectionReason(for: ticket)
        h.eq(provider.scans, 0)
        provider.space = 4
        h.ok(launcher.rejectionReason(for: ticket) != nil)
        h.eq(provider.scans, 0)
    }
    h.test("an action on one app scans that app only") {
        final class CountingProvider: SpaceProviding {
            var scans = 0
            var scoped: [String] = []
            func snapshot() throws -> SpaceSnapshot {
                scans += 1
                return SpaceSnapshot(activeSpaceID: 3, windows: [])
            }
            func snapshot(of target: AppTarget) throws -> SpaceSnapshot {
                scoped.append(target.bundleID ?? "?")
                return SpaceSnapshot(activeSpaceID: 3, windows: [])
            }
            func displays() -> [DisplaySpaceInfo] {
                [DisplaySpaceInfo(displayUUID: "screen", bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                  currentSpaceID: 3, currentSpaceUUID: "space-3", isActive: true)]
            }
        }
        let provider = CountingProvider()
        let launcher = Launcher(provider: provider, config: .defaults, warn: { _ in })
        // The window is not in the inventory, so the click stops before any side effect.
        _ = try? launcher.dockClickWindow(windowID: 999, pid: 1, target: AppTarget(bundleID: "app.one", name: "One"),
                                          forceNew: false, context: LaunchContext(display: provider.displays()[0]))
        h.eq(provider.scans, 0)
        h.eq(provider.scoped, ["app.one"])
    }
    h.test("missing Safari candidate recovers only to one verified visible window on the same desktop/display") {
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let context = LaunchContext(spaceID: 3, displayBounds: display)
        func window(_ id: CGWindowID, pid: pid_t = 88, space: SpaceID = 3,
                    bounds: CGRect = CGRect(x: 0, y: 33, width: 1728, height: 1012),
                    onscreen: Bool = true, minimized: Bool = false, hidden: Bool = false,
                    known: Bool = true) -> WindowInfo {
            WindowInfo(windowID: id, pid: pid, ownerName: "Safari", bundleID: "com.apple.Safari",
                       spaceIDs: [space], bounds: bounds, isOnscreen: onscreen,
                       isMinimized: minimized, isHidden: hidden, spaceMembershipKnown: known)
        }
        let requested = window(7472, bounds: CGRect(x: 427, y: 85, width: 873, height: 161), onscreen: false)
        let browser = window(7452)
        func recover(_ windows: [WindowInfo], requested target: WindowInfo? = nil,
                     verified: Set<CGWindowID> = [7452], accessory: Bool = false) -> WindowInfo? {
            WindowFocusPolicy.recoveryWindow(for: target ?? requested,
                in: SpaceSnapshot(activeSpaceID: 3, windows: windows), context: context,
                verifiedAXIDs: verified, requestedIsAccessory: accessory)
        }
        h.eq(recover([requested, browser])?.windowID, .some(7452))
        h.ok(recover([requested, browser], verified: []) == nil)
        h.ok(recover([requested]) == nil)
        // Another visible CG window is ambiguous even if AX exposes only one.
        h.ok(recover([requested, browser, window(7500)]) == nil)
        for candidate in [window(7452, pid: 99), window(7452, space: 4),
                          window(7452, bounds: CGRect(x: 2000, y: 33, width: 800, height: 600)),
                          window(7452, known: false), window(7452, onscreen: false)] {
            h.ok(recover([requested, candidate]) == nil)
        }
        for target in [window(7472, onscreen: false, minimized: true),
                       window(7472, onscreen: false, hidden: true),
                       window(7472, onscreen: false, known: false), window(7472, space: 4), window(7472)] {
            h.ok(recover([target, browser], requested: target) == nil)
        }
        let accessory = window(7472)
        h.eq(recover([accessory, browser], requested: accessory, accessory: true)?.windowID, .some(7452))
        let minimizedBrowser = window(7452, onscreen: false, minimized: true)
        let hiddenBrowser = window(7452, onscreen: false, hidden: true)
        h.eq(recover([requested, minimizedBrowser])?.windowID, .some(7452))
        h.eq(recover([requested, hiddenBrowser])?.windowID, .some(7452))
        h.ok(recover([requested, minimizedBrowser], verified: []) == nil)
        h.ok(recover([requested, hiddenBrowser], verified: []) == nil)
        h.ok(recover([requested, minimizedBrowser, window(7500)]) == nil)
        h.ok(recover([requested, hiddenBrowser, window(7500, onscreen: false, minimized: true)]) == nil)
        h.ok(recover([requested, window(7452, space: 4, onscreen: false, minimized: true)]) == nil)
        h.ok(recover([requested, window(7452, onscreen: false, minimized: true, known: false)]) == nil)
        let snapshot = SpaceSnapshot(activeSpaceID: 3, windows: [requested, browser])
        h.eq(AppState.classify(target: AppTarget(bundleID: "com.apple.Safari", name: "Safari"), snapshot: snapshot, currentSpace: 3, display: display),
             .windowHere(windowID: 7452, pid: 88, mode: .inactive))
        h.eq(snapshot.windows.count, 2) // No uncertain window is erased from inventory.
        let minimized = window(7452, onscreen: false, minimized: true)
        h.eq(AppState.classify(target: AppTarget(bundleID: "com.apple.Safari", name: "Safari"),
             snapshot: SpaceSnapshot(activeSpaceID: 3, windows: [minimized]), currentSpace: 3, display: display),
             .windowHere(windowID: 7452, pid: 88, mode: .minimized))
    }
    h.test("missing AX permits activation only for the sole real window on the requested desktop/display") {
        let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let context = LaunchContext(spaceID: 3, displayBounds: display)
        func window(_ id: CGWindowID = 3890, pid: pid_t = 4040, spaces: [SpaceID] = [3],
                    known: Bool = true, onscreen: Bool = false,
                    bounds: CGRect = CGRect(x: 416, y: 30, width: 1728, height: 1006)) -> WindowInfo {
            WindowInfo(windowID: id, pid: pid, ownerName: "App", bundleID: "test.app",
                       spaceIDs: spaces, bounds: bounds, isOnscreen: onscreen, spaceMembershipKnown: known)
        }
        let requested = window()
        func allowed(_ windows: [WindowInfo], requested target: WindowInfo? = nil,
                     context requestedContext: LaunchContext? = nil) -> Bool {
            WindowFocusPolicy.canActivateMissingWindow(for: target ?? requested,
                in: SpaceSnapshot(activeSpaceID: 3, windows: windows), context: requestedContext ?? context)
        }
        h.ok(allowed([requested])) // One full-size, off-screen window; AX omitted it.
        h.ok(allowed([requested, window(3893, spaces: [])])) // Confirmed spaceless off-screen helper.
        h.ok(allowed([requested, window(4000, pid: 99, spaces: [4])])) // Another process is irrelevant.
        h.ok(!allowed([]))
        h.ok(!allowed([window(4000)])) // Requested identity is not the sole observed window.
        h.ok(!allowed([requested, window(4000)])) // Never guess between windows, even on this Space.
        h.ok(!allowed([requested, window(4000, spaces: [4])]))
        h.ok(!allowed([requested, window(4000, spaces: [], known: false)]))
        h.ok(!allowed([requested, window(4000, spaces: [], onscreen: true)]))
        h.ok(!allowed([requested, window(4000, bounds: CGRect(x: 3000, y: 30, width: 1000, height: 900))]))
        for target in [window(spaces: [4]), window(spaces: []), window(known: false),
                       window(bounds: .zero), window(bounds: CGRect(x: 3000, y: 30, width: 1000, height: 900)),
                       window(0), window(pid: 0)] {
            h.ok(!allowed([target], requested: target))
        }
        h.ok(!allowed([requested], context: LaunchContext(spaceID: 0, displayBounds: display)))
        // Recovery still cannot select an arbitrary replacement when AX is missing.
        h.ok(WindowFocusPolicy.recoveryWindow(for: requested,
            in: SpaceSnapshot(activeSpaceID: 3, windows: [requested]), context: context,
            verifiedAXIDs: []) == nil)
    }
    h.test("a foreground app with an off-screen unclassified window routes to focus for every app") {
        for name in ["Safari", "Claude", "Slack", "System Settings", "Other"] {
            let target = AppTarget(bundleID: name, name: name)
            let window = WindowInfo(windowID: 41, pid: 88, ownerName: name, bundleID: name,
                spaceIDs: [3], bounds: CGRect(x: 0, y: 30, width: 1000, height: 900), isOnscreen: false)
            let snapshot = SpaceSnapshot(activeSpaceID: 3, windows: [window])
            let state = AppState.classify(target: target, snapshot: snapshot, frontmostPID: 88)
            h.eq(state, .windowHere(windowID: 41, pid: 88, mode: .inactive))
            h.eq(LaunchEngine.dockClick(state: state, config: .defaults, target: target, forceNew: false),
                 .raise(windowID: 41, pid: 88))
        }
    }
    h.test("temporary Accessibility requests restore only their own changes on every exit") {
        for role in [Optional<String>.none, "", "AXUnknown"] {
            h.ok(WindowFocusPolicy.needsWindowAccess(role: role))
        }
        for role in ["AXWindow", "AXScrollArea"] {
            h.ok(!WindowFocusPolicy.needsWindowAccess(role: role))
        }
        var writes: [Bool] = []
        var request: WindowFocusPolicy.AccessibilityRequest? = .init(currentValue: false) { writes.append($0); return true }
        h.ok(request?.requested == true)
        h.eq(request?.retryDuration, .some(2.5))
        h.eq(writes, [true])
        request = nil
        h.eq(writes, [true, false])
        for original in [Optional<Bool>.none, true] {
            writes = []
            request = .init(currentValue: original) { writes.append($0); return true }
            h.ok(request?.requested == false)
            h.eq(request?.retryDuration, .some(1.5))
            request = nil
            h.eq(writes, [])
        }
        writes = []
        request = .init(currentValue: false) { writes.append($0); return false }
        h.ok(request?.requested == false)
        request = nil
        h.eq(writes, [true]) // Failed enablement does not claim ownership or disable someone else's mode.
    }
    h.test("all apps use the same focus operation and wait for their exact window to become accessible") {
        // Labels are fixtures only: the production operation never receives an app name.
        for (label, readyAt) in [("native", 0.0), ("Safari", 0.16), ("Slack", 2.0), ("Claude", 2.0), ("other framework", 0.8)] {
            var clock = 0.0, attempts = 0, activations = 0
            var request: WindowFocusPolicy.AccessibilityRequest? = .init(currentValue: readyAt >= 2 ? false : nil) { _ in true }
            let result = WindowFocusPolicy.performFocus(timeout: request!.retryDuration,
                canAct: { true }, attempt: {
                    attempts += 1
                    return clock >= readyAt ? .raised : .unavailable
                }, activate: {
                    h.ok(clock >= readyAt, "\(label) cannot activate before window identity is available")
                    activations += 1
                }, confirm: { clock >= readyAt }, now: { clock }, wait: { clock += 0.08 })
            withExtendedLifetime(request) {}
            h.eq(result, .focused, label)
            h.eq(activations, 1)
            h.ok(attempts > 0 && clock < 2.5)
            request = nil
        }
    }
    h.test("AX success alone cannot claim focus; activation and unsupported raises require the exact foreground result") {
        var clock = 0.0, activations = 0
        let timedOut = WindowFocusPolicy.performFocus(timeout: 1.5,
            canAct: { true }, attempt: { .raised }, activate: { activations += 1 },
            confirm: { false }, now: { clock }, wait: { clock += 0.08 })
        h.eq(timedOut, .failed) // AX success, but target never came forward.
        h.eq(activations, 1)
        h.ok(clock >= 1.5 && clock < 1.6)
        clock = 0; activations = 0
        h.eq(WindowFocusPolicy.performFocus(timeout: 1.5,
            canAct: { true }, attempt: { .ready }, activate: { activations += 1 },
            confirm: { activations == 1 }, now: { clock }, wait: { clock += 0.08 }), .focused)
        h.eq(activations, 1) // Unsupported AX raise with an actually foreground window succeeds.
        h.eq(WindowFocusPolicy.performFocus(timeout: 1.5, requireConfirmation: false,
            canAct: { true }, attempt: { .raised }, activate: {}, confirm: { false },
            now: { clock }, wait: { clock += 0.08 }), .focused) // Preserve intentional raise-without-activation.
    }
    h.test("focus readiness still cancels on context/mouse changes and never activates an unknown target") {
        var clock = 0.0, attempts = 0, activations = 0
        h.eq(WindowFocusPolicy.performFocus(timeout: 2.5,
            canAct: { clock < 0.16 }, attempt: { attempts += 1; return .unavailable },
            activate: { activations += 1 }, confirm: { false }, now: { clock }, wait: { clock += 0.08 }), .cancelled)
        h.eq(activations, 0)
        h.eq(attempts, 2)
        h.ok(clock < 2.5)
        clock = 0; attempts = 0
        h.eq(WindowFocusPolicy.performFocus(timeout: 2.5,
            canAct: { attempts == 0 }, attempt: { attempts += 1; return .ready },
            activate: { activations += 1 }, confirm: { true }, now: { clock }, wait: { clock += 0.08 }), .cancelled)
        h.eq(activations, 0) // Context changed during AX lookup: stop before activation/confirmation.
        clock = 0
        h.eq(WindowFocusPolicy.performFocus(timeout: 1.5, allowUnidentifiedActivation: true,
            canAct: { true }, attempt: { .unavailable }, activate: { activations += 1 },
            confirm: { activations == 1 }, now: { clock }, wait: { clock += 0.08 }), .focused)
        h.eq(activations, 1) // Only the previously verified sole-local-window exception.
    }
    h.test("a scoped AX request still permits verified sole-window activation before its window is exposed") {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let context = LaunchContext(spaceID: 3, displayBounds: bounds)
        let requested = WindowInfo(windowID: 41, pid: 88, ownerName: "App", bundleID: "app",
            spaceIDs: [3], bounds: CGRect(x: 0, y: 30, width: 1000, height: 900), isOnscreen: false)
        let competitor = WindowInfo(windowID: 42, pid: 88, ownerName: "App", bundleID: "app",
            spaceIDs: [4], bounds: requested.bounds, isOnscreen: false)
        for windows in [[requested], [requested, competitor]] {
            var clock = 0.0, activations = 0, writes: [Bool] = []
            var request: WindowFocusPolicy.AccessibilityRequest? = .init(currentValue: false) {
                writes.append($0); return true
            }
            let safe = WindowFocusPolicy.canActivateMissingWindow(for: requested,
                in: SpaceSnapshot(activeSpaceID: 3, windows: windows), context: context)
            let result = WindowFocusPolicy.performFocus(timeout: request!.retryDuration,
                allowUnidentifiedActivation: safe, canAct: { true },
                attempt: { activations > 0 ? .raised : .unavailable },
                activate: { activations += 1 }, confirm: { activations > 0 && clock > 0 },
                now: { clock }, wait: { clock += 0.08 })
            h.eq(result, safe ? .focused : .failed)
            h.eq(activations, safe ? 1 : 0)
            withExtendedLifetime(request) {}
            request = nil
            h.eq(writes, [true, false])
        }
    }
    h.test("activation without an AX window needs one reopen and exact foreground confirmation") {
        // Reproduce the failure: activation is accepted, but the window
        // remains unavailable. A longer retry of AX alone cannot restore it.
        var clock = 0.0, activations = 0, reopens = 0
        h.eq(WindowFocusPolicy.performFocus(timeout: 1.5, allowUnidentifiedActivation: true,
            canAct: { true }, attempt: { .unavailable }, activate: { activations += 1 },
            confirm: { false }, now: { clock }, wait: { clock += 0.08 }), .failed)
        h.eq(activations, 1)
        for exposesAX in [true, false] {
            clock = 0; activations = 0; reopens = 0
            let result = WindowFocusPolicy.performFocus(timeout: 1.5, allowUnidentifiedActivation: true,
                canAct: { true }, attempt: { reopens > 0 && exposesAX ? .raised : .unavailable },
                activate: { activations += 1 }, recover: {
                    h.ok(clock >= 0.24) // Give ordinary asynchronous activation time first.
                    reopens += 1
                }, confirm: { reopens == 1 && clock >= 0.4 },
                now: { clock }, wait: { clock += 0.08 })
            h.eq(result, .focused)
            h.eq(activations, 1)
            h.eq(reopens, 1) // Works even if AX stays unavailable but the exact window is visibly frontmost.
            h.ok(clock < 1.5)
        }
        clock = 0; reopens = 0
        h.eq(WindowFocusPolicy.performFocus(timeout: 1.5, allowUnidentifiedActivation: true,
            canAct: { true }, attempt: { .unavailable }, activate: {}, recover: { reopens += 1 },
            confirm: { false }, now: { clock }, wait: { clock += 0.08 }), .failed)
        h.eq(reopens, 1) // Reopen acceptance without actual focus never reports success or repeats the request.
    }
    h.test("reopen cannot choose another instance or bypass window/context safeguards") {
        h.ok(WindowFocusPolicy.canReopenApp(pid: 88, runningPIDs: [88]))
        for pids in [[], [89], [88, 89], [89, 88]] as [[pid_t]] {
            h.ok(!WindowFocusPolicy.canReopenApp(pid: 88, runningPIDs: pids))
        }
        h.ok(!WindowFocusPolicy.canReopenApp(pid: 0, runningPIDs: [0]))
        var clock = 0.0, reopens = 0
        for (sole, confirm, confirmationRequired, attempt) in [
            (false, false, true, WindowFocusPolicy.RaiseAttempt.unavailable),
            (true, true, true, .unavailable), // Plain activation already succeeded.
            (true, false, true, .ready),     // Identified AX target: retain exact per-window handling.
            (true, false, false, .unavailable) // Intentional nonactivating second-instance path.
        ] {
            clock = 0
            _ = WindowFocusPolicy.performFocus(timeout: 1.5, allowUnidentifiedActivation: sole,
                requireConfirmation: confirmationRequired,
                canAct: { true }, attempt: { attempt }, activate: {}, recover: { reopens += 1 },
                confirm: { confirm }, now: { clock }, wait: { clock += 0.08 })
        }
        h.eq(reopens, 0)
        clock = 0
        h.eq(WindowFocusPolicy.performFocus(timeout: 1.5, allowUnidentifiedActivation: true,
            canAct: { clock < 0.2 }, attempt: { .unavailable }, activate: {}, recover: { reopens += 1 },
            confirm: { false }, now: { clock }, wait: { clock += 0.08 }), .cancelled)
        h.eq(reopens, 0) // A click, desktop switch, or newly ambiguous window cancels before reopening.
        clock = 0
        var current = true
        h.eq(WindowFocusPolicy.performFocus(timeout: 1.5, allowUnidentifiedActivation: true,
            canAct: { current }, attempt: { .unavailable }, activate: {},
            recover: { reopens += 1; current = false }, confirm: { false },
            now: { clock }, wait: { clock += 0.08 }), .cancelled)
        h.eq(reopens, 1)
        clock = 0; reopens = 0
        h.eq(WindowFocusPolicy.performFocus(timeout: 0.1, allowUnidentifiedActivation: true,
            canAct: { true }, attempt: { .unavailable }, activate: {}, recover: { reopens += 1 },
            confirm: { false }, now: { clock }, wait: { clock += 0.08 }), .failed)
        h.eq(reopens, 0) // No recovery scheduled after the request deadline.
    }
    h.test("context cancellation during confirmation is distinct from a focus timeout") {
        var current = true, clock = 0.0
        let result = WindowFocusPolicy.performFocus(timeout: 1.5,
            canAct: { current }, attempt: { .ready }, activate: {},
            confirm: { current = false; return false },
            now: { clock }, wait: { clock += 0.08 })
        h.eq(result, .cancelled)
        h.eq(clock, 0)
    }
    h.test("unsupported AX raise succeeds only when the exact requested window is confirmed frontmost") {
        func confirmed(_ app: pid_t?, _ window: CGWindowID?, _ owner: pid_t?,
                       requested: CGWindowID = 9852, pid: pid_t = 50842) -> Bool {
            WindowFocusPolicy.isConfirmedFocused(windowID: requested, pid: pid,
                frontmostPID: app, frontmostWindowID: window, frontmostWindowPID: owner)
        }
        h.ok(confirmed(50842, 9852, 50842))
        h.ok(!confirmed(50842, 9853, 50842)) // Same app, different window is not success.
        h.ok(!confirmed(50843, 9852, 50842)) // Visible window behind the active app.
        h.ok(!confirmed(50842, 9852, 50843)) // Owner mismatch / reused identity.
        h.ok(!confirmed(nil, 9852, 50842))
        h.ok(!confirmed(50842, nil, 50842)) // No on-screen normal-window evidence.
        h.ok(!confirmed(50842, 9852, nil))
        h.ok(!confirmed(50842, 0, 50842, requested: 0))
        h.ok(!confirmed(0, 9852, 0, pid: 0))
    }
    h.test("stale GUI/CLI pin stores merge edits; corruption is preserved, not replaced") {
        try scratch { root in
            let file = root.appendingPathComponent("pins.json")
            let gui = PinStore(url: file), cli = PinStore(url: file)
            gui.pin("a", onSpace: "S")
            cli.pinEverywhere("b")
            gui.toggleEverywhereException("b", onSpace: "S")
            cli.setOrder(["b", "a"], onSpace: "S")
            let merged = gui.reload()
            h.eq(merged.spacePins(onSpace: "S"), ["a"])
            h.eq(merged.everywherePins(), ["b"])
            h.eq(merged.everywhereExceptions(onSpace: "S"), ["b"])
            h.eq(merged.order(onSpace: "S"), ["b", "a"])
            for invalid in ["not json", "{\"everywhere\":123}"] {
                let bytes = Data(invalid.utf8)
                try bytes.write(to: file)
                cli.pin("c", onSpace: "S")
                h.eq(try Data(contentsOf: file), bytes)
            }
        }
    }
    h.test("two real processes overlap 60 atomic pin transactions without lost updates") {
        try scratch { root in
            let file = root.appendingPathComponent("pins.json")
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let workers = ["worker-a", "worker-b"].map { prefix -> Process in
                let p = Process(); p.executableURL = executable
                p.arguments = ["--pin-worker", file.path, prefix]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                return p
            }
            for worker in workers { try worker.run() }
            defer { for worker in workers where worker.isRunning { worker.terminate() } }
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while workers.contains(where: \.isRunning), ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
            h.ok(!workers.contains(where: \.isRunning), "worker deadline")
            for worker in workers where !worker.isRunning { h.eq(worker.terminationStatus, Int32(0)) }
            let pins = PinStore(url: file).spacePins(onSpace: "concurrent")
            h.eq(pins.count, 60)
            h.eq(Set(pins).count, 60)
        }
    }
    h.test("a stuck pin writer has a bounded lock wait and reports failure; retry commits pin plus order together") {
        try scratch { root in
            let file = root.appendingPathComponent("pins.json")
            let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            child.arguments = ["--pin-lock-worker", file.path]
            try child.run()
            defer { if child.isRunning { child.terminate() } }
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !FileManager.default.fileExists(atPath: file.path + ".ready"), ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
            h.ok(FileManager.default.fileExists(atPath: file.path + ".ready"))
            let store = PinStore(url: file)
            let started = ProcessInfo.processInfo.systemUptime
            h.ok(!store.pinAndReorder("a", onSpace: "S", visibleOrder: ["a"]))
            h.ok(ProcessInfo.processInfo.systemUptime - started < 0.6)
            h.ok(!FileManager.default.fileExists(atPath: file.path))
            while child.isRunning, ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
            h.ok(!child.isRunning)
            h.ok(store.pinAndReorder("a", onSpace: "S", visibleOrder: ["a"]))
            let reloaded = PinStore(url: file).reload()
            h.eq(reloaded.spacePins(onSpace: "S"), ["a"])
            h.eq(reloaded.order(onSpace: "S"), ["a"])
        }
    }
    h.test("journal captures originals once, restores absent keys, and survives partial/finalization failures") {
        try scratch { root in
            let journal = SystemSettingsJournal(url: root.appendingPathComponent("recovery.json"))
            var system = ["a": Data("original".utf8)]
            try journal.capture(keys: ["a", "b"], read: { system[$0] })
            system["a"] = Data("overwritten".utf8); system["b"] = Data("created".utf8)
            try journal.capture(keys: ["a", "b"], read: { system[$0] })
            do {
                try journal.restore(write: { key, data in
                    if key == "b" { throw CocoaError(.fileWriteUnknown) }
                    system[key] = data
                })
                h.ok(false, "injected restore error should throw")
            } catch { h.ok(journal.exists) }
            h.eq(system["a"], Data("original".utf8))
            do {
                try journal.restore(write: { system[$0] = $1 }, finalize: { throw CocoaError(.fileWriteUnknown) })
                h.ok(false, "injected finalization error should throw")
            } catch { h.ok(journal.exists) }
            h.ok(system["b"] == nil)
            try journal.restore(write: { system[$0] = $1 })
            h.ok(!journal.exists)
            h.eq(system["a"], Data("original".utf8))
        }
    }
    h.test("a Dock still hidden by Powerspaces is never recorded as the user's original") {
        // A Dock left hidden after a 1.2.4 Reset Settings lost the backups: our own
        // autohide + tile size 1 were recorded, so every restore re-hid the Dock.
        let leftover: [String: Any] = ["autohide": true, "tilesize": 1]
        h.eq(AppleDockOriginals.clean(leftover).count, 0)
        let fullHide: [String: Any] = ["autohide": true, "autohide-delay": 1000.0, "autohide-time-modifier": 0.0, "tilesize": 1]
        h.eq(AppleDockOriginals.clean(fullHide).count, 0)
        let delayOnly: [String: Any] = ["autohide": true, "autohide-delay": NSNumber(value: Float(1000)), "tilesize": 48]
        h.eq(AppleDockOriginals.clean(delayOnly).count, 0)
        let user: [String: Any] = ["autohide": true, "autohide-delay": 0.2, "autohide-time-modifier": 0.0, "tilesize": 36]
        let kept = AppleDockOriginals.clean(user)
        h.eq(kept.count, 4)
        h.eq(kept["tilesize"] as? Int, 36)
        h.eq(kept["autohide"] as? Bool, true)
        h.eq(AppleDockOriginals.clean([:]).count, 0)
    }
    h.test("failed capture or corrupt journal cannot authorize replacement of recovery data") {
        try scratch { root in
            let journal = SystemSettingsJournal(url: root.appendingPathComponent("recovery.json"))
            do {
                try journal.capture(keys: ["a"], read: { _ in throw CocoaError(.fileReadUnknown) })
                h.ok(false)
            } catch { h.ok(!journal.exists) }
            let corrupt = Data("broken".utf8); try corrupt.write(to: journal.url)
            do { try journal.capture(keys: ["a"], read: { _ in nil }); h.ok(false) } catch { h.eq(try Data(contentsOf: journal.url), corrupt) }
            var writes = 0
            do { try journal.restore(write: { _, _ in writes += 1 }); h.ok(false) } catch { h.eq(writes, 0) }
            let incomplete = Data("{}".utf8); try incomplete.write(to: journal.url)
            do { try journal.capture(keys: ["a"], read: { _ in nil }); h.ok(false) } catch { h.eq(try Data(contentsOf: journal.url), incomplete) }
            do { try journal.restore(keys: ["a"], write: { _, _ in writes += 1 }); h.ok(false) } catch { h.eq(writes, 0) }
        }
    }
    h.test("helper failures and timeout are bounded; argv preserves paths and arguments literally") {
        h.eq(ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: []), .exited(0))
        h.eq(ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/false"), arguments: []), .exited(1))
        h.eq(ProcessRunner.run(URL(fileURLWithPath: "/does/not/exist"), arguments: []), .failed)
        let started = ProcessInfo.processInfo.systemUptime
        h.eq(ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"], timeout: 0.05), .timedOut)
        h.ok(ProcessInfo.processInfo.systemUptime - started < 1)
        let app = URL(fileURLWithPath: "/Applications/App With Spaces.app")
        h.eq(Launcher.openArguments(appURL: app, newInstance: true, background: true, args: ["--new-window", "a;b"]),
             ["-g", "-n", "-a", app.path, "--args", "--new-window", "a;b"])
    }
    h.test("polite quit refusal leaves all participants alive and prevents reopen") {
        let accepts = FakeQuit(accepts: true), refuses = FakeQuit(accepts: false)
        h.ok(!QuitCoordinator.requestQuit([accepts, refuses], timeout: 0))
        h.eq(accepts.requests, 1); h.eq(refuses.requests, 1)
        h.ok(!refuses.hasExited)
        var opens = 0
        let outcome = QuitCoordinator.reopen([refuses], timeout: 0) { opens += 1; return .launched }
        h.ok(outcome == nil); h.eq(opens, 0)
        let successful = QuitCoordinator.reopen([accepts], timeout: 0) { opens += 1; return .launched }
        if case .launched = successful { h.ok(true) } else { h.ok(false) }
        h.eq(opens, 1)
    }
    h.test("reaper confirmation requires trusted complete empty inventories; missing/filtered data is insufficient") {
        h.ok(WindowInventory.confirmsEmpty(rawCount: 0, axCount: 0, trusted: true, nativeInteraction: false))
        for (raw, ax) in [(nil, Optional(0)), (Optional(0), nil), (Optional(1), Optional(0)), (Optional(0), Optional(1))] {
            h.ok(!WindowInventory.confirmsEmpty(rawCount: raw, axCount: ax, trusted: true, nativeInteraction: false))
        }
        h.ok(!WindowInventory.confirmsEmpty(rawCount: 0, axCount: 0, trusted: false, nativeInteraction: false))
        h.ok(!WindowInventory.confirmsEmpty(rawCount: 0, axCount: 0, trusted: true, nativeInteraction: true))
    }
    h.test("verified standard recovery windows tolerate unavailable modal flags and ordinary restore transitions") {
        for modal in [Optional<Bool>.none, false] {
            h.ok(WindowFilter.isRestorableWindow(role: "AXWindow", subrole: "AXStandardWindow", isModal: modal))
        }
        h.ok(!WindowFilter.isRestorableWindow(role: "AXWindow", subrole: "AXStandardWindow", isModal: true))
        h.ok(!WindowFilter.isRestorableWindow(role: "AXScrollArea", subrole: "AXStandardWindow", isModal: false))
        h.ok(!WindowFilter.isRestorableWindow(role: "AXWindow", subrole: "AXDialog", isModal: false))
        h.ok(!WindowFilter.isRestorableWindow(role: nil, subrole: "AXStandardWindow", isModal: false))
        h.ok(!WindowFilter.isRestorableWindow(role: "AXWindow", subrole: nil, isModal: false))
    }
    h.test("native overview bypasses the whole gesture and mid-gesture drag never injects a switch") {
        var state = psw_gesture_state()
        h.eq(psw_gesture_decision(&state, 1, 0, 0, true), PSWGesturePass)
        h.eq(psw_gesture_decision(&state, 2, 1, 0, false), PSWGesturePass)
        h.eq(psw_gesture_decision(&state, 4, 0, 100, false), PSWGesturePass)
        h.ok(!state.tracking && !state.bypass && !state.fired)
        h.eq(psw_gesture_decision(&state, 1, 0, 0, false), PSWGestureSuppress)
        h.eq(psw_gesture_decision(&state, 2, 1, 0, true), PSWGestureSuppress)
        h.eq(psw_gesture_decision(&state, 4, 0, 100, false), PSWGestureSuppress)
        h.eq(psw_gesture_decision(&state, 1, 0, 0, false), PSWGestureSuppress)
        h.eq(psw_gesture_decision(&state, 2, -1, 0, false), PSWGestureLeft)
        h.eq(psw_gesture_decision(&state, 2, 1, 0, false), PSWGestureSuppress)
        h.eq(psw_gesture_decision(&state, 4, 0, 100, false), PSWGestureSuppress)
        h.eq(psw_gesture_decision(&state, 1, 0, 0, false), PSWGestureSuppress)
        h.eq(psw_gesture_decision(&state, 4, 0, 100, false), PSWGestureRight)
        h.eq(psw_gesture_decision(&state, 1, 0, 0, true), PSWGesturePass)
        h.eq(psw_gesture_decision(&state, 8, 0, 0, false), PSWGesturePass)
    }
}
