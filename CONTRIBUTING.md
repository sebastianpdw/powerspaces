# Contributing to Powerspaces

Thanks for your interest in contributing! Powerspaces is an open-source
project and contributions of all kinds are welcome: bug reports, feature
ideas, documentation, translations, and code.

This document explains how to contribute and, importantly, the **Developer
Certificate of Origin (DCO)** sign-off that every contribution requires.

---

## Quick start

1. **Open an issue first** for anything non-trivial. It saves you from
   building something that doesn't fit the project's direction, and lets us
   discuss approach before code is written. Small fixes (typos, obvious bugs)
   can go straight to a pull request.
2. **Fork** the repository and create a branch for your change.
3. **Build it** with the standard Command Line Tools workflow (no full Xcode
   required):
   ```
   swift build
   swift run spacekit-tests   # run the test suite; it should exit 0
   ```
4. **Sign off your commits** (see the DCO section below). This is required:
   PRs without sign-off can't be merged.
5. **Open a pull request** with a clear description of what changed and why.

---

## Developer Certificate of Origin (DCO)

To keep the project's licensing clean and to preserve the ability to evolve
how Powerspaces is licensed in the future, every contribution must be made
under the **Developer Certificate of Origin**.

The DCO is a lightweight, widely used alternative to a CLA (it's what the
Linux kernel and many other projects use). You don't sign any separate
paperwork. You simply add a `Signed-off-by` line to each commit, which
certifies that you wrote the contribution (or otherwise have the right to
submit it) and that it can be included under the project's license.

By signing off, you agree to the following:

```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

### How to sign off

Add a `Signed-off-by` line to your commit message using your real name and
an email address you can be reached at:

```
Signed-off-by: Jane Doe <jane.doe@example.com>
```

Git can add this for you automatically with the `-s` flag:

```
git commit -s -m "Fix dock refresh when display wakes from sleep"
```

If you forgot to sign off your last commit, you can amend it:

```
git commit --amend -s --no-edit
```

For a branch with multiple commits, you can sign them all off by rebasing:

```
git rebase --signoff main
```

> **Tip:** set `git config user.name` and `git config user.email` once and
> the `-s` flag will use them every time.

Pull requests are checked for sign-off automatically. If a commit is missing
its `Signed-off-by` line, the check will fail and you'll be asked to amend.

---

## Coding guidelines

Powerspaces follows a few design principles (also written up in the
project's architecture docs). Please keep changes aligned with them:

- **Keep the core pure and tested.** Behavioral decisions live behind the
  `SpaceProviding` protocol and operate on a plain `SpaceSnapshot` value.
  New decision logic should be a pure function that can be tested with a fake
  provider, with no live window-server calls in the decision path.
- **Quarantine private OS APIs.** All private SkyLight/CGS calls stay in
  `CGSPrivate.swift`. Don't scatter `@_silgen_name` symbols or private API
  usage through the rest of the codebase.
- **Prefer strategy-as-data.** Per-app behaviors (e.g. new-window handling)
  are config-driven values, not branching logic sprinkled across files.
  Adding a behavior should ideally be one new enum case.
- **Stay lightweight and reversible.** This is a long-running menu-bar agent,
  so respect energy use (no busy polling, suspend work when the display
  sleeps). Don't introduce changes that require disabling SIP, request
  permissions beyond Accessibility without discussion, or leave
  non-reversible state on the user's machine.
- **Add tests for new logic.** The suite runs with `swift run spacekit-tests`
  and must pass (exit 0) before a PR is merged.

---

## Reporting bugs

When filing a bug, please include:

- Your macOS version (e.g. macOS 26.5) and Mac model (Apple Silicon / Intel).
- What you expected to happen vs. what actually happened.
- Steps to reproduce, ideally minimal.
- Relevant config from `~/.config/powerspaces/` if the issue is
  behavior/strategy related (feel free to redact anything personal).

---

## Translations

Localizations are very welcome. Open an issue or PR with the language you'd
like to add and we'll point you at the strings. Translation contributions
also need DCO sign-off on the commits.

---

## License

By contributing to Powerspaces, you agree that your contributions will be
licensed under the **GNU General Public License v3.0**, the same license that
covers the project (see [LICENSE](./LICENSE)). The DCO sign-off above is how
you certify your right to contribute under that license.
