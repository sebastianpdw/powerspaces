// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import SpaceKit

/// One-click setup for the Raycast extension, driven from Preferences.
///
/// The extension is a small Node project that shells out to the `powerspaces`
/// CLI, so getting it running needs three things a GUI app can't do silently:
/// the CLI on `PATH`, `npm install`, and a one-time `npm run dev` (`ray develop`)
/// to *import* the extension into Raycast. We do the parts the app can do for
/// you — install the bundled CLI and copy the bundled extension to a writable
/// folder — then hand the npm steps to a Terminal window so you can watch the
/// import and see any errors. After that import, no Terminal is needed: Raycast
/// keeps the extension and launches it on demand.
///
/// `make-app.sh` bundles the CLI binary and the extension source into the .app's
/// Resources; running unbundled (`swift run`) has neither, so `runSetup()` throws
/// a clear error telling you to build with `make-app.sh`.
enum RaycastSetup {
    /// Where the `powerspaces` CLI can be installed.
    ///
    /// `.userLocal` (the default) needs **no admin** — a plain copy into the
    /// user's own `~/.local/bin`. `.systemWide` lands on every shell's `PATH`
    /// but `/usr/local/bin` needs an admin password. Either way the extension is
    /// pointed at the absolute path the binary actually landed at (it shells out
    /// by absolute path, so the shell `PATH` is irrelevant to Raycast), so it
    /// keeps working regardless of which one you pick.
    enum CLILocation {
        case userLocal
        case systemWide

        var url: URL {
            switch self {
            case .userLocal:
                return FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/bin/powerspaces")
            case .systemWide:
                return URL(fileURLWithPath: "/usr/local/bin/powerspaces")
            }
        }

        var path: String { url.path }
    }

    /// Default install location: per-user, so enabling the CLI or the extension
    /// from Preferences never needs an admin password.
    static let defaultCLILocation: CLILocation = .userLocal

    /// The extension source bundled into the .app by `make-app.sh`.
    static var bundledExtensionURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("raycast-extension", isDirectory: true)
    }

    /// The `powerspaces` CLI binary bundled into the .app by `make-app.sh`.
    static var bundledCLIURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("powerspaces")
    }

    /// Writable copy of the extension that npm builds in (node_modules lands here).
    /// A stable location under `~/.config/powerspaces` so the imported extension
    /// keeps resolving after setup, independent of the .app bundle or the repo.
    static var workingExtensionDir: URL {
        PowerspacesPaths.configDir.appendingPathComponent("raycast-extension", isDirectory: true)
    }

    /// Where the CLI is currently installed, if anywhere (prefers the per-user
    /// copy when both exist).
    static var installedLocation: CLILocation? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: CLILocation.userLocal.path) { return .userLocal }
        if fm.isExecutableFile(atPath: CLILocation.systemWide.path) { return .systemWide }
        return nil
    }

    /// Install the bundled CLI into the per-user `~/.local/bin` with **no admin
    /// and no Terminal** — a direct file copy. Returns where it landed.
    @discardableResult
    static func installCLIToUserLocal() throws -> URL {
        guard let src = bundledCLIURL, FileManager.default.fileExists(atPath: src.path) else {
            throw SetupError.notBundled
        }
        let dest = CLILocation.userLocal.url
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: src, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return dest
    }

    /// Install the bundled CLI into `/usr/local/bin` (on every shell's PATH) via a
    /// Terminal window that uses `sudo` — this one needs an admin password.
    static func installCLISystemWide() throws {
        guard let src = bundledCLIURL, FileManager.default.fileExists(atPath: src.path) else {
            throw SetupError.notBundled
        }
        let dest = CLILocation.systemWide
        let script = """
            #!/bin/bash
            set -e
            echo "Installing the powerspaces CLI → \(dest.path)"
            echo "(/usr/local/bin needs admin. Enter your login password if asked.)"
            sudo mkdir -p \(shQuote(dest.url.deletingLastPathComponent().path))
            sudo cp \(shQuote(src.path)) \(shQuote(dest.path))
            sudo chmod 755 \(shQuote(dest.path))
            echo
            echo "✓ Installed. You can close this window (⌘W)."
            """
        try runInTerminal(script, named: "install-cli.command")
    }

    /// Rewrite the working copy's package.json so the extension's `powerspacesBin`
    /// default is the absolute path the CLI is installed at. The extension shells
    /// out by absolute path, so this is what lets a per-user CLI work in Raycast
    /// without `/usr/local/bin` and without editing `PATH`.
    private static func pointExtensionAtCLI(_ cli: URL, in extDir: URL) throws {
        let pkg = extDir.appendingPathComponent("package.json")
        let text = try String(contentsOf: pkg, encoding: .utf8)
            .replacingOccurrences(
                of: "\"default\": \"/usr/local/bin/powerspaces\"",
                with: "\"default\": \"\(cli.path)\"")
        try text.write(to: pkg, atomically: true, encoding: .utf8)
    }

    /// Write `script` as an executable `.command` under the config dir and open it
    /// in Terminal (`.command` files launch in Terminal by default).
    private static func runInTerminal(_ script: String, named name: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: PowerspacesPaths.configDir, withIntermediateDirectories: true)
        let url = PowerspacesPaths.configDir.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    /// Best-effort npm probe. GUI apps don't inherit the user's shell `PATH`
    /// (nvm/Homebrew live in the shell rc), so we ask a login+interactive zsh —
    /// the same environment Terminal will use to actually run the install. A nil
    /// here is a soft warning, not a hard block: Terminal may still find npm.
    static func npmVersion() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lic", "command -v npm >/dev/null 2>&1 && npm --version"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // An interactive rc may echo noise; take the last line that looks like a version.
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.first?.isNumber ?? false }
    }

    /// Open nodejs.org so the user can install Node.js (which provides npm).
    static func openNodeDownload() {
        if let url = URL(string: "https://nodejs.org/") { NSWorkspace.shared.open(url) }
    }

    enum SetupError: LocalizedError {
        case notBundled
        var errorDescription: String? {
            "The extension and CLI aren't bundled in this build. Rebuild the app with "
                + "scripts/make-app.sh (which bundles them), then try Set Up again."
        }
    }

    /// Install the bundled CLI + extension to writable locations and open Terminal
    /// to finish the npm steps. Synchronous and quick — the long part (npm) runs in
    /// the Terminal window we open at the end.
    static func runSetup() throws {
        let fm = FileManager.default
        guard let extSrc = bundledExtensionURL, fm.fileExists(atPath: extSrc.path) else {
            throw SetupError.notBundled
        }

        // Refresh the working copy from the bundle (drops any stale node_modules;
        // npm install rebuilds it). The imported extension points here, so we keep
        // this path stable across re-runs.
        try fm.createDirectory(at: PowerspacesPaths.configDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: workingExtensionDir.path) {
            try fm.removeItem(at: workingExtensionDir)
        }
        try fm.copyItem(at: extSrc, to: workingExtensionDir)

        // Install the CLI to a per-user, admin-free location and point the
        // extension's `powerspacesBin` default at that absolute path, so Raycast
        // finds it without `/usr/local/bin` and without editing `PATH`.
        let cliDest = defaultCLILocation.url
        try pointExtensionAtCLI(cliDest, in: workingExtensionDir)

        // The setup script: install the CLI (a plain copy into the per-user
        // ~/.local/bin — no admin), npm install, then import via `ray develop`.
        // We run the dev
        // server only until Raycast reports the import succeeded, then stop it and
        // print a clear DONE banner — so the window ends with an unmistakable
        // "safe to close" signal instead of leaving the watcher spinning forever
        // (the extension stays registered in Raycast once `ray develop` has built
        // it, so stopping the watcher is fine). Paths are single-quoted so spaces
        // or shell metacharacters in them can't break out of the script.
        let cliSrc = bundledCLIURL.map { shQuote($0.path) } ?? "''"
        let extDir = shQuote(workingExtensionDir.path)
        let script = """
            #!/bin/bash
            set -e
            echo "── Powerspaces · Raycast extension setup ───────────────────"
            echo "Three steps run automatically. Don't close this window until you"
            echo "see the “DONE, safe to close” box at the very end."
            echo

            CLI_SRC=\(cliSrc)
            CLI_DEST=\(shQuote(cliDest.path))
            EXT_DIR=\(extDir)

            if [ -n "$CLI_SRC" ] && [ -f "$CLI_SRC" ]; then
              echo "[1/3] Installing the powerspaces CLI → $CLI_DEST"
              mkdir -p "$(dirname "$CLI_DEST")"
              cp "$CLI_SRC" "$CLI_DEST"
              chmod +x "$CLI_DEST"
              echo "      ✓ CLI installed (no admin needed)"
              echo
            fi

            cd "$EXT_DIR"
            echo "[2/3] Installing dependencies (npm install)…"
            echo "      The npm “warn deprecated” lines are normal, just ignore them."
            npm install
            echo "      ✓ Dependencies installed"
            echo

            echo "[3/3] Importing the extension into Raycast. Please wait, don't close yet…"
            echo
            LOG="$EXT_DIR/.raycast-import.log"
            : > "$LOG"
            npm run dev >"$LOG" 2>&1 &
            DEV_PID=$!
            disown "$DEV_PID" 2>/dev/null || true
            tail -n +1 -f "$LOG" 2>/dev/null &
            TAIL_PID=$!
            disown "$TAIL_PID" 2>/dev/null || true

            # ray develop prints "ready  - built extension successfully" once the
            # extension is registered, then keeps watching. Wait for that line (or
            # for the dev server to exit), then stop the watcher.
            OK=0
            for _ in $(seq 1 120); do
              sleep 1
              if grep -qiE 'built extension successfully|ready[[:space:]]+-' "$LOG"; then OK=1; break; fi
              if ! kill -0 "$DEV_PID" 2>/dev/null; then
                if grep -qiE 'built extension successfully|ready' "$LOG"; then OK=1; fi
                break
              fi
            done
            if [ "$OK" = 1 ]; then sleep 2; fi

            # Stop the dev watcher and its children; the import is already registered.
            kill "$TAIL_PID" 2>/dev/null || true
            for p in $(pgrep -P "$DEV_PID" 2>/dev/null); do
              for q in $(pgrep -P "$p" 2>/dev/null); do kill "$q" 2>/dev/null || true; done
              kill "$p" 2>/dev/null || true
            done
            kill "$DEV_PID" 2>/dev/null || true

            echo
            if [ "$OK" = 1 ]; then
              echo "============================================================"
              echo "  ✅  DONE. Powerspaces is now in Raycast."
              echo
              echo "  ➜  It is SAFE TO CLOSE THIS WINDOW now  (press ⌘W)."
              echo "     No Terminal is needed from here on."
              echo "============================================================"
              echo
              echo "In Raycast, search “Open on Current Space”. Tip: give it the"
              echo "alias “o” or a ⌘⌥O hotkey to launch it in one keystroke."
            else
              echo "────────────────────────────────────────────────────────────"
              echo "⚠️  Couldn't confirm the import finished."
              echo "    Make sure the Raycast app is installed and you're signed in,"
              echo "    then run Set Up again. Full log:"
              echo "    $LOG"
              echo "────────────────────────────────────────────────────────────"
            fi
            echo
            """

        let scriptURL = workingExtensionDir.appendingPathComponent("setup.command")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // .command files open in Terminal by default; this runs the script there.
        NSWorkspace.shared.open(scriptURL)
    }

    /// POSIX single-quote a string for safe interpolation into the shell script.
    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
