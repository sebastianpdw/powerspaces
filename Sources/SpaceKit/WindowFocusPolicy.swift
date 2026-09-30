// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation

/// Recover an off-screen CG candidate that AX cannot identify without choosing
/// arbitrarily between windows or activating an app's window on another desktop.
public enum WindowFocusPolicy {
    /// Some apps expose their focused/main window before including it in AXWindows.
    /// Every route must identify the exact requested CG window; never substitute
    /// the app's main window just because it is available.
    public static func exactWindow<Element>(id: CGWindowID, windows: [Element],
                                            focused: () -> Element?, main: () -> Element?,
                                            identify: (Element) -> CGWindowID?) -> Element? {
        guard id != 0 else { return nil }
        if let window = windows.first(where: { identify($0) == id }) { return window }
        if let window = focused(), identify(window) == id { return window }
        if let window = main(), identify(window) == id { return window }
        return nil
    }

    public static func needsWindowAccess(role: String?) -> Bool {
        role == nil || role == "" || role == "AXUnknown"
    }

    /// A user-initiated request, scoped to one focus operation. Unsupported or
    /// already-enabled apps are untouched; only our own change is restored.
    public final class AccessibilityRequest {
        public let requested: Bool
        private let restore: (() -> Void)?
        public var retryDuration: TimeInterval { requested ? 2.5 : 1.5 }

        public init(currentValue: Bool?, setEnabled: @escaping (Bool) -> Bool) {
            requested = currentValue == false && setEnabled(true)
            restore = requested ? { _ = setEnabled(false) } : nil
        }
        deinit { restore?() }
    }

    public enum RaiseAttempt { case unavailable, ready, raised }
    public enum Outcome: Equatable { case focused, cancelled, failed }

    /// Reopening uses the bundle URL, so it cannot choose between multiple
    /// instances. The caller also rechecks the sole-window and desktop guards.
    public static func canReopenApp(pid: pid_t, runningPIDs: [pid_t]) -> Bool {
        pid > 0 && runningPIDs == [pid]
    }

    /// One bounded retry loop for every app. Activation requires an identified
    /// window, except the separately validated sole-local-window fallback. If
    /// activation leaves that window inaccessible, request one Dock-style reopen;
    /// activation alone does not restore an app's minimized window.
    public static func performFocus(timeout: TimeInterval, allowUnidentifiedActivation: Bool = false,
                                    requireConfirmation: Bool = true,
                                    canAct: () -> Bool, attempt: () -> RaiseAttempt,
                                    activate: () -> Void, recover: () -> Void = {}, confirm: () -> Bool,
                                    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                                    wait: () -> Void = { usleep(80_000) }) -> Outcome {
        let deadline = now() + timeout
        var activatedAt: TimeInterval?
        var recovered = false
        repeat {
            guard canAct() else { return .cancelled }
            let result = attempt()
            guard canAct() else { return .cancelled }
            if activatedAt == nil, result != .unavailable || allowUnidentifiedActivation {
                activate()
                activatedAt = now()
            }
            guard canAct() else { return .cancelled }
            if (!requireConfirmation && result == .raised) || confirm() { return .focused }
            guard canAct() else { return .cancelled }
            guard now() < deadline else { return .failed }
            if allowUnidentifiedActivation, requireConfirmation, result == .unavailable,
               !recovered, let activatedAt, now() - activatedAt >= 0.24 {
                recover()
                recovered = true
                guard canAct() else { return .cancelled }
            }
            wait()
        } while now() < deadline
        return .failed
    }

    /// Missing AX data is not proof of an accessory. Activation can help an app
    /// expose/restore its window, but only when its sole real CG window is the
    /// requested one on this desktop/display. Unknown or additional windows veto
    /// this fallback so activation cannot choose a different desktop's window.
    public static func canActivateMissingWindow(for requested: WindowInfo, in snapshot: SpaceSnapshot,
                                               context: LaunchContext) -> Bool {
        guard requested.windowID != 0, requested.pid > 0, context.spaceID != 0,
              requested.spaceMembershipKnown, requested.isOn(context.spaceID),
              requested.bounds.width > 0, requested.bounds.height > 0,
              requested.isVisible(onSpace: context.spaceID, display: context.displayBounds) else { return false }
        let real = snapshot.windows.filter { $0.pid == requested.pid && $0.isReal }
        return real.count == 1 && real.first?.windowID == requested.windowID
    }

    /// A successful app activation alone cannot confirm an exact-window raise.
    /// The caller supplies freshly observed on-screen, front-to-back CG facts
    /// and must also revalidate the original desktop/display context.
    public static func isConfirmedFocused(windowID: CGWindowID, pid: pid_t,
                                          frontmostPID: pid_t?, frontmostWindowID: CGWindowID?,
                                          frontmostWindowPID: pid_t?) -> Bool {
        windowID != 0 && pid > 0 && frontmostPID == pid
            && frontmostWindowID == windowID && frontmostWindowPID == pid
    }

    /// CG eligibility only. The caller must verify the candidate's identity and
    /// ordinary-window role through AX before using it.
    public static func candidates(for requested: WindowInfo, in snapshot: SpaceSnapshot,
                                  context: LaunchContext, requestedIsAccessory: Bool = false) -> [WindowInfo] {
        guard context.spaceID != 0,
              (!requested.isOnscreen || requestedIsAccessory), !requested.isMinimized, !requested.isHidden,
              requested.spaceMembershipKnown, requested.isOn(context.spaceID) else { return [] }
        return snapshot.windows.filter {
            $0.pid == requested.pid && $0.windowID != requested.windowID
                && ($0.isOnscreen || $0.isMinimized || $0.isHidden)
                && $0.spaceMembershipKnown && $0.isOn(context.spaceID)
                && $0.isVisible(onSpace: context.spaceID, display: context.displayBounds)
        }
    }

    public static func recoveryWindow(for requested: WindowInfo, in snapshot: SpaceSnapshot,
                                      context: LaunchContext, verifiedAXIDs: Set<CGWindowID>,
                                      requestedIsAccessory: Bool = false) -> WindowInfo? {
        let candidates = candidates(for: requested, in: snapshot, context: context, requestedIsAccessory: requestedIsAccessory)
        guard candidates.count == 1, let candidate = candidates.first,
              verifiedAXIDs.contains(candidate.windowID) else { return nil }
        return candidate
    }
}
