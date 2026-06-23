# Getting started

## Prerequisites

- macOS 14+ (developed/verified on macOS 26.5).
- Apple's **Command Line Tools** (full Xcode is *not* required):
  ```sh
  xcode-select --install   # only if `swift --version` fails
  ```

## Install with Homebrew (easiest)

The simplest way to get Powerspaces: Homebrew downloads the prebuilt app straight
into your Applications folder.

```sh
brew tap sebastianpdw/tap              # one-time
brew trust sebastianpdw/tap            # Homebrew 6.0+: trust a third-party tap
brew install --cask powerspaces        # copies Powerspaces.app into /Applications
xattr -dr com.apple.quarantine /Applications/Powerspaces.app   # clear Gatekeeper (the app is unsigned), one-time
```

The app isn't notarized, so macOS blocks the first launch. Allow it **either way**:

- **Terminal:** the `xattr` line above clears it in one step (copy it right after the install), then open Powerspaces.
- **System Settings:** try to open Powerspaces, then go to **System Settings → Privacy & Security**, scroll to Security, and click **Open Anyway** next to Powerspaces.

Then grant **Accessibility** when prompted. Head to the [User guide](user-guide.md)
for how to use the dock.

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

---

Next: the [User guide](user-guide.md) for everyday use, or the
[CLI reference](cli.md) for the command line.
