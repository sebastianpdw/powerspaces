// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// What actually happened when a launch was carried out.
public enum LaunchOutcome: Sendable {
    case focused
    case minimized
    case launched
    case newWindow(StrategyKind)
    case reopenedOnCurrentSpace
    case closed(Int)
    case quit(Bool)
    case warned(String)
}

/// Executes a launch decision. The side-effecting layer (NSWorkspace / `open` /
/// AppleScript / CGEvent / Accessibility), driven by the unit-tested
/// `LaunchEngine.decide`. Accessibility-dependent actions degrade to a warning
/// when the process isn't trusted, so nothing fails silently.
///
/// One type, split across files by concern (internal extensions sharing
/// `provider`/`config`/`warn`):
/// - `Launcher.swift` — entry points + lifecycle (launch / dock-click / close / quit).
/// - `Launcher+NewWindow.swift` — per-strategy new-window dispatch + multi-display placement.
/// - `Launcher+Primitives.swift` — process & Accessibility primitives (open, activate, raise…).
/// - `Launcher+Finder.swift` — Finder's first-click new-window quirks.
public struct Launcher {
    let provider: SpaceProviding
    let config: StrategyConfig
    let warn: (String) -> Void

    public init(provider: SpaceProviding,
                config: StrategyConfig,
                warn: @escaping (String) -> Void) {
        self.provider = provider
        self.config = config
        self.warn = warn
    }

    @discardableResult
    public func launch(target: AppTarget, forceNew: Bool) throws -> LaunchOutcome {
        let snapshot = try provider.snapshot()
        // Classify the app's state once, log it (so the chosen branch is traceable
        // in Console.app), then map it to a decision — no booleans re-derived here.
        let state = AppState.classify(target: target, snapshot: snapshot)
        Log.debug("launch \(target.bundleID ?? target.name ?? "?") — state \(state.label) forceNew=\(forceNew)")
        let decision = LaunchEngine.decide(state: state, config: config, target: target, forceNew: forceNew)
        switch decision {
        case let .focusWindow(windowID, pid):
            raise(windowID: windowID, pid: pid)
            return .focused
        case .launchApp:
            return coldLaunch(target)
        case let .newWindow(kind):
            return newWindow(target, kind: kind, snapshot: snapshot)
        }
    }

    /// Dock-icon click: bring-to-front, or minimize if already frontmost
    /// (issues 8 & 9), otherwise smart-launch. `preferredDisplay` (the bounds of
    /// the display this dock lives on) makes a new window land on *this* screen on
    /// a multi-display setup — see `placeNewWindowHere`.
    @discardableResult
    public func dockClick(target: AppTarget, forceNew: Bool,
                          preferredDisplay: CGRect? = nil, dockSpace: SpaceID? = nil) throws -> LaunchOutcome {
        let snapshot = try provider.snapshot()
        // Classify once with the live frontmost app folded in, so the logged state
        // carries the window mode (active / inactive / minimized / hidden) the
        // toggle turns on. `frontmostPID` is reused below instead of read twice.
        // `dockSpace` (the clicked dock's display's visible desktop) is what counts as
        // "here" — so clicking a second screen's dock judges the app against that
        // screen's desktop, not the menu bar's (otherwise it minimized instead of
        // opening a window there).
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let state = AppState.classify(target: target, snapshot: snapshot, frontmostPID: frontmostPID,
                                      currentSpace: dockSpace)
        Log.debug("dock-click \(target.bundleID ?? target.name ?? "?") — state \(state.label) forceNew=\(forceNew)")
        let decision = LaunchEngine.decide(state: state, config: config, target: target, forceNew: forceNew)
        let isFrontmost: Bool = {
            guard case let .focusWindow(_, pid) = decision else { return false }
            return frontmostPID == pid
        }()
        // A minimized window must always restore on click, never re-minimize.
        // Read the live AX state for the targeted window (apps like Finder stay
        // frontmost while their last window is minimized, so isFrontmost alone
        // can't tell us). Needs Accessibility; falls back to false otherwise.
        let isMinimized: Bool = {
            guard case let .focusWindow(windowID, pid) = decision,
                  WindowAX.isTrusted,
                  let axWindow = WindowAX.axWindow(windowID: windowID, pid: pid) else { return false }
            return WindowAX.isMinimized(axWindow)
        }()
        let action = LaunchEngine.dockClick(decision: decision, isFrontmost: isFrontmost, isMinimized: isMinimized)
        return perform(action, target: target, newWindowSnapshot: snapshot, preferredDisplay: preferredDisplay)
    }

    /// Dock-icon click on *one specific window* — the "Windows" feature shows an
    /// icon per open window, so the click must act on exactly that window instead
    /// of letting the engine pick the app's first one. Toggle is per window:
    /// minimized → restore; visible & this app's frontmost window → minimize;
    /// visible but behind → raise it to the front. `forceNew` (shift/option) still
    /// makes a brand-new window, same as a normal click.
    @discardableResult
    public func dockClickWindow(windowID: CGWindowID, pid: pid_t,
                                target: AppTarget, forceNew: Bool,
                                preferredDisplay: CGRect? = nil) throws -> LaunchOutcome {
        if forceNew {
            let snapshot = try provider.snapshot()
            return newWindow(target, kind: config.strategy(for: target.bundleID),
                             snapshot: snapshot, preferredDisplay: preferredDisplay)
        }
        // Read this window's live AX state once (needs Accessibility; without it
        // both default false, so the click just raises/activates).
        let axWindow = WindowAX.isTrusted ? WindowAX.axWindow(windowID: windowID, pid: pid) : nil
        let isMinimized = axWindow.map(WindowAX.isMinimized) ?? false
        let appIsFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        // Treat as "frontmost" for the toggle only when this is the focused app's
        // main window — so clicking a behind window's icon raises it rather than
        // minimizing the app's front window.
        let isFront = appIsFront && (axWindow.map(WindowAX.isMain) ?? false)
        let decision = LaunchDecision.focusWindow(windowID: windowID, pid: pid)
        let action = LaunchEngine.dockClick(decision: decision, isFrontmost: isFront, isMinimized: isMinimized)
        // The new-window snapshot is only fetched if that branch is actually taken
        // (autoclosure), so the common raise/minimize toggle stays a single AX read.
        return try perform(action, target: target, newWindowSnapshot: try provider.snapshot(),
                           preferredDisplay: preferredDisplay)
    }

    /// Carries out a `DockClickAction` (shared by `dockClick` and `dockClickWindow`).
    /// `newWindowSnapshot` is an autoclosure so the snapshot is only taken when the
    /// `.newWindow` branch runs.
    private func perform(_ action: DockClickAction, target: AppTarget,
                         newWindowSnapshot: @autoclosure () throws -> SpaceSnapshot,
                         preferredDisplay: CGRect? = nil) rethrows -> LaunchOutcome {
        switch action {
        case let .raise(windowID, pid):
            raise(windowID: windowID, pid: pid)
            return .focused
        case let .minimize(windowID, pid):
            minimize(windowID: windowID, pid: pid)
            return .minimized
        case .launch:
            return coldLaunch(target, preferredDisplay: preferredDisplay)
        case let .newWindow(kind):
            return newWindow(target, kind: kind, snapshot: try newWindowSnapshot(),
                             preferredDisplay: preferredDisplay)
        }
    }

    /// Close the app's windows that are on the current desktop (issue 1). With
    /// `onDisplay` set (the bounds of the dock's display), it scopes to that
    /// screen's visible desktop instead of the active Space — so "Quit (this
    /// desktop)" on a dock acts on the desktop that dock is showing.
    @discardableResult
    public func closeOnCurrentDesktop(target: AppTarget, onDisplay display: CGRect? = nil) throws -> LaunchOutcome {
        guard WindowAX.isTrusted else {
            return warned(target, "needs Accessibility (granted to the powerspaces app) to close its windows here.")
        }
        let snapshot = try provider.snapshot()
        let here = snapshot.windows(of: target).filter { window in
            if let display { return window.isOnVisibleSpace && window.isOnDisplay(display) }
            return window.isOn(snapshot.activeSpaceID)
        }
        var closed = 0
        for window in here {
            if let axWindow = WindowAX.axWindow(windowID: window.windowID, pid: window.pid),
               WindowAX.close(axWindow) { closed += 1 }
        }
        return .closed(closed)
    }

    /// Close one specific window — the window a per-window dock icon stands for.
    /// Needs Accessibility; warns when it isn't granted or the window has no
    /// close button (so nothing fails silently).
    @discardableResult
    public func closeWindow(windowID: CGWindowID, pid: pid_t, target: AppTarget) -> LaunchOutcome {
        guard WindowAX.isTrusted else {
            return warned(target, "needs Accessibility (granted to the powerspaces app) to close its windows.")
        }
        guard let axWindow = WindowAX.axWindow(windowID: windowID, pid: pid),
              WindowAX.close(axWindow) else {
            return warned(target, "couldn't close that window.")
        }
        return .closed(1)
    }

    /// Quit the app entirely — every instance on every desktop (issue 2). Sends each
    /// instance the polite `terminate()` first, then, after a short grace period,
    /// force-quits any survivor that *isn't* asking the user about unsaved work.
    ///
    /// The polite pass alone isn't enough: a backgrounded app can sit on the quit for
    /// ~10 s before honoring it (WhatsApp, App-Nap-throttled, keeps its windows up the
    /// whole time — measured), and lock-less Electron apps (Claude) leave idle
    /// window-less background copies that ignore a polite quit outright. So after the
    /// grace we force the stragglers, which is what makes "Quit (all desktops)" feel
    /// immediate.
    ///
    /// The one thing we never force-kill is an app showing a **blocking dialog** — the
    /// "Save changes before quitting?" sheet/alert it raises in response to the quit.
    /// We leave it open and warn the user (so unsaved work is theirs to resolve, not
    /// silently lost). Without Accessibility we can't read dialogs, so we fall back to
    /// the safe subset: force only window-less survivors, never a windowed app.
    ///
    /// Runs off the main thread (the launcher queue), so the brief wait can't freeze
    /// the UI.
    @discardableResult
    public func quitApp(target: AppTarget) -> LaunchOutcome {
        let instances = runningInstances(of: target)
        guard !instances.isEmpty else { return .quit(false) }
        for app in instances { app.terminate() }
        // terminate() is async and a background instance can ignore it; give them a
        // moment to exit (≈1.5 s) before forcing the stragglers.
        pollUntil(timeout: 1.5, interval: 50_000) {
            runningInstances(of: target).allSatisfy { $0.isTerminated }
        }
        let survivors = runningInstances(of: target).filter { !$0.isTerminated }
        guard !survivors.isEmpty else { return .quit(true) }

        // No Accessibility → can't tell a save prompt from a normal window, so don't
        // risk an app's unsaved work: force only the window-less ghosts, as before.
        guard WindowAX.isTrusted else {
            let windowlessPids = windowlessInstancePids(of: target, among: survivors)
            for app in survivors where windowlessPids.contains(app.processIdentifier) { app.forceTerminate() }
            return .quit(true)
        }

        var sparedForUnsavedWork = false
        for app in survivors {
            if WindowAX.isShowingBlockingDialog(pid: app.processIdentifier) {
                sparedForUnsavedWork = true
                continue
            }
            app.forceTerminate()
        }
        if sparedForUnsavedWork {
            return warned(target, "has unsaved changes — left it open so you can save first.")
        }
        return .quit(true)
    }

    /// Every running instance of the target — all processes sharing its bundle id (so
    /// multi-instance apps are covered in full), falling back to a name match when the
    /// target carries no bundle id.
    private func runningInstances(of target: AppTarget) -> [NSRunningApplication] {
        if let bundleID = target.bundleID {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        }
        guard let name = target.name else { return [] }
        return NSWorkspace.shared.runningApplications.filter { $0.localizedName == name }
    }

    /// The pids of `instances` that currently have no real window anywhere — the idle
    /// duplicates safe to force-quit. Reads one live snapshot; on failure returns an
    /// empty set, so nothing is force-quit and only the polite terminate applies.
    private func windowlessInstancePids(of target: AppTarget,
                                        among instances: [NSRunningApplication]) -> Set<pid_t> {
        guard let snapshot = try? provider.snapshot() else { return [] }
        let pidsWithWindows = Set(snapshot.windows(of: target).map(\.pid))
        return Set(instances.map(\.processIdentifier)).subtracting(pidsWithWindows)
    }

    func warned(_ target: AppTarget, _ tail: String) -> LaunchOutcome {
        let message = "\(displayName(for: target)) \(tail)"
        warn(message)
        return .warned(message)
    }

    func displayName(for target: AppTarget) -> String {
        if let name = target.name { return name }
        if let bundleID = target.bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName {
            return name
        }
        return target.bundleID ?? "The app"
    }
}
