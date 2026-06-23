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
