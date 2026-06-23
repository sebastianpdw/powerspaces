// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// Shared keyboard-navigation state for the launcher grid. The view owns the
/// rendering (highlight + scroll) while the hosting panel's key monitor drives
/// the selection, since a borderless panel routes arrow keys through `NSEvent`
/// before they reach the focused search field. The view keeps `count`/`columns`
/// in sync so up/down jump exactly one grid row and the index never runs off
/// the ends.
final class LauncherKeyboard: ObservableObject {
    /// Index into the *filtered* list of the currently highlighted app.
    @Published var selection = 0

    private var count = 0
    private var columns = 1

    enum Direction { case left, right, up, down }

    /// Move the highlight, clamped to the visible list (no wrap-around).
    func move(_ direction: Direction) {
        guard count > 0 else { return }
        var next = selection
        switch direction {
        case .left:  next -= 1
        case .right: next += 1
        case .up:    next -= columns
        case .down:  next += columns
        }
        selection = min(max(next, 0), count - 1)
    }

    /// Called by the view whenever the grid's geometry or the filter changes.
    func sync(count: Int, columns: Int) {
        self.count = count
        self.columns = max(1, columns)
        if selection >= count { selection = max(0, count - 1) }
    }
}

/// The App Launcher's content: a search field over a scrollable grid of every
/// installed app. Click a tile to launch (routed through the smart-launch engine
/// by the app layer); drag a tile onto the dock bar to pin it (the bar's existing
/// `.app`-drop pipeline handles the pin, so no extra wiring is needed here).
/// The first app is selected on open and the arrow keys move the selection.
struct AppLauncherView: View {
    /// The cached, off-main-loaded app list + recents the grid renders.
    @ObservedObject var store: InstalledAppsStore
    /// Drives arrow-key navigation; the hosting panel feeds it key events.
    @ObservedObject var keyboard: LauncherKeyboard
    /// Selection-ring and fill colors for the highlighted tile, from Preferences
    /// (the analogues of the running-app box's outline/highlight).
    let outlineColor: Color
    let highlightColor: Color
    /// A tile was clicked (or Return pressed): launch it. The panel closes after.
    /// `forceNew` (⌘ held) opens a brand-new window on the current space instead of
    /// focusing an existing one — same semantics as a ⌘-modified dock click.
    let onLaunch: (InstalledApp, Bool) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// Tile sizing — kept in one place so the column-count math below matches
    /// what the adaptive grid actually renders.
    private let tileMin: CGFloat = 96
    private let gridSpacing: CGFloat = 16
    private let gridPadding: CGFloat = 20

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: tileMin, maximum: 120), spacing: gridSpacing)]
    }

    /// The grid contents. With no query: recently-launched apps first, then the rest
    /// alphabetically. With a query: name/bundle-id substring matches first, then a
    /// loose subsequence match ("ggl" → Google Chrome), best matches on top.
    private var filtered: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            let recent = store.recentApps
            let recentIDs = Set(recent.compactMap { $0.bundleID })
            let rest = store.apps.filter { !($0.bundleID.map(recentIDs.contains) ?? false) }
            return recent + rest
        }
        let lower = q.lowercased()
        let scored = store.apps.compactMap { app -> (InstalledApp, Int)? in
            let name = app.name.lowercased()
            if name.hasPrefix(lower) { return (app, 0) }
            if name.contains(lower) { return (app, 1) }
            if let id = app.bundleID?.lowercased(), id.contains(lower) { return (app, 2) }
            if Self.isSubsequence(lower, of: name) { return (app, 3) }
            return nil
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1
                : $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending }
            .map(\.0)
    }

    /// Whether `needle`'s characters appear in order within `haystack` (the loose
    /// fuzzy match used as a last resort). Both are already lowercased.
    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        for ch in needle {
            var found = false
            while let h = iterator.next() {
                if h == ch { found = true; break }
            }
            if !found { return false }
        }
        return true
    }

    /// How many columns the adaptive grid fits at `width` — the same "largest
    /// count whose tracks stay ≥ minimum" rule SwiftUI uses — so up/down move by
    /// a real row. `width` is the grid's outer width (padding included).
    private func columnCount(forWidth width: CGFloat) -> Int {
        let inner = width - gridPadding * 2
        return max(1, Int((inner + gridSpacing) / (tileMin + gridSpacing)))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 660, minHeight: 480)
        // Reduce Transparency: swap the blurred body for a solid background.
        .background(SystemDisplay.reduceTransparency
                    ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                    : AnyShapeStyle(.ultraThinMaterial))
        // ⌘Return launches the highlighted app in a brand-new window. A borderless
        // panel routes a plain Return to the search field's editor (→ `.onSubmit`),
        // so a hidden, zero-opacity button claims the ⌘-modified key equivalent via
        // `performKeyEquivalent` before the field editor sees it. If the equivalent
        // isn't consumed for any reason, plain Return still launches (without
        // `forceNew`), so this degrades gracefully and never double-launches.
        .background(
            Button("Open in new window") { launchSelected(forceNew: true) }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
        // Typing changes the result set: re-home the highlight to the first hit.
        // The grid's GeometryReader re-syncs count/columns when the list resizes.
        .onChange(of: query) { _, _ in keyboard.selection = 0 }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search apps", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { launchSelected(forceNew: false) }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear { searchFocused = true }
    }

    @ViewBuilder private var content: some View {
        if store.apps.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading apps…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.tertiary)
                Text("No apps match “\(query)”").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, app in
                                AppTile(app: app,
                                        selected: index == keyboard.selection,
                                        outlineColor: outlineColor,
                                        highlightColor: highlightColor) { forceNew in
                                    launch(app, forceNew)
                                }
                                .id(app.id)
                            }
                        }
                        .padding(gridPadding)
                    }
                    // Keep the highlighted tile on screen as the arrows move it.
                    .onChange(of: keyboard.selection) { _, new in
                        guard filtered.indices.contains(new) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(filtered[new].id, anchor: .center)
                        }
                    }
                }
                .onAppear { syncKeyboard(width: geo.size.width) }
                .onChange(of: geo.size.width) { _, w in syncKeyboard(width: w) }
                .onChange(of: filtered.count) { _, _ in syncKeyboard(width: geo.size.width) }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(filtered.count) app\(filtered.count == 1 ? "" : "s")")
            Spacer()
            Label("↑↓←→ to select · Return to launch · ⌘Return for a new window · drag onto the bar to pin",
                  systemImage: "hand.draw")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func syncKeyboard(width: CGFloat) {
        keyboard.sync(count: filtered.count, columns: columnCount(forWidth: width))
    }

    private func launchSelected(forceNew: Bool) {
        guard filtered.indices.contains(keyboard.selection) else { return }
        launch(filtered[keyboard.selection], forceNew)
    }

    /// Record the launch (so it surfaces in "Recent") and hand off to the app layer.
    private func launch(_ app: InstalledApp, _ forceNew: Bool) {
        store.recordLaunch(app)
        onLaunch(app, forceNew)
    }
}

/// A single app in the grid: its icon over its name. Clicking launches it; the
/// `.onDrag` puts the app's file URL on the drag pasteboard so dropping it on the
/// bar pins it (the bar reads file-URL drags of application bundles). The
/// `selected` tile (driven by the arrow keys) reads with the configured fill +
/// ring colors; hover stays a subtle fill so mouse and keyboard don't fight over
/// one look.
private struct AppTile: View {
    let app: InstalledApp
    let selected: Bool
    let outlineColor: Color
    let highlightColor: Color
    /// `true` when ⌘ is held at click time — open the app in a new window.
    let onLaunch: (Bool) -> Void
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
            Text(app.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 28, alignment: .top)
        }
        .frame(width: 96)
        .padding(8)
        .background(fill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? outlineColor : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { onLaunch(NSEvent.modifierFlags.contains(.command)) }
        .onDrag { NSItemProvider(object: app.url as NSURL) }
        .help(app.name)
    }

    private var fill: Color {
        if selected { return highlightColor }
        if hovered { return Color.primary.opacity(0.12) }
        return .clear
    }
}
