// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation

/// Resolves user-supplied app strings ("Firefox", "org.mozilla.firefox") into
/// a matchable `AppTarget` and a launchable app URL.
public enum AppResolver {
    public static func target(from string: String) -> AppTarget {
        // A dotted string that resolves as a bundle id is treated as one.
        if string.contains("."),
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: string) != nil {
            return AppTarget(bundleID: string, name: nil)
        }
        // Otherwise treat it as a display name; try to recover the bundle id
        // from a currently-running app so window matching is canonical.
        if let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.localizedName == string }) {
            return AppTarget(bundleID: running.bundleIdentifier, name: string)
        }
        return AppTarget(bundleID: nil, name: string)
    }

    /// The Finder display name of the app at `url`, without the trailing `.app`
    /// (which `FileManager.displayName` keeps when "show all filename extensions"
    /// is on). One definition so the per-Space dock and the launcher grid label
    /// apps identically.
    public static func displayName(forAppURL url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    public static func appURL(for target: AppTarget) -> URL? {
        if let bundleID = target.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        if let name = target.name {
            for dir in ["/Applications", "/System/Applications",
                        NSHomeDirectory() + "/Applications"] {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent("\(name).app")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}
