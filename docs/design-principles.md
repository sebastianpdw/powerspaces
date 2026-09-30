<!-- site-nav -->
<p align="center">
  <a href="README.md"><b>Powerspaces</b></a> &nbsp;·&nbsp;
  <a href="user-guide.md">User guide</a> &nbsp;·&nbsp;
  <a href="user-guide-extensive.md">Full guide</a> &nbsp;·&nbsp;
  <a href="getting-started.md">Getting started</a> &nbsp;·&nbsp;
  <a href="cli.md">CLI</a> &nbsp;·&nbsp;
  <a href="https://ko-fi.com/sebastianpdw">♥ Support</a> &nbsp;·&nbsp;
  <a href="https://powerspaces.app">Website ↗</a>
</p>

# Design principles

powerspaces is built to three rules. Every feature and refactor is weighed
against them; when they conflict, **lightweight wins, then minimal, then
modular**.

## 1. Lightweight: sip resources, never hog them

A menu-bar agent runs all day, so it must be invisible in Activity Monitor.

- **Push first, poll only where the OS gives us nothing.** Space switches and
  app launch/quit/activate come from `NSWorkspace` notifications and refresh
  instantly. The timer exists *only* to catch window open/close (macOS posts no
  notification for those).
- **Do nothing when nothing can be seen.** Polling pauses when the display
  sleeps or the session is switched away. With no dock to update, there is no
  work to do.
- **One cheap read per refresh.** A refresh is a single window-list snapshot plus
  a space-membership read: no thumbnails, no screen capture, no per-tick
  allocation storms. The dock view only rebuilds when its contents actually
  change (snapshot equality short-circuit).
- **No background threads, no caches that grow.** State is small, value-typed,
  and rebuilt from the live snapshot rather than accumulated.
- **Opt-in cost is opt-in.** Expensive extras (live window-title labels, read via
  Accessibility) only run when the user turns them on.

## 2. Minimal: touch the system as little as possible

powerspaces *augments* native Spaces; it must never fight the OS or demand more
access than the job needs.

- **Read-only on the window server.** We only *read* space membership via the
  same private CGS calls AltTab/Hammerspoon use. We never move other apps'
  windows across Spaces, so **no SIP changes, ever**.
- **The fewest permissions that work.** Accessibility only (to raise the exact
  window). **No** Screen Recording: the dock uses app identity, not titles or
  thumbnails. Automation only for the per-app `appleScript` strategy.
- **No global system mutation.** No login items forced on, no defaults rewritten,
  no Dock replaced. Native Spaces, gestures, and Mission Control keep working.
- **Self-contained, reversible state.** All settings live in plain JSON under
  `~/.config/powerspaces/`. Deleting the app leaves the system as it was.
- **Degrade, don't break.** Anything that needs Accessibility checks `isTrusted`
  first and falls back to a warning instead of failing silently.

## 3. Modular: easy to read, adjust, and extend

- **A pure core behind a seam.** All behavioural logic is a pure function of a
  `SpaceSnapshot` behind the `SpaceProviding` protocol. The live implementation
  talks to the window server; tests inject a fake. That seam is what makes a
  system-level app unit-testable at all.
- **`SpaceKit` (logic) is split from the app (UI).** The library has no AppKit UI
  and is shared verbatim by three thin entry points: CLI, menu-bar app, and test
  runner.
- **One file, one purpose.** Each module owns a single responsibility (decide,
  execute, model the dock, resolve apps, persist pins). Private OS surface is
  quarantined to `CGSPrivate.swift`.
- **Data, not branches, for variation.** Per-app new-window behaviour is a
  `StrategyKind` value chosen by config, so adding a behaviour is a new case +
  one `switch` arm, not a rewrite.
- **Classify state, then switch.** The launch/dock decision reads the world into
  one named `AppState` (`notRunning` / `runningWindowless` / `windowElsewhere` /
  `windowHere`) and switches over it, rather than re-deriving a tangle of booleans
  at each call site, so the states are explicit, exhaustive, and loggable.
- **Pure decisions are tested; side effects are thin.** The unit-tested
  `LaunchEngine`/`DockModel` decide *what* to do, and the `Launcher` only *does* it.

## Where the code deviates today

The rules above are what the project aims for, and the code does not meet all of
them yet. Each gap below says why it exists and what would close it. A gap is
closed by changing the code, not by rewording the principle.

- **Background queues** (against "No background threads"). The window inventory
  is read on a serial background queue (`sampleQueue` in
  `DockRefreshCoordinator.swift`) and dock actions run on a second one
  (`launcherQueue` in `AppDelegate.swift`), because a scan can take more than a
  second and an action waits on the target app, and neither may freeze the dock.
  Reads that never block on another app, and launch steps driven by
  notifications instead of bounded waits, would remove both.
- **More than one read per refresh** (against "One cheap read per refresh").
  Besides the window list, a refresh reads Space membership once per candidate
  window, makes one Accessibility pass per app that owns a candidate, and reads
  window titles when labels are on; the pass and the titles each have a 2 second
  budget (`CGSSpaceProvider.swift`, `AppDelegate.swift`). Accessibility is what
  tells a real window from a helper surface, which geometry alone cannot. A
  window-server signal that separates the two, or Accessibility notifications
  in place of a full pass, would restore the single read.
- **State kept between refreshes** (against "no caches that grow"). The provider
  remembers which windows Accessibility has confirmed (`remembered` in
  `CGSSpaceProvider`), so a window stays listed when its app misses the budget,
  and the app keeps the last validated dock list per display and desktop
  (`DockMemo`), so a desktop switch shows a list before its scan lands. Both are
  bounded: the first is rebuilt from each scan, the second holds one list per
  display and desktop and is dropped when pins, preferences or the display
  layout change. A scan that is fast and always answered would make both
  unnecessary.
- **The poll does more than watch windows** (against "Push first, poll only
  where the OS gives us nothing"). Each poll tick also checks the fast-switch
  event tap and re-arms it if an earlier re-arm failed, and a one-second timer
  runs while a fast-switch override waits for permission (`AppDelegate.swift`),
  because macOS posts no notification for a granted permission or for a tap
  that stays disabled. Both are idle when fast switching is off; a push signal
  for either would remove them.
- **The keyboard override turns off the system Space shortcuts** (against "No
  global system mutation" and "Read-only on the window server"). When the
  opt-in keyboard override is on, the fast-switch engine (`CSpaceSwitch.c`)
  disables the four system shortcuts for moving a Space left or right through a
  private call, because the key press can only be intercepted reliably once the
  native shortcut is off; both overrides also post synthetic swipe events. The
  original states are journalled first and restored when the override is turned
  off, on quit, and at the next launch after a crash. A supported way to switch
  Spaces without the animation would remove the engine.
- **`AXManualAccessibility` is set on another app** (against "No global system
  mutation"). During a focus operation, `requestWindowAccess` in
  `WindowAX.swift` sets the attribute on the app whose clicked window is not yet
  usable through Accessibility, because some apps (Electron documents this)
  only expose their windows on request, and sets it back when the operation
  ends. Apps that expose their windows without being asked would remove the
  need.
- **The shortcut journal is not JSON** (against "Self-contained, reversible
  state"). The fast-switch engine stores the original shortcut states through
  CFPreferences (`PSWOriginalSpaceHotkeys` in `CSpaceSwitch.c`), so they land in
  the app's preferences domain and not under `~/.config/powerspaces/`. The
  backup must be durable before the engine changes anything, and CFPreferences
  is what the C code has at hand. Writing it as a JSON record next to
  `dock-recovery.json` would remove the deviation.
- **Private calls outside `CGSPrivate.swift`** (against "Private OS surface is
  quarantined to `CGSPrivate.swift`"). The Swift declarations are all in that
  file, but `Launcher+Primitives.swift` calls `CGSCopySpacesForWindows` directly
  to recheck one window without a full scan, and the fast-switch engine declares
  its own private calls and event fields in C (`CSpaceSwitch.c`,
  `EventSerialization.h`). Routing the launcher's check through the provider,
  and keeping the C declarations in one private header, would restore the
  quarantine.
