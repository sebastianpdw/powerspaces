// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation

/// A mouse drag or click in progress. macOS has no status for Mission Control:
/// a check for large Dock-owned windows stood in for one, and held actions back
/// because such a window can stay on screen after the overview has closed.
public enum NativeInteraction {
    public static var isActive: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }
}
