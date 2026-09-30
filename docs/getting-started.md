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

# Getting started

## Prerequisites

- macOS 14+ (developed and verified on macOS 27.0; releases up to 1.2.4 were
  verified on macOS 26.5). The Homebrew install below needs nothing else.
- To build from source: Apple's **Command Line Tools** for the `powerspaces` CLI
  and the tests.
  ```sh
  xcode-select --install   # only if `swift --version` fails
  ```
- To build **the app** on macOS 27: **Xcode**. SwiftUI's `@State` is a macro in the
  macOS 27 SDK, and its plugin ships with Xcode, not with the Command Line Tools.
  You do not have to switch your default toolchain; put this in front of a build
  command:
  ```sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/install-app.sh
  ```

## Install with Homebrew (easiest)

The simplest way to get Powerspaces: Homebrew downloads the prebuilt app straight
into your Applications folder.

```sh
brew tap sebastianpdw/tap              # one-time
brew trust sebastianpdw/tap            # Homebrew 6.0+: trust a third-party tap
brew install --cask powerspaces        # copies Powerspaces.app into /Applications
```

Powerspaces is Apple **Developer-ID signed and notarized**, so it launches with no
Gatekeeper warning — no `xattr`, no right-click → Open. Just open it and grant
**Accessibility** when prompted. Head to the [User guide](user-guide.md) for how to
use the dock.

The prebuilt app is **Apple Silicon only** for now; on an Intel Mac, build from a
clone (below). Update later with `brew upgrade --cask powerspaces`.

## Install from a clone

Prefer to install straight from the repo? Build and install the app bundle:

```sh
./scripts/install-app.sh            # builds Powerspaces.app → /Applications
open /Applications/Powerspaces.app
```

- **No `sudo`?** Override the destination:
  ```sh
  APP_DEST="$HOME/Applications" ./scripts/install-app.sh
  ```
- **Want the `powerspaces` CLI too?** Build and copy the binary (see the
  [CLI reference](cli.md)):
  ```sh
  swift build -c release
  sudo cp .build/release/powerspaces /usr/local/bin/powerspaces
  ```

## Build from source

```sh
swift build -c release
```

On macOS 27, put `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in
front (see Prerequisites), or build the CLI alone with `--product powerspaces`.

Binaries land in `.build/release/` (`PowerspacesApp` and the `powerspaces` CLI). To
run the app straight from the source tree without installing:

```sh
swift run PowerspacesApp
```

That's an *unbundled* binary, so macOS shows a generic "exec" icon. For a proper
Dock icon and the name "Powerspaces", build the bundle:

```sh
./scripts/make-app.sh        # builds Powerspaces.app with an AppIcon.icns
open ./Powerspaces.app
```

## Run the tests

XCTest/Swift Testing don't ship with Command Line Tools, so the suite is a plain
executable, so no Xcode is required:

```sh
swift run spacekit-tests     # → all assertions pass, 0 failed
```

Two scripts cover what the core suite cannot reach. The first compiles the app's
own sources, so on macOS 27 it needs Xcode like the app does:

```sh
swift build && ./scripts/test-ui-lifetimes.sh   # dock refresh, animations, dock + HUD lifetimes
./scripts/test-fast-switch.sh                   # the desktop-switch engine against a fake host
```

Neither launches the app or posts a real event.

---

Next: the [User guide](user-guide.md) for everyday use, or the
[CLI reference](cli.md) for the command line.
