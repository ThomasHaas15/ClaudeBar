import Foundation

@MainActor
@Observable
final class StatuslineInstaller {
    static let shared = StatuslineInstaller()

    enum State: Equatable {
        case notInstalled
        case installed
        case foreignStatusline(command: String)
    }

    private(set) var state: State = .notInstalled

    private init() { refresh() }

    /// The relay Claude Code runs on every prompt. It is the app's only source
    /// of rate-limit data: Claude Code keeps the unified window percentages in
    /// memory and hands them to the status line, and writes them nowhere else.
    ///
    /// The version marker in its header is bumped whenever the payload it reads
    /// changes shape — `refresh()` rewrites an older copy in place, because a
    /// relay installed by a previous version of ClaudeBar keeps running against
    /// the new Claude Code until someone replaces it.
    static let scriptBody = #"""
    #!/bin/sh
    # claudebar-statusline v2 — managed by ClaudeBar, replaced on upgrade.
    INPUT=$(cat)
    INPUT="$INPUT" /usr/bin/python3 - <<'PY'
    import json, os, sys
    raw = os.environ.get("INPUT", "")
    try:
        d = json.loads(raw)
    except Exception:
        sys.exit(0)
    rl = d.get("rate_limits") or {}
    home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    os.makedirs(home, exist_ok=True)
    out = os.path.join(home, "rate-limits.json")
    tmp = out + ".tmp"
    with open(tmp, "w") as f:
        json.dump(rl, f)
    os.replace(tmp, out)

    def pct(b):
        if not b:
            return None
        # Claude Code sends used_percentage (0-100); older builds sent
        # utilization, as a fraction on some versions and a percentage on others.
        if "used_percentage" in b:
            return int(b["used_percentage"])
        if "utilization" in b:
            u = b["utilization"]
            return int(u * 100) if u <= 1.0 else int(u)
        return None

    parts = []
    for key, label in (("five_hour", "5h"), ("seven_day", "7d"), ("spend_limit", "$")):
        p = pct(rl.get(key))
        if p is not None:
            parts.append("%s:%d%%" % (label, p))
    print(" ".join(parts))
    PY
    """#

    func refresh() {
        let fm = FileManager.default
        let scriptPath = ClaudePaths.statuslineScript.path
        let scriptExists = fm.fileExists(atPath: scriptPath)

        let configured = currentConfiguredCommand()
        let pointsToOurs = configured?.contains("claudebar-statusline.sh") == true

        if pointsToOurs && scriptExists {
            upgradeScriptIfStale()
            state = .installed
        } else if let cmd = configured, !cmd.isEmpty, !pointsToOurs {
            state = .foreignStatusline(command: cmd)
        } else {
            state = .notInstalled
        }
    }

    /// Replaces a relay left behind by an older ClaudeBar. Without this the
    /// script installed once keeps running forever against a Claude Code that
    /// has moved on — the v1 relay read `rate_limits.five_hour.utilization`,
    /// which current versions no longer send, so it wrote the file the app
    /// reads but showed `5h:0%` in the terminal.
    ///
    /// Only ever rewrites a file this app is already the configured owner of,
    /// and only when its contents differ from the current relay.
    @discardableResult
    func upgradeScriptIfStale(at url: URL = ClaudePaths.statuslineScript) -> Bool {
        guard let onDisk = try? String(contentsOf: url, encoding: .utf8), onDisk != Self.scriptBody else {
            return false
        }
        guard (try? Self.scriptBody.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            return false
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return true
    }

    func install() throws {
        let fm = FileManager.default
        let dir = ClaudePaths.home
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let url = ClaudePaths.statuslineScript
        try Self.scriptBody.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        try patchSettings(addCommand: url.path)
        refresh()
    }

    func uninstall() throws {
        try unpatchSettings()
        let url = ClaudePaths.statuslineScript
        try? FileManager.default.removeItem(at: url)
        refresh()
    }

    private func currentConfiguredCommand() -> String? {
        guard
            let data = try? Data(contentsOf: ClaudePaths.settings),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let statusLine = json["statusLine"] as? [String: Any],
            let command = statusLine["command"] as? String
        else { return nil }
        return command
    }

    private func patchSettings(addCommand command: String) throws {
        let url = ClaudePaths.settings
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = parsed
        }
        dict["statusLine"] = [
            "type": "command",
            "command": command,
            "padding": 0
        ] as [String: Any]
        let out = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        try out.write(to: url, options: .atomic)
    }

    private func unpatchSettings() throws {
        let url = ClaudePaths.settings
        guard
            let data = try? Data(contentsOf: url),
            var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        dict.removeValue(forKey: "statusLine")
        let out = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        try out.write(to: url, options: .atomic)
    }
}
