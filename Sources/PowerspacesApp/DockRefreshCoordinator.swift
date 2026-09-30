// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation
import SpaceKit

struct DockRefreshSample: Sendable {
    let snapshot: SpaceSnapshot?
    /// The displays before the window inventory was read; `displays` is after it.
    let startDisplays: [DisplaySpaceInfo]
    let displays: [DisplaySpaceInfo]
    let titles: [CGWindowID: String]
    let active: CGWindowID?
}

extension DisplaySpaceInfo {
    /// The desktop on this display: its persistent UUID, or its numeric id without one.
    var desktopKey: String { currentSpaceUUID.isEmpty ? String(currentSpaceID) : currentSpaceUUID }
}

extension SpaceSnapshot {
    /// For a projection onto another desktop than the one this was read on: without
    /// the windows that have no Space. An old on-screen flag cannot place them there.
    func placedWindowsOnly() -> SpaceSnapshot {
        SpaceSnapshot(activeSpaceID: activeSpaceID, windows: windows.filter { !$0.spaceIDs.isEmpty },
                      runningBundleIDs: runningBundleIDs, windowOwnerPIDs: windowOwnerPIDs)
    }
}

/// The last validated list per display and desktop, shown at once when a desktop
/// returns. Only a validated scan writes one, so it never describes another desktop.
struct DockMemo {
    /// `source` is what the render log prints: scan, memo or projection.
    struct Render { let source: String; let apps: [DockApp]; let animate, changed: Bool }
    private var lists: [String: [String: [DockApp]]] = [:]
    /// Per display, the desktop a scan last rendered; nil from a desktop change
    /// until its scan lands, so that scan swaps the whole bar without animation.
    private var settled: [String: String] = [:]

    /// A desktop change: nil when this display kept its desktop. One that moved shows
    /// the desktop's memo or, without one (a first visit), `projection`. A projection
    /// is provisional: it is never stored, and nil (no inventory yet) shows nothing.
    mutating func recall(_ display: DisplaySpaceInfo, projection: () -> [DockApp]?) -> Render? {
        guard settled[display.displayUUID] != display.desktopKey else { return nil }
        settled[display.displayUUID] = nil
        let memo = lists[display.displayUUID]?[display.desktopKey]
        return (memo ?? projection()).map {
            Render(source: memo == nil ? "projection" : "memo", apps: $0, animate: false, changed: true)
        }
    }

    mutating func store(_ apps: [DockApp], for display: DisplaySpaceInfo) -> Render {
        let uuid = display.displayUUID, key = display.desktopKey
        defer { settled[uuid] = key; lists[uuid, default: [:]][key] = apps }
        return Render(source: "scan", apps: apps, animate: settled[uuid] == key, changed: lists[uuid]?[key] != apps)
    }

    /// Pins, a preference or the display layout changed: every list is stale.
    mutating func forget() { lists = [:] }
}

/// Desktop identity is cheap and read on the main thread when needed. The window
/// inventory is slow: one off-main lane, one running scan, one coalesced follow-up.
/// A scan is published only if every display showed the same desktop at its start,
/// at its end, at each desktop change in between and on arrival; otherwise it is
/// rescanned. Nothing else discards one.
@MainActor
final class DockRefreshCoordinator {
    struct Options: Sendable {
        let labels: Bool
        let frontmostPID: pid_t?
    }

    var onSample: (DockRefreshSample) -> Void = { _ in }
    var onDisplays: ([DisplaySpaceInfo]) -> Void = { _ in }
    var onIdle: () -> Void = {}

    private let readSample: @Sendable (Options) -> DockRefreshSample
    private let readDisplays: @Sendable () -> [DisplaySpaceInfo]
    private let sampleQueue = DispatchQueue(label: "nl.sebastianpdw.powerspaces.snapshot", qos: .utility)
    private var paused = false
    private var sampling = false
    private var sampleRequested = false
    private var seenWhileSampling: [[DisplaySpaceInfo]] = []
    private var options = Options(labels: false, frontmostPID: nil)
    private var lastSlowLog = -Double.infinity

    init(readSample: @escaping @Sendable (Options) -> DockRefreshSample,
         readDisplays: @escaping @Sendable () -> [DisplaySpaceInfo]) {
        self.readSample = readSample
        self.readDisplays = readDisplays
    }

    func request(options: Options, desktopChanged: Bool = false) {
        self.options = options
        paused = false
        if desktopChanged {
            let started = ProcessInfo.processInfo.systemUptime
            let displays = readDisplays()
            Log.notice("Dock desktop refresh: elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) spaces=\(displays.map(\.currentSpaceID))")
            if sampling { seenWhileSampling.append(displays) }
            if !displays.isEmpty { onDisplays(displays) }
        }
        refreshSample()
    }

    func suspend() {
        paused = true
        sampleRequested = false
        if sampling { seenWhileSampling.append([]) } // no desktop was showing: void even after resume
    }

    private func refreshSample() {
        guard !paused else { return }
        guard !sampling else { sampleRequested = true; return }
        sampling = true
        let options = options, read = readSample
        let started = ProcessInfo.processInfo.systemUptime
        sampleQueue.async { [weak self] in
            let result = read(options)
            Task { @MainActor in
                guard let self else { return }
                self.sampling = false
                let desktops = { (displays: [DisplaySpaceInfo]) in displays.map { [$0.displayUUID, $0.desktopKey] } }
                let accepted = !self.paused && desktops(result.startDisplays) == desktops(result.displays)
                    && (self.seenWhileSampling + [self.readDisplays()]).allSatisfy { desktops($0) == desktops(result.displays) }
                self.seenWhileSampling = []
                if accepted { self.onSample(result) } else if !self.paused { self.sampleRequested = true }
                let now = ProcessInfo.processInfo.systemUptime
                if !accepted || (now - started >= 1 && now - self.lastSlowLog >= 30) {
                    self.lastSlowLog = now
                    Log.notice("Dock background refresh: elapsedMs=\(Int((now - started) * 1000)) accepted=\(accepted) followup=\(self.sampleRequested)")
                }
                if self.sampleRequested {
                    self.sampleRequested = false
                    self.refreshSample()
                } else if !self.paused { self.onIdle() }
            }
        }
    }
}
