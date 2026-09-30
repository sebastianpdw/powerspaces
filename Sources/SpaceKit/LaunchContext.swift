// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation

/// Intent captured before queueing an action; never replaced by a later active Space.
public struct LaunchContext: Equatable, Sendable {
    public let spaceID: SpaceID
    public let spaceUUID: String?
    public let displayUUID: String?
    public let displayBounds: CGRect?

    public init(spaceID: SpaceID, spaceUUID: String? = nil,
                displayUUID: String? = nil, displayBounds: CGRect? = nil) {
        self.spaceID = spaceID; self.spaceUUID = spaceUUID
        self.displayUUID = displayUUID; self.displayBounds = displayBounds
    }
    public init(display: DisplaySpaceInfo) {
        self.init(spaceID: display.currentSpaceID, spaceUUID: display.currentSpaceUUID,
                  displayUUID: display.displayUUID, displayBounds: display.bounds)
    }
    public func isCurrent(snapshot: SpaceSnapshot, displays: [DisplaySpaceInfo]) -> Bool {
        guard spaceID != 0 else { return false }
        if let displayBounds {
            guard displayBounds.width > 0, displayBounds.height > 0,
                  !displayBounds.isInfinite, !displayBounds.isNull else { return false }
        }
        if let displayUUID {
            guard let display = displays.first(where: { $0.displayUUID == displayUUID }) else { return false }
            guard display.bounds.width > 0, display.bounds.height > 0 else { return false }
            return display.currentSpaceID == spaceID
                && (spaceUUID == nil || spaceUUID == "" || display.currentSpaceUUID == spaceUUID)
                && (displayBounds == nil || display.bounds == displayBounds)
        }
        if let displayBounds {
            return displays.contains { $0.bounds == displayBounds && $0.currentSpaceID == spaceID }
        }
        return snapshot.activeSpaceID == spaceID
    }
}
