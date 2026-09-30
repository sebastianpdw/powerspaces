# Changelog

What changed in each release, newest first. Version numbers match the `VERSION`
file and the Homebrew cask.

## 1.3.0 (30 September 2026)

Support for macOS 27, a simpler way of deciding which windows are real, and safer
handling of launches, quits and system settings. Changes are described relative to
version 1.2.4.

### macOS 27

- **Faster desktop switch works on macOS 27.** macOS 27 ignores the swipe events
  that earlier versions accepted. Powerspaces now sends them in the form macOS 27
  expects. On macOS 14 to 26 the event carries the same values as before; the
  engine now also sets its own marker, time and position on it.
- **Every switch is confirmed.** After a switch Powerspaces checks which desktop
  is actually showing. Fast repeated switches are queued and run one at a time.
- **macOS 28 and later are not supported yet.** Faster desktop switch reports that
  and stays off there, instead of sending events that may not work.
- **Menu icons stay visible.** macOS 27 hides the icons of menu items by default;
  Powerspaces keeps its own.

### Fixed

- **The dock returns to the screen edge when the macOS Dock is hidden again.**
  Turning **Hide the macOS Dock** on no longer leaves the bar floating where the
  macOS Dock used to be.
- **One icon per window.** Helper surfaces that apps keep next to their windows
  (Safari's address-bar suggestions, tab previews, hidden panels) and windows that
  were closed but are kept alive in the background no longer show up as extra
  icons. Accessibility now decides which windows are real, and the window server
  only says which desktop they are on.
- **The dock no longer holds up the app while it reads windows.** Reading runs off
  the main thread, and a result is used only if the desktop did not change while
  it was read.
- **The dock follows a desktop switch at once.** It shows the list last confirmed
  for that desktop straight away and replaces it without animation when the fresh
  scan lands.
- **Apps keep their place in the dock** while they are temporarily absent, and a
  whole group of windows of one app can be dragged together.
- **Actions act on the desktop you clicked on.** Each action records its desktop
  and display when you click. If that changed before the action runs, it is
  cancelled with a message instead of acting somewhere else.
- **Pins changed from the command line reach the running app**, and two programs
  writing pins at the same time can no longer damage the pins file.
- **Your Dock settings are restored exactly.** When Powerspaces hides the macOS
  Dock it saves all four settings it changes, and restores them on quit, on
  uninstall and at the next launch after a crash.
- **A macOS Dock left hidden by an older version comes back.** If its saved
  settings were lost, Powerspaces no longer records its own hidden Dock as yours;
  turning the option off or quitting restores the macOS default Dock.
- **Retired dock buttons and warning panels are released**, so the app no longer
  grows in memory over a long session.

### Changed: what you may notice

- **The dock refreshes every 2 seconds by default**, and up to three times slower
  while nothing changes. It was 0.1 seconds. A window opened or closed inside the
  frontmost app can take that long to show. Desktop switches and app launches
  still update the dock at once. The faster settings remain available under
  **Preferences → Behavior**.
- **Quit is always polite.** Powerspaces no longer force-quits an app that does
  not quit within a moment. It reports that the app has not finished quitting.
- **"Quit after closing the last window"** (experimental, off by default) now only
  acts after a Close made through the Powerspaces dock, not after any closing of
  the last window.
- **The macOS Dock is not hidden again automatically** after wake or a display
  change. If macOS shows it, turn **Hide the macOS Dock** off and on.
- **Focusing and minimizing need Accessibility.** Without it a click shows a
  message that points to the permission, where earlier versions activated or hid
  the whole app. For the command-line tool and the Raycast extension the
  permission belongs to the app that runs them (Terminal, Raycast).
- **Faster desktop switch also needs permission to post events.** macOS may ask
  once.
- **A switch that starts during a mouse drag uses the normal animation**, so a
  window you are dragging travels along.
- **A dock action clicked while the mouse button is still held down is
  cancelled**, with a message.
- **Closed windows that an app keeps alive do not count as windows.** Apps such as
  Slack and most Electron apps hide a window when you close it. Such an app has no
  icon on that desktop until it shows a window again, unless it is pinned.
- **When an app does not open a new window, the warning says what to try.** Some
  apps refuse the default way of opening a new window. The warning now suggests
  right-clicking the app's icon in the dock and choosing another New-window
  strategy.
- **Floating panels and inspectors do not get their own icon** while their app
  also has a standard window.
- **Apps are opened through Launch Services.** New-window strategies that pass
  arguments no longer run the app's binary directly.
- **The log says more.** One line per dock action, per dock redraw, per change in
  an app's window count, and for any scan that takes a second or more. These lines
  name the app by its identifier and carry process and window numbers, desktop
  numbers, counts and durations, so the macOS log shows which apps you used
  through the dock and when. Powerspaces does not log window titles, document
  names or addresses. An AppleScript error is logged as macOS returns it. The log
  stays on your Mac.

### For developers

- **Building the app on macOS 27 needs Xcode.** The command-line tool and the
  tests still build with the Command Line Tools.
- **Local builds can keep their permissions.** `scripts/make-app.sh` signs with
  the certificate named in `SIGN_IDENTITY`. Without it the build is ad-hoc signed
  as before, which makes macOS ask for Accessibility and Automation again after
  every rebuild. Local builds no longer ask Apple's timestamp server, so they work
  offline.
- **The build refuses an app that macOS 14 cannot launch**, and stops on a bad
  signature.
- Three test entry points, all documented in the README: the core runner, the
  AppKit harness and the desktop-switch engine harness (also under sanitizers).
  The two harness scripts keep their files inside the repository. The core runner
  uses a temporary folder and removes it.
- [Design principles](design-principles.md) now lists where the code deviates
  from a principle and what would close each gap.

### Verified, and not yet verified

| | Status |
|---|---|
| macOS 27.0, Apple Silicon, one display: per-desktop dock, faster desktop switch, dock clicks, new windows | Verified in use |
| Permissions survive a rebuild signed with the same certificate | Verified |
| macOS 14 to 26 | Not run on these versions after these changes |
| Two displays | Used for a day without problems, not tested systematically |
| Natural scrolling switched on, with faster desktop switch | Not verified |

## 1.2.4 and earlier

See the [releases page](https://github.com/sebastianpdw/powerspaces/releases).
