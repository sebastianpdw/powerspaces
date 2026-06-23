# CLI reference

The `powerspaces` command is the engine's front door, handy for scripting, quick
checks, and the Raycast hook. It runs the same smart-launch the dock does, from your
shell.

## Install the CLI

Build the release binary, then copy it onto your `PATH`:

```sh
swift build -c release
sudo cp .build/release/powerspaces /usr/local/bin/powerspaces
```

No `sudo`? Copy it to a prefix you own instead (make sure it's on your `PATH`):

```sh
swift build -c release
cp .build/release/powerspaces "$HOME/.local/bin/powerspaces"
```

You can also run it straight from the source tree with `swift run powerspaces …`.

## Commands

```sh
powerspaces current-space            # the active desktop's Space id
powerspaces list-windows             # apps/windows on the current desktop
powerspaces list-windows --all       # all windows, with their Space ids
powerspaces decide <app>             # show what would happen; no action taken
powerspaces open   <app>             # do it (smart-launch)
powerspaces open   <app> --new       # force a brand-new window
```

`<app>` accepts a display name (`Firefox`) or a bundle id (`org.mozilla.firefox`).
`--new` forces a new window even if one already exists on the current desktop.

> **Tip:** `decide` is completely side-effect free. Run it to preview exactly what
> `open` *would* do before committing.

## Pinning from the shell

```sh
powerspaces pin   Slack              # pin to the current desktop
powerspaces pin   Slack --all        # pin to all desktops
powerspaces unpin Slack [--all]      # unpin from this / all desktops
powerspaces pins                     # list this desktop's pins (with scope)
powerspaces close Slack              # close its windows on this desktop
powerspaces close Slack --all        # quit the app everywhere
```

## Configuration

The per-app "new window" strategy is configurable. Copy the example and edit:

```sh
mkdir -p ~/.config/powerspaces
cp config.example.json ~/.config/powerspaces/config.json
```

Your entries override the built-in defaults; unknown apps use `defaultStrategy`. See
the [Launch strategies](user-guide-extensive.md#launch-strategies) section of the
extensive guide for the full table of strategies.

## Environment overrides

Handy for testing: point the CLI at custom files or a custom binary:

| Variable | Points at |
|---|---|
| `POWERSPACES_CONFIG` | a strategy `config.json` |
| `POWERSPACES_PINS` | a `pins.json` |
| `POWERSPACES_BIN` | the `powerspaces` binary (used by the Raycast extension) |

## Verifying it works

With windows spread across two desktops:

```sh
powerspaces list-windows --all       # confirm windows map to Spaces
# Stand on desktop 2 while an app runs only on desktop 1:
powerspaces decide <thatApp>         # → newWindow(...)  (it'll open here)
```

See the [limitations section of the extensive user guide](user-guide-extensive.md#good-to-know-limitations)
for what to expect with single-instance apps and other edge cases.

## Raycast / Spotlight

The CLI is what the Raycast extension calls. The easiest setup is **Preferences →
System → Raycast** in the app (see the
[user guide](user-guide-extensive.md#raycast-extension-experimental)). To wire it up
by hand, load the bundled extension in [`raycast-extension/`](../raycast-extension/)
(it shells out to `powerspaces open`); set `POWERSPACES_BIN` if the binary isn't on
the default `PATH`.
