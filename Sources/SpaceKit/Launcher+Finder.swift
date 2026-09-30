// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

extension Launcher {
    /// A folder open uses Launch Services even after a windowless Finder restart.
    /// The shared placement verifier checks the original requested display/Space.
    func openNewFinderWindow() -> Bool {
        runProcess(URL(fileURLWithPath: "/usr/bin/open"), [FileManager.default.homeDirectoryForCurrentUser.path])
    }
}
