// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation
import ApplicationServices

// Private SkyLight / CoreGraphics window-server symbols. These are the same
// read-only calls AltTab/Hammerspoon use; reading space membership this way
// does NOT require disabling SIP. All private surface is isolated to this file.

typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ windowIDs: CFArray) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopyActiveMenuBarDisplayIdentifier")
func CGSCopyActiveMenuBarDisplayIdentifier(_ cid: CGSConnectionID) -> Unmanaged<CFString>?

// Maps an AXUIElement (a window) back to its CGWindowID, so we can raise the
// *exact* window on the current Space rather than the app's frontmost (which
// may live elsewhere and cause a space jump).
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ outID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// current | others | user  →  "all spaces" mask for CGSCopySpacesForWindows.
let kCGSSpaceAll: Int32 = 0x7
