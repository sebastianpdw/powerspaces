// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import OSLog

/// A tiny wrapper over the unified logging system (`os.Logger`) so the previously
/// silent persistence/load failures (swallowed by `try?`) leave a trace in the
/// Console / `log` stream instead of vanishing. Keep messages free of secrets and
/// user content — only paths, error descriptions, and identifiers.
public enum Log {
    private static let logger = Logger(subsystem: "nl.sebastianpdw.powerspaces", category: "spacekit")

    public static func error(_ message: String) { logger.error("\(message, privacy: .public)") }
    public static func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }
}
