// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import ColorSync
import SpaceKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Typed as the seam: the dock path uses only `snapshot()` + `displays()`.
    private let provider: SpaceProviding = CGSSpaceProvider()
    private var config = StrategyConfig.load(from: StrategyConfig.defaultConfigURL)
    private let pins = PinStore(url: PinStore.defaultURL)
    private lazy var launcher = makeLauncher()
    /// One independent dock per display that should show one, keyed by display
    /// UUID. Reconciled as displays are attached/detached and as the "dock screens"
    /// preference changes (see `reconcileDocks`). Each dock shows and acts on its
    /// own screen, so two screens behave like two desktops.
    private var docks: [String: DockPanel] = [:]
    private let launcherPanel = AppLauncherPanel()
    /// The optional global shortcut that opens the App Launcher from anywhere. Lazy
    /// so its fire-closure can capture `self`; applied from `applyLauncherHotkey`.
    private lazy var launcherHotkey = GlobalHotkey { [weak self] in self?.launcherPanel.toggle() }
    private let strategySettings = StrategySettingsController()
    /// The menu-bar status item, its menu, and the menu's toggle actions. Most
    /// toggles just flip a preference; the three that need the app to do more are
    /// wired in via closures. `nil`-glyph state (no clickable item) is handled
    /// inside the controller. Lazy so the closures can capture `self`.
    private lazy var statusItemController = StatusItemController(
        onRefresh: { [weak self] in self?.refreshAction() },
        onOpenPreferences: { [weak self] in self?.openPreferences() },
        onAppLauncherDisabled: { [weak self] in self?.launcherPanel.close() })
    private var pollTimer: Timer?
    /// True while the poll is suspended because nothing is visible to update
    /// (display asleep or session switched away). Keeps the poll from re-arming
    /// until the screen/session comes back.
    private var isPollingPaused = false
    /// Consecutive poll ticks that found nothing changed. Drives the gentle
    /// backoff in `scheduleNextPoll`; reset to 0 on any change or workspace event.
    private var pollIdleTicks = 0
    /// The last validated list per display and desktop: what a returning desktop
    /// shows at once, how a poll tick tells whether the window world changed, and
    /// when a Space switch suppresses the per-icon animation (the whole bar swaps).
    private var memo = DockMemo()
    /// The displays (with their visible Space) from the last refresh, so click/pin
    /// handlers can resolve a dock's desktop UUID and screen bounds.
    private var displaySpaces: [DisplaySpaceInfo] = []
    /// The Apple-Dock-hidden state we've actually applied to the system, so a
    /// generic `preferencesDidChange` (which fires for *every* setting) only
    /// triggers the disruptive defaults-write + Dock restart when this toggle is
    /// what changed.
    private var appliedHideAppleDock = false
    /// The "faster desktop switch" states we've actually applied (swipe-override
    /// and keyboard-override), so a generic `preferencesDidChange` only re-applies
    /// the one that flipped — mirrors `appliedHideAppleDock`.
    private var appliedFasterDesktopSwitch = false
    private var appliedFasterKeyboardSwitch = false
    /// The faster-switch *preference* values we last acted on, so a generic
    /// `preferencesDidChange` (which fires for every setting) re-applies — and
    /// re-warns about Accessibility — only when the user actually flips one of these
    /// toggles, not on every unrelated change. Distinct from `applied*`, which tracks
    /// the real engine state and stays false while a wanted override waits on
    /// Accessibility (the accessibility watch covers that re-apply instead).
    private var lastFasterDesktopSwitchPref = false
    private var lastFasterKeyboardSwitchPref = false
    /// A short poll that watches for Accessibility being granted *after* launch, so
    /// a wanted-but-not-yet-installed override (its event tap needs Accessibility)
    /// switches itself on the moment permission arrives. Runs only while something
    /// is pending and stops itself once everything wanted is installed — see
    /// `startAccessibilityWatchIfNeeded`.
    private var accessibilityWatchTimer: Timer?
    /// Bounded pending work; app-launch requests coalesce until they finish.
    private var pendingActions: Set<String> = []
    private var launcherContext: LaunchContext?
    private lazy var dockRefresh = makeDockRefreshCoordinator()
    /// The last validated scan: the inventory with its titles and active window.
    private var latestSample: DockRefreshSample?
    /// Apps we've already told the user are effectively single-window — their
    /// "open a new window" attempt flashed a window on this desktop that the app
    /// then reaped (Claude does this since v1.1617.0 dropped multi-window). Warned
    /// once per session per app so a repeated click doesn't nag. See
    /// `verifyNewWindowLanded`.
    private var warnedSingleWindowBundleIDs: Set<String> = []

    /// Launcher actions can block — they shell out to `/usr/bin/open` and wait, and
    /// poll during quit-reopen / window-restore. Running them on this serial queue
    /// keeps a dock click from freezing the bar; the UI refresh hops back to main.
    /// (The CLI keeps calling the same `Launcher` synchronously, which is correct
    /// for a short-lived process.)
    private let launcherQueue = DispatchQueue(label: "nl.sebastianpdw.powerspaces.launcher", qos: .userInitiated)

    private func makeLauncher() -> Launcher {
        Launcher(provider: provider, config: config, launchRoute: .workspace,
                 warn: { message in DispatchQueue.main.async { MainActor.assumeIsolated { HUD.show(message) } } })
    }

    private func currentContext(for displayUUID: String? = nil) -> LaunchContext? {
        let display = displayUUID.flatMap { id in displaySpaces.first { $0.displayUUID == id } }
            ?? (displayUUID == nil ? displaySpaces.first { $0.isActive } : nil)
        return display.map(LaunchContext.init(display:))
    }

    /// A bounded serial executor. Repeated launches of the same app coalesce;
    /// every queued request validates its original desktop before side effects.
    private func runLauncher(context: LaunchContext? = nil, key: String = UUID().uuidString,
                             _ action: @escaping (Launcher) -> Void) {
        guard pendingActions.count < 8 else { HUD.show("Please wait for the pending dock actions to finish."); return }
        guard !pendingActions.contains(key), let context = context ?? currentContext() else { return }
        pendingActions.insert(key)
        let clicked = ProcessInfo.processInfo.systemUptime
        let ticket = ActionTicket(context: context, createdAt: clicked)
        let launcher = UnsafeTransfer(self.launcher)
        let action = UnsafeTransfer(action)
        launcherQueue.async { [weak self] in
            let began = ProcessInfo.processInfo.systemUptime
            let rejection = launcher.value.rejectionReason(for: ticket)
            if rejection == nil {
                action.value(launcher.value)
            }
            let ended = ProcessInfo.processInfo.systemUptime
            Log.notice("Dock action timing: waitedMs=\(Int((began - clicked) * 1000)) ranMs=\(Int((ended - began) * 1000)) rejected=\(rejection?.rawValue ?? "no")")
            Task { @MainActor in
                guard let self else { return }
                self.pendingActions.remove(key)
                if let rejection {
                    switch rejection {
                    case .expired:
                        HUD.show("Dock action expired while waiting. Try clicking again.")
                    case .snapshotUnavailable:
                        HUD.show("Dock action cancelled because the window list was unavailable. Try again.")
                    case .desktopChanged:
                        HUD.show("Dock action cancelled because this dock's desktop changed. Try again.")
                    case .nativeInteraction:
                        HUD.show("Dock action cancelled while the mouse button was held down. Try again.")
                    }
                }
                self.refresh()
            }
        }
    }

    private func runLaunch(target: AppTarget, context: LaunchContext? = nil,
                           _ action: @escaping (Launcher) -> LaunchOutcome?) {
        guard let context = context ?? currentContext() else { return }
        let key = "launch:" + (target.bundleID ?? target.name ?? "?")
        runLauncher(context: context, key: key) { [weak self] launcher in
            let outcome = action(launcher)
            Task { @MainActor in
                self?.verifyNewWindowLanded(outcome: outcome, target: target, launchSpace: context.spaceID)
            }
        }
    }

    /// If a new-window strategy claimed success, wait, then confirm the window is
    /// still there. We warn only on the true single-window signature: the app is
    /// still running, owns no window on the Space we opened it onto, *yet still has
    /// a real window on another desktop* — i.e. it reaped the fresh window and
    /// handed back to its existing instance. If it has no real window anywhere, the
    /// user just closed the window (or quit) themselves shortly after opening it;
    /// that is not single-window-by-design, so we stay quiet and don't mark the app
    /// as warned. Strategies that don't try to make a window *here* (`.focusOnly`,
    /// or the non-window `.warn`/`.quitReopen`, which never reach `.newWindow`) are
    /// skipped.
    private func verifyNewWindowLanded(outcome: LaunchOutcome?, target: AppTarget, launchSpace: SpaceID?) {
        guard case let .newWindow(kind) = outcome, kind != .focusOnly,
              let launchSpace, let bundleID = target.bundleID,
              !warnedSingleWindowBundleIDs.contains(bundleID) else { return }
        Task { @MainActor [weak self] in
            // The reap happens ~8 s after launch (measured); wait past that.
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self,
                  let snapshot = self.latestSample?.snapshot,
                  snapshot.isRunning(target),
                  snapshot.windows(of: target, onSpace: launchSpace).isEmpty,
                  // Hand-off to an existing instance leaves a real window on another
                  // desktop (we already know there's none on `launchSpace`). No real
                  // window anywhere ⇒ the user closed it themselves — don't warn.
                  !snapshot.realWindows(of: target).isEmpty
            else { return } // window stuck, app gone, or user-closed → nothing to warn about
            self.warnedSingleWindowBundleIDs.insert(bundleID)
            let name = target.name ?? bundleID
            HUD.show("\(name): the new window didn’t stay open. This app looks single-window by design. "
                     + "Right-click it → “When open elsewhere” → “Quit there and reopen here” or “Show a warning”.",
                     icon: Self.appIcon(forBundleID: bundleID))
        }
    }

    /// What to do about Accessibility at launch. Pure — no side effects, no globals —
    /// so the branching is easy to reason about (and unit-testable in isolation); the
    /// caller performs the side effects. See `applicationDidFinishLaunching`.
    ///
    /// - `welcome`: first run — show the welcome window.
    /// - `repairStaleGrant`: a faster-switch override is on but we're not actually
    ///   trusted (a stale TCC grant after a reinstall) — turn the overrides off and show
    ///   the repair popup instead of the misleading "faster switch needs Accessibility".
    /// - `prompt`: nothing pending — (re)prompt for Accessibility if not yet trusted.
    enum LaunchAccessibilityAction { case welcome, repairStaleGrant, prompt }

    static func decideLaunchAccessibility(hasSeenWelcome: Bool,
                                          trusted: Bool,
                                          fasterSwitchWanted: Bool) -> LaunchAccessibilityAction {
        guard hasSeenWelcome else { return .welcome }
        if !trusted && fasterSwitchWanted { return .repairStaleGrant }
        return .prompt
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No app bundle means no asset-catalog icon, so give the app a proper
        // Dock / app-switcher icon for when Preferences brings it forward.
        NSApp.applicationIconImage = AppIcon.image()
        // Bound every Accessibility call up front: window-title reads happen on this
        // (main) thread during a dock refresh, so an app that has itself wedged must
        // not be able to hang us waiting for an AX reply. See the function's note.
        capAccessibilityMessagingTimeout()
        // Decide how to handle Accessibility at launch (see `decideLaunchAccessibility`):
        //  • First run — show the welcome window that explains what Powerspaces does and
        //    why it needs Accessibility, with a button that triggers the system prompt.
        //  • Stale grant — a faster-switch override is on in preferences but macOS
        //    doesn't actually trust us. The unsigned app's TCC grant doesn't survive a
        //    reinstall/rebuild, so System Settings can still show it on while it's dead.
        //    The narrow "faster switch needs Accessibility" warning understates it — with
        //    no Accessibility *nothing* works — so turn the overrides off (the preference
        //    was lying) and show the repair popup, which offers a clean reset & re-grant.
        //  • Otherwise — just (re)prompt if we're still not trusted.
        // The stale-grant branch must run here, *before* the crash-recovery block below:
        // clearing `fasterKeyboardSwitch` lets that block force-restore the system space
        // hotkeys (a reinstall leaves them disabled at the system level, and only the
        // forcing restore re-enables them in a fresh process). It also runs before the
        // preferences observer is added, so these pref writes can't trigger a re-apply
        // cascade — same reasoning as `applyLoginItem` below.
        let fasterSwitchWanted = Preferences.shared.fasterDesktopSwitch
            || Preferences.shared.fasterKeyboardSwitch
        switch Self.decideLaunchAccessibility(
            hasSeenWelcome: Preferences.shared.hasSeenWelcome,
            trusted: AccessibilityPermission.isTrusted,
            fasterSwitchWanted: fasterSwitchWanted) {
        case .welcome:
            Preferences.shared.hasSeenWelcome = true
            WelcomeWindowController.show()
        case .repairStaleGrant:
            Preferences.shared.fasterDesktopSwitch = false
            Preferences.shared.fasterKeyboardSwitch = false
            AccessibilityRepairWindowController.show()
        case .prompt:
            promptForAccessibilityIfNeeded()
        }
        // Enforce the "hide Apple's Dock" preference at startup: if it's on, re-hide
        // (we restore the Dock on quit, so each launch must re-apply). If it's off,
        // leave the system Dock untouched — we never call apply(hidden:) here.
        appliedHideAppleDock = Preferences.shared.hideAppleDock
        AppleDockController.apply(hidden: appliedHideAppleDock)
        // Reconcile the "launch at login" preference with the real OS registration.
        // Runs before the preferences observer is added below, so the adopt-branch
        // write can't trigger a re-apply cascade.
        applyLoginItem()
        // Recover before reading/adopting shortcut bindings, even when the
        // keyboard override is still wanted after a crash.
        FasterDesktopSwitch.installFailureHandler()
        if FasterDesktopSwitch.restoreSpaceHotkeys(
            legacyRecovery: Preferences.shared.spaceHotkeysDisabledByUs) {
            Preferences.shared.spaceHotkeysDisabledByUs = false
        } else {
            HUD.show(FasterDesktopSwitch.unavailableMessage, force: true)
        }
        applyFasterDesktopSwitch()  // install the swipe-override tap if it's on
        applyFasterKeyboardSwitch() // take over the keyboard shortcut if it's on
        // If either override is on but couldn't install (Accessibility not granted
        // yet — the common case right after a reinstall / permission reset), watch
        // for the grant and install it then, instead of leaving it on-but-dead.
        startAccessibilityWatchIfNeeded()
        statusItemController.sync()
        setupObservers()
        launcherPanel.onPresent = { [weak self] screen in
            self?.launcherContext = self?.currentContext(for: screen?.displayUUID)
        }
        launcherPanel.onLaunch = { [weak self] app, forceNew in
            guard let self, let context = self.launcherContext else { return }
            self.runLaunch(target: app.target, context: context) {
                try? $0.dockClick(target: app.target, forceNew: forceNew, context: context)
            }
        }
        applyLauncherHotkey() // register the global launcher shortcut if one is set
        InstalledAppsStore.shared.reload() // pre-warm the app list so the launcher opens instantly
        // The strategy controller writes config.json; reload it into the live
        // launcher and refresh so the docks' submenu ticks update.
        strategySettings.onChanged = { [weak self] in
            guard let self else { return }
            self.config = StrategyConfig.load(from: StrategyConfig.defaultConfigURL)
            self.launcher = self.makeLauncher()
            self.refresh()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesDidChange),
            name: .preferencesDidChange, object: nil)
        // Build the docks for the displays that should have one. `refresh()` calls
        // `reconcileDocks`, which creates, configures, and shows each panel.
        refresh()
    }

    // MARK: - Per-display docks

    private func pinsChanged(_ succeeded: Bool) {
        if !succeeded { HUD.show("Could not save the dock change. Check the pins file or retry after another settings operation finishes.") }
        memo.forget()
        refresh()
    }

    /// Wire a freshly created dock's callbacks. `displayUUID` ties the panel to its
    /// display so pins, the dock-color editor, and (on a multi-display setup) the
    /// screen a new window opens on all target *this* dock's desktop rather than
    /// the active one.
    private func configure(_ dock: DockPanel, displayUUID: String) {
        dock.onSelect = { [weak self] app, forceNew in
            guard let self else { return }
            // A per-window icon ("Windows" feature) carries the exact window to
            // act on; a normal icon routes through the smart-launch decision. The
            // dock's own display is the preferred screen for a new window, and its
            // visible desktop is what the click judges "here" against.
            guard let context = self.currentContext(for: displayUUID) else { return }
            self.runLaunch(target: app.target, context: context) { launcher in
                if let windowID = app.windowID, let pid = app.pid {
                    return try? launcher.dockClickWindow(windowID: windowID, pid: pid,
                                                         target: app.target, forceNew: forceNew,
                                                         context: context)
                }
                return try? launcher.dockClick(target: app.target, forceNew: forceNew,
                                               context: context)
            }
        }
        dock.onPinHere = { [weak self] app in
            guard let self, let uuid = self.spaceUUID(forDisplay: displayUUID),
                  let bundleID = app.bundleID else { return }
            self.pinsChanged(self.pins.toggle(bundleID, onSpace: uuid))
        }
        dock.onPinEverywhere = { [weak self] app in
            guard let self, let bundleID = app.bundleID else { return }
            self.pinsChanged(self.pins.toggleEverywhere(bundleID))
        }
        // "Unpin (this desktop)" on an all-desktops pin: hide it here only, leaving
        // it pinned on every other desktop (or show it again if already hidden).
        dock.onToggleHereForEverywhere = { [weak self] app in
            guard let self, let uuid = self.spaceUUID(forDisplay: displayUUID),
                  let bundleID = app.bundleID else { return }
            self.pinsChanged(self.pins.toggleEverywhereException(bundleID, onSpace: uuid))
        }
        dock.onCloseThisDesktop = { [weak self] app in
            guard let self else { return }
            guard let context = self.currentContext(for: displayUUID) else { return }
            self.runLauncher(context: context) { [weak self] launcher in
                if case let .closed(count) = try? launcher.closeOnCurrentDesktop(target: app.target, context: context), count > 0 {
                    Task { @MainActor in self?.scheduleReap(app) }
                }
            }
        }
        dock.onCloseAllDesktops = { [weak self] app in
            self?.runLauncher { $0.quitApp(target: app.target) }
        }
        dock.onCloseWindow = { [weak self] app in
            guard let windowID = app.windowID, let pid = app.pid else { return }
            guard let self, let context = self.currentContext(for: displayUUID) else { return }
            self.runLauncher(context: context) { [weak self] launcher in
                if case .closed(1) = launcher.closeWindow(windowID: windowID, pid: pid, target: app.target, context: context) {
                    Task { @MainActor in self?.scheduleReap(app) }
                }
            }
        }
        dock.onDropApp = { [weak self] bundleID, order, uuid in
            guard let self else { return }
            guard let uuid, uuid == self.spaceUUID(forDisplay: displayUUID) else {
                HUD.show("Drop cancelled because the dock's desktop changed. Try again."); self.refresh(); return
            }
            self.pinsChanged(self.pins.pinAndReorder(bundleID, onSpace: uuid, visibleOrder: order))
        }
        dock.onReorder = { [weak self] keys, uuid in
            guard let self else { return }
            guard let uuid, uuid == self.spaceUUID(forDisplay: displayUUID) else {
                HUD.show("Reorder cancelled because the dock's desktop changed. Try again."); self.refresh(); return
            }
            self.pinsChanged(self.pins.reorderVisible(keys, onSpace: uuid))
        }
        dock.currentStrategy = { [weak self] app in
            self?.config.strategy(for: app.bundleID) ?? .newInstance
        }
        // App Launcher: the tile toggles the all-apps grid; a launch from the grid
        // routes through the same smart-launch path a dock click uses, so the app
        // opens on the current desktop. Open it on the clicked dock's screen so it
        // appears on the desktop the user is looking at, not the menu-bar screen.
        dock.onOpenLauncher = { [weak self] in
            self?.launcherPanel.toggle(on: self?.screen(forDisplay: displayUUID))
        }
        // Right-click the dock → "Open Preferences": the fallback path in when the
        // menu-bar item is set to Hidden (then there's no icon left to click).
        dock.onOpenPreferences = { [weak self] in self?.openPreferences() }
        // Right-click the dock → open this dock's desktop's dock color editor.
        dock.onEditDockColor = { [weak self] in self?.editDockColor(forDisplay: displayUUID) }
        dock.onDisableLauncher = { [weak self] in
            self?.launcherPanel.close()
            Preferences.shared.appLauncherEnabled = false // posts preferencesDidChange → refresh
        }
        dock.onSetStrategy = { [weak self] app, kind in
            guard let self, let bundleID = app.bundleID else { return }
            _ = self.strategySettings.setStrategy(kind, forBundleID: bundleID, name: app.name)
        }
    }

    /// Create docks for displays that should have one and remove docks for displays
    /// that no longer should (preference changed) or have been detached. Idempotent,
    /// so it's safe to call on every refresh, preference change, and screen change.
    private func reconcileDocks(displays: [DisplaySpaceInfo]) {
        let prefs = Preferences.shared
        let desired = displays.filter { prefs.showsDockOnDisplay($0.displayUUID) }
        let desiredUUIDs = Set(desired.map(\.displayUUID))
        // Tear down docks that are no longer wanted or whose display is gone.
        // Collect the keys first — mutating `docks` while iterating it is unsafe.
        let toRemove = docks.keys.filter { !desiredUUIDs.contains($0) }
        for uuid in toRemove {
            docks[uuid]?.orderOut(nil)
            docks[uuid]?.close()
            docks[uuid] = nil
        }
        // Bring up docks for newly wanted displays.
        for info in desired where docks[info.displayUUID] == nil {
            guard let screen = self.screen(forDisplay: info) else { continue }
            let dock = DockPanel(screen: screen)
            configure(dock, displayUUID: info.displayUUID)
            docks[info.displayUUID] = dock
            dock.show()
            dock.applyAppearance()
        }
    }

    /// The `NSScreen` for a display info, matched by UUID, falling back to its
    /// global bounds (in case the window-server UUID and Core Graphics UUID differ).
    private func screen(forDisplay info: DisplaySpaceInfo) -> NSScreen? {
        if let byUUID = NSScreen.screens.first(where: { $0.displayUUID == info.displayUUID }) {
            return byUUID
        }
        return NSScreen.screens.first { CGDisplayBounds($0.displayID) == info.bounds }
    }

    /// The visible-Space UUID of a display (for pin lookups), from the last refresh.
    private func spaceUUID(forDisplay uuid: String) -> String? {
        let value = displaySpaces.first { $0.displayUUID == uuid }?.currentSpaceUUID
        return (value?.isEmpty == false) ? value : nil
    }
    /// The `NSScreen` for this display, or nil if it isn't currently attached — used
    /// to open the App Launcher on the screen whose dock tile was clicked.
    private func screen(forDisplay uuid: String) -> NSScreen? {
        NSScreen.screens.first { $0.displayUUID == uuid }
    }

    /// Never leave the user without any dock: if we hid Apple's, bring it back when
    /// Powerspaces exits. The preference stays on, so the next launch re-hides it —
    /// the only window where the Dock stays hidden with us gone is after a crash
    /// (recoverable by toggling the setting or relaunching).
    func applicationWillTerminate(_ notification: Notification) {
        // Unconditional: it restores only what a recovery record says we changed,
        // which includes a restore that was still waiting when the app quit.
        AppleDockController.apply(hidden: false, now: true)
        // Remove the event tap and restore the system space-switch hotkeys cleanly.
        FasterDesktopSwitch.setSwipeEnabled(false)
        FasterDesktopSwitch.setKeyboardEnabled(false)
        Preferences.shared.spaceHotkeysDisabledByUs = FasterDesktopSwitch.hotkeysNeedRestore
        accessibilityWatchTimer?.invalidate()
        accessibilityWatchTimer = nil
    }

    /// Reconcile the "launch at login" preference with the OS login-item state at
    /// startup. The OS persists the registration itself, so this never has to apply it
    /// on every launch — it only fixes the two ways the two can drift, and never
    /// silently turns the login item off:
    ///   • pref on, OS off → re-register (a reinstall clears the per-bundle registration).
    ///   • pref off, OS on → adopt it as the preference (e.g. enabled before it was a
    ///     tracked setting, or via System Settings) rather than disabling it.
    private func applyLoginItem() {
        let prefs = Preferences.shared
        if prefs.launchAtLogin {
            if !LoginItem.isEnabled { try? LoginItem.setEnabled(true) }
        } else if LoginItem.isEnabled {
            prefs.launchAtLogin = true
        }
    }

    /// Apply the swipe "faster desktop switch" preference: install or remove the
    /// swipe-override event tap. If enabling fails — almost always missing
    /// Accessibility — warn once via the HUD; the accessibility watch then installs
    /// it the moment permission is granted (see `startAccessibilityWatchIfNeeded`).
    private func applyFasterDesktopSwitch(requestPermission: Bool = false) {
        let want = Preferences.shared.fasterDesktopSwitch
        lastFasterDesktopSwitchPref = want
        if want && requestPermission { AccessibilityPermission.promptForFastSwitch(userInitiated: true) }
        let ok = FasterDesktopSwitch.setSwipeEnabled(want)
        // Track what's *actually* installed, not what's merely wanted: a failed
        // enable (no Accessibility yet) leaves this false, so the watch re-applies
        // it on grant rather than the toggle looking on while the tap is absent.
        appliedFasterDesktopSwitch = want && ok
        if want && !ok { warnFasterSwitchUnavailable() }
    }

    /// Apply the keyboard "faster desktop switch" preference: take over (or release)
    /// the user's "Move left/right a space" shortcut. Records whether we've disabled
    /// the system hotkeys so a crash can be recovered from on the next launch.
    private func applyFasterKeyboardSwitch(requestPermission: Bool = false) {
        let want = Preferences.shared.fasterKeyboardSwitch
        lastFasterKeyboardSwitchPref = want
        if want && requestPermission { AccessibilityPermission.promptForFastSwitch(userInitiated: true) }
        let ok = FasterDesktopSwitch.setKeyboardEnabled(want)
        // New engine recovery is durable and stores exact states. The old
        // boolean is retained solely to migrate runs of older app versions.
        if ok || FasterDesktopSwitch.hotkeysNeedRestore {
            Preferences.shared.spaceHotkeysDisabledByUs = false
        }
        // As with the swipe: only count it applied if the tap actually installed,
        // so a failed (ungranted) enable is retried by the watch.
        appliedFasterKeyboardSwitch = want && ok
        if want && !ok { warnFasterSwitchUnavailable() }
    }

    private func warnFasterSwitchUnavailable() {
        HUD.show(FasterDesktopSwitch.unavailableMessage, force: true)
    }

    /// A "faster desktop switch" override is turned on in preferences but isn't
    /// actually installed because AX or event-posting approval is pending. `applied*` tracks
    /// the real engine state, so a failed enable leaves its flag false.
    private var fasterSwitchAwaitingPermission: Bool {
        FasterDesktopSwitch.awaitingPermission &&
            ((Preferences.shared.fasterDesktopSwitch && !appliedFasterDesktopSwitch)
            || (Preferences.shared.fasterKeyboardSwitch && !appliedFasterKeyboardSwitch))
    }

    /// Start (or stop) the accessibility watch to match what's pending. While an
    /// override is waiting for permission it checks AX and event-posting access
    /// once a second and re-applies the pending override after both are approved — so a
    /// freshly reinstalled / permission-reset app turns its overrides on by itself,
    /// instead of showing them "on" while they do nothing until toggled off and on.
    /// Idempotent and self-terminating: it stops once nothing is pending, so there's
    /// no idle timer in the steady state. Mirrors the `pollTimer` scheduling pattern.
    private func startAccessibilityWatchIfNeeded() {
        guard fasterSwitchAwaitingPermission else {
            accessibilityWatchTimer?.invalidate()
            accessibilityWatchTimer = nil
            return
        }
        guard accessibilityWatchTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // Fires on the main run loop, so we're already on the main actor.
            MainActor.assumeIsolated { self?.accessibilityWatchTick() }
        }
        accessibilityWatchTimer = timer
    }

    private func accessibilityWatchTick() {
        // An AX grant may precede event-posting approval. Request the latter
        // once, without repeatedly showing a prompt while this timer waits.
        AccessibilityPermission.promptForFastSwitch()
        guard FasterDesktopSwitch.hasAccess else { return }
        if Preferences.shared.fasterDesktopSwitch && !appliedFasterDesktopSwitch {
            applyFasterDesktopSwitch()
        }
        if Preferences.shared.fasterKeyboardSwitch && !appliedFasterKeyboardSwitch {
            applyFasterKeyboardSwitch()
        }
        // Re-evaluate: stops the timer once everything wanted is installed.
        startAccessibilityWatchIfNeeded()
    }

    @objc private func openPreferences() {
        PreferencesWindowController.show(strategies: strategySettings)
    }

    /// Open the per-desktop dock color editor for the desktop shown on the given
    /// display. The override it writes is keyed by that desktop's Space UUID, so it
    /// leaves every other desktop (and every other screen) on the default color.
    private func editDockColor(forDisplay displayUUID: String) {
        guard let uuid = spaceUUID(forDisplay: displayUUID) else {
            HUD.show("Couldn't tell which desktop is on that screen, so the dock color can't be "
                     + "set here. Try again in a moment.", force: true)
            return
        }
        DockColorWindowController.show(spaceUUID: uuid)
    }

    /// The Finder icon for a bundle id, used to brand a HUD banner. nil if unresolved.
    private static func appIcon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Register (or clear) the global App Launcher shortcut to match the preference.
    /// Cheap and idempotent — the hotkey wrapper tears down any old combo first — so
    /// it's safe to call on launch and on every preference change.
    private func applyLauncherHotkey() {
        let hotkey = Preferences.shared.launcherHotkey
        launcherHotkey.apply(keyCode: hotkey.keyCode, modifiers: hotkey.carbonModifiers)
    }

    @objc private func preferencesDidChange() {
        // Only touch the system Dock when this specific toggle flipped — every
        // preference change posts this notification, and rewriting defaults +
        // restarting the Dock on each one would be jarring.
        if Preferences.shared.hideAppleDock != appliedHideAppleDock {
            appliedHideAppleDock = Preferences.shared.hideAppleDock
            AppleDockController.apply(hidden: appliedHideAppleDock)
            repositionAfterAppleDockRestart()
        }
        // Same "only act when this toggle flipped" guard for the two overrides —
        // compared against the last *preference* value (not the applied engine state)
        // so an override that's on but waiting on Accessibility doesn't re-apply and
        // re-show its warning on every unrelated preference change.
        if Preferences.shared.fasterDesktopSwitch != lastFasterDesktopSwitchPref {
            applyFasterDesktopSwitch(requestPermission: true)
        }
        if Preferences.shared.fasterKeyboardSwitch != lastFasterKeyboardSwitchPref {
            applyFasterKeyboardSwitch(requestPermission: true)
        }
        // An override may have just been enabled while still ungranted (now pending),
        // or disabled (no longer pending) — start or stop the watch to match.
        startAccessibilityWatchIfNeeded()
        applyLauncherHotkey() // the launcher shortcut may have changed
        statusItemController.sync() // the glyph may have changed — create / remove / restyle the item
        restartPoll() // the interval may have changed
        docks.values.forEach { $0.applyAppearance() }
        memo.forget() // a setting may have changed what the docks list
        // The "dock screens" setting may have flipped; refresh() reconciles which
        // displays have a dock.
        refresh()
    }

    /// A shown macOS Dock reaches `visibleFrame` only once the restarted Dock is up,
    /// after the rebuild that follows the toggle, and its screen-change notification
    /// does not always arrive. So re-place every dock twice, bounded, to rise above
    /// it. Hiding needs none of this: `DockPanel.usableFrame` ignores the Dock's edge.
    private func repositionAfterAppleDockRestart() {
        Task { @MainActor [weak self] in
            for (elapsed, wait) in [(1, 1.0), (3, 2.0)] {
                try? await Task.sleep(for: .seconds(wait))
                guard let self else { return }
                for dock in self.docks.values { dock.reposition() }
                let inset = NSScreen.main.map { Int($0.visibleFrame.minY - $0.frame.minY) } ?? -1
                Log.notice("Apple Dock: repositioned \(self.docks.count) docks \(elapsed)s after the Dock change, main screen bottom inset=\(inset)")
            }
        }
    }

    /// The most the poll interval can stretch when nothing is changing — small,
    /// so a window open/close (which posts no notification) still appears within a
    /// few seconds even at full backoff.
    private static let maxPollBackoff = 3.0

    /// (Re)start the poll at the base interval, clearing any idle backoff.
    private func restartPoll() {
        pollIdleTicks = 0
        scheduleNextPoll()
    }

    /// Arm the next one-shot poll. The interval is the user's base rate, gently
    /// stretched the longer the window world has sat unchanged (`pollIdleTicks`)
    /// up to `maxPollBackoff`× — so an idle desktop is polled less often, while
    /// any change or workspace event snaps it back to the snappy base rate.
    private func scheduleNextPoll() {
        pollTimer?.invalidate()
        pollTimer = nil
        // Nothing to poll for while the dock can't be seen — wait for resume.
        guard !isPollingPaused else { return }
        let base = Preferences.shared.pollInterval
        let factor = min(1.0 + Double(pollIdleTicks) * 0.5, AppDelegate.maxPollBackoff)
        let interval = pollIdleTicks >= 4 ? max(2.0, base * factor) : base * factor
        // One-shot, scheduled in the default run-loop mode (like the old repeating
        // timer) so it never fires under an open context menu or mid-drag and
        // rebuilds the bar out from under the user. It re-arms itself in pollTick.
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            // Fires on the main run loop (default mode), so we're already on the main actor.
            MainActor.assumeIsolated { self?.pollTick() }
        }
        // Let macOS coalesce these wake-ups with other timers — a real energy win
        // for an all-day agent, with no effect on how fresh the dock feels.
        timer.tolerance = interval * 0.1
        pollTimer = timer
    }

    /// One poll: refresh, then grow or reset the backoff based on whether anything
    /// changed, and arm the next tick.
    private func pollTick() {
        FasterDesktopSwitch.checkHealth()
        if FasterDesktopSwitch.awaitingPermission {
            appliedFasterDesktopSwitch = false
            appliedFasterKeyboardSwitch = false
            startAccessibilityWatchIfNeeded()
        }
        refresh() // Completion re-arms the timer; slow reads never build a backlog.
    }

    private func setupObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(desktopChanged),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        for name in names {
            nc.addObserver(self, selector: #selector(refreshAction), name: name, object: nil)
        }
        // Suspend the poll entirely while nothing is visible to update — the
        // display is asleep, or the login session is switched away — and resume
        // (with a catch-up refresh) when it comes back. Saves battery on idle.
        nc.addObserver(self, selector: #selector(suspendPolling),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(suspendPolling),
                       name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(resumePolling),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(resumePolling),
                       name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        // A display attached/detached or rearranged: add/remove docks and
        // reposition the survivors. Posted on the default center by NSApplication.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Re-apply appearance when the system's accessibility display settings change
        // (Reduce Motion / Reduce Transparency), so the dock adapts without a relaunch.
        nc.addObserver(self, selector: #selector(systemDisplaySettingsChanged),
                       name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        // And when the user switches between light and dark, so colours we set on
        // layers (rather than semantic system colours) refresh too.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(systemDisplaySettingsChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        // Window open/close don't post workspace notifications; poll lightly at
        // the user's chosen interval.
        restartPoll()
    }

    /// A system appearance or accessibility-display setting changed (light/dark,
    /// Reduce Motion, Reduce Transparency). Re-apply each dock's appearance and
    /// refresh so the change takes effect live. Delivered on the main run loop.
    @objc private func systemDisplaySettingsChanged() {
        docks.values.forEach { $0.applyAppearance() }
        refresh()
    }

    /// The display layout changed (monitor plugged/unplugged or rearranged):
    /// reconcile which displays have a dock and refresh their contents.
    @objc private func screensChanged() {
        pollIdleTicks = 0
        memo.forget()
        refresh(desktopChanged: true)
        // refresh() adds/removes docks but leaves survivors where they are, and a
        // pure geometry change doesn't alter their contents (so no rebuild → no
        // reposition). Re-place every surviving dock on its (possibly moved) screen
        // here, matching the doc-comment on the screen-change observer. A dock whose
        // display is still coming back has a nil boundScreen and skips safely; the
        // follow-up screen-change event places it once that display returns.
        for dock in docks.values { dock.reposition() }
    }

    @objc private func refreshAction() {
        // An app launch-quit-activate event or a manual
        // refresh just updated us — drop back to the snappy base poll rate.
        pollIdleTicks = 0
        refresh()
    }

    @objc private func desktopChanged() {
        pollIdleTicks = 0
        refresh(desktopChanged: true)
    }

    /// Stop the poll while the screen is asleep / the session is switched away —
    /// there's no dock on screen, so the wake-ups would just drain the battery.
    @objc private func suspendPolling() {
        isPollingPaused = true
        dockRefresh.suspend()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Screen woke / session returned: refresh once to catch up, then resume the
    /// light poll.
    @objc private func resumePolling() {
        guard isPollingPaused else { return }
        isPollingPaused = false
        restartPoll()
        refresh(desktopChanged: true)
    }

    /// Rebuild every dock's contents from the live snapshot, one per display.
    /// Reconciles which displays have a dock first (so a plugged-in monitor or a
    /// flipped preference takes effect), then fills each from its display's visible
    /// Space. Sampling is off-main; overlapping events coalesce into one resample.
    private func refresh(desktopChanged: Bool = false) {
        guard !isPollingPaused else { return }
        pollTimer?.invalidate(); pollTimer = nil
        dockRefresh.request(options: .init(labels: Preferences.shared.showWindowLabels,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier), desktopChanged: desktopChanged)
    }

    private func makeDockRefreshCoordinator() -> DockRefreshCoordinator {
        let provider = UnsafeTransfer(self.provider)
        let coordinator = DockRefreshCoordinator(readSample: { options in
            let startDisplays = provider.value.displays()
            let snapshot = try? provider.value.snapshot()
            var titles: [CGWindowID: String] = [:]
            let titleDeadline = ProcessInfo.processInfo.systemUptime + 2
            let reader = WindowTitleReader(deadline: titleDeadline)
            if options.labels, let snapshot {
                for window in snapshot.windows {
                    guard ProcessInfo.processInfo.systemUptime < titleDeadline else { break }
                    if let title = reader.title(windowID: window.windowID, pid: window.pid) { titles[window.windowID] = title }
                }
            }
            let active = options.labels && ProcessInfo.processInfo.systemUptime < titleDeadline
                ? options.frontmostPID.flatMap { reader.mainWindowID(pid: $0) } : nil
            // Read last: the titles above also depend on the desktop showing.
            return DockRefreshSample(snapshot: snapshot, startDisplays: startDisplays,
                                     displays: provider.value.displays(), titles: titles, active: active)
        }, readDisplays: { provider.value.displays() })
        coordinator.onSample = { [weak self] result in
            guard let self, !self.isPollingPaused, let snapshot = result.snapshot, !result.displays.isEmpty else { return }
            self.latestSample = result
            let changed = self.applyRefresh(snapshot: snapshot, sample: result)
            self.pollIdleTicks = changed ? 0 : self.pollIdleTicks + 1
        }
        // A desktop change shows each dock's memo at once or, on a first visit, the last
        // inventory projected onto its desktop; the scan that follows corrects it.
        coordinator.onDisplays = { [weak self] displays in
            guard let self else { return }
            self.displaySpaces = displays
            _ = self.render(displays) { dock, info in
                self.memo.recall(info) {
                    guard let sample = self.latestSample, let snapshot = sample.snapshot else { return nil }
                    return self.dockLists(snapshot: snapshot.placedWindowsOnly(), sample: sample)(dock, info)
                }
            }
        }
        coordinator.onIdle = { [weak self] in self?.scheduleNextPoll() }
        return coordinator
    }

    private func applyRefresh(snapshot: SpaceSnapshot, sample: DockRefreshSample) -> Bool {
        _ = pins.reload()
        displaySpaces = sample.displays
        let list = dockLists(snapshot: snapshot, sample: sample)
        // A Space switch swaps the whole bar at once; the memo suppresses the
        // per-icon join/leave animation for that one rebuild.
        return render(sample.displays) { dock, info in memo.store(list(dock, info), for: info) }
    }

    /// How each dock's list is built from an inventory and the titles read with it.
    /// The scan and the projection (a first visit to a desktop) both list through here.
    private func dockLists(snapshot: SpaceSnapshot, sample: DockRefreshSample)
        -> (DockPanel, DisplaySpaceInfo) -> [DockApp] {
        // Used only for optional windowless dock entries, never for termination.
        let pidsWithWindows = snapshot.windowOwnerPIDs
        let prefs = Preferences.shared
        // "Show apps with no open windows": running, regular (Dock-showing) apps
        // with no window anywhere in this snapshot — computed from the *full*
        // snapshot (so a ⌘-hidden app, which still has windows, isn't mistaken for
        // window-less) and shown on every desktop's dock since they have no window
        // tying them to one. Off → empty, so nothing extra is injected.
        let windowlessApps = prefs.showWindowlessApps ? Self.windowlessApps(pidsWithWindows: pidsWithWindows) : []
        // "Show hidden windows": when off, drop ⌘-hidden apps' windows before
        // building the docks, so a hidden app disappears until it's unhidden.
        let displaySnapshot = prefs.showHiddenWindows ? snapshot : snapshot.droppingHiddenWindows()
        // "Windows" feature: per-window icons, and/or the wide window-title mode
        // (which is also one item per window). Both expand the app list per window.
        let options = DockRefresher.DisplayOptions(
            expandPerWindow: prefs.showIconPerWindow || prefs.showWindowLabels,
            shouldLabel: { prefs.showsWindowLabel(windowCount: $0) })
        // Titles and active-window identity were sampled off-main once per app.
        // The active/forefront window — the frontmost app's main window — so the
        // wide window-title mode can render that bar's title in bold. It's a single
        // global window, so read it once per refresh and reuse across every dock.
        // Only computed in label mode: otherwise a focus change would flip an item
        // and needlessly rebuild the icon-only bars.
        let activeWindowID = prefs.showWindowLabels ? sample.active : nil

        // Every attached display's bounds (top-left origin, matching window centers),
        // so the per-display filter can keep a window whose center has transiently
        // slid off this display during a native desktop switch (it's on *no* display
        // then, not another one) instead of dropping it — which emptied the bar.
        let allDisplayBounds = NSScreen.screens
            .map { CGDisplayBounds($0.displayID) }.filter { $0 != .zero }
        return { [pins] dock, info in
            // Authoritative live bounds for this dock's screen (the window-server
            // value can be .zero if a UUID didn't resolve; the panel's own display
            // is always valid).
            let displayBounds = CGDisplayBounds(dock.boundDisplayID) != .zero
                ? CGDisplayBounds(dock.boundDisplayID) : info.bounds
            let spaceUUID = info.currentSpaceUUID.isEmpty ? nil : info.currentSpaceUUID
            let display = DockRefresher.displayApps(
                onDisplay: displayBounds,
                snapshot: displaySnapshot,
                // This display's visible Space, so a window minimized on another
                // desktop of the same display doesn't leak into this bar (it's
                // off-screen-but-real, hence otherwise counted purely by geometry).
                visibleSpace: info.currentSpaceID,
                allDisplays: allDisplayBounds,
                pinnedHere: spaceUUID.map { pins.spacePins(onSpace: $0) } ?? [],
                pinnedEverywhere: pins.everywherePins(),
                excludedHere: spaceUUID.map { pins.everywhereExceptions(onSpace: $0) } ?? [],
                order: spaceUUID.map { pins.order(onSpace: $0) } ?? [],
                includeLauncher: prefs.appLauncherEnabled,
                windowlessApps: windowlessApps,
                options: options,
                nameForBundleID: AppDelegate.appName(for:),
                titleForWindow: { id, _ in sample.titles[id] })
            // Flag the bar standing for the forefront window (matched by the same
            // window id the title attach uses) so the panel can bold it. nil id —
            // labels off, or no main window — leaves every item unflagged.
            return activeWindowID.map { active in
                display.map { $0.withActive(($0.windowID ?? $0.windowIDs.first) == active) }
            } ?? display
        }
    }

    /// Put every dock on its display's desktop, then show the list `list` gives for
    /// it, if any. A desktop change and the scan both render through here.
    private func render(_ displays: [DisplaySpaceInfo],
                        list: (DockPanel, DisplaySpaceInfo) -> DockMemo.Render?) -> Bool {
        // The active display's desktop number, for the optional menu-bar readout.
        statusItemController.updateDesktop(
            (displays.first(where: { $0.isActive })?.spaceIndex).flatMap { $0 > 0 ? $0 : nil })
        // Create/remove docks to match the displays that should have one.
        reconcileDocks(displays: displays)
        var anyChanged = false
        for (uuid, dock) in docks {
            guard let info = displays.first(where: { $0.displayUUID == uuid }) else { continue }
            // Tell the bar which desktop it's on so it can paint that desktop's
            // custom dock color (re-tints when this changes — e.g. on a Space switch).
            dock.spaceUUID = info.currentSpaceUUID.isEmpty ? nil : info.currentSpaceUUID
            // The desktop's 1-based number, for the glanceable indicator badge.
            dock.desktopNumber = info.spaceIndex > 0 ? info.spaceIndex : nil
            // Hide / auto-hide / show the bar on a screen showing a full-screen app,
            // per the full-screen dock preference (a no-op while the state is unchanged).
            dock.applyFullscreenState(info.isFullscreen)
            guard let render = list(dock, info) else { continue }
            dock.update(apps: render.apps, animateChanges: render.animate)
            guard render.changed else { continue }
            anyChanged = true
            Log.notice("Dock render: source=\(render.source) display=\(uuid.prefix(8)) space=\(info.currentSpaceID) icons=\(render.apps.count)")
        }
        return anyChanged
    }

    /// Only an explicit, successful close from our own dock can arm the opt-in
    /// reaper. Filtered disappearance during Mission Control never arms it.
    private func scheduleReap(_ app: DockApp) {
        guard Preferences.shared.quitOnLastWindowClose, let pid = app.pid,
              let running = NSRunningApplication(processIdentifier: pid), let launched = running.launchDate else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, Preferences.shared.quitOnLastWindowClose else { return }
            self.launcherQueue.async {
                guard let current = NSRunningApplication(processIdentifier: pid),
                      current.launchDate == launched, !current.isTerminated,
                      current.activationPolicy == .regular,
                      WindowInventory.confirmsNoWindows(pid: pid),
                      current.launchDate == launched, !current.isTerminated else { return }
                Log.notice("Quit requested: app=\(current.bundleIdentifier ?? "unknown") pid=\(pid) reason=explicit-close-cleanup")
                current.terminate() // Always polite; never force-kill.
            }
        }
    }

    /// Running regular apps with no listed windows, for the optional dock entries.
    private static func windowlessApps(pidsWithWindows: Set<pid_t>) -> [DockApp] {
        NSWorkspace.shared.runningApplications.compactMap { app -> DockApp? in
            let pid = app.processIdentifier
            guard isReapableRegularApp(app), let bundleID = app.bundleIdentifier,
                  !pidsWithWindows.contains(pid) else { return nil }
            let name = app.localizedName ?? appName(for: bundleID) ?? bundleID
            return DockApp(bundleID: bundleID, name: name, pid: pid, windowCount: 0)
        }
    }

    /// A running app eligible for the window-less treatments above: a regular
    /// (Dock-showing) app that's alive and isn't Powerspaces itself. Background
    /// agents, accessories, and our own process never qualify.
    private static func isReapableRegularApp(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && !app.isTerminated
            && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }

    private static func appName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return AppResolver.displayName(forAppURL: url)
    }

    private func promptForAccessibilityIfNeeded() {
        AccessibilityPermission.prompt()
    }
}

/// Carries a non-`Sendable` value across a single, known-safe concurrency hop — here a
/// value-type `Launcher` copy and its action closure handed to the serial launcher
/// queue, which runs one at a time before the result returns to the main actor. The
/// `@unchecked Sendable` is the explicit assertion that nothing else touches the value
/// concurrently.
private struct UnsafeTransfer<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
