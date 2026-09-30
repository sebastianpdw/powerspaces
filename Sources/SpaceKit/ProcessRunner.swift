// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Darwin

/// Supervise only our own short-lived helpers, never another GUI app's binary.
public enum ProcessRunner {
    public enum Result: Equatable { case exited(Int32), timedOut, failed }
    public static func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 5,
                           standardError: FileHandle? = nil) -> Result {
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError ?? FileHandle.nullDevice
        do { try process.run() } catch { return .failed }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        if process.isRunning {
            // This PID is the helper we created, not a target application's PID.
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            return .timedOut
        }
        return .exited(process.terminationStatus)
    }
}
