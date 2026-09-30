// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Low-level side-effecting primitives the strategies compose: focusing windows
/// (`raise` / `minimize`), launching apps (`openFirstWindow` / `openApp` /
/// `openWithArgs` / `activate`), and the raw process / AppleScript / key-event
/// calls underneath them.
extension Launcher {
    // MARK: - Focus an exact window on the current Space

    /// Recover only an unavailable off-screen entry or a confirmed AX accessory.
    /// A verified per-window target remains exact; an ambiguous inventory is not a
    /// reason to select a different window or another desktop.
    func focusWindow(windowID: CGWindowID, pid: pid_t, target: AppTarget,
                     snapshot: SpaceSnapshot, context: LaunchContext) -> LaunchOutcome {
        let access = WindowAX.requestWindowAccess(windowID: windowID, pid: pid)
        defer { withExtendedLifetime(access) {} }
        var focusID = windowID
        var requiresSingleWindow = false
        if WindowAX.isTrusted,
           let requested = snapshot.windows(of: target).first(where: { $0.windowID == windowID && $0.pid == pid }) {
            let lookup = WindowAX.lookupWindow(windowID: windowID, pid: pid)
            var recover = false
            var accessory = false
            var unavailable = false
            switch lookup {
            case .failure(.missing):
                unavailable = true
                // A newly requested AX tree can take a moment to appear. Retry
                // the exact ID without activating an unidentified window.
                recover = !access.requested && !requested.isOnscreen && !requested.isMinimized && !requested.isHidden
            case .failure(.identity):
                // An unmappable AX entry must not block the independently
                // verified sole-CG-window activation path. It does not justify
                // selecting a different window from the AX inventory.
                unavailable = true
            case let .success(window):
                let role = WindowAX.role(of: window)
                unavailable = WindowFocusPolicy.needsWindowAccess(role: role)
                if !unavailable, role != "AXWindow" {
                    accessory = true
                    recover = true
                }
            default: break // Failed/malformed inventories are not evidence of an accessory.
            }
            // Check uniqueness using current CG facts first. Then verify the
            // sole candidate's ordinary AX kind and honor explicit modal flags.
            let candidates = WindowFocusPolicy.candidates(for: requested, in: snapshot, context: context,
                                                          requestedIsAccessory: accessory)
            var verification = "candidate-count"
            if recover, candidates.count == 1, let candidate = candidates.first {
                switch WindowAX.lookupWindow(windowID: candidate.windowID, pid: candidate.pid) {
                case let .failure(error): verification = error.diagnostic
                case let .success(window):
                    let role = WindowAX.role(of: window), subrole = WindowAX.subrole(of: window)
                    let modal = WindowAX.modalStatus(of: window)
                    let minimized = WindowAX.minimizedStatus(of: window) ?? candidate.isMinimized
                    verification = "kind role=\(role ?? "unknown") subrole=\(subrole ?? "unknown") modal=\(modal.map(String.init) ?? "unknown") minimized=\(minimized)"
                    if WindowFilter.isRestorableWindow(role: role, subrole: subrole, isModal: modal, isMinimized: minimized),
                       let verified = WindowFocusPolicy.recoveryWindow(for: requested, in: snapshot, context: context,
                           verifiedAXIDs: [candidate.windowID], requestedIsAccessory: accessory) {
                        focusID = verified.windowID
                    }
                }
            }
            if unavailable, focusID == windowID,
               !accessory,
               WindowFocusPolicy.canActivateMissingWindow(for: requested, in: snapshot, context: context) {
                // A sole real off-screen window may be absent from AX until its
                // app is activated. An AX readiness request must not disable this
                // safe path: waiting for AX first would prevent that activation.
                // Fresh unfiltered uniqueness/context checks still guard raise.
                requiresSingleWindow = true
                Log.info("Window focus activation fallback: pid=\(pid) window=\(windowID) space=\(context.spaceID)")
            } else if recover, focusID == windowID {
                // Do not blindly activate the process when an unavailable entry
                // cannot be resolved: it could select a window on another Space.
                let here = snapshot.windows.filter { $0.pid == pid && $0.isVisible(onSpace: context.spaceID, display: context.displayBounds) }
                Log.error("Window raise failed: pid=\(pid) window=\(windowID) stage=recovery-unavailable verification=\(verification) eligibleCandidates=\(candidates.count) requestedSpace=\(context.spaceID) onscreenHere=\(here.filter(\.isOnscreen).count) minimizedHere=\(here.filter(\.isMinimized).count) hiddenHere=\(here.filter(\.isHidden).count) trusted=\(WindowAX.isTrusted)")
                return warned(target, raiseFailureMessage())
            }
        }
        switch raise(windowID: focusID, pid: pid, context: context, requiresSingleWindow: requiresSingleWindow,
                     windowAccess: access) {
        case .cancelled: return .cancelled
        case .failed: return warned(target, raiseFailureMessage())
        case .focused: break
        }
        if focusID != windowID {
            Log.info("Window focus recovered: pid=\(pid) requestedWindow=\(windowID) focusedWindow=\(focusID) space=\(context.spaceID)")
        }
        return .focused
    }

    /// Identity-only check: avoid a full AX/window resample on every retry.
    func windowContextIsCurrent(_ context: LaunchContext, windowID: CGWindowID, pid: pid_t) -> Bool {
        windowContextRejection(context, windowID: windowID, pid: pid) == nil
    }

    private func windowContextRejection(_ context: LaunchContext, windowID: CGWindowID, pid: pid_t,
                                        requiresSingleWindow: Bool = false) -> String? {
        let displays = provider.displays()
        let active = displays.first(where: { $0.isActive })?.currentSpaceID ?? 0
        guard context.isCurrent(snapshot: SpaceSnapshot(activeSpaceID: active, windows: []), displays: displays) else {
            let current = displays.first { $0.displayUUID == context.displayUUID }?.currentSpaceID
            return "desktop-context requestedSpace=\(context.spaceID) currentDisplaySpace=\(current.map(String.init) ?? "unavailable") activeSpace=\(active)"
        }
        // optionIncludingWindow is an at/above-or-below modifier, not a supported
        // exact-window query. Include off-screen/minimized windows in this read.
        guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return "window-inventory-unavailable"
        }
        guard let info = windows.first(where: { $0[kCGWindowNumber as String] as? CGWindowID == windowID }) else {
            return "window-missing"
        }
        guard info[kCGWindowOwnerPID as String] as? pid_t == pid else { return "window-owner" }
        if requiresSingleWindow {
            // Recheck the sole-window condition using fresh, unfiltered CG data;
            // a second window may have appeared since the dock snapshot. Unknown
            // membership vetoes activation; known spaceless off-screen helpers do not.
            for other in windows where other[kCGWindowOwnerPID as String] as? pid_t == pid {
                guard let id = other[kCGWindowNumber as String] as? CGWindowID, id != windowID else { continue }
                let rect = (other[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
                guard WindowFilter.isRealWindow(layer: other[kCGWindowLayer as String] as? Int ?? -1,
                    alpha: other[kCGWindowAlpha as String] as? Double ?? 1,
                    width: rect.width, height: rect.height) else { continue }
                let membership = CGSCopySpacesForWindows(CGSMainConnectionID(), kCGSSpaceAll,
                    [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber]
                if membership?.isEmpty != true || other[kCGWindowIsOnscreen as String] as? Bool == true {
                    return "activation-window-ambiguous otherWindow=\(id)"
                }
            }
        }
        let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
        let ids = [NSNumber(value: windowID)] as CFArray
        let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(), kCGSSpaceAll, ids)?.takeRetainedValue() as? [NSNumber]
        if let display = context.displayBounds {
            guard bounds.width > 0, bounds.height > 0,
                  display.contains(CGPoint(x: bounds.midX, y: bounds.midY)) else { return "window-display" }
        }
        if let spaces, !spaces.isEmpty {
            return spaces.contains { $0.uint64Value == context.spaceID } ? nil
                : "window-space requestedSpace=\(context.spaceID) windowSpaces=\(spaces.map(\.uint64Value))"
        }
        // Secondary displays can lack Space membership during transitions. Only
        // current visible geometry is sufficient then; never guess for an
        // off-screen/minimized/hidden window or follow it onto another desktop.
        return context.displayBounds != nil && info[kCGWindowIsOnscreen as String] as? Bool == true ? nil : "window-membership-unavailable"
    }

    /// Bring an exact window forward. `activateApp` (default true) also makes the
    /// owning process frontmost. Pass `false` to raise the window *without* process
    /// activation: a freshly-spawned *second* instance of a single-window Electron app
    /// (Claude) treats being activated as "I'm a duplicate", hands off to the primary
    /// instance and closes its own window ~8 s later (the "opens briefly then closes"
    /// bug). For that one path we raise the window via Accessibility but never call
    /// `activate()`; the window is already on the current Space, so it's still visible.
    @discardableResult
    func raise(windowID: CGWindowID, pid: pid_t, activateApp: Bool = true, context: LaunchContext? = nil,
               requiresSingleWindow: Bool = false, windowAccess: WindowFocusPolicy.AccessibilityRequest? = nil) -> WindowFocusPolicy.Outcome {
        guard WindowAX.isTrusted else {
            Log.error("Window raise failed: pid=\(pid) window=\(windowID) stage=permission trusted=false")
            return .failed
        }
        let access = windowAccess ?? WindowAX.requestWindowAccess(windowID: windowID, pid: pid)
        defer { withExtendedLifetime(access) {} }
        let started = ProcessInfo.processInfo.systemUptime
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
        var attempts = 0
        var failure = "unknown"
        var lastAX = "not-attempted"
        var restoreError: AXError?
        var activation: Bool?
        var frontmostError: AXError?
        var reopenRequested = false
        var observedFocus = "not-observed"
        var cancelled = false
        func canAct() -> Bool {
            if NativeInteraction.isActive {
                failure = "native-interaction native=left-mouse-down"
                cancelled = true
                return false
            }
            if let context, let rejection = windowContextRejection(context, windowID: windowID, pid: pid,
                                                                   requiresSingleWindow: requiresSingleWindow) {
                failure = rejection
                cancelled = true
                return false
            }
            return true
        }
        // Pull the window out of the Dock and bring it forward. `unminimize` first
        // because kAXRaiseAction does nothing to a minimized window.
        func tryRaise() -> WindowFocusPolicy.RaiseAttempt {
            attempts += 1
            restoreError = nil
            guard canAct() else { return .unavailable }
            let axWindow: AXUIElement
            switch WindowAX.lookupWindow(windowID: windowID, pid: pid) {
            case let .success(window): axWindow = window
            case let .failure(error):
                lastAX = error.diagnostic; failure = lastAX; return .unavailable
            }
            guard let role = WindowAX.role(of: axWindow), role == kAXWindowRole as String else {
                failure = "window-kind"
                lastAX = failure
                return .unavailable
            }
            guard canAct() else { return .unavailable }
            restoreError = AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            guard canAct() else { return .unavailable }
            let error = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            failure = "raise axError=\(error.rawValue)"
            lastAX = failure
            return error == .success ? .raised : .ready
        }
        func confirmFocus() -> Bool {
            guard !cancelled, canAct(),
                  let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
            else { return false }
            let front = windows.first(where: { info in
                let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
                if let display = context?.displayBounds,
                   !display.contains(CGPoint(x: bounds.midX, y: bounds.midY)) { return false }
                return WindowFilter.isRealWindow(layer: info[kCGWindowLayer as String] as? Int ?? -1,
                    alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                    width: bounds.width, height: bounds.height)
            })
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let frontID = front?[kCGWindowNumber as String] as? CGWindowID
            let frontOwner = front?[kCGWindowOwnerPID as String] as? pid_t
            let onscreen = windows.contains { $0[kCGWindowNumber as String] as? CGWindowID == windowID }
            observedFocus = "frontApp=\(frontPID ?? 0) frontWindow=\(frontID ?? 0) frontOwner=\(frontOwner ?? 0) targetOnscreen=\(onscreen)"
            guard canAct(),
                  WindowFocusPolicy.isConfirmedFocused(windowID: windowID, pid: pid,
                      frontmostPID: frontPID, frontmostWindowID: frontID, frontmostWindowPID: frontOwner)
            else { return false }
            // Confirm the exact window on the requested display for both
            // successful and unsupported AX raises; activation is asynchronous.
            Log.notice("Window focus confirmed: app=\(bundleID) pid=\(pid) window=\(windowID) space=\(context?.spaceID ?? 0) raiseStage=\(failure) frontmostAX=\(frontmostError.map { String($0.rawValue) } ?? "unused") reopened=\(reopenRequested) attempts=\(attempts)")
            return true
        }
        let raised = WindowFocusPolicy.performFocus(timeout: access.retryDuration,
            allowUnidentifiedActivation: requiresSingleWindow, requireConfirmation: activateApp,
            canAct: canAct, attempt: tryRaise,
            activate: {
                guard activateApp, canAct() else { return }
                guard let app = NSRunningApplication(processIdentifier: pid) else { return }
                let result = activateOwner(app, canAct: canAct)
                activation = result.accepted
                frontmostError = result.axError
            }, recover: {
                guard activateApp, let context, canAct() else { return }
                reopenRequested = reopenSoleWindow(windowID: windowID, pid: pid, context: context)
            }, confirm: confirmFocus)
        if raised != .focused {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let details = "app=\(bundleID) pid=\(pid) window=\(windowID) stage=\(failure) lastAX=\(lastAX) restoreError=\(restoreError.map { String($0.rawValue) } ?? "unavailable") activateApp=\(activateApp) activated=\(activation.map(String.init) ?? "unavailable") frontmostAX=\(frontmostError.map { String($0.rawValue) } ?? "unused") reopened=\(reopenRequested) \(observedFocus) attempts=\(attempts) elapsed=\(elapsed) trusted=\(WindowAX.isTrusted)"
            if raised == .cancelled { Log.info("Window focus cancelled: \(details)") }
            else { Log.error("Window raise failed: \(details)") }
        }
        return raised
    }

    /// Ask the existing app to restore its sole local window, like opening its
    /// Dock icon. Unlike activate(), reopening lets the app restore a window it
    /// omits from AXWindows. No new-instance flag or app-specific scripting.
    private func reopenSoleWindow(windowID: CGWindowID, pid: pid_t, context: LaunchContext) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              let bundleID = app.bundleIdentifier, let url = app.bundleURL,
              WindowFocusPolicy.canReopenApp(pid: pid, runningPIDs:
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)),
              !NativeInteraction.isActive,
              windowContextRejection(context, windowID: windowID, pid: pid, requiresSingleWindow: true) == nil
        else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        Log.info("Window reopen requested: app=\(bundleID) pid=\(pid) window=\(windowID) space=\(context.spaceID)")
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { opened, error in
            // LaunchServices completion is not proof that the window is frontmost.
            // The existing focus loop independently checks the exact ID and Space.
            Log.info("Window reopen completed: app=\(bundleID) requestedPID=\(pid) actualPID=\(opened?.processIdentifier ?? 0) error=\((error as NSError?)?.code ?? 0)")
        }
        return true
    }

    /// Only a failed trust check justifies sending the user to permission settings.
    func raiseFailureMessage() -> String {
        WindowAX.isTrusted
            ? "could not bring that window forward. Accessibility is enabled; try clicking the window again."
            : "needs Accessibility access. Enable Powerspaces in System Settings → Privacy & Security → Accessibility."
    }

    func minimize(windowID: CGWindowID, pid: pid_t, context: LaunchContext? = nil) -> Bool {
        guard WindowAX.isTrusted, !NativeInteraction.isActive,
              context.map({ windowContextIsCurrent($0, windowID: windowID, pid: pid) }) != false,
              let axWindow = WindowAX.axWindow(windowID: windowID, pid: pid),
              !NativeInteraction.isActive,
              context.map({ windowContextIsCurrent($0, windowID: windowID, pid: pid) }) != false else { return false }
        return WindowAX.minimize(axWindow)
    }

    // MARK: - Open / new-window helpers

    /// Open/reopen normally before waiting for a window. Some apps create their
    /// first window only when activated; waiting in the background prevents that
    /// interaction. This path never starts a second instance or quits an app.
    func openFirstWindow(_ target: AppTarget, context: LaunchContext) -> LaunchOutcome {
        guard !NativeInteraction.isActive else {
            return warned(target, "the mouse button was held down — launch cancelled. Try again.")
        }
        guard let before = try? provider.snapshot(of: target),
              context.isCurrent(snapshot: before, displays: provider.displays()) else {
            return warned(target, "desktop context changed — launch cancelled.")
        }
        guard before.realWindows(of: target).isEmpty else {
            return warned(target, "its windows changed before opening — try clicking it again.")
        }
        let opened = target.bundleID == "com.apple.finder" ? openNewFinderWindow()
            : openApp(target, newInstance: false, background: false, context: context)
        guard opened else { return warned(target, "could not be launched.") }
        // No real windows existed: a reused formerly spaceless CG identity is
        // also a valid first window, not just a newly allocated window ID.
        if !placeNewWindowHere(target, existing: [], context: context, focus: true) {
            // The app was opened. A first window that outlasts the wait is slow,
            // not missing, and some apps open none: that is no reason to warn.
            Log.notice("First window not confirmed in time: app=\(target.bundleID ?? "unknown") space=\(context.spaceID)")
        }
        return .launched
    }

    @discardableResult
    func openApp(_ target: AppTarget, newInstance: Bool, background: Bool = false, args: [String] = [], context: LaunchContext) -> Bool {
        guard let url = AppResolver.appURL(for: target) else { return false }
        if launchRoute == .workspace {
            return WorkspaceAppOpener.open(url, arguments: args, newInstance: newInstance,
                                           background: background, context: context)
        }
        return runProcess(URL(fileURLWithPath: "/usr/bin/open"),
                          Self.openArguments(appURL: url, newInstance: newInstance, background: background, args: args))
    }

    /// -n ensures Launch Services delivers --args on a new launch. Single-profile
    /// browsers may hand off internally; compatibility must be checked per app.
    public static func openArguments(appURL: URL, newInstance: Bool, background: Bool, args: [String]) -> [String] {
        var command = ["-a", appURL.path]
        if newInstance { command.insert("-n", at: 0) }
        if background { command.insert("-g", at: 0) }
        if !args.isEmpty { command += ["--args"] + args }
        return command
    }

    @discardableResult
    func openWithArgs(_ target: AppTarget, args: [String], context: LaunchContext) -> Bool {
        openApp(target, newInstance: true, background: true, args: args, context: context)
    }

    /// A nonactivating dock cannot yield cooperative activation from the active
    /// app. AXRaise alone reorders windows inside an inactive app. Use the public
    /// application-level Accessibility attribute to activate its validated owner;
    /// keep ordinary activation for unsupported AX implementations. Callers must
    /// still confirm focus and (for exact window actions) revalidate the desktop.
    private func activateOwner(_ app: NSRunningApplication, canAct: () -> Bool = { true })
        -> (accepted: Bool, axError: AXError?) {
        guard !app.isTerminated, canAct() else { return (false, nil) }
        app.unhide()
        guard canAct() else { return (false, nil) }
        let error = WindowAX.isTrusted
            ? AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                kAXFrontmostAttribute as CFString, kCFBooleanTrue) : nil
        if error == .success { return (true, error) }
        return (canAct() && app.activate(), error)
    }

    @discardableResult
    func activate(_ target: AppTarget) -> Bool {
        guard let bundleID = target.bundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        return activateOwner(app, canAct: { !NativeInteraction.isActive }).accepted
    }

    @discardableResult
    func runProcess(_ executable: URL, _ arguments: [String]) -> Bool {
        let result = ProcessRunner.run(executable, arguments: arguments)
        if result == .exited(0) { return true }
        warn("\(executable.lastPathComponent) failed or timed out; the requested operation was not confirmed.")
        return false
    }

    /// Supervise a short-lived AppleScript helper so an unresponsive Apple-event
    /// target cannot occupy the launcher queue indefinitely. Stderr goes to a
    /// temporary file (not an undrained pipe); only a bounded prefix is logged.
    @discardableResult
    func runAppleScript(_ source: String) -> Bool {
        let errors = FileManager.default.temporaryDirectory.appendingPathComponent("powerspaces-script-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: errors.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: errors) else { return false }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: errors) }
        let result = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", source],
                                       standardError: handle)
        if result == .exited(0) { return true }
        let reader = try? FileHandle(forReadingFrom: errors)
        let detail = (try? reader?.read(upToCount: 2048)).flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        try? reader?.close()
        Log.error("AppleScript failed or timed out (\(result)): \(detail)")
        return false
    }

    func postCmdN(to target: AppTarget, context: LaunchContext) -> Bool {
        guard WindowAX.isTrusted, !NativeInteraction.isActive,
              let bundleID = target.bundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              activateOwner(app, canAct: { !NativeInteraction.isActive }).accepted else { return false }
        let ready = pollUntil(timeout: 0.5, interval: 20_000) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        }
        guard ready, !app.isTerminated, !NativeInteraction.isActive,
              let snapshot = try? provider.snapshot(of: target), contextIsCurrent(context, snapshot: snapshot),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x2D, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x2D, keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(app.processIdentifier); up.postToPid(app.processIdentifier)
        return true
    }
}
