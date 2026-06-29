# Security Policy

## Reporting a vulnerability

Please report security vulnerabilities **privately**. Do not open a public issue
for a security problem.

Use GitHub's **private vulnerability reporting**: open the
[Security tab](https://github.com/sebastianpdw/powerspaces/security) and click
**"Report a vulnerability"**. That starts a private advisory thread visible only
to you and the maintainer.

You can expect an initial response within a few days. If a report is confirmed, a
fix and a coordinated disclosure follow (with credit, if you'd like it).

## Supported versions

Powerspaces is a small, single-maintainer project. Security fixes land on the
**latest release** on `main`; there are no long-term support branches.

| Version | Supported |
|---|---|
| Latest release (`main`) | ✅ |
| Older tags | ❌ |

## Scope

Powerspaces is a local, single-user macOS menu-bar app with **no network surface**
(no servers, no telemetry, no remote endpoints). Things worth reporting:

- It uses **private CoreGraphics / SkyLight APIs** and the **Accessibility** API to
  read and move windows and switch Spaces.
- It launches apps via `/usr/bin/open`, app binaries, and **AppleScript** according
  to a user-editable strategy config (`~/.config/powerspaces/config.json`). That
  config is a trust-sensitive, code-bearing file: the `appleScript` strategy runs
  the script it contains, so the file is read only when it is owned by you and is
  not group or world writable.
- The install and build scripts may use `sudo` to write into `/Applications` or
  `/usr/local/bin`.

Out of scope: anything that needs an attacker to already run code as your macOS
user (the user account is the trust boundary), and the use of private Apple APIs
itself (a deliberate, documented design choice).

## Distribution integrity

The Homebrew cask's prebuilt `Powerspaces.app` is **Apple Developer-ID signed and
notarized**, and the cask pins the release's `sha256`, so a tampered download fails
to install. If you obtain a prebuilt binary from anywhere other than the official
GitHub Releases / Homebrew tap, verify it yourself before trusting it:

```sh
spctl -a -vvv /Applications/Powerspaces.app        # expect: accepted, source=Notarized Developer ID
codesign -dv --verbose=4 /Applications/Powerspaces.app
```
