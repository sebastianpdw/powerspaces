// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Pure, testable model of pinned apps. A pin is either scoped to one desktop
/// (keyed by the Space's persistent UUID) or to **all** desktops. An all-desktops
/// pin can also be hidden on individual desktops via a per-desktop *exception*
/// ("unpin this desktop" while staying pinned everywhere else). Fully isolated
/// per desktop.
public struct PinModel: Equatable, Sendable {
    /// bundle ids pinned to a specific desktop (Space UUID -> [bundleID]).
    public private(set) var pinsBySpace: [String: [String]]
    /// bundle ids pinned to every desktop (including future ones).
    public private(set) var everywhere: [String]
    /// All-desktops pins the user has hidden on specific desktops (Space UUID ->
    /// [bundleID]). An entry here means "this `everywhere` app should NOT show on
    /// this one desktop"; it stays pinned on every other desktop.
    public private(set) var everywhereExceptionsBySpace: [String: [String]]
    /// The user's saved icon arrangement per desktop (Space UUID -> ordered
    /// `orderKey`s). Drives `DockModel`'s left-to-right order so a drag sticks.
    public private(set) var orderBySpace: [String: [String]]

    public init(pinsBySpace: [String: [String]] = [:], everywhere: [String] = [],
                everywhereExceptionsBySpace: [String: [String]] = [:],
                orderBySpace: [String: [String]] = [:]) {
        self.pinsBySpace = pinsBySpace
        self.everywhere = everywhere
        self.everywhereExceptionsBySpace = everywhereExceptionsBySpace
        self.orderBySpace = orderBySpace
    }

    /// Explicit pins for this desktop only (not the all-desktops ones).
    public func spacePins(onSpace uuid: String) -> [String] { pinsBySpace[uuid] ?? [] }
    public func everywherePins() -> [String] { everywhere }
    /// All-desktops pins the user has hidden on this desktop.
    public func everywhereExceptions(onSpace uuid: String) -> [String] {
        everywhereExceptionsBySpace[uuid] ?? []
    }

    /// Everything that should show on this desktop (all-desktops first, then this
    /// desktop's own, de-duplicated). All-desktops pins the user hid here are
    /// dropped — unless they're also explicitly pinned to this desktop, in which
    /// case the local pin wins and they still show.
    public func pinned(onSpace uuid: String) -> [String] {
        let hidden = Set(everywhereExceptions(onSpace: uuid))
        let here = spacePins(onSpace: uuid)
        let hereSet = Set(here)
        let visibleEverywhere = everywhere.filter { !hidden.contains($0) || hereSet.contains($0) }
        return (visibleEverywhere + here).uniqued()
    }

    public func isPinnedHere(_ bundleID: String, onSpace uuid: String) -> Bool {
        spacePins(onSpace: uuid).contains(bundleID)
    }
    public func isPinnedEverywhere(_ bundleID: String) -> Bool { everywhere.contains(bundleID) }
    /// True when an all-desktops pin has been hidden on this one desktop.
    public func isExcludedEverywhere(_ bundleID: String, onSpace uuid: String) -> Bool {
        everywhereExceptions(onSpace: uuid).contains(bundleID)
    }
    /// True when the app actually shows on this desktop (a local pin, or an
    /// all-desktops pin that hasn't been hidden here).
    public func isPinned(_ bundleID: String, onSpace uuid: String) -> Bool {
        isPinnedHere(bundleID, onSpace: uuid)
            || (isPinnedEverywhere(bundleID) && !isExcludedEverywhere(bundleID, onSpace: uuid))
    }

    public mutating func pin(_ bundleID: String, onSpace uuid: String) {
        // An explicit local pin overrides a prior "unpin this desktop" exception.
        includeEverywhere(bundleID, onSpace: uuid)
        guard !isPinnedHere(bundleID, onSpace: uuid) else { return }
        pinsBySpace[uuid, default: []].append(bundleID)
    }
    public mutating func unpin(_ bundleID: String, onSpace uuid: String) {
        guard var list = pinsBySpace[uuid] else { return }
        list.removeAll { $0 == bundleID }
        pinsBySpace[uuid] = list.isEmpty ? nil : list
    }
    public mutating func toggle(_ bundleID: String, onSpace uuid: String) {
        if isPinnedHere(bundleID, onSpace: uuid) { unpin(bundleID, onSpace: uuid) }
        else { pin(bundleID, onSpace: uuid) }
    }

    public mutating func pinEverywhere(_ bundleID: String) {
        // Re-pinning everywhere starts fresh: drop any per-desktop exceptions so
        // the app shows on every desktop again.
        clearEverywhereExceptions(bundleID)
        guard !everywhere.contains(bundleID) else { return }
        everywhere.append(bundleID)
    }
    public mutating func unpinEverywhere(_ bundleID: String) {
        everywhere.removeAll { $0 == bundleID }
        // The exceptions only mean anything while the app is pinned everywhere.
        clearEverywhereExceptions(bundleID)
    }
    public mutating func toggleEverywhere(_ bundleID: String) {
        if everywhere.contains(bundleID) { unpinEverywhere(bundleID) } else { pinEverywhere(bundleID) }
    }

    /// Hide an all-desktops pin on one desktop, keeping it on every other. Also
    /// drops any explicit local pin for that desktop, so the app is truly gone
    /// from here (the local pin would otherwise keep it visible).
    public mutating func excludeEverywhere(_ bundleID: String, onSpace uuid: String) {
        unpin(bundleID, onSpace: uuid)
        guard !isExcludedEverywhere(bundleID, onSpace: uuid) else { return }
        everywhereExceptionsBySpace[uuid, default: []].append(bundleID)
    }
    /// Undo `excludeEverywhere`: show the all-desktops pin on this desktop again.
    public mutating func includeEverywhere(_ bundleID: String, onSpace uuid: String) {
        guard var list = everywhereExceptionsBySpace[uuid] else { return }
        list.removeAll { $0 == bundleID }
        everywhereExceptionsBySpace[uuid] = list.isEmpty ? nil : list
    }
    public mutating func toggleEverywhereException(_ bundleID: String, onSpace uuid: String) {
        if isExcludedEverywhere(bundleID, onSpace: uuid) { includeEverywhere(bundleID, onSpace: uuid) }
        else { excludeEverywhere(bundleID, onSpace: uuid) }
    }

    /// Forget every desktop's exception for this bundle id (used when the
    /// all-desktops pin itself is added or removed).
    private mutating func clearEverywhereExceptions(_ bundleID: String) {
        for uuid in everywhereExceptionsBySpace.keys {
            includeEverywhere(bundleID, onSpace: uuid)
        }
    }

    /// The saved arrangement for one desktop (empty if never reordered).
    public func order(onSpace uuid: String) -> [String] { orderBySpace[uuid] ?? [] }
    /// Replaces this desktop's arrangement. An empty list clears it (back to the
    /// default pinned-then-alphabetical order).
    public mutating func setOrder(_ keys: [String], onSpace uuid: String) {
        orderBySpace[uuid] = keys.isEmpty ? nil : keys
    }
}

extension PinModel: Codable {
    enum CodingKeys: String, CodingKey {
        case pinsBySpace, everywhere, everywhereExceptionsBySpace, orderBySpace
    }
    // Migration-safe: missing keys decode to empty, so older pins.json still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinsBySpace = (try? c.decode([String: [String]].self, forKey: .pinsBySpace)) ?? [:]
        everywhere = (try? c.decode([String].self, forKey: .everywhere)) ?? []
        everywhereExceptionsBySpace =
            (try? c.decode([String: [String]].self, forKey: .everywhereExceptionsBySpace)) ?? [:]
        orderBySpace = (try? c.decode([String: [String]].self, forKey: .orderBySpace)) ?? [:]
    }
}

/// Persists a `PinModel` to disk as JSON (so pins survive reboots).
public final class PinStore {
    private var model: PinModel
    private let url: URL

    public init(url: URL) {
        self.url = url
        self.model = PinStore.read(url) ?? PinModel()
    }

    public func spacePins(onSpace uuid: String) -> [String] { model.spacePins(onSpace: uuid) }
    public func everywherePins() -> [String] { model.everywherePins() }
    public func everywhereExceptions(onSpace uuid: String) -> [String] { model.everywhereExceptions(onSpace: uuid) }
    public func isPinned(_ b: String, onSpace uuid: String) -> Bool { model.isPinned(b, onSpace: uuid) }

    public func pin(_ b: String, onSpace uuid: String) { model.pin(b, onSpace: uuid); save() }
    public func unpin(_ b: String, onSpace uuid: String) { model.unpin(b, onSpace: uuid); save() }
    public func toggle(_ b: String, onSpace uuid: String) { model.toggle(b, onSpace: uuid); save() }
    public func pinEverywhere(_ b: String) { model.pinEverywhere(b); save() }
    public func unpinEverywhere(_ b: String) { model.unpinEverywhere(b); save() }
    public func toggleEverywhere(_ b: String) { model.toggleEverywhere(b); save() }
    public func toggleEverywhereException(_ b: String, onSpace uuid: String) { model.toggleEverywhereException(b, onSpace: uuid); save() }

    public func order(onSpace uuid: String) -> [String] { model.order(onSpace: uuid) }
    public func setOrder(_ keys: [String], onSpace uuid: String) { model.setOrder(keys, onSpace: uuid); save() }

    public static var defaultURL: URL { PowerspacesPaths.pinsFile }

    private static func read(_ url: URL) -> PinModel? { JSONFileStore.read(PinModel.self, from: url) }

    // A dropped save means pins won't survive a restart, so JSONFileStore logs the failure.
    private func save() { JSONFileStore.writeEncodable(model, to: url) }
}
