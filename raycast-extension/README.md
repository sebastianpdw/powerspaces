# Powerspaces: Raycast extension

A small Raycast extension
with one command, **Open on Current Space**, that lists every installed app (via
`getApplications()`) and opens/focuses the one you pick on the desktop (Space)
you're currently standing on, instead of yanking you to wherever it already runs.

Because the extension owns its own Action Panel, each app gets custom ⌘K actions
that you **cannot** add to Raycast's built-in app results:

- **Open on Current Space** (Enter) → `powerspaces open <bundleId>`
- **Open New Window Here** (⌘N) → `powerspaces open <bundleId> --new`
- **Open Normally** (⌘O) → the native launch

New apps appear automatically, so there is zero per-app maintenance.

## Prerequisites

The extension shells out to the **`powerspaces` CLI**, so build and install it
first:

```sh
swift build -c release
sudo cp .build/release/powerspaces /usr/local/bin/powerspaces
powerspaces decide Slack   # sanity check
```

If your CLI lives somewhere else, set its path in the extension's preferences
(Raycast → Extensions → Powerspaces → Open on Current Space → ⌘⇧, ).

## Run it (loads the extension into Raycast)

```sh
cd raycast-extension
npm install
npm run dev      # ray develop; keeps it loaded while running
```

Stop `npm run dev` once you've used it; the command stays installed in Raycast.
To remove it, use Raycast → Extensions → right-click → Remove, or run
`npm run build` and import the built copy.

## Using it

1. Invoke **Open on Current Space** (give it an alias/hotkey for speed; ⌘K →
   Add Alias, e.g. `ocs`).
2. Type the app name, press **Enter** → it opens on the Space you're on.

### Sort order

The dropdown at the right of the search bar picks how apps are ordered. The
choice is remembered across launches and also governs the order of search
results (not just the full list):

- **Recently Opened** (default): apps you opened most recently float to the top.
  Search "W" and the **W**eather you just used outranks **W**arp.
- **Most Used**: ordered by how many times you've opened each app.
- **Alphabetical**: plain A→Z.

Recency/frequency are tracked by the extension itself (every open is recorded),
so both fall back to alphabetical until there's history to sort by.

## Why this isn't a transparent "type app name → Enter" launcher

An extension is a single entry in root search; its internal app list doesn't appear
directly in root search. So this is "invoke the command, then pick the app."
