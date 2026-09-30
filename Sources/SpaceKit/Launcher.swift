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
    case cancelled
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
    let launchRoute: ApplicationLaunchRoute

    public init(provider: SpaceProviding,
                config: StrategyConfig, launchRoute: ApplicationLaunchRoute = .commandLine,
                warn: @escaping (String) -> Void) {
        self.provider = provider
        self.config = config
        self.warn = warn
        self.launchRoute = launchRoute
    }

    @discardableResult
    public func launch(target: AppTarget, forceNew: Bool, context: LaunchContext? = nil) throws -> LaunchOutcome {
        let snapshot = try provider.snapshot(of: target)
        // Classify the app's state once, log it (so the chosen branch is traceable
        // in Console.app), then map it to a decision — no booleans re-derived here.
        let context = resolvedContext(context, snapshot: snapshot)
        guard context.isCurrent(snapshot: snapshot, displays: provider.displays()), !NativeInteraction.isActive else {
            return warned(target, "the desktop changed or the mouse button was held down — try again.")
        }
        let state = AppState.classify(target: target, snapshot: snapshot,
                                      currentSpace: context.spaceID, display: context.displayBounds)
        Log.debug("launch \(target.bundleID ?? target.name ?? "?") — state \(state.label) forceNew=\(forceNew)")
        let decision = LaunchEngine.decide(state: state, config: config, target: target, forceNew: forceNew)
        switch decision {
        case .warnUnknown: return warned(target, "window desktop membership is unavailable — left its windows unchanged.")
        case let .focusWindow(windowID, pid):
            return focusWindow(windowID: windowID, pid: pid, target: target, snapshot: snapshot, context: context)
        case .launchApp:
            return openFirstWindow(target, context: context)
        case let .newWindow(kind):
            return newWindow(target, kind: kind, snapshot: snapshot, context: context)
        }
    }

    /// Dock-icon click: bring-to-front, or minimize if already frontmost
    /// (issues 8 & 9), otherwise smart-launch. `preferredDisplay` (the bounds of
    /// the display this dock lives on) makes a new window land on *this* screen on
    /// a multi-display setup — see `placeNewWindowHere`.
    @discardableResult
    public func dockClick(target: AppTarget, forceNew: Bool,
                          preferredDisplay: CGRect? = nil, dockSpace: SpaceID? = nil,
                          context: LaunchContext? = nil) throws -> LaunchOutcome {
        let snapshot = try provider.snapshot(of: target)
        let context = resolvedContext(context, snapshot: snapshot,
                                      preferredDisplay: preferredDisplay, dockSpace: dockSpace)
        guard context.isCurrent(snapshot: snapshot, displays: provider.displays()), !NativeInteraction.isActive else {
            return warned(target, "the desktop changed or the mouse button was held down — try again.")
        }
        let state = AppState.classify(target: target, snapshot: snapshot,
                                      frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                      currentSpace: context.spaceID, display: context.displayBounds)
        let action = LaunchEngine.dockClick(state: state, config: config, target: target, forceNew: forceNew)
        Log.notice("Dock action: app=\(target.bundleID ?? "unknown") state=\(state.label) action=\(action) space=\(context.spaceID) forceNew=\(forceNew)")
        return perform(action, target: target, newWindowSnapshot: snapshot, context: context)
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
                                preferredDisplay: CGRect? = nil, context: LaunchContext? = nil) throws -> LaunchOutcome {
        let snapshot = try provider.snapshot(of: target)
        let context = resolvedContext(context, snapshot: snapshot, preferredDisplay: preferredDisplay)
        guard context.isCurrent(snapshot: snapshot, displays: provider.displays()), !NativeInteraction.isActive else {
            return warned(target, "the desktop changed or the mouse button was held down — try again.")
        }
        guard let window = snapshot.windows(of: target).first(where: { $0.windowID == windowID && $0.pid == pid }),
              window.isVisible(onSpace: context.spaceID, display: context.displayBounds) else {
            return warned(target, "that window is no longer on the requested desktop.")
        }
        let ax = WindowAX.isTrusted ? WindowAX.axWindow(windowID: windowID, pid: pid) : nil
        let mode: AppState.WindowMode
        if window.isMinimized || ax.map(WindowAX.isMinimized) == true { mode = .minimized }
        else if window.isHidden { mode = .hidden }
        else if window.isOnscreen && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && ax.map(WindowAX.isMain) == true { mode = .active }
        else { mode = .inactive }
        let action = LaunchEngine.dockClick(state: .windowHere(windowID: windowID, pid: pid, mode: mode),
                                           config: config, target: target, forceNew: forceNew)
        Log.notice("Dock window action: app=\(target.bundleID ?? "unknown") pid=\(pid) window=\(windowID) mode=\(mode) action=\(action) space=\(context.spaceID)")
        return perform(action, target: target, newWindowSnapshot: snapshot, context: context)
    }

    /// Carries out a `DockClickAction` (shared by `dockClick` and `dockClickWindow`).
    /// `newWindowSnapshot` is an autoclosure so the snapshot is only taken when the
    /// `.newWindow` branch runs.
    private func perform(_ action: DockClickAction, target: AppTarget,
                         newWindowSnapshot: @autoclosure () throws -> SpaceSnapshot,
                         context: LaunchContext) rethrows -> LaunchOutcome {
        switch action {
        case .warnUnknown: return warned(target, "window desktop membership is unavailable — left its windows unchanged.")
        case let .raise(windowID, pid):
            return focusWindow(windowID: windowID, pid: pid, target: target,
                               snapshot: try newWindowSnapshot(), context: context)
        case let .minimize(windowID, pid):
            return minimize(windowID: windowID, pid: pid, context: context) ? .minimized
                : warned(target, "could not minimize that window. Check Accessibility permission.")
        case .launch:
            return openFirstWindow(target, context: context)
        case let .newWindow(kind):
            return newWindow(target, kind: kind, snapshot: try newWindowSnapshot(),
                             context: context)
        }
    }

    /// Close the app's windows that are on the current desktop (issue 1). With
    /// `onDisplay` set (the bounds of the dock's display), it scopes to that
    /// screen's visible desktop instead of the active Space — so "Quit (this
    /// desktop)" on a dock acts on the desktop that dock is showing.
    @discardableResult
    public func closeOnCurrentDesktop(target: AppTarget, onDisplay display: CGRect? = nil,
                                      dockSpace: SpaceID? = nil, context: LaunchContext? = nil) throws -> LaunchOutcome {
        guard WindowAX.isTrusted else {
            return warned(target, "needs Accessibility (granted to the powerspaces app) to close its windows here.")
        }
        let snapshot = try provider.snapshot(of: target)
        let context = resolvedContext(context, snapshot: snapshot, preferredDisplay: display, dockSpace: dockSpace)
        guard context.isCurrent(snapshot: snapshot, displays: provider.displays()), !NativeInteraction.isActive else {
            return warned(target, "the desktop changed or the mouse button was held down — no windows closed.")
        }
        let candidates = snapshot.windows(of: target)
        guard !candidates.contains(where: { $0.isReal && $0.spaceIDs.isEmpty }) else {
            return warned(target, "window desktop membership is unavailable — no windows closed.")
        }
        let here = candidates.filter { $0.canClose(onSpace: context.spaceID, display: context.displayBounds) }
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
    public func closeWindow(windowID: CGWindowID, pid: pid_t, target: AppTarget, context: LaunchContext? = nil) -> LaunchOutcome {
        guard WindowAX.isTrusted else {
            return warned(target, "needs Accessibility (granted to the powerspaces app) to close its windows.")
        }
        if let context {
            guard let snapshot = try? provider.snapshot(of: target), contextIsCurrent(context, snapshot: snapshot), !NativeInteraction.isActive,
                  snapshot.windows(of: target).contains(where: { $0.windowID == windowID && $0.pid == pid && $0.canClose(onSpace: context.spaceID, display: context.displayBounds) }) else {
                return warned(target, "that window is no longer safely identified on the requested desktop.")
            }
        }
        guard let axWindow = WindowAX.axWindow(windowID: windowID, pid: pid),
              WindowAX.close(axWindow) else {
            return warned(target, "couldn't close that window.")
        }
        return .closed(1)
    }

    /// Normal Quit is always polite. A timeout/refusal is not permission to kill.
    @discardableResult
    public func quitApp(target: AppTarget) -> LaunchOutcome {
        let instances = runningInstances(of: target)
        guard !instances.isEmpty else { return .quit(false) }
        Log.notice("Quit requested: app=\(target.bundleID ?? "unknown") reason=explicit-quit pids=\(instances.map(\.processIdentifier))")
        let exited = QuitCoordinator.requestQuit(instances)
        return exited ? .quit(true) : warned(target, "has not finished quitting — save or dismiss its dialogs and try again.")
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

    /// Keep the original guards, but retain the reason instead of merging every
    /// cancellation into a permission-like warning with no diagnostic record.
    public func rejectionReason(for ticket: ActionTicket) -> ActionTicket.Rejection? {
        let started = ProcessInfo.processInfo.systemUptime
        func rejected(_ reason: ActionTicket.Rejection, snapshot: SpaceSnapshot? = nil,
                      displays: [DisplaySpaceInfo] = [], native: String? = nil) -> ActionTicket.Rejection {
            let now = ProcessInfo.processInfo.systemUptime
            let current = displays.first { $0.displayUUID == ticket.context.displayUUID }?.currentSpaceID
            Log.error("Dock action cancelled: reason=\(reason.rawValue) requestedSpace=\(ticket.context.spaceID) display=\(ticket.context.displayUUID?.prefix(8) ?? "unspecified") currentDisplaySpace=\(current.map(String.init) ?? "unavailable") activeSpace=\(snapshot.map { String($0.activeSpaceID) } ?? "unavailable") timeRemaining=\(ticket.deadline - now) validationElapsed=\(now - started) native=\(native ?? "none")")
            return reason
        }
        guard ticket.hasNotExpired(at: started) else { return rejected(.expired) }
        // A ticket only asks whether its desktop is still showing. A window inventory
        // here made every click wait for a full scan before its action took another.
        let displays = provider.displays()
        guard let active = (displays.first(where: \.isActive) ?? displays.first)?.currentSpaceID else {
            return rejected(.snapshotUnavailable)
        }
        let snapshot = SpaceSnapshot(activeSpaceID: active, windows: [])
        let mouseDown = NativeInteraction.isActive
        if let reason = ticket.rejectionReason(snapshot: snapshot, displays: displays,
                                              now: ProcessInfo.processInfo.systemUptime,
                                              nativeInteraction: mouseDown) {
            return rejected(reason, snapshot: snapshot, displays: displays, native: mouseDown ? "left-mouse-down" : nil)
        }
        return nil
    }
    public func contextIsCurrent(_ context: LaunchContext, snapshot: SpaceSnapshot) -> Bool {
        context.isCurrent(snapshot: snapshot, displays: provider.displays())
    }

    func resolvedContext(_ context: LaunchContext?, snapshot: SpaceSnapshot,
                         preferredDisplay: CGRect? = nil, dockSpace: SpaceID? = nil) -> LaunchContext {
        if let context { return context }
        let displays = provider.displays()
        if let bounds = preferredDisplay, let info = displays.first(where: { $0.bounds == bounds }) {
            return LaunchContext(spaceID: dockSpace ?? info.currentSpaceID, spaceUUID: info.currentSpaceUUID,
                                 displayUUID: info.displayUUID, displayBounds: bounds)
        }
        if preferredDisplay == nil, dockSpace == nil, let active = displays.first(where: { $0.isActive }) {
            return LaunchContext(display: active)
        }
        return LaunchContext(spaceID: dockSpace ?? snapshot.activeSpaceID, displayBounds: preferredDisplay)
    }

    func warned(_ target: AppTarget, _ tail: String) -> LaunchOutcome {
        Log.error("App action warning: app=\(target.bundleID ?? "unknown") reason=\(tail)")
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
