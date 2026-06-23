// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation
import SpaceKit

// A tiny, dependency-free test harness. XCTest and Swift Testing are not
// available with Command Line Tools only, so the suite runs as a plain
// executable: `swift run spacekit-tests` (exit code 0 = all green).

final class Harness {
    private(set) var assertions = 0
    private(set) var failures = 0
    private var failedTests = 0
    private var currentFailures = 0

    func test(_ name: String, _ body: () throws -> Void) {
        currentFailures = 0
        do { try body() } catch { fail("threw \(error)") }
        if currentFailures == 0 {
            print("  ✓ \(name)")
        } else {
            print("  ✗ \(name) (\(currentFailures) failed)")
            failedTests += 1
        }
    }

    func ok(_ condition: Bool, _ message: @autoclosure () -> String = "") {
        assertions += 1
        if !condition { fail(message()) }
    }

    func eq<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String = "") {
        assertions += 1
        if actual != expected {
            fail("\(message()) — got \(actual), expected \(expected)")
        }
    }

    private func fail(_ message: String) {
        failures += 1
        currentFailures += 1
        print("      → \(message)")
    }

    func finish() -> Never {
        print("\n\(assertions) assertions, \(failures) failed across tests "
              + "(\(failedTests) failing test\(failedTests == 1 ? "" : "s"))")
        exit(failures == 0 ? 0 : 1)
    }
}

let h = Harness()

// MARK: - Helpers

func win(_ id: CGWindowID, _ pid: pid_t = 100, name: String = "App",
         bundle: String? = nil, spaces: [SpaceID]) -> WindowInfo {
    WindowInfo(windowID: id, pid: pid, ownerName: name, bundleID: bundle, spaceIDs: spaces)
}

struct FakeProvider: SpaceProviding {
    let snap: SpaceSnapshot
    var displaysList: [DisplaySpaceInfo] = []
    func snapshot() throws -> SpaceSnapshot { snap }
    func displays() -> [DisplaySpaceInfo] { displaysList }
    // Concrete (not on the protocol) — exercised directly, like the live CLI does.
    func currentSpaceID() throws -> SpaceID { snap.activeSpaceID }
}

let config = StrategyConfig.defaults
let firefox = AppTarget(bundleID: "org.mozilla.firefox", name: "Firefox")

// MARK: - AppState (the classified state every decision switches over)

print("AppState")

h.test("classify: not running (no window, not in running set) → notRunning") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [], runningBundleIDs: [])
    h.eq(AppState.classify(target: firefox, snapshot: snap), .notRunning)
}

h.test("classify: alive but window-less → runningWindowless") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [],
                             runningBundleIDs: ["org.mozilla.firefox"])
    h.eq(AppState.classify(target: firefox, snapshot: snap), .runningWindowless)
}

h.test("classify: window only on another Space → windowElsewhere") {
    let snap = SpaceSnapshot(activeSpaceID: 2, windows: [
        win(10, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
    ])
    h.eq(AppState.classify(target: firefox, snapshot: snap), .windowElsewhere)
}

h.test("classify: only spaceless phantoms + running → runningWindowless (Claude after ✕)") {
    // ✕-closing Claude's last window leaves the process alive owning only off-screen
    // placeholder windows that belong to no Space (empty spaceIDs). Those ghosts must
    // NOT read as "a window on another desktop" — otherwise we'd spawn a brand-new
    // instance over the idle one and pile up copies. They're nowhere → reuse the
    // instance (runningWindowless), don't duplicate it.
    let claude = AppTarget(bundleID: "com.anthropic.claudefordesktop", name: "Claude")
    let snap = SpaceSnapshot(activeSpaceID: 100, windows: [
        win(25961, 1215, name: "Claude", bundle: "com.anthropic.claudefordesktop", spaces: []),
        win(25959, 1215, name: "Claude", bundle: "com.anthropic.claudefordesktop", spaces: []),
    ], runningBundleIDs: ["com.anthropic.claudefordesktop"])
    h.eq(AppState.classify(target: claude, snapshot: snap), .runningWindowless)
}

h.test("classify: a real window elsewhere outranks a spaceless phantom → windowElsewhere") {
    // A phantom alongside a genuine window on another desktop must not downgrade the
    // app to windowless — there really is a window to avoid yanking to.
    let snap = SpaceSnapshot(activeSpaceID: 2, windows: [
        win(10, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: []),
        win(11, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
    ], runningBundleIDs: ["org.mozilla.firefox"])
    h.eq(AppState.classify(target: firefox, snapshot: snap), .windowElsewhere)
}

h.test("classify: spaceless phantoms but not in the running set → notRunning") {
    // Defensive: if only ghost windows linger and the process is gone from the
    // running set, the app is truly absent — a phantom alone never means "running".
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: []),
    ], runningBundleIDs: [])
    h.eq(AppState.classify(target: firefox, snapshot: snap), .notRunning)
}

h.test("classify→decide: a windowless Claude reopens here via newInstance (which reuses)") {
    // End-to-end guard tying the phantom classification to Claude's pinned strategy:
    // the ghost classifies as runningWindowless and decides newWindow(.newInstance).
    // (The launcher's .newInstance case then reuses the idle instance with `open -a`
    // rather than spawning a duplicate — proven live on-device.)
    let claude = AppTarget(bundleID: "com.anthropic.claudefordesktop", name: "Claude")
    let snap = SpaceSnapshot(activeSpaceID: 100, windows: [
        win(25961, 1215, name: "Claude", bundle: "com.anthropic.claudefordesktop", spaces: []),
    ], runningBundleIDs: ["com.anthropic.claudefordesktop"])
    h.eq(LaunchEngine.decide(target: claude, snapshot: snap, config: config, forceNew: false),
         .newWindow(.newInstance))
}

h.test("classify: window here, no frontmost info → windowHere(.inactive)") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
    ])
    h.eq(AppState.classify(target: firefox, snapshot: snap),
         .windowHere(windowID: 10, pid: 100, mode: .inactive))
}

h.test("classify: window here and its app is frontmost → windowHere(.active)") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
    ])
    h.eq(AppState.classify(target: firefox, snapshot: snap, frontmostPID: 100),
         .windowHere(windowID: 10, pid: 100, mode: .active))
}

h.test("classify: a minimized here-window is .minimized even if its app is frontmost") {
    // Finder keeps frontmost ownership with its last window minimized — mode must
    // still report .minimized so the toggle restores rather than re-minimizes.
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        WindowInfo(windowID: 10, pid: 100, ownerName: "Finder",
                   bundleID: "com.apple.finder", spaceIDs: [1],
                   isOnscreen: false, isMinimized: true),
    ])
    h.eq(AppState.classify(target: AppTarget(bundleID: "com.apple.finder", name: "Finder"),
                           snapshot: snap, frontmostPID: 100),
         .windowHere(windowID: 10, pid: 100, mode: .minimized))
}

h.test("classify: a ⌘H-hidden here-window is .hidden") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        WindowInfo(windowID: 10, pid: 100, ownerName: "Firefox",
                   bundleID: "org.mozilla.firefox", spaceIDs: [1],
                   isOnscreen: false, isHidden: true),
    ])
    h.eq(AppState.classify(target: firefox, snapshot: snap, frontmostPID: 999),
         .windowHere(windowID: 10, pid: 100, mode: .hidden))
}

h.test("label is a short, secret-free state name") {
    h.eq(AppState.notRunning.label, "notRunning")
    h.eq(AppState.runningWindowless.label, "runningWindowless")
    h.eq(AppState.windowElsewhere.label, "windowElsewhere")
    h.eq(AppState.windowHere(windowID: 1, pid: 2, mode: .active).label, "windowHere(active)")
    h.eq(AppState.windowHere(windowID: 1, pid: 2, mode: .minimized).label, "windowHere(minimized)")
}

h.test("decide(state:) is the launch transition table — one state → one decision") {
    let target = firefox
    h.eq(LaunchEngine.decide(state: .notRunning, config: config, target: target, forceNew: false),
         .launchApp)
    h.eq(LaunchEngine.decide(state: .runningWindowless, config: config, target: target, forceNew: false),
         .newWindow(.openArgs))
    h.eq(LaunchEngine.decide(state: .windowElsewhere, config: config, target: target, forceNew: false),
         .newWindow(.openArgs))
    let here = AppState.windowHere(windowID: 10, pid: 100, mode: .inactive)
    h.eq(LaunchEngine.decide(state: here, config: config, target: target, forceNew: false),
         .focusWindow(windowID: 10, pid: 100))
    // forceNew turns a here-window into a fresh-window request.
    h.eq(LaunchEngine.decide(state: here, config: config, target: target, forceNew: true),
         .newWindow(.openArgs))
}

// MARK: - LaunchEngine

print("LaunchEngine")

h.test("focuses a window already on the current Space") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
    ])
    h.eq(LaunchEngine.decide(target: firefox, snapshot: snap, config: config, forceNew: false),
         .focusWindow(windowID: 10, pid: 100))
}

h.test("forceNew opens a new window even if one is here") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
    ])
    h.eq(LaunchEngine.decide(target: firefox, snapshot: snap, config: config, forceNew: true),
         .newWindow(.openArgs))
}

h.test("launches when not running anywhere") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 200, name: "Notes", bundle: "com.apple.Notes", spaces: [1]),
    ])
    h.eq(LaunchEngine.decide(target: firefox, snapshot: snap, config: config, forceNew: false),
         .launchApp)
}

h.test("new window when running only on another Space (core fix, issues 1 & 2)") {
    let snap = SpaceSnapshot(activeSpaceID: 2, windows: [
        win(10, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
    ])
    h.eq(LaunchEngine.decide(target: firefox, snapshot: snap, config: config, forceNew: false),
         .newWindow(.openArgs))
}

h.test("running window-less app makes a new window, not a cold launch (Finder after Quit-all)") {
    // "Quit (all desktops)" terminates Finder; macOS auto-relaunches it with no
    // windows. The decision must route to its new-window strategy (make new
    // Finder window) instead of a plain `open -a`, which spawns nothing.
    let finder = AppTarget(bundleID: "com.apple.finder", name: "Finder")
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [],
                             runningBundleIDs: ["com.apple.finder"])
    h.eq(LaunchEngine.decide(target: finder, snapshot: snap, config: config, forceNew: false),
         .newWindow(.appleScript))
}

h.test("a running window-less app still gets a new window under forceNew") {
    let finder = AppTarget(bundleID: "com.apple.finder", name: "Finder")
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [],
                             runningBundleIDs: ["com.apple.finder"])
    h.eq(LaunchEngine.decide(target: finder, snapshot: snap, config: config, forceNew: true),
         .newWindow(.appleScript))
}

h.test("truly-not-running app still cold-launches (no running set entry)") {
    // Same empty-window snapshot, but the app isn't in the running set → the
    // first window lands here via a plain launch.
    let finder = AppTarget(bundleID: "com.apple.finder", name: "Finder")
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [], runningBundleIDs: [])
    h.eq(LaunchEngine.decide(target: finder, snapshot: snap, config: config, forceNew: false),
         .launchApp)
}

h.test("single-window apps warn when open only elsewhere") {
    let messages = AppTarget(bundleID: "com.apple.MobileSMS", name: "Messages")
    let snap = SpaceSnapshot(activeSpaceID: 2, windows: [
        win(10, 100, name: "Messages", bundle: "com.apple.MobileSMS", spaces: [1]),
    ])
    h.eq(LaunchEngine.decide(target: messages, snapshot: snap, config: config, forceNew: false),
         .newWindow(.warn))
}

h.test("apps that may hold unsaved work warn when open only elsewhere") {
    let mail = AppTarget(bundleID: "com.apple.mail", name: "Mail")
    let snap = SpaceSnapshot(activeSpaceID: 2, windows: [
        win(10, 100, name: "Mail", bundle: "com.apple.mail", spaces: [1]),
    ])
    h.eq(LaunchEngine.decide(target: mail, snapshot: snap, config: config, forceNew: false),
         .newWindow(.warn))
}

h.test("a quitReopen override routes through decide()") {
    // quitReopen is opt-in (no app ships with it), so confirm a user override for a
    // single-window app open only elsewhere resolves to the quit-and-reopen strategy.
    let cfg = try StrategyConfig.load(from: Data("""
        { "apps": [ { "bundleID": "com.apple.systempreferences", "strategy": "quitReopen" } ] }
        """.utf8))
    let settings = AppTarget(bundleID: "com.apple.systempreferences", name: "System Settings")
    let snap = SpaceSnapshot(activeSpaceID: 2, windows: [
        win(10, 100, name: "System Settings", bundle: "com.apple.systempreferences", spaces: [1]),
    ])
    h.eq(LaunchEngine.decide(target: settings, snapshot: snap, config: cfg, forceNew: false),
         .newWindow(.quitReopen))
}

h.test("decide() honors the user's open-elsewhere setting (override + default)") {
    // Behavior 5: when the app is open only on another desktop, the new-window
    // strategy must come from the *user's* config — not just the shipped defaults.
    // Here the user sets a global default of ⌘N and a per-app override (Firefox →
    // warn); decide() must route through both.
    let cfg = try StrategyConfig.load(from: Data("""
        { "defaultStrategy": "cmdN",
          "apps": [ { "bundleID": "org.mozilla.firefox", "strategy": "warn" } ] }
        """.utf8))
    let unknown = AppTarget(bundleID: "com.acme.tool", name: "Acme")
    let snap = SpaceSnapshot(activeSpaceID: 2, windows: [
        win(10, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
        win(20, 200, name: "Acme", bundle: "com.acme.tool", spaces: [1]),
    ])
    // The per-app override wins for Firefox…
    h.eq(LaunchEngine.decide(target: firefox, snapshot: snap, config: cfg, forceNew: false),
         .newWindow(.warn))
    // …and the user's global default applies to every other app.
    h.eq(LaunchEngine.decide(target: unknown, snapshot: snap, config: cfg, forceNew: false),
         .newWindow(.cmdN))
}

h.test("matches by owner name when bundle id is missing") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "WeirdApp", bundle: nil, spaces: [1]),
    ])
    let target = AppTarget(bundleID: nil, name: "WeirdApp")
    h.eq(LaunchEngine.decide(target: target, snapshot: snap, config: config, forceNew: false),
         .focusWindow(windowID: 10, pid: 100))
}

h.test("picks the window on the current Space, not one on another") {
    let snap = SpaceSnapshot(activeSpaceID: 2, windows: [
        win(10, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
        win(20, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [2]),
    ])
    h.eq(LaunchEngine.decide(target: firefox, snapshot: snap, config: config, forceNew: false),
         .focusWindow(windowID: 20, pid: 100))
}

h.test("a window pinned to All Desktops counts as here") {
    let snap = SpaceSnapshot(activeSpaceID: 3, windows: [
        win(10, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1, 2, 3]),
    ])
    h.eq(LaunchEngine.decide(target: firefox, snapshot: snap, config: config, forceNew: false),
         .focusWindow(windowID: 10, pid: 100))
}

h.test("provider seam works with a fake") {
    let snap = SpaceSnapshot(activeSpaceID: 5, windows: [])
    let provider = FakeProvider(snap: snap)
    h.eq(try provider.currentSpaceID(), 5)
    h.eq(try provider.snapshot(), snap)
}

// MARK: - StrategyConfig

print("StrategyConfig")

h.test("known bundle resolves its configured strategy") {
    h.eq(StrategyConfig.defaults.strategy(for: "com.apple.MobileSMS"), .warn)
    h.eq(StrategyConfig.defaults.strategy(for: "com.apple.systempreferences"), .warn)
    h.eq(StrategyConfig.defaults.strategy(for: "com.apple.mail"), .warn)
    h.eq(StrategyConfig.defaults.strategy(for: "org.mozilla.firefox"), .openArgs)
    h.eq(StrategyConfig.defaults.strategy(for: "com.apple.finder"), .appleScript)
}

h.test("browser openArgs carries --new-window") {
    h.eq(StrategyConfig.defaults.args(for: "org.mozilla.firefox"), ["--new-window"])
    h.eq(StrategyConfig.defaults.args(for: "com.google.Chrome"), ["--new-window"])
    h.eq(StrategyConfig.defaults.args(for: "com.apple.finder"), [])
}

h.test("unknown bundle falls back to the default kind") {
    h.eq(StrategyConfig.defaults.strategy(for: "com.unknown.app"), .newInstance)
    h.eq(StrategyConfig.defaults.strategy(for: nil), .newInstance)
}

h.test("applescript snippet lookup") {
    h.ok(StrategyConfig.defaults.appleScript(for: "com.apple.finder") != nil)
    h.ok(StrategyConfig.defaults.appleScript(for: "org.mozilla.firefox") == nil)
}

h.test("load merges user overrides on top of defaults") {
    let json = """
    {
      "defaultStrategy": "focusOnly",
      "apps": [
        { "bundleID": "org.mozilla.firefox", "strategy": "appleScript", "appleScript": "noop" }
      ]
    }
    """
    let cfg = try StrategyConfig.load(from: Data(json.utf8))
    h.eq(cfg.defaultKind, .focusOnly)
    h.eq(cfg.strategy(for: "org.mozilla.firefox"), .appleScript) // overridden
    h.eq(cfg.appleScript(for: "org.mozilla.firefox"), "noop")
    h.eq(cfg.strategy(for: "com.apple.finder"), .appleScript)     // default kept
    h.eq(cfg.strategy(for: "com.unknown.app"), .focusOnly)        // new default
}

h.test("load without a default keeps newInstance") {
    let cfg = try StrategyConfig.load(from: Data(#"{ "apps": [] }"#.utf8))
    h.eq(cfg.defaultKind, .newInstance)
}

h.test("invalid file falls back to defaults") {
    let url = URL(fileURLWithPath: "/nonexistent/powerspaces/config.json")
    h.eq(StrategyConfig.load(from: url), StrategyConfig.defaults)
}

h.test("AppStrategy round-trips through JSON") {
    let original = AppStrategy(bundleID: "x", strategy: .cmdN, appleScript: nil)
    let data = try JSONEncoder().encode(original)
    h.eq(try JSONDecoder().decode(AppStrategy.self, from: data), original)
}

// MARK: - DockModel

print("DockModel")

h.test("only current-Space apps are included") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
        win(20, 200, name: "Mail", bundle: "com.apple.mail", spaces: [2]),
    ])
    h.eq(DockModel.apps(onCurrentSpace: snap).map(\.name), ["Firefox"])
}

h.test("groups windows by app with a count") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
        win(11, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
        win(20, 200, name: "Notes", bundle: "com.apple.Notes", spaces: [1]),
    ])
    let apps = DockModel.apps(onCurrentSpace: snap)
    h.eq(apps.count, 2)
    h.eq(apps.first { $0.name == "Firefox" }?.windowCount, 2)
    h.eq(apps.first { $0.name == "Notes" }?.windowCount, 1)
}

h.test("sorted by name, case-insensitively") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Zed", bundle: "z", spaces: [1]),
        win(20, 200, name: "arc", bundle: "a", spaces: [1]),
    ])
    h.eq(DockModel.apps(onCurrentSpace: snap).map(\.name), ["arc", "Zed"])
}

h.test("keys by owner name when bundle id is missing") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "NoBundle", bundle: nil, spaces: [1]),
        win(11, 100, name: "NoBundle", bundle: nil, spaces: [1]),
    ])
    let apps = DockModel.apps(onCurrentSpace: snap)
    h.eq(apps.count, 1)
    h.eq(apps.first?.windowCount, 2)
    h.eq(apps.first?.target, AppTarget(bundleID: nil, name: "NoBundle"))
}

h.test("empty when no windows live on the current Space") {
    let snap = SpaceSnapshot(activeSpaceID: 9, windows: [
        win(10, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
    ])
    h.ok(DockModel.apps(onCurrentSpace: snap).isEmpty)
}

// MARK: - DockModel: per-window expansion ("Windows" feature)

print("DockModel — per-window expansion")

h.test("expands an app into one entry per window") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
        win(11, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
        win(20, 200, name: "Notes", bundle: "com.apple.Notes", spaces: [1]),
    ])
    let expanded = DockModel.expandingPerWindow(DockModel.apps(onCurrentSpace: snap))
    // Two Firefox icons, one Notes icon.
    h.eq(expanded.map(\.name), ["Firefox", "Firefox", "Notes"])
    // Duplicates stay adjacent and keep the same identity/order key.
    h.eq(expanded[0].orderKey, expanded[1].orderKey)
    // Each Firefox copy is tagged with its own window (so a click hits that exact
    // one); the lone Notes icon stays untagged.
    h.eq(expanded.map(\.windowID), [CGWindowID(10), CGWindowID(11), nil])
}

h.test("base apps carry their windows on the current Space (ascending)") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(11, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
        win(10, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
    ])
    let app = DockModel.apps(onCurrentSpace: snap).first
    h.eq(app?.windowIDs, [10, 11]) // stable order regardless of snapshot z-order
    h.ok(app?.windowID == nil)     // the un-expanded entry has no specific window
}

h.test("a single-window app is left untouched") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Firefox", bundle: "org.mozilla.firefox", spaces: [1]),
    ])
    let apps = DockModel.apps(onCurrentSpace: snap)
    h.eq(DockModel.expandingPerWindow(apps), apps) // identity transform
}

h.test("a pinned-but-not-running app yields exactly one entry") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [])
    let apps = DockModel.apps(onCurrentSpace: snap, pinnedHere: ["com.apple.Notes"],
                              pinnedEverywhere: [], nameForBundleID: { _ in "Notes" })
    let expanded = DockModel.expandingPerWindow(apps)
    h.eq(expanded.count, 1) // windowCount 0 must not vanish or duplicate
    h.eq(expanded.first?.name, "Notes")
}

h.test("expansion preserves the saved arrangement, grouping copies together") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Arc", bundle: "a", spaces: [1]),
        win(20, 200, name: "Zed", bundle: "z", spaces: [1]),
        win(21, 200, name: "Zed", bundle: "z", spaces: [1]),
    ])
    let apps = DockModel.apps(onCurrentSpace: snap, pinnedHere: [], pinnedEverywhere: [],
                              order: ["z", "a"], nameForBundleID: { _ in nil })
    h.eq(DockModel.expandingPerWindow(apps).map(\.name), ["Zed", "Zed", "Arc"])
}

h.test("withTitle attaches a window label and expansion carries it per copy") {
    let base = DockApp(bundleID: "x", name: "X", pid: 1, windowCount: 2, windowIDs: [10, 11])
    h.ok(base.title == nil)                       // pure model leaves it unset
    h.eq(base.withTitle("Inbox — Mail").title, "Inbox — Mail")
    // Each per-window copy keeps the label so the panel can show it.
    h.eq(DockModel.expandingPerWindow([base.withTitle("T")]).map(\.title), ["T", "T"])
}

// MARK: - Pins

print("PinModel")

h.test("pin / unpin / isPinned, isolated per desktop") {
    var model = PinModel()
    model.pin("com.apple.Notes", onSpace: "A")
    h.ok(model.isPinned("com.apple.Notes", onSpace: "A"))
    h.ok(!model.isPinned("com.apple.Notes", onSpace: "B")) // isolated across desktops
    model.unpin("com.apple.Notes", onSpace: "A")
    h.ok(!model.isPinned("com.apple.Notes", onSpace: "A"))
}

h.test("pin is idempotent; toggle flips") {
    var model = PinModel()
    model.pin("x", onSpace: "A"); model.pin("x", onSpace: "A")
    h.eq(model.pinned(onSpace: "A"), ["x"])
    model.toggle("x", onSpace: "A")
    h.eq(model.pinned(onSpace: "A"), [])
    model.toggle("x", onSpace: "A")
    h.eq(model.pinned(onSpace: "A"), ["x"])
}

h.test("different desktops keep different pins") {
    var model = PinModel()
    model.pin("a", onSpace: "A")
    model.pin("b", onSpace: "B")
    h.eq(model.pinned(onSpace: "A"), ["a"])
    h.eq(model.pinned(onSpace: "B"), ["b"])
}

h.test("PinModel round-trips through JSON (persistence)") {
    var model = PinModel()
    model.pin("a", onSpace: "A"); model.pin("b", onSpace: "A")
    let data = try JSONEncoder().encode(model)
    h.eq(try JSONDecoder().decode(PinModel.self, from: data), model)
}

print("DockModel + pins")

h.test("a pinned-but-not-running app still appears in the dock") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [])
    let apps = DockModel.apps(onCurrentSpace: snap, pinnedHere: ["com.apple.Notes"], pinnedEverywhere: [],
                              nameForBundleID: { _ in "Notes" })
    h.eq(apps.map(\.name), ["Notes"])
    h.ok(apps.first?.isPinned == true)
    h.ok(apps.first?.isRunning == false)
}

h.test("a pinned app that's also running is shown once, marked pinned") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Notes", bundle: "com.apple.Notes", spaces: [1]),
    ])
    let apps = DockModel.apps(onCurrentSpace: snap, pinnedHere: ["com.apple.Notes"], pinnedEverywhere: [],
                              nameForBundleID: { _ in "Notes" })
    h.eq(apps.count, 1)
    h.ok(apps.first?.isPinned == true)
    h.ok(apps.first?.isRunning == true)
}

h.test("pins come first (in pin order), then running-unpinned by name") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Zed", bundle: "z", spaces: [1]),
        win(20, 200, name: "Arc", bundle: "a", spaces: [1]),
    ])
    let apps = DockModel.apps(onCurrentSpace: snap, pinnedHere: ["com.apple.Notes"], pinnedEverywhere: [],
                              nameForBundleID: { _ in "Notes" })
    h.eq(apps.map(\.name), ["Notes", "Arc", "Zed"])
}

h.test("a pinned app with no resolvable name is skipped") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [])
    let apps = DockModel.apps(onCurrentSpace: snap, pinnedHere: ["com.unknown.app"], pinnedEverywhere: [],
                              nameForBundleID: { _ in nil })
    h.ok(apps.isEmpty)
}

print("Pins — all desktops + scope")

h.test("pin-everywhere shows on every desktop and is distinct from this-desktop") {
    var model = PinModel()
    model.pinEverywhere("com.apple.Notes")
    h.ok(model.isPinnedEverywhere("com.apple.Notes"))
    h.ok(model.isPinned("com.apple.Notes", onSpace: "A"))
    h.ok(model.isPinned("com.apple.Notes", onSpace: "B")) // every desktop
    h.ok(!model.isPinnedHere("com.apple.Notes", onSpace: "A")) // not a per-desktop pin
}

h.test("pinned(onSpace) merges all-desktops first, then this desktop, de-duped") {
    var model = PinModel()
    model.pinEverywhere("everywhere.app")
    model.pin("here.app", onSpace: "A")
    model.pin("everywhere.app", onSpace: "A") // also explicitly here -> still once
    h.eq(model.pinned(onSpace: "A"), ["everywhere.app", "here.app"])
}

h.test("exclude-everywhere hides an all-desktops pin on one desktop only") {
    var model = PinModel()
    model.pinEverywhere("everywhere.app")
    model.excludeEverywhere("everywhere.app", onSpace: "A")
    h.ok(model.isPinnedEverywhere("everywhere.app")) // still pinned everywhere
    h.ok(model.isExcludedEverywhere("everywhere.app", onSpace: "A"))
    h.ok(!model.isPinned("everywhere.app", onSpace: "A")) // gone from this desktop
    h.ok(model.isPinned("everywhere.app", onSpace: "B")) // still on every other desktop
    h.eq(model.pinned(onSpace: "A"), [])
    h.eq(model.pinned(onSpace: "B"), ["everywhere.app"])
}

h.test("include-everywhere shows a previously-hidden all-desktops pin again") {
    var model = PinModel()
    model.pinEverywhere("everywhere.app")
    model.excludeEverywhere("everywhere.app", onSpace: "A")
    model.includeEverywhere("everywhere.app", onSpace: "A")
    h.ok(!model.isExcludedEverywhere("everywhere.app", onSpace: "A"))
    h.eq(model.pinned(onSpace: "A"), ["everywhere.app"])
}

h.test("excluding an all-desktops pin also drops a stale local pin, so it truly hides") {
    var model = PinModel()
    model.pin("app", onSpace: "A")        // explicitly pinned here too
    model.pinEverywhere("app")
    model.excludeEverywhere("app", onSpace: "A")
    h.ok(!model.isPinnedHere("app", onSpace: "A")) // local pin cleared
    h.eq(model.pinned(onSpace: "A"), [])
}

h.test("a local pin overrides an exception (re-pinning here brings it back)") {
    var model = PinModel()
    model.pinEverywhere("app")
    model.excludeEverywhere("app", onSpace: "A")
    model.pin("app", onSpace: "A") // explicit local pin wins, and clears the exception
    h.ok(!model.isExcludedEverywhere("app", onSpace: "A"))
    h.eq(model.pinned(onSpace: "A"), ["app"])
}

h.test("toggling the all-desktops pin off then on forgets per-desktop exceptions") {
    var model = PinModel()
    model.pinEverywhere("app")
    model.excludeEverywhere("app", onSpace: "A")
    model.unpinEverywhere("app")
    h.ok(!model.isExcludedEverywhere("app", onSpace: "A")) // exception cleared on unpin
    model.pinEverywhere("app")
    h.eq(model.pinned(onSpace: "A"), ["app"]) // shows everywhere again, fresh
}

h.test("exceptions are isolated per desktop") {
    var model = PinModel()
    model.pinEverywhere("app")
    model.toggleEverywhereException("app", onSpace: "A") // hide on A
    h.eq(model.everywhereExceptions(onSpace: "A"), ["app"])
    h.eq(model.everywhereExceptions(onSpace: "B"), [])
    model.toggleEverywhereException("app", onSpace: "A") // show again on A
    h.eq(model.everywhereExceptions(onSpace: "A"), [])
}

h.test("PinModel round-trips per-desktop exceptions through JSON") {
    var model = PinModel()
    model.pinEverywhere("app")
    model.excludeEverywhere("app", onSpace: "A")
    let data = try JSONEncoder().encode(model)
    h.eq(try JSONDecoder().decode(PinModel.self, from: data), model)
}

h.test("PinModel JSON is migration-safe (old file without 'everywhere')") {
    let oldJSON = #"{ "pinsBySpace": { "A": ["x"] } }"#
    let model = try JSONDecoder().decode(PinModel.self, from: Data(oldJSON.utf8))
    h.eq(model.spacePins(onSpace: "A"), ["x"])
    h.eq(model.everywherePins(), [])
    h.eq(model.everywhereExceptions(onSpace: "A"), []) // a file predating exceptions still loads
    h.eq(model.order(onSpace: "A"), []) // a file predating saved order still loads
}

h.test("setOrder saves and clears the arrangement, isolated per desktop") {
    var model = PinModel()
    model.setOrder(["a", "b"], onSpace: "A")
    h.eq(model.order(onSpace: "A"), ["a", "b"])
    h.eq(model.order(onSpace: "B"), []) // each desktop arranges independently
    model.setOrder([], onSpace: "A") // an empty list clears it
    h.eq(model.order(onSpace: "A"), [])
}

h.test("PinModel round-trips the saved order through JSON") {
    var model = PinModel()
    model.pin("a", onSpace: "A")
    model.setOrder(["a", "b"], onSpace: "A")
    let data = try JSONEncoder().encode(model)
    h.eq(try JSONDecoder().decode(PinModel.self, from: data), model)
}

h.test("DockModel marks all-desktops vs this-desktop pins") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [])
    let apps = DockModel.apps(onCurrentSpace: snap,
                              pinnedHere: ["here.app"], pinnedEverywhere: ["all.app"],
                              nameForBundleID: { _ in "App" })
    let all = apps.first { $0.bundleID == "all.app" }
    let here = apps.first { $0.bundleID == "here.app" }
    h.ok(all?.isPinnedEverywhere == true && all?.isPinnedHere == false)
    h.ok(here?.isPinnedHere == true && here?.isPinnedEverywhere == false)
    h.eq(apps.map(\.bundleID), ["all.app", "here.app"]) // all-desktops first
}

h.test("an all-desktops pin hidden here drops out of the dock when not running") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [])
    let apps = DockModel.apps(onCurrentSpace: snap,
                              pinnedHere: [], pinnedEverywhere: ["all.app"],
                              excludedHere: ["all.app"],
                              nameForBundleID: { _ in "App" })
    h.ok(apps.isEmpty) // gone from this desktop entirely
}

h.test("a running app hidden-here is shown but tagged isExcludedHere (for the re-show menu)") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "App", bundle: "all.app", spaces: [1]),
    ])
    let apps = DockModel.apps(onCurrentSpace: snap,
                              pinnedHere: [], pinnedEverywhere: ["all.app"],
                              excludedHere: ["all.app"],
                              nameForBundleID: { _ in "App" })
    let app = apps.first { $0.bundleID == "all.app" }
    h.eq(apps.count, 1)
    h.ok(app?.isPinnedEverywhere == true)
    h.ok(app?.isExcludedHere == true)
    h.ok(app?.isPinned == false) // shows because it's running, not as a pin
}

h.test("a local pin wins over an exception (still shown, not excluded)") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [])
    let apps = DockModel.apps(onCurrentSpace: snap,
                              pinnedHere: ["app"], pinnedEverywhere: ["app"],
                              excludedHere: ["app"],
                              nameForBundleID: { _ in "App" })
    let app = apps.first { $0.bundleID == "app" }
    h.eq(apps.count, 1)
    h.ok(app?.isPinnedHere == true)
    h.ok(app?.isExcludedHere == false)
}

print("Dock order (saved arrangement)")

h.test("the saved order overrides the default pinned-then-alphabetical layout") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Arc", bundle: "a", spaces: [1]),
        win(20, 200, name: "Zed", bundle: "z", spaces: [1]),
    ])
    // Default would be Notes (pinned), Arc, Zed. The saved order rearranges all three.
    let apps = DockModel.apps(onCurrentSpace: snap,
                              pinnedHere: ["com.apple.Notes"], pinnedEverywhere: [],
                              order: ["z", "com.apple.Notes", "a"],
                              nameForBundleID: { _ in "Notes" })
    h.eq(apps.map(\.name), ["Zed", "Notes", "Arc"])
}

h.test("apps missing from the saved order keep their default spot and trail behind") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Arc", bundle: "a", spaces: [1]),
        win(20, 200, name: "Mail", bundle: "m", spaces: [1]),
        win(30, 300, name: "Zed", bundle: "z", spaces: [1]),
    ])
    // Only Zed is remembered; Arc and Mail fall back to alphabetical, after it.
    let apps = DockModel.apps(onCurrentSpace: snap,
                              pinnedHere: [], pinnedEverywhere: [], order: ["z"],
                              nameForBundleID: { _ in nil })
    h.eq(apps.map(\.name), ["Zed", "Arc", "Mail"])
}

h.test("an empty saved order leaves the default arrangement untouched") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Zed", bundle: "z", spaces: [1]),
        win(20, 200, name: "Arc", bundle: "a", spaces: [1]),
    ])
    let apps = DockModel.apps(onCurrentSpace: snap,
                              pinnedHere: [], pinnedEverywhere: [], order: [],
                              nameForBundleID: { _ in nil })
    h.eq(apps.map(\.name), ["Arc", "Zed"])
}

h.test("an app without a bundle id is ordered by its owner name") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Arc", bundle: "a", spaces: [1]),
        win(20, 200, name: "NoBundle", bundle: nil, spaces: [1]),
    ])
    let apps = DockModel.apps(onCurrentSpace: snap,
                              pinnedHere: [], pinnedEverywhere: [], order: ["NoBundle", "a"],
                              nameForBundleID: { _ in nil })
    h.eq(apps.map(\.name), ["NoBundle", "Arc"])
}

print("DockModel — App Launcher tile")

h.test("the launcher tile is off by default and leftmost when on") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Arc", bundle: "a", spaces: [1]),
        win(20, 200, name: "Zed", bundle: "z", spaces: [1]),
    ])
    let off = DockModel.apps(onCurrentSpace: snap, pinnedHere: [], pinnedEverywhere: [],
                             nameForBundleID: { _ in nil })
    h.ok(!off.contains { $0.isLauncher }, "no launcher tile unless asked for")
    let on = DockModel.apps(onCurrentSpace: snap, pinnedHere: [], pinnedEverywhere: [],
                            includeLauncher: true, nameForBundleID: { _ in nil })
    h.eq(on.first?.isLauncher, true)
    h.eq(on.map(\.name), ["Applications", "Arc", "Zed"])
}

h.test("the launcher stays leftmost even when other apps have a saved order") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Arc", bundle: "a", spaces: [1]),
        win(20, 200, name: "Zed", bundle: "z", spaces: [1]),
    ])
    // Saved order ranks the real apps but predates the launcher; it must still lead.
    let apps = DockModel.apps(onCurrentSpace: snap, pinnedHere: [], pinnedEverywhere: [],
                              order: ["z", "a"], includeLauncher: true,
                              nameForBundleID: { _ in nil })
    h.eq(apps.map(\.name), ["Applications", "Zed", "Arc"])
}

h.test("once placed in the saved order, the launcher keeps that slot") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Arc", bundle: "a", spaces: [1]),
        win(20, 200, name: "Zed", bundle: "z", spaces: [1]),
    ])
    let apps = DockModel.apps(onCurrentSpace: snap, pinnedHere: [], pinnedEverywhere: [],
                              order: ["a", DockApp.launcherOrderKey, "z"], includeLauncher: true,
                              nameForBundleID: { _ in nil })
    h.eq(apps.map(\.name), ["Arc", "Applications", "Zed"])
    h.eq(apps[1].isLauncher, true)
}

print("DockClickAction")

h.test("click brings to front; click again (frontmost) minimizes") {
    let here = LaunchDecision.focusWindow(windowID: 7, pid: 100)
    h.eq(LaunchEngine.dockClick(decision: here, isFrontmost: false), .raise(windowID: 7, pid: 100))
    h.eq(LaunchEngine.dockClick(decision: here, isFrontmost: true), .minimize(windowID: 7, pid: 100))
}

h.test("a minimized window always restores, never re-minimizes (Finder repro)") {
    let here = LaunchDecision.focusWindow(windowID: 7, pid: 100)
    // Frontmost but minimized — Finder stays the active app with its last window
    // in the Dock. Must restore, not minimize-again (which was the dead-icon bug).
    h.eq(LaunchEngine.dockClick(decision: here, isFrontmost: true, isMinimized: true),
         .raise(windowID: 7, pid: 100))
    // Not frontmost and minimized — still restore.
    h.eq(LaunchEngine.dockClick(decision: here, isFrontmost: false, isMinimized: true),
         .raise(windowID: 7, pid: 100))
}

h.test("the full click cycle: raise → minimize → restore → minimize") {
    let here = LaunchDecision.focusWindow(windowID: 7, pid: 100)
    // 1: not front, not minimized → raise
    h.eq(LaunchEngine.dockClick(decision: here, isFrontmost: false, isMinimized: false),
         .raise(windowID: 7, pid: 100))
    // 2: now front, visible → minimize
    h.eq(LaunchEngine.dockClick(decision: here, isFrontmost: true, isMinimized: false),
         .minimize(windowID: 7, pid: 100))
    // 3: minimized (Finder still front) → restore
    h.eq(LaunchEngine.dockClick(decision: here, isFrontmost: true, isMinimized: true),
         .raise(windowID: 7, pid: 100))
    // 4: front, visible again → minimize
    h.eq(LaunchEngine.dockClick(decision: here, isFrontmost: true, isMinimized: false),
         .minimize(windowID: 7, pid: 100))
}

h.test("click maps launch/new-window through unchanged") {
    h.eq(LaunchEngine.dockClick(decision: .launchApp, isFrontmost: false), .launch)
    h.eq(LaunchEngine.dockClick(decision: .newWindow(.openArgs), isFrontmost: true), .newWindow(.openArgs))
}

// MARK: - Quit vs Minimize — the dock icon's lifecycle (behaviors 7 & 8)

print("Quit & Minimize — dock icon lifecycle")

h.test("quitting an app (no windows, not pinned) removes its dock icon") {
    // Behavior 7: the red-cross / "Quit" terminates the app. With no window left on
    // the Space and no pin holding it, the app must drop out of the dock entirely —
    // its icon disappears.
    let afterQuit = SpaceSnapshot(activeSpaceID: 1, windows: [], runningBundleIDs: [])
    h.ok(DockModel.apps(onCurrentSpace: afterQuit).isEmpty, "icon disappears after quit")

    // …but a *pinned* app is kept — now as a not-running launcher, so a later click
    // relaunches it rather than leaving a hole in the dock.
    let pinned = DockModel.apps(onCurrentSpace: afterQuit,
                                pinnedHere: ["com.apple.Notes"], pinnedEverywhere: [],
                                nameForBundleID: { _ in "Notes" })
    h.eq(pinned.map(\.name), ["Notes"])
    h.ok(pinned.first?.isRunning == false, "kept by its pin, shown as not running")
}

h.test("a minimized window keeps the app in the dock, shown as running/active") {
    // Behavior 8: clicking Minimize hides the window, but it stays on the Space
    // (WindowFilter keeps minimized windows — see the WindowFilter suite). So the
    // dock must still list the app and mark it running — `isRunning` is what drives
    // the dock's "active" rendering (non-dimmed / running box, DockPanel ~L380), so
    // the icon stays put and shows active rather than dimming away like a quit app.
    let minimizedOnly = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Notes", bundle: "com.apple.Notes", spaces: [1]),
    ])
    let apps = DockModel.apps(onCurrentSpace: minimizedOnly)
    h.eq(apps.map(\.name), ["Notes"])
    h.ok(apps.first?.isRunning == true, "still running → icon shown as active")
    h.eq(apps.first?.windowCount, 1)
}

// MARK: - DockRefresher (the display pipeline: expand + label)

print("DockRefresher")

// A space with a 2-window app (Firefox) and a 1-window app (Notes).
let twoApps = SpaceSnapshot(activeSpaceID: 1, windows: [
    win(10, 100, name: "Firefox", bundle: "ff", spaces: [1]),
    win(11, 100, name: "Firefox", bundle: "ff", spaces: [1]),
    win(20, 200, name: "Notes", bundle: "notes", spaces: [1]),
])

h.test("expand off → one entry per app, and labels off reads no titles") {
    var titleCalls = 0
    let apps = DockRefresher.displayApps(
        snapshot: twoApps, pinnedHere: [], pinnedEverywhere: [], order: [],
        options: .init(expandPerWindow: false, shouldLabel: { _ in false }),
        nameForBundleID: { _ in nil },
        titleForWindow: { _, _ in titleCalls += 1; return "T" })
    h.eq(apps.map(\.name), ["Firefox", "Notes"])
    h.ok(apps.allSatisfy { $0.windowID == nil }, "not expanded")
    h.ok(apps.allSatisfy { $0.title == nil }, "no titles attached")
    h.eq(titleCalls, 0, "labels off must not read any window titles")
}

h.test("expand on → one entry per window for multi-window apps") {
    let apps = DockRefresher.displayApps(
        snapshot: twoApps, pinnedHere: [], pinnedEverywhere: [], order: [],
        options: .init(expandPerWindow: true, shouldLabel: { _ in false }),
        nameForBundleID: { _ in nil }, titleForWindow: { _, _ in nil })
    h.eq(apps.map(\.name), ["Firefox", "Firefox", "Notes"])
    h.ok(apps[0].windowID == 10)
    h.ok(apps[1].windowID == 11)
    h.ok(apps[2].windowID == nil, "a single-window app is left untagged")
}

h.test("labels on → each labeled item gets its own window's title") {
    var seen: [CGWindowID] = []
    let apps = DockRefresher.displayApps(
        snapshot: twoApps, pinnedHere: [], pinnedEverywhere: [], order: [],
        options: .init(expandPerWindow: true, shouldLabel: { _ in true }),
        nameForBundleID: { _ in nil },
        titleForWindow: { wid, _ in seen.append(wid); return "title-\(wid)" })
    h.eq(apps.map { $0.title ?? "·" }, ["title-10", "title-11", "title-20"])
    h.eq(seen.sorted(), [10, 11, 20])
}

h.test("\"multiple windows\" scope labels only apps with >1 window here") {
    let apps = DockRefresher.displayApps(
        snapshot: twoApps, pinnedHere: [], pinnedEverywhere: [], order: [],
        options: .init(expandPerWindow: false, shouldLabel: { $0 > 1 }),
        nameForBundleID: { _ in nil },
        titleForWindow: { wid, _ in "title-\(wid)" })
    h.ok(apps[0].title == "title-10", "Firefox (2 windows) labeled, using its first window")
    h.ok(apps[1].title == nil, "Notes (1 window) stays unlabeled")
}

h.test("a pinned-but-not-running app never triggers a title read") {
    var titleCalls = 0
    let onlyFirefox = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Firefox", bundle: "ff", spaces: [1]),
    ])
    let apps = DockRefresher.displayApps(
        snapshot: onlyFirefox, pinnedHere: [], pinnedEverywhere: ["notes"], order: [],
        options: .init(expandPerWindow: true, shouldLabel: { _ in true }),
        nameForBundleID: { $0 == "notes" ? "Notes" : nil },
        titleForWindow: { _, _ in titleCalls += 1; return "T" })
    let notes = apps.first { $0.name == "Notes" }
    h.ok(notes != nil && notes?.title == nil, "pinned-not-running has no window to label")
    h.eq(titleCalls, 1, "only the one running window (Firefox) is read")
}

// MARK: - WindowFilter (real-vs-phantom window predicate)

print("WindowFilter")
h.test("keeps real windows (Safari/Finder real windows observed)") {
    h.ok(WindowFilter.isRealWindow(layer: 0, alpha: 1, width: 1728, height: 1010))
    h.ok(WindowFilter.isRealWindow(layer: 0, alpha: 1, width: 920, height: 436))
}
h.test("drops Safari/Finder accessory windows on the same layer") {
    // Full-width toolbar / tab-bar strips (Finder + Safari).
    h.ok(!WindowFilter.isRealWindow(layer: 0, alpha: 1, width: 1728, height: 33))
    // Short accessory bar — the one that makes a new Safari tab look like a window.
    h.ok(!WindowFilter.isRealWindow(layer: 0, alpha: 1, width: 865, height: 61))
    // Transparent hover-URL status overlay.
    h.ok(!WindowFilter.isRealWindow(layer: 0, alpha: 0, width: 273, height: 20))
    // Tiny helper squares.
    h.ok(!WindowFilter.isRealWindow(layer: 0, alpha: 1, width: 64, height: 64))
}
h.test("drops non-zero layers (menu bar, dock, popovers)") {
    h.ok(!WindowFilter.isRealWindow(layer: 25, alpha: 1, width: 1728, height: 1010))
}
h.test("keeps semi-transparent real windows (e.g. a translucent terminal)") {
    h.ok(WindowFilter.isRealWindow(layer: 0, alpha: 0.85, width: 800, height: 600))
}
h.test("threshold is inclusive at the minimum size") {
    let m = WindowFilter.minRealWindowSize
    h.ok(WindowFilter.isRealWindow(layer: 0, alpha: 1, width: m, height: m))
    h.ok(!WindowFilter.isRealWindow(layer: 0, alpha: 1, width: m - 1, height: m))
    h.ok(!WindowFilter.isRealWindow(layer: 0, alpha: 1, width: m, height: m - 1))
}
h.test("active-space phantom: claims current Space, not onscreen, not minimized") {
    // The full-size placeholder that briefly claims the current Space.
    h.ok(WindowFilter.isActiveSpacePhantom(claimsActiveSpace: true, isOnscreen: false))
}
h.test("active-space: real onscreen window (stacked) is kept") {
    h.ok(!WindowFilter.isActiveSpacePhantom(claimsActiveSpace: true, isOnscreen: true))
}
h.test("active-space: minimized window is kept (icon stays in the dock)") {
    // A minimized window sits in the Dock with onscreen=false but is real — it
    // must not be dropped, or a minimized-only app vanishes from the dock.
    h.ok(!WindowFilter.isActiveSpacePhantom(
        claimsActiveSpace: true, isOnscreen: false, isMinimized: true))
}
h.test("active-space: ⌘-hidden window is kept (app stays clickable in the dock)") {
    // A ⌘-hidden app's windows are off-screen and not minimized but are real —
    // dropping them would make hiding an app erase it from the dock.
    h.ok(!WindowFilter.isActiveSpacePhantom(
        claimsActiveSpace: true, isOnscreen: false, isMinimized: false, isHidden: true))
}
h.test("other-space windows are never treated as phantoms") {
    // Windows on other Spaces always report onscreen=false; we must keep them so
    // the engine still knows the app runs elsewhere.
    h.ok(!WindowFilter.isActiveSpacePhantom(claimsActiveSpace: false, isOnscreen: false))
    h.ok(!WindowFilter.isActiveSpacePhantom(claimsActiveSpace: false, isOnscreen: true))
}

// MARK: - WindowFilter.isStandaloneWindow (real-window-vs-impostor predicate)
//
// Values are the live AX readings from the verification probes: a standalone
// window, a modal alert panel, a sheet, and Safari's search-suggestions list.
h.test("a real standalone window counts (a new Safari window)") {
    h.ok(WindowFilter.isStandaloneWindow(role: "AXWindow", subrole: "AXStandardWindow", isModal: false))
    // Only the role is required, so floating/utility/full-screen windows count too.
    h.ok(WindowFilter.isStandaloneWindow(role: "AXWindow", subrole: "AXFloatingWindow", isModal: false))
    h.ok(WindowFilter.isStandaloneWindow(role: "AXWindow", subrole: nil, isModal: false))
}
h.test("a modal alert panel is not a standalone window") {
    h.ok(!WindowFilter.isStandaloneWindow(role: "AXWindow", subrole: "AXDialog", isModal: true))
    // A system dialog, and modal alone, also disqualify it.
    h.ok(!WindowFilter.isStandaloneWindow(role: "AXWindow", subrole: "AXSystemDialog", isModal: false))
    h.ok(!WindowFilter.isStandaloneWindow(role: "AXWindow", subrole: "AXStandardWindow", isModal: true))
}
h.test("a sheet is not a standalone window (the System Settings popup)") {
    // role AXSheet, no subrole, not flagged modal.
    h.ok(!WindowFilter.isStandaloneWindow(role: "AXSheet", subrole: nil, isModal: false))
}
h.test("Safari's search-suggestions list is not a standalone window (role AXScrollArea)") {
    // Typing in the smart-search field surfaces an AXScrollArea as its own
    // window-server window next to the page window — it must not add a 2nd icon.
    h.ok(!WindowFilter.isStandaloneWindow(role: "AXScrollArea", subrole: nil, isModal: false))
}
h.test("an unreadable AX kind is not counted as a standalone window") {
    // The provider keeps all of an app's windows when it finds no standalone window
    // at all, so treating a nil role as 'not a window' here can't erase an app.
    h.ok(!WindowFilter.isStandaloneWindow(role: nil, subrole: nil, isModal: false))
}

// MARK: - WindowFilter.isBlockingDialog (spare a save prompt from "Quit (all desktops)")

h.test("a save sheet is a blocking dialog (role AXSheet)") {
    h.ok(WindowFilter.isBlockingDialog(role: "AXSheet", subrole: nil, isModal: false))
}
h.test("a modal alert panel is a blocking dialog") {
    h.ok(WindowFilter.isBlockingDialog(role: "AXWindow", subrole: "AXDialog", isModal: true))
    h.ok(WindowFilter.isBlockingDialog(role: "AXWindow", subrole: "AXSystemDialog", isModal: false))
    h.ok(WindowFilter.isBlockingDialog(role: "AXWindow", subrole: "AXStandardWindow", isModal: true))
}
h.test("a normal window is not a blocking dialog (WhatsApp gets force-quit)") {
    h.ok(!WindowFilter.isBlockingDialog(role: "AXWindow", subrole: "AXStandardWindow", isModal: false))
    h.ok(!WindowFilter.isBlockingDialog(role: "AXWindow", subrole: nil, isModal: false))
}
h.test("a non-window accessory is not mistaken for a blocking dialog (no spurious spare)") {
    // A search-suggestions AXScrollArea isn't a standalone window, but it's not a
    // dialog either — it must not keep an app alive as if it were a save prompt.
    h.ok(!WindowFilter.isBlockingDialog(role: "AXScrollArea", subrole: nil, isModal: false))
}
h.test("an unreadable AX kind is not treated as a blocking dialog") {
    h.ok(!WindowFilter.isBlockingDialog(role: nil, subrole: nil, isModal: false))
}

// MARK: - DockModel: per-display content (multi-display)

// A window with explicit geometry/visibility for the per-display filter.
func dwin(_ id: CGWindowID, _ pid: pid_t = 100, name: String, bundle: String,
          rect: CGRect, onscreen: Bool = true, minimized: Bool = false,
          hidden: Bool = false, spaces: [SpaceID] = []) -> WindowInfo {
    WindowInfo(windowID: id, pid: pid, ownerName: name, bundleID: bundle, spaceIDs: spaces,
               bounds: rect, isOnscreen: onscreen, isMinimized: minimized, isHidden: hidden)
}

// Two side-by-side 1920×1080 displays (global top-left origin).
let leftDisplay = CGRect(x: 0, y: 0, width: 1920, height: 1080)
let rightDisplay = CGRect(x: 1920, y: 0, width: 1920, height: 1080)

print("DockModel — per display")
h.test("a display's dock shows only the apps on that display's visible Space") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        dwin(10, 100, name: "Firefox", bundle: "org.mozilla.firefox",
             rect: CGRect(x: 100, y: 100, width: 800, height: 600)),       // on left, visible
        dwin(20, 200, name: "Notes", bundle: "com.apple.Notes",
             rect: CGRect(x: 2000, y: 100, width: 800, height: 600)),      // on right, visible
    ])
    let left = DockModel.apps(onDisplay: leftDisplay, snapshot: snap).map(\.name)
    let right = DockModel.apps(onDisplay: rightDisplay, snapshot: snap).map(\.name)
    h.eq(left, ["Firefox"], "left dock = left-screen apps")
    h.eq(right, ["Notes"], "right dock = right-screen apps")
}
h.test("a minimized window keeps its app on the display it was minimized from") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        dwin(30, 300, name: "Slack", bundle: "com.tinyspeck.slackmacgap",
             rect: CGRect(x: 200, y: 200, width: 700, height: 500), onscreen: false, minimized: true),
    ])
    h.eq(DockModel.apps(onDisplay: leftDisplay, snapshot: snap).map(\.name), ["Slack"],
         "minimized app stays in its display's dock")
    h.eq(DockModel.apps(onDisplay: rightDisplay, snapshot: snap).count, 0,
         "and not in the other display's dock")
}
h.test("a window minimized on another desktop of this display is excluded") {
    // The repro: same app open on two desktops of one display, the desktop-2 copy
    // minimized. Viewing desktop 1, its minimized desktop-2 window must NOT count —
    // otherwise the app shows a phantom second icon alongside its real desktop-1 one.
    // (`isOnscreen` is relative to the visible desktop: the desktop-1 window is
    // onscreen here, the desktop-2 window is minimized and off-screen.)
    let viewingOne = SpaceSnapshot(activeSpaceID: 1, windows: [
        dwin(60, 600, name: "Claude", bundle: "com.anthropic.claudefordesktop",
             rect: CGRect(x: 200, y: 200, width: 900, height: 700), spaces: [1]),         // real, here
        dwin(61, 601, name: "Claude", bundle: "com.anthropic.claudefordesktop",
             rect: CGRect(x: 200, y: 200, width: 900, height: 700),
             onscreen: false, minimized: true, spaces: [2]),                              // minimized on desktop 2
    ])
    let apps = DockModel.apps(onDisplay: leftDisplay, snapshot: viewingOne, visibleSpace: 1)
    h.eq(apps.map(\.name), ["Claude"], "the app appears once")
    h.eq(apps.first?.windowCount, 1, "counting only the window on the visible desktop")
    // Standing on desktop 2 instead: now its window is the onscreen one, and the
    // desktop-1 window is parked on a hidden Space (off-screen, not minimized).
    let viewingTwo = SpaceSnapshot(activeSpaceID: 2, windows: [
        dwin(60, 600, name: "Claude", bundle: "com.anthropic.claudefordesktop",
             rect: CGRect(x: 200, y: 200, width: 900, height: 700),
             onscreen: false, minimized: false, spaces: [1]),                             // hidden on desktop 1
        dwin(61, 601, name: "Claude", bundle: "com.anthropic.claudefordesktop",
             rect: CGRect(x: 200, y: 200, width: 900, height: 700), spaces: [2]),         // real, here
    ])
    let onTwo = DockModel.apps(onDisplay: leftDisplay, snapshot: viewingTwo, visibleSpace: 2)
    h.eq(onTwo.first?.windowCount, 1, "and it shows once on its own desktop")
}
h.test("a minimized window with unknown Space (secondary display) still shows") {
    // macOS only reports Space membership for the active display; an empty set means
    // "unknown", so the geometric test must still keep a minimized window in the bar.
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        dwin(70, 700, name: "Slack", bundle: "com.tinyspeck.slackmacgap",
             rect: CGRect(x: 2000, y: 100, width: 700, height: 500),
             onscreen: false, minimized: true, spaces: []),
    ])
    h.eq(DockModel.apps(onDisplay: rightDisplay, snapshot: snap, visibleSpace: 9).map(\.name),
         ["Slack"], "unknown-Space minimized window falls back to geometry")
}
h.test("a window parked on a display's hidden desktop is excluded") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        // off-screen + not minimized = on a hidden Space of the right display.
        dwin(40, 400, name: "Mail", bundle: "com.apple.mail",
             rect: CGRect(x: 2100, y: 150, width: 800, height: 600), onscreen: false, minimized: false),
    ])
    h.eq(DockModel.apps(onDisplay: rightDisplay, snapshot: snap).count, 0,
         "a hidden-desktop window is not on the visible bar")
}
h.test("a ⌘-hidden window keeps its app on the display it was hidden on") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        // off-screen + not minimized but hidden (⌘H) = still on the visible bar.
        dwin(50, 500, name: "Music", bundle: "com.apple.Music",
             rect: CGRect(x: 200, y: 200, width: 700, height: 500),
             onscreen: false, minimized: false, hidden: true),
    ])
    h.eq(DockModel.apps(onDisplay: leftDisplay, snapshot: snap).map(\.name), ["Music"],
         "a hidden app stays in its display's dock")
    h.eq(DockModel.apps(onDisplay: rightDisplay, snapshot: snap).count, 0,
         "and not in the other display's dock")
}

// The branches above cover the off-screen window's Space being *unknown* (empty,
// the secondary-display fallback) and *mismatched* (parked on another desktop).
// These two pin down the remaining leaf: an off-screen (minimized or ⌘-hidden)
// window whose *known* Space *matches* the desktop being viewed — it must count.
h.test("a minimized window whose known Space matches the visible desktop is kept") {
    // isOnVisibleDesktop's `isOn(visibleSpace)` branch, reached via a minimized
    // (off-screen) window: minimized on desktop 1, viewing desktop 1 → counts.
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        dwin(80, 800, name: "Slack", bundle: "com.tinyspeck.slackmacgap",
             rect: CGRect(x: 200, y: 200, width: 700, height: 500),
             onscreen: false, minimized: true, spaces: [1]),
    ])
    h.eq(DockModel.apps(onDisplay: leftDisplay, snapshot: snap, visibleSpace: 1).map(\.name),
         ["Slack"], "minimized-here window counts on the desktop it belongs to")
    // …and the geometric `&& isOnDisplay` still scopes it: it's on the left screen,
    // so the right display's bar (same desktop id) must not show it.
    h.eq(DockModel.apps(onDisplay: rightDisplay, snapshot: snap, visibleSpace: 1).count, 0,
         "but only on the screen it physically sits on")
}
h.test("a ⌘-hidden window on another desktop (known Space) is excluded") {
    // The hidden twin of the minimized-leak fix: a ⌘-hidden window parked on
    // desktop 2 must not leak into desktop 1's bar (its Space != visibleSpace).
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        dwin(81, 801, name: "Music", bundle: "com.apple.Music",
             rect: CGRect(x: 200, y: 200, width: 700, height: 500),
             onscreen: false, minimized: false, hidden: true, spaces: [2]),
    ])
    h.eq(DockModel.apps(onDisplay: leftDisplay, snapshot: snap, visibleSpace: 1).count, 0,
         "a hidden window whose Space is another desktop does not count here")
}
h.test("a ⌘-hidden window whose known Space matches the visible desktop is kept") {
    // The same `isOn(visibleSpace)` leaf, reached via a ⌘-hidden window: hidden on
    // desktop 1, viewing desktop 1 → counts, so ⌘-H doesn't erase the icon.
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        dwin(82, 802, name: "Music", bundle: "com.apple.Music",
             rect: CGRect(x: 200, y: 200, width: 700, height: 500),
             onscreen: false, minimized: false, hidden: true, spaces: [1]),
    ])
    h.eq(DockModel.apps(onDisplay: leftDisplay, snapshot: snap, visibleSpace: 1).map(\.name),
         ["Music"], "a hidden-here window keeps its app on the visible desktop")
}

// MARK: - DockModel: window-less running apps ("show apps with no open windows")

print("DockModel — window-less apps")
h.test("a window-less running app is injected and shown as running") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Notes", bundle: "com.apple.Notes", spaces: [1]),
    ])
    let windowless = [DockApp(bundleID: "com.apple.Music", name: "Music", pid: 900, windowCount: 0)]
    let apps = DockModel.apps(onCurrentSpace: snap, pinnedHere: [], pinnedEverywhere: [],
                              windowlessApps: windowless, nameForBundleID: { _ in nil })
    h.eq(apps.map(\.name), ["Music", "Notes"], "the window-less app joins the dock, sorted by name")
    h.ok(apps.first { $0.name == "Music" }?.isRunning == true, "and reads as running (has a pid)")
}
h.test("a window-less app already present (it has a window) is not duplicated") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(20, 200, name: "Notes", bundle: "com.apple.Notes", spaces: [1]),
    ])
    // Same bundle as a windowed app — must be de-duped, not added twice.
    let windowless = [DockApp(bundleID: "com.apple.Notes", name: "Notes", pid: 200, windowCount: 0)]
    let apps = DockModel.apps(onCurrentSpace: snap, pinnedHere: [], pinnedEverywhere: [],
                              windowlessApps: windowless, nameForBundleID: { _ in nil })
    h.eq(apps.map(\.name), ["Notes"], "no duplicate Notes entry")
}
h.test("with no injected window-less apps, a running window-less app stays out of the dock") {
    // The "off" leaf of the window-less branch: when "show apps with no open windows"
    // is off the app layer passes an empty list, so an app that's running but has no
    // window on this Space is simply absent — only its windowed neighbour shows.
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Notes", bundle: "com.apple.Notes", spaces: [1]),
    ], runningBundleIDs: ["com.apple.Notes", "com.apple.Music"]) // Music runs, no window here
    let apps = DockModel.apps(onCurrentSpace: snap, pinnedHere: [], pinnedEverywhere: [],
                              windowlessApps: [], nameForBundleID: { _ in nil })
    h.eq(apps.map(\.name), ["Notes"], "no window-less item is injected when none are supplied")
}
h.test("per-display dock still merges pins for that display's desktop") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        dwin(10, 100, name: "Firefox", bundle: "org.mozilla.firefox",
             rect: CGRect(x: 100, y: 100, width: 800, height: 600)),
    ])
    let apps = DockModel.apps(onDisplay: leftDisplay, snapshot: snap,
                              pinnedHere: ["com.apple.Notes"], pinnedEverywhere: [],
                              order: [], nameForBundleID: { _ in "Notes" })
    h.ok(apps.contains { $0.name == "Notes" && $0.isPinnedHere }, "pinned-but-not-running app shows")
    h.ok(apps.contains { $0.name == "Firefox" }, "running app on this display shows")
}

// MARK: - SpaceSnapshot: the "show hidden apps" filter (decision-tree gate)

// The dock builds from `snapshot` when "show hidden apps" is ON and from
// `snapshot.droppingHiddenWindows()` when it's OFF (see AppDelegate.refresh).
// These pin down both sides of that gate at the model level.
print("SpaceSnapshot — \"show hidden apps\" filter")
h.test("show-hidden ON keeps a ⌘-hidden app; OFF drops it, leaving visible apps") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        dwin(10, 100, name: "Notes", bundle: "com.apple.Notes",
             rect: CGRect(x: 100, y: 100, width: 800, height: 600), spaces: [1]),       // visible
        dwin(20, 200, name: "Music", bundle: "com.apple.Music",
             rect: CGRect(x: 150, y: 150, width: 800, height: 600),
             onscreen: false, hidden: true, spaces: [1]),                                // ⌘-hidden
    ])
    // ON (default): the snapshot is used as-is, so the hidden app is kept.
    h.eq(DockModel.apps(onCurrentSpace: snap).map(\.name), ["Music", "Notes"],
         "show-hidden on: the ⌘-hidden app stays in the dock")
    // OFF: hidden windows are dropped first, so the hidden app vanishes.
    h.eq(DockModel.apps(onCurrentSpace: snap.droppingHiddenWindows()).map(\.name), ["Notes"],
         "show-hidden off: the ⌘-hidden app is gone, the visible one stays")
}
h.test("dropping hidden windows leaves a snapshot with none unchanged (identity)") {
    let snap = SpaceSnapshot(activeSpaceID: 1, windows: [
        win(10, 100, name: "Notes", bundle: "com.apple.Notes", spaces: [1]),
    ], runningBundleIDs: ["com.apple.Notes"])
    h.eq(snap.droppingHiddenWindows(), snap, "no hidden windows → same snapshot")
}

// MARK: - DisplayPlacement (multi-display: new window lands on the active screen)

// Two side-by-side 1920×1080 displays in the global top-left-origin space:
// `left` is the primary at (0,0); `right` sits to its right at x=1920.
let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
let twoDisplays = [left, right]

print("DisplayPlacement")
h.test("window already on the active display is left alone") {
    let onLeft = CGRect(x: 100, y: 100, width: 800, height: 600)
    h.ok(DisplayPlacement.reposition(window: onLeft, displays: twoDisplays, active: left) == nil,
         "a window on the active display should not move")
}
h.test("window on the other display is translated onto the active one, keeping relative position") {
    // Same relative spot (100,100 from the display's top-left) but on the right screen.
    let onRight = CGRect(x: 1920 + 100, y: 100, width: 800, height: 600)
    let moved = DisplayPlacement.reposition(window: onRight, displays: twoDisplays, active: left)
    h.eq(moved, CGRect(x: 100, y: 100, width: 800, height: 600),
         "should land at the same relative position on the active (left) display")
}
h.test("repositioned window is clamped to stay fully on the active display") {
    // Near the right edge of the right display → naive translate would spill off
    // the left display's right edge; it must be pulled back to fit.
    let nearEdge = CGRect(x: 1920 + 1600, y: 800, width: 800, height: 600)
    let moved = DisplayPlacement.reposition(window: nearEdge, displays: twoDisplays, active: left)
    if let moved {
        h.ok(left.contains(CGRect(origin: moved.origin, size: CGSize(width: 0.1, height: 0.1))),
             "origin must be inside the active display")
        h.ok(moved.maxX <= left.maxX && moved.maxY <= left.maxY,
             "the whole window must fit on the active display")
        h.eq(moved.size, nearEdge.size, "size is preserved")
    } else {
        h.ok(false, "expected the window to be repositioned")
    }
}
h.test("a window larger than the active display pins to its top-left") {
    let huge = CGRect(x: 1920 + 50, y: 50, width: 3000, height: 2000)
    let moved = DisplayPlacement.reposition(window: huge, displays: twoDisplays, active: left)
    h.eq(moved?.origin, CGPoint(x: 0, y: 0), "oversize window pins to the active display's origin")
}
h.test("single display: a window on it never moves") {
    let onLeft = CGRect(x: 200, y: 200, width: 640, height: 480)
    h.ok(DisplayPlacement.reposition(window: onLeft, displays: [left], active: left) == nil)
}

// MARK: - Live provider smoke (skips if CGS is unavailable)

print("Live provider (integration)")
h.test("current Space is readable, or skipped") {
    do {
        let id = try CGSSpaceProvider().currentSpaceID()
        h.ok(id > 0, "expected a real Space id")
    } catch {
        print("      ~ skipped: CGS unavailable (\(error))")
    }
}

h.finish()
