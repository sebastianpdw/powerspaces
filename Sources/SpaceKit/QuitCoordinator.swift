// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation

/// Captured process handles; this protocol deliberately offers only polite quit.
public protocol QuitParticipant {
    func requestQuit()
    var hasExited: Bool { get }
}

extension NSRunningApplication: QuitParticipant {
    public func requestQuit() { _ = terminate() }
    public var hasExited: Bool { isTerminated }
}

public enum QuitCoordinator {
    public static func requestQuit(_ instances: [QuitParticipant], timeout: TimeInterval = 1.5) -> Bool {
        instances.forEach { $0.requestQuit() }
        return pollUntil(timeout: timeout, interval: 50_000) { instances.allSatisfy(\.hasExited) }
    }

    /// A refusal/timeout never calls open, so a dying old instance cannot be mistaken for a relaunch.
    public static func reopen(_ instances: [QuitParticipant], timeout: TimeInterval = 2,
                              open: () -> LaunchOutcome) -> LaunchOutcome? {
        guard requestQuit(instances, timeout: timeout) else { return nil }
        return open()
    }
}
