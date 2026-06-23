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
    /// The last display list we pushed to each dock (keyed by display UUID), so a
    /// poll tick can tell whether the window world actually changed (the dock
    /// dedupes internally but doesn't report back, and skips updates mid-drag).
    private var lastDisplayByDisplay: [String: [DockApp]] = [:]
    /// The last visible-Space UUID seen per display, so a Space switch on that
    /// display suppresses the per-icon join/leave animation (the whole bar swaps).
    private var lastSpaceByDisplay: [String: String] = [:]
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
    /// Close-to-quit bookkeeping (experimental `quitOnLastWindowClose`): the pids
    /// that had ≥1 window on the previous refresh, and the pids that just went
    /// window-less and are awaiting a one-tick confirmation before being quit.
    /// See `reapWindowlessInstances`.
    private var pidsWithWindowsLastRefresh: Set<pid_t> = []
    private var reapPendingPids: Set<pid_t> = []
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
        Launcher(provider: provider, config: config,
                 warn: { message in DispatchQueue.main.async { MainActor.assumeIsolated { HUD.show(message) } } })
    }

    /// Run a (possibly blocking) launcher action off the main thread, then refresh
    /// the dock back on main. `Launcher` is a value type captured by copy here on
    /// the main thread, so a concurrent `makeLauncher()` reassignment can't race it.
    private func runLauncher(_ action: @escaping (Launcher) -> Void) {
        // `Launcher` is a value type copied here on the main actor; the serial queue
        // runs one action at a time and the UI refresh hops back to main. The copy is
        // safe to hand across the one queue hop, but neither `Launcher` nor the action
        // closure is `Sendable`, so wrap them in a transfer box for the crossing rather
        // than pushing `Sendable` through all of SpaceKit.
        let launcher = UnsafeTransfer(self.launcher)
        let action = UnsafeTransfer(action)
        launcherQueue.async { [weak self] in
            action.value(launcher.value)
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Like `runLauncher`, but for the smart-launch paths that can open a *new
    /// window*. After the launch, if a window-making strategy reported success,
    /// verify a little later that the window actually stuck: a single-window app
    /// (Claude since v1.1617.0 removed multi-window) flashes a fresh window on the
    /// current desktop, then hands off to its existing instance and closes that
    /// window — leaving the process running but window-less. We can't make such an
    /// app keep a second window, so when we detect it we warn the user and point
    /// them at a strategy that does work (see `verifyNewWindowLanded`).
    private func runLaunch(target: AppTarget, _ action: @escaping (Launcher) -> LaunchOutcome?) {
        // The Space we're launching onto, read on the main actor before the hop. The
        // check below compares against *this* Space (not whichever is active later),
        // so it stays correct even if the user switches desktops during the wait.
        // (`currentSpaceID` isn't on the `SpaceProviding` seam; the snapshot carries it.)
        let launchSpace = (try? provider.snapshot())?.activeSpaceID
        let launcher = UnsafeTransfer(self.launcher)
        let action = UnsafeTransfer(action)
        launcherQueue.async { [weak self] in
            let outcome = action.value(launcher.value)
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.verifyNewWindowLanded(outcome: outcome, target: target, launchSpace: launchSpace)
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
                  let snapshot = try? self.provider.snapshot(),
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
        if appliedHideAppleDock { AppleDockController.apply(hidden: true) }
        // Reconcile the "launch at login" preference with the real OS registration.
        // Runs before the preferences observer is added below, so the adopt-branch
        // write can't trigger a re-apply cascade.
        applyLoginItem()
        // Crash recovery: if a prior run disabled the system space-switch hotkeys
        // for the keyboard override but didn't restore them, force them back on
        // before we (maybe) re-apply the current state.
        if Preferences.shared.spaceHotkeysDisabledByUs && !Preferences.shared.fasterKeyboardSwitch {
            FasterDesktopSwitch.restoreSpaceHotkeys()
            Preferences.shared.spaceHotkeysDisabledByUs = false
        }
        applyFasterDesktopSwitch()  // install the swipe-override tap if it's on
        applyFasterKeyboardSwitch() // take over the keyboard shortcut if it's on
        // If either override is on but couldn't install (Accessibility not granted
        // yet — the common case right after a reinstall / permission reset), watch
        // for the grant and install it then, instead of leaving it on-but-dead.
        startAccessibilityWatchIfNeeded()
        statusItemController.sync()
        setupObservers()
        launcherPanel.onLaunch = { [weak self] app, forceNew in
            self?.runLaunch(target: app.target) { try? $0.dockClick(target: app.target, forceNew: forceNew) }
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
            let bounds = self.bounds(forDisplay: displayUUID)
            let dockSpace = self.currentSpaceID(forDisplay: displayUUID)
            self.runLaunch(target: app.target) { launcher in
                if let windowID = app.windowID, let pid = app.pid {
                    return try? launcher.dockClickWindow(windowID: windowID, pid: pid,
                                                         target: app.target, forceNew: forceNew,
                                                         preferredDisplay: bounds)
                }
                return try? launcher.dockClick(target: app.target, forceNew: forceNew,
                                               preferredDisplay: bounds, dockSpace: dockSpace)
            }
        }
        dock.onPinHere = { [weak self] app in
            guard let self, let uuid = self.spaceUUID(forDisplay: displayUUID),
                  let bundleID = app.bundleID else { return }
            self.pins.toggle(bundleID, onSpace: uuid)
            self.refresh()
        }
        dock.onPinEverywhere = { [weak self] app in
            guard let self, let bundleID = app.bundleID else { return }
            self.pins.toggleEverywhere(bundleID)
            self.refresh()
        }
        // "Unpin (this desktop)" on an all-desktops pin: hide it here only, leaving
        // it pinned on every other desktop (or show it again if already hidden).
        dock.onToggleHereForEverywhere = { [weak self] app in
            guard let self, let uuid = self.spaceUUID(forDisplay: displayUUID),
                  let bundleID = app.bundleID else { return }
            self.pins.toggleEverywhereException(bundleID, onSpace: uuid)
            self.refresh()
        }
        dock.onCloseThisDesktop = { [weak self] app in
            guard let self else { return }
            let bounds = self.bounds(forDisplay: displayUUID)
            self.runLauncher { _ = try? $0.closeOnCurrentDesktop(target: app.target, onDisplay: bounds) }
        }
        dock.onCloseAllDesktops = { [weak self] app in
            self?.runLauncher { $0.quitApp(target: app.target) }
        }
        dock.onCloseWindow = { [weak self] app in
            guard let windowID = app.windowID, let pid = app.pid else { return }
            self?.runLauncher { _ = $0.closeWindow(windowID: windowID, pid: pid, target: app.target) }
        }
        dock.onDropApp = { [weak self] bundleID, order in
            guard let self, let uuid = self.spaceUUID(forDisplay: displayUUID) else { return }
            self.pins.pin(bundleID, onSpace: uuid)
            // Persist the arrangement the user dropped into, so the new app stays
            // wedged where they placed it instead of jumping to the end.
            self.pins.setOrder(order, onSpace: uuid)
            self.refresh()
        }
        dock.onReorder = { [weak self] keys in
            guard let self, let uuid = self.spaceUUID(forDisplay: displayUUID) else { return }
            self.pins.setOrder(keys, onSpace: uuid)
            self.refresh()
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
            lastDisplayByDisplay[uuid] = nil
            lastSpaceByDisplay[uuid] = nil
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
    /// The numeric Space id visible on this display — what a dock click on this
    /// display treats as "the current desktop" (so it judges the app against this
    /// screen's desktop, not the menu bar's). nil when unknown (0).
    private func currentSpaceID(forDisplay uuid: String) -> SpaceID? {
        let value = displaySpaces.first { $0.displayUUID == uuid }?.currentSpaceID
        return (value ?? 0) != 0 ? value : nil
    }

    /// The global bounds of a display (the preferred screen for new windows, and the
    /// scope for that screen's dock contents). Prefers the live Core Graphics bounds
    /// of the matching screen — authoritative and always non-zero for an attached
    /// display — and falls back to what the window server reported last refresh.
    private func bounds(forDisplay uuid: String) -> CGRect? {
        if let screen = NSScreen.screens.first(where: { $0.displayUUID == uuid }) {
            let live = CGDisplayBounds(screen.displayID)
            if live != .zero { return live }
        }
        return displaySpaces.first { $0.displayUUID == uuid }?.bounds
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
        if appliedHideAppleDock { AppleDockController.apply(hidden: false) }
        // Remove the event tap and restore the system space-switch hotkeys cleanly.
        FasterDesktopSwitch.setSwipeEnabled(false)
        FasterDesktopSwitch.setKeyboardEnabled(false)
        Preferences.shared.spaceHotkeysDisabledByUs = false
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
    private func applyFasterDesktopSwitch() {
        let want = Preferences.shared.fasterDesktopSwitch
        lastFasterDesktopSwitchPref = want
        let ok = FasterDesktopSwitch.setSwipeEnabled(want)
        // Track what's *actually* installed, not what's merely wanted: a failed
        // enable (no Accessibility yet) leaves this false, so the watch re-applies
        // it on grant rather than the toggle looking on while the tap is absent.
        appliedFasterDesktopSwitch = want && ok
        if want && !ok { warnFasterSwitchNeedsAccessibility() }
    }

    /// Apply the keyboard "faster desktop switch" preference: take over (or release)
    /// the user's "Move left/right a space" shortcut. Records whether we've disabled
    /// the system hotkeys so a crash can be recovered from on the next launch.
    private func applyFasterKeyboardSwitch() {
        let want = Preferences.shared.fasterKeyboardSwitch
        lastFasterKeyboardSwitchPref = want
        let ok = FasterDesktopSwitch.setKeyboardEnabled(want)
        Preferences.shared.spaceHotkeysDisabledByUs = want && ok
        // As with the swipe: only count it applied if the tap actually installed,
        // so a failed (ungranted) enable is retried by the watch.
        appliedFasterKeyboardSwitch = want && ok
        if want && !ok { warnFasterSwitchNeedsAccessibility() }
    }

    private func warnFasterSwitchNeedsAccessibility() {
        HUD.show("Faster desktop switch needs Accessibility. Grant Powerspaces in "
                 + "System Settings ▸ Privacy & Security ▸ Accessibility, and it turns "
                 + "on by itself.",
                 force: true)
    }

    /// A "faster desktop switch" override is turned on in preferences but isn't
    /// actually installed — i.e. we're waiting on Accessibility. `applied*` tracks
    /// the real engine state, so a failed enable leaves its flag false.
    private var fasterSwitchAwaitingAccessibility: Bool {
        (Preferences.shared.fasterDesktopSwitch && !appliedFasterDesktopSwitch)
            || (Preferences.shared.fasterKeyboardSwitch && !appliedFasterKeyboardSwitch)
    }

    /// Start (or stop) the accessibility watch to match what's pending. While an
    /// override is wanted-but-not-installed it polls `AXIsProcessTrusted()` once a
    /// second and re-applies the pending override the moment macOS trusts us — so a
    /// freshly reinstalled / permission-reset app turns its overrides on by itself,
    /// instead of showing them "on" while they do nothing until toggled off and on.
    /// Idempotent and self-terminating: it stops once nothing is pending, so there's
    /// no idle timer in the steady state. Mirrors the `pollTimer` scheduling pattern.
    private func startAccessibilityWatchIfNeeded() {
        guard fasterSwitchAwaitingAccessibility else {
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
        // Nothing we can do until macOS trusts us; keep waiting.
        guard AccessibilityPermission.isTrusted else { return }
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
        }
        // Same "only act when this toggle flipped" guard for the two overrides —
        // compared against the last *preference* value (not the applied engine state)
        // so an override that's on but waiting on Accessibility doesn't re-apply and
        // re-show its warning on every unrelated preference change.
        if Preferences.shared.fasterDesktopSwitch != lastFasterDesktopSwitchPref {
            applyFasterDesktopSwitch()
        }
        if Preferences.shared.fasterKeyboardSwitch != lastFasterKeyboardSwitchPref {
            applyFasterKeyboardSwitch()
        }
        // An override may have just been enabled while still ungranted (now pending),
        // or disabled (no longer pending) — start or stop the watch to match.
        startAccessibilityWatchIfNeeded()
        applyLauncherHotkey() // the launcher shortcut may have changed
        statusItemController.sync() // the glyph may have changed — create / remove / restyle the item
        restartPoll() // the interval may have changed
        docks.values.forEach { $0.applyAppearance() }
        // The "dock screens" setting may have flipped; refresh() reconciles which
        // displays have a dock.
        refresh()
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
        let interval = base * factor
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
        let changed = refresh()
        pollIdleTicks = changed ? 0 : pollIdleTicks + 1
        scheduleNextPoll()
    }

    private func setupObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
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
        refresh()
    }

    @objc private func refreshAction() {
        // A workspace event (space switch / app launch-quit-activate) or a manual
        // refresh just updated us — drop back to the snappy base poll rate.
        pollIdleTicks = 0
        refresh()
    }

    /// Stop the poll while the screen is asleep / the session is switched away —
    /// there's no dock on screen, so the wake-ups would just drain the battery.
    @objc private func suspendPolling() {
        isPollingPaused = true
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Screen woke / session returned: refresh once to catch up, then resume the
    /// light poll.
    @objc private func resumePolling() {
        guard isPollingPaused else { return }
        isPollingPaused = false
        restartPoll()
        refresh()
    }

    /// Rebuild every dock's contents from the live snapshot, one per display.
    /// Reconciles which displays have a dock first (so a plugged-in monitor or a
    /// flipped preference takes effect), then fills each from its display's visible
    /// Space. Returns whether any dock's display list changed, so the poll can
    /// decide whether to back off.
    @discardableResult
    private func refresh() -> Bool {
        guard let snapshot = try? provider.snapshot() else { return false }
        // Pids that own at least one window this tick — the shared basis for both
        // window-less treatments (reaping idle instances, and the window-less dock
        // items). Computed once here rather than in each helper.
        let pidsWithWindows = Set(snapshot.windows.map(\.pid))
        reapWindowlessInstances(pidsWithWindows: pidsWithWindows)
        let displays = provider.displays()
        displaySpaces = displays
        // The active display's desktop number, for the optional menu-bar readout.
        statusItemController.updateDesktop(
            (displays.first(where: { $0.isActive })?.spaceIndex).flatMap { $0 > 0 ? $0 : nil })
        // Create/remove docks to match the displays that should have one.
        reconcileDocks(displays: displays)

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
        // A fresh per-refresh reader memoizes each app's AX window list, so an app
        // with several labeled windows is fetched once, not once per window. Shared
        // across docks — the same window may be labeled on more than one bar.
        let titleReader = WindowTitleReader()
        // The active/forefront window — the frontmost app's main window — so the
        // wide window-title mode can render that bar's title in bold. It's a single
        // global window, so read it once per refresh and reuse across every dock.
        // Only computed in label mode: otherwise a focus change would flip an item
        // and needlessly rebuild the icon-only bars.
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let activeWindowID: CGWindowID? = (prefs.showWindowLabels ? frontmostPID : nil)
            .flatMap { titleReader.mainWindowID(pid: $0) }

        // Every attached display's bounds (top-left origin, matching window centers),
        // so the per-display filter can keep a window whose center has transiently
        // slid off this display during a native desktop switch (it's on *no* display
        // then, not another one) instead of dropping it — which emptied the bar.
        let allDisplayBounds = NSScreen.screens
            .map { CGDisplayBounds($0.displayID) }.filter { $0 != .zero }
        var anyChanged = false
        for (uuid, dock) in docks {
            guard let info = displays.first(where: { $0.displayUUID == uuid }) else { continue }
            // Authoritative live bounds for this dock's screen (the window-server
            // value can be .zero if a UUID didn't resolve; the panel's own display
            // is always valid).
            let displayBounds = CGDisplayBounds(dock.boundDisplayID) != .zero
                ? CGDisplayBounds(dock.boundDisplayID) : info.bounds
            let spaceUUID = info.currentSpaceUUID.isEmpty ? nil : info.currentSpaceUUID
            // A Space switch swaps the whole bar at once; suppress the per-icon
            // join/leave animation for that one rebuild.
            let spaceChanged = info.currentSpaceUUID != (lastSpaceByDisplay[uuid] ?? "")
            lastSpaceByDisplay[uuid] = info.currentSpaceUUID
            // Tell the bar which desktop it's on so it can paint that desktop's
            // custom dock color (re-tints when this changes — e.g. on a Space switch).
            dock.spaceUUID = spaceUUID
            // The desktop's 1-based number, for the glanceable indicator badge.
            dock.desktopNumber = info.spaceIndex > 0 ? info.spaceIndex : nil
            // Hide / auto-hide / show the bar on a screen showing a full-screen app,
            // per the full-screen dock preference (a no-op while the state is unchanged).
            dock.applyFullscreenState(info.isFullscreen)
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
                titleForWindow: titleReader.title(windowID:pid:))
            // Flag the bar standing for the forefront window (matched by the same
            // window id the title attach uses) so the panel can bold it. nil id —
            // labels off, or no main window — leaves every item unflagged.
            let marked = activeWindowID.map { active in
                display.map { $0.withActive(($0.windowID ?? $0.windowIDs.first) == active) }
            } ?? display
            dock.update(apps: marked, animateChanges: !spaceChanged)
            if marked != lastDisplayByDisplay[uuid] { anyChanged = true }
            lastDisplayByDisplay[uuid] = marked
        }
        return anyChanged
    }

    /// Experimental "close releases the app" (`quitOnLastWindowClose`): when an app
    /// instance's last window closes, quit that process so it doesn't linger
    /// window-less — the cause of the background-instance pile-up (e.g. an Electron
    /// app like Claude summoned to many desktops). Per-pid, with a one-tick debounce
    /// so an app that closes one window only to open another (Finder-style "new
    /// window" flows) isn't quit mid-swap. Only regular (Dock-showing) apps, never
    /// Powerspaces itself; pre-existing window-less instances are left alone — only a
    /// window the user actively closes triggers a reap. No-op (but keeps tracking)
    /// when the preference is off.
    private func reapWindowlessInstances(pidsWithWindows: Set<pid_t>) {
        // Update the "had windows last tick" baseline on the way out, after this
        // tick's candidates have been computed from the previous value.
        defer { pidsWithWindowsLastRefresh = pidsWithWindows }
        guard Preferences.shared.quitOnLastWindowClose else {
            // Carry no backlog while off, so enabling the setting doesn't immediately
            // quit apps that were already window-less before it was turned on.
            reapPendingPids = []
            return
        }
        // A pid that went window-less last tick and is *still* window-less now: quit
        // it. The one-tick gap is what protects a close-then-reopen from being reaped.
        for pid in reapPendingPids where !pidsWithWindows.contains(pid) {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  Self.isReapableRegularApp(app) else { continue }
            app.terminate()
        }
        // Next round's candidates: apps that had a window last tick and have none now.
        reapPendingPids = pidsWithWindowsLastRefresh.subtracting(pidsWithWindows)
    }

    /// Running apps that have **no window** this tick (`pidsWithWindows` is the set
    /// that do) — the dock items the "show apps with no open windows" option injects.
    /// Limited to regular, non-terminated, Dock-showing apps that aren't us (see
    /// `isReapableRegularApp`), and keyed off the live pid so a ⌘-hidden app (which
    /// still owns off-screen windows in the snapshot) is correctly *excluded*. Each
    /// becomes a running, zero-window `DockApp`; a click opens a fresh window here.
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
