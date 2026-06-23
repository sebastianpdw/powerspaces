// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import SpaceKit

// powerspaces — CLI front end for the smart-launch engine and space reads.
// Call `powerspaces open <app>` from Raycast/Spotlight/the dock to get
// "focus-if-here-else-new-window-on-current-space" behavior (issues 1 & 2).

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"
let rest = Array(args.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func loadConfig() -> StrategyConfig {
    if let path = ProcessInfo.processInfo.environment["POWERSPACES_CONFIG"] {
        return StrategyConfig.load(from: URL(fileURLWithPath: path))
    }
    return StrategyConfig.load(from: StrategyConfig.defaultConfigURL)
}

func loadPinStore() -> PinStore {
    if let path = ProcessInfo.processInfo.environment["POWERSPACES_PINS"] {
        return PinStore(url: URL(fileURLWithPath: path))
    }
    return PinStore(url: PinStore.defaultURL)
}

func flag(_ name: String, in args: [String]) -> Bool { args.contains(name) }

func positional(_ args: [String]) -> [String] { args.filter { !$0.hasPrefix("-") } }

// Same guard as the app: cap AX calls so a command that touches another app's windows
// (open/close) can't hang on a target whose own main thread is wedged.
capAccessibilityMessagingTimeout()

switch command {
case "current-space":
    do {
        let id = try CGSSpaceProvider().currentSpaceID()
        print("current space: \(id)")
    } catch { fail("\(error)") }

case "list-windows":
    do {
        let provider = CGSSpaceProvider()
        let snapshot = try provider.snapshot()
        let scope = positional(rest).first ?? (flag("--all", in: rest) ? "all" : "current")
        let windows = scope == "all"
            ? snapshot.windows
            : snapshot.windows(onSpace: snapshot.activeSpaceID)
        print("active space: \(snapshot.activeSpaceID)  (\(windows.count) windows, scope=\(scope))")
        for w in windows {
            let spaces = w.spaceIDs.map(String.init).joined(separator: ",")
            let here = w.isOn(snapshot.activeSpaceID) ? "*" : " "
            let bundle = w.bundleID ?? "?"
            print("  \(here) win \(w.windowID)  space[\(spaces)]  \(w.ownerName)  (\(bundle))")
        }
    } catch { fail("\(error)") }

case "decide", "open":
    let positionals = positional(rest)
    guard let appArg = positionals.first else { fail("usage: powerspaces \(command) <app> [--new]") }
    let forceNew = flag("--new", in: rest)
    let target = AppResolver.target(from: appArg)
    do {
        let provider = CGSSpaceProvider()
        let config = loadConfig()
        if command == "decide" {
            let snapshot = try provider.snapshot()
            let decision = LaunchEngine.decide(
                target: target, snapshot: snapshot, config: config, forceNew: forceNew
            )
            print("target: \(target.bundleID ?? target.name ?? appArg)")
            print("decision: \(decision)")
        } else {
            let launcher = Launcher(provider: provider, config: config,
                                    warn: { message in print("⚠️  \(message)") })
            let outcome = try launcher.launch(target: target, forceNew: forceNew)
            print("did: \(outcome)")
        }
    } catch { fail("\(error)") }

case "pin", "unpin":
    guard let appArg = positional(rest).first else { fail("usage: powerspaces \(command) <app> [--all]") }
    let target = AppResolver.target(from: appArg)
    guard let bundleID = target.bundleID else {
        fail("could not resolve a bundle id for \(appArg) — pin by bundle id, or launch the app first")
    }
    let all = flag("--all", in: rest)
    do {
        let uuid = try CGSSpaceProvider().currentSpaceUUID()
        let store = loadPinStore()
        switch (command, all) {
        case ("pin", true): store.pinEverywhere(bundleID)
        case ("pin", false): store.pin(bundleID, onSpace: uuid)
        case ("unpin", true): store.unpinEverywhere(bundleID)
        default: store.unpin(bundleID, onSpace: uuid)
        }
        let scope = all ? "all desktops" : "this desktop (\(uuid))"
        print("\(command)ned \(bundleID) on \(scope) — pinned here now: \(store.isPinned(bundleID, onSpace: uuid))")
    } catch { fail("\(error)") }

case "pins":
    do {
        let uuid = try CGSSpaceProvider().currentSpaceUUID()
        let store = loadPinStore()
        print("current desktop: \(uuid)")
        let everywhere = store.everywherePins()
        let here = store.spacePins(onSpace: uuid)
        if everywhere.isEmpty && here.isEmpty { print("  (no pins)") }
        for bundleID in everywhere { print("  • \(bundleID)  [all desktops]") }
        for bundleID in here { print("  • \(bundleID)  [this desktop]") }
    } catch { fail("\(error)") }

case "close":
    guard let appArg = positional(rest).first else { fail("usage: powerspaces close <app> [--all]") }
    let target = AppResolver.target(from: appArg)
    let all = flag("--all", in: rest)
    do {
        let launcher = Launcher(provider: CGSSpaceProvider(), config: loadConfig(),
                                warn: { message in print("⚠️  \(message)") })
        let outcome = all ? launcher.quitApp(target: target)
                          : try launcher.closeOnCurrentDesktop(target: target)
        print("did: \(outcome)")
    } catch { fail("\(error)") }

case "dump-spaces":
    // Debug-only: gated behind POWERSPACES_DEBUG so the diagnostic dump isn't part
    // of the normal shipping surface (it stays usable for development).
    guard ProcessInfo.processInfo.environment["POWERSPACES_DEBUG"] != nil else {
        fail("dump-spaces is a debug command — set POWERSPACES_DEBUG=1 to use it")
    }
    if let raw = CGSSpaceProvider().rawManagedDisplaySpaces() {
        for (i, display) in raw.enumerated() {
            print("display \(i): identifier=\(display["Display Identifier"] ?? "?")")
            print("  current space keys: \((display["Current Space"] as? [String: Any])?.keys.sorted() ?? [])")
            print("  current space: \(display["Current Space"] ?? "?")")
        }
    } else {
        fail("CGSCopyManagedDisplaySpaces returned nil")
    }

default:
    print("""
    powerspaces — make macOS Spaces behave like Windows virtual desktops

    usage:
      powerspaces current-space            print the active Space id
      powerspaces list-windows [--all]     list windows on the current Space (or all)
      powerspaces decide <app> [--new]     show the smart-launch decision (no action)
      powerspaces open   <app> [--new]     focus-if-here-else-new-window-on-current-space
      powerspaces pin    <app> [--all]     pin an app to this desktop (or all desktops)
      powerspaces unpin  <app> [--all]     unpin from this desktop (or all desktops)
      powerspaces pins                     list this desktop's pinned apps
      powerspaces close  <app> [--all]     close on this desktop (or quit everywhere)

    <app> may be a name ("Firefox") or a bundle id ("org.mozilla.firefox").
    --new forces a brand-new window even if one already exists here.
    """)
}
