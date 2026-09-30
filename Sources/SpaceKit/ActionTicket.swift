// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Queued intent has both a desktop identity and an expiry; neither is refreshed
/// merely because earlier work took a long time.
public struct ActionTicket: Sendable {
    public enum Rejection: String, Sendable {
        case expired
        case snapshotUnavailable
        case nativeInteraction
        case desktopChanged
    }
    public let context: LaunchContext
    public let deadline: TimeInterval
    public init(context: LaunchContext, createdAt: TimeInterval, lifetime: TimeInterval = 8) {
        self.context = context; deadline = createdAt + lifetime
    }
    public func hasNotExpired(at now: TimeInterval) -> Bool { now < deadline }
    public func rejectionReason(snapshot: SpaceSnapshot, displays: [DisplaySpaceInfo],
                                now: TimeInterval, nativeInteraction: Bool) -> Rejection? {
        if !hasNotExpired(at: now) { return .expired }
        if nativeInteraction { return .nativeInteraction }
        if !context.isCurrent(snapshot: snapshot, displays: displays) { return .desktopChanged }
        return nil
    }
}
