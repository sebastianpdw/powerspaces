// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation

public enum ApplicationLaunchRoute: Sendable { case workspace, commandLine }

/// GUI launches use the supported application API, with completion and a bounded
/// wait on the launcher queue. The main thread remains free to process AppKit.
enum WorkspaceAppOpener {
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var succeeded = false
        let semaphore = DispatchSemaphore(value: 0)
        func canStart() -> Bool { lock.lock(); defer { lock.unlock() }; return !cancelled }
        func finish(_ success: Bool) {
            lock.lock(); succeeded = success && !cancelled; lock.unlock()
            semaphore.signal()
        }
        func result(timedOut: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if timedOut { cancelled = true }
            return succeeded && !timedOut
        }
    }

    static func open(_ url: URL, arguments: [String], newInstance: Bool,
                     background: Bool, context: LaunchContext) -> Bool {
        guard !Thread.isMainThread else { return false }
        let completion = Completion()
        DispatchQueue.main.async {
            guard completion.canStart(), !NativeInteraction.isActive else { completion.finish(false); return }
            let displays = CGSSpaceProvider().displays()
            let snapshot = SpaceSnapshot(activeSpaceID: displays.first(where: \.isActive)?.currentSpaceID ?? 0, windows: [])
            guard context.isCurrent(snapshot: snapshot, displays: displays) else { completion.finish(false); return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = arguments
            configuration.createsNewApplicationInstance = newInstance
            configuration.activates = !background
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                completion.finish(app != nil && error == nil)
            }
        }
        let timedOut = completion.semaphore.wait(timeout: .now() + 5) == .timedOut
        return completion.result(timedOut: timedOut)
    }
}
