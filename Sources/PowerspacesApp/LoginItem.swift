// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import ServiceManagement

/// Starts Powerspaces automatically when the user logs in, so the per-Space dock is
/// there from the moment the desktop appears. Backed by macOS `SMAppService`, the
/// modern login-item API (macOS 13+): registering adds the bundled `.app` to the
/// user's login items; unregistering removes it.
///
/// The OS persists the registration itself (it survives quits and reboots), so it —
/// not our JSON store — is the real source of truth for whether we launch at login.
/// The `launchAtLogin` *preference* mirrors that desired state: it lets the setting
/// live alongside the others in `preferences.json`, and lets `AppDelegate` re-assert
/// it at startup if a reinstall cleared the per-bundle registration (see
/// `AppDelegate.applyLoginItem`).
///
/// Registration only works for a real bundled app: run unbundled (e.g. `swift run`)
/// there's no `.app` for the OS to launch, so `register()` throws — surfaced to the
/// user by the toggle rather than failing silently.
enum LoginItem {
    /// Whether macOS currently launches Powerspaces at login.
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Add or remove the login item. Throws when it can't be changed — most often
    /// because we're running unbundled, where there's no `.app` to register.
    static func setEnabled(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}
