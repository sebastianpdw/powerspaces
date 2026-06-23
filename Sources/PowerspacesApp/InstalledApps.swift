// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import SpaceKit

/// The launcher's data model: the installed-app list (scanned off the main thread
/// and cached, so opening the launcher is instant) plus the recently-launched
/// apps. A shared, observable singleton the launcher view binds to.
@MainActor
final class InstalledAppsStore: ObservableObject {
    static let shared = InstalledAppsStore()

    @Published private(set) var apps: [InstalledApp] = []
    /// Bundle ids of recently-launched apps, most recent first. Persisted so the
    /// "Recent" apps survive relaunches.
    @Published private(set) var recentBundleIDs: [String] = []

    private var isLoading = false
    private let recentsURL = PowerspacesPaths.configDir.appendingPathComponent("launcher-recents.json")
    private static let maxRecents = 12

    private init() {
        if let data = try? Data(contentsOf: recentsURL),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            recentBundleIDs = ids
        }
    }

    /// Rescan the Applications folders off the main thread and publish on main.
    /// Cheap to call on every launcher open; a scan already in flight is coalesced,
    /// and the previously-cached list stays on screen until the fresh one lands.
    func reload() {
        guard !isLoading else { return }
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let scanned = InstalledApps.all()
            await MainActor.run {
                self.apps = scanned
                self.isLoading = false
            }
        }
    }

    /// The recently-launched apps that are still installed, newest first.
    var recentApps: [InstalledApp] {
        let byID = Dictionary(apps.compactMap { app in app.bundleID.map { ($0, app) } },
                              uniquingKeysWith: { first, _ in first })
        return recentBundleIDs.compactMap { byID[$0] }
    }

    /// Record that `app` was launched, moving it to the front of the recents.
    func recordLaunch(_ app: InstalledApp) {
        guard let id = app.bundleID else { return }
        var list = recentBundleIDs.filter { $0 != id }
        list.insert(id, at: 0)
        if list.count > Self.maxRecents { list = Array(list.prefix(Self.maxRecents)) }
        recentBundleIDs = list
        if let data = try? JSONEncoder().encode(list) {
            try? FileManager.default.createDirectory(
                at: recentsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: recentsURL)
        }
    }
}

/// One installed application, as shown in the App Launcher grid.
struct InstalledApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String?

    /// The file URL is the natural identity (one tile per .app on disk).
    var id: URL { url }

    /// The target to hand the smart-launch engine. Bundle id is canonical for
    /// window matching; the name is the fallback.
    var target: AppTarget { AppTarget(bundleID: bundleID, name: name) }

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// Enumerates the apps a user would expect to "see in their Applications folder":
/// `/Applications` (incl. one level of subfolders like *Utilities*), the matching
/// system folders, the read-only system "cryptex" (where Safari now lives),
/// `~/Applications`, Apple's `CoreServices/Applications` utilities folder (Keychain
/// Access and friends), plus Finder (which hides in the CoreServices root). A plain
/// `FileManager` scan — no Spotlight, no background indexing — so it stays
/// lightweight and runs only when the launcher is actually opened.
enum InstalledApps {
    /// The folders scanned, in priority order. A user copy in `/Applications`
    /// shadows the same-named app elsewhere (first one wins, see `all()`).
    private static var searchPaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            // Safari ships in a read-only cryptex on modern macOS — it is not in
            // /System/Applications, and the /Applications/Safari.app firmlink is
            // invisible to a plain directory scan, so point at the cryptex directly.
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications"),
            // Apple's folder for user-facing utilities that aren't in
            // /System/Applications — Keychain Access, Archive Utility, Wireless
            // Diagnostics, Directory Utility, and friends. (Distinct from the
            // CoreServices *root*, which is ~120 background agents we don't scan.)
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
        ]
    }

    /// Individual user-facing apps that live outside the scanned folders. Finder
    /// sits in the `/System/Library/CoreServices` *root*, alongside ~120 background
    /// agents and UI helpers (Dock, loginwindow, WiFiAgent…) and system-invoked
    /// flows (Setup Assistant, Installer…), so we never scan that root wholesale —
    /// Finder is the only app there a user would actually launch, so list it by hand.
    private static let extraAppPaths = [
        URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
    ]

    /// Every installed app, de-duplicated by name (the first folder wins) and
    /// sorted case-insensitively — the order the grid renders in.
    static func all() -> [InstalledApp] {
        (searchPaths.flatMap(scan) + extraAppPaths.compactMap(app(at:)))
            .uniqued(on: { $0.name.lowercased() })
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The `.app` bundles directly inside `dir` (non-recursive — subfolders like
    /// *Utilities* are listed explicitly in `searchPaths`).
    private static func scan(_ dir: URL) -> [InstalledApp] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }
        return entries.compactMap(app(at:))
    }

    /// Build an `InstalledApp` from a `.app` bundle URL, or `nil` if it isn't an
    /// app bundle or doesn't exist on disk.
    private static func app(at url: URL) -> InstalledApp? {
        guard url.pathExtension == "app",
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let name = AppResolver.displayName(forAppURL: url)
        return InstalledApp(url: url, name: name, bundleID: Bundle(url: url)?.bundleIdentifier)
    }
}
