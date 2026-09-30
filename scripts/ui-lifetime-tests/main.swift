// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SpaceKit

// Compiled with the real GUI sources, excluding the normal app entry point.
// No AppDelegate, shown windows, target-app actions, or system-setting changes.
final class WeakReference<T: AnyObject> { weak var value: T?; init(_ value: T) { self.value = value } }
@MainActor func buttons(in view: NSView) -> [DockButton] {
    (view as? DockButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
}

let app = NSApplication.shared
var failures = 0
var assertions = 0
@MainActor func check(_ value: Bool, _ message: String) {
    assertions += 1
    if !value { failures += 1; print("FAIL: " + message) }
}
// test-ui-lifetimes.sh names a per-run directory inside the repository in TMPDIR.
// Foundation's temporaryDirectory ignores that variable, so read it here.
guard let tmp = ProcessInfo.processInfo.environment["TMPDIR"] else {
    print("FAIL: TMPDIR must name the test directory; run scripts/test-ui-lifetimes.sh")
    exit(1)
}
let root = URL(fileURLWithPath: tmp).appendingPathComponent("powerspaces-ui-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
check(root.path.hasPrefix(tmp), "Test files stay in the directory TMPDIR names")
let prefs = Preferences(preferencesURL: root.appendingPathComponent("preferences.json"),
                        dockColorsURL: root.appendingPathComponent("dock-colors.json"))
prefs.appleDockAutohideBackup = false
prefs.appleDockTilesizeBackup = "72"
prefs.spaceHotkeysDisabledByUs = true
prefs.pollInterval = 0.1
prefs.resetAllToDefaults()
check(prefs.appleDockAutohideBackup == false, "Reset preserves legacy autohide recovery")
check(prefs.appleDockTilesizeBackup == "72", "Reset preserves legacy tile recovery")
check(prefs.spaceHotkeysDisabledByUs, "Reset preserves shortcut crash marker")
check(prefs.pollInterval == 2, "Reset uses the documented 2-second poll default")
let reloaded = Preferences(preferencesURL: root.appendingPathComponent("preferences.json"),
                           dockColorsURL: root.appendingPathComponent("dock-colors.json"))
check(reloaded.appleDockTilesizeBackup == "72" && reloaded.spaceHotkeysDisabledByUs,
      "Recovery survives a settings-store reload")

var oldButtons: [WeakReference<DockButton>] = []
var oldPanels: [WeakReference<NSPanel>] = []
var oldContainers: [WeakReference<NSView>] = []
autoreleasepool {
    guard let screen = NSScreen.screens.first else { fatalError("A GUI session is required for AppKit lifetime tests") }
    let dock = DockPanel(screen: screen)
    for generation in 0..<200 {
        autoreleasepool {
            dock.update(apps: [DockApp(bundleID: nil, name: "Test \(generation)", pid: nil, windowCount: 0)], animateChanges: false)
            check(!dock.isVisible, "Lifetime fixture stays hidden")
            let current = buttons(in: dock.contentView!)
            check(current.count == 1 && current[0].onRightClick != nil, "Real rebuild installs right-click callback")
            oldButtons.append(contentsOf: current.map(WeakReference.init))
            dock.update(apps: [], animateChanges: false)
        }
    }
}
check(oldButtons.allSatisfy { $0.value == nil }, "All 200 rebuilt DockButtons deallocate")
for generation in 0..<200 {
    autoreleasepool {
        let panel = HUD.makePanel("Test \(generation)", prefs: prefs)
        check(!panel.isVisible, "HUD factory stays hidden")
        oldPanels.append(WeakReference(panel))
        oldContainers.append(WeakReference(panel.contentView!))
    }
}
check(oldPanels.allSatisfy { $0.value == nil }, "All 200 HUD panels deallocate")
check(oldContainers.allSatisfy { $0.value == nil }, "All 200 HUD containers deallocate")
autoreleasepool {
    let dock = DockPanel(screen: NSScreen.screens.first!)
    dock.spaceUUID = "original"
    let apps = DockModel.expandingPerWindow([DockApp(bundleID: "test", name: "Test", pid: 100,
        windowCount: 2, windowIDs: [1, 2], windowPIDs: [1: 100, 2: 200])])
    dock.update(apps: apps, animateChanges: false)
    let current = buttons(in: dock.contentView!)
    check(current.map { $0.app?.pid } == [pid_t(100), pid_t(200)], "Real rebuild preserves distinct window owners")
    var reportedSpace: String?
    dock.onReorder = { _, uuid in reportedSpace = uuid }
    current[0].onBeginDrag?(current[0])
    dock.spaceUUID = "changed"
    current[0].onEndDrag?(current[0])
    check(reportedSpace == "original", "Reorder reports the desktop captured before the drag")
    check(!dock.isVisible && !dock.isReordering, "Fixture remains hidden and finishes its drag")
}
runDockRefreshTests(check)

// macOS keeps reserving the Dock's edge in visibleFrame after Powerspaces hides the
// Dock, until something else refreshes it. While we hide it, only the menu bar counts.
do {
    let full = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let menuBar = CGRect(x: 0, y: 0, width: 1728, height: 1084)
    for dockEdge in [CGRect(x: 0, y: 90, width: 1728, height: 994), CGRect(x: 80, y: 0, width: 1648, height: 1084),
                     CGRect(x: 0, y: 0, width: 1648, height: 1084)] {
        check(DockPanel.usableFrame(visible: dockEdge, full: full, appleDockHidden: true) == menuBar,
              "A Dock hidden by Powerspaces reserves no edge: \(dockEdge)")
        check(DockPanel.usableFrame(visible: dockEdge, full: full, appleDockHidden: false) == dockEdge,
              "A visible macOS Dock keeps its edge reserved: \(dockEdge)")
    }
}
try? FileManager.default.removeItem(at: root) // exit() below skips a defer
check(!FileManager.default.fileExists(atPath: root.path), "Test files are removed before exit")
print("\(assertions) AppKit assertions, \(failures) failed; refresh scheduling, animations, 200 dock rebuilds and 200 hidden HUD lifetimes")
exit(failures == 0 ? 0 : 1)
