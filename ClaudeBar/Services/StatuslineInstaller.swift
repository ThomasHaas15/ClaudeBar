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

    static let scriptBody = #"""
    #!/bin/sh
    INPUT=$(cat)
    INPUT="$INPUT" /usr/bin/python3 - <<'PY'
    import json, os, sys
    raw = os.environ.get("INPUT", "")
    try:
        d = json.loads(raw)
    except Exception:
        sys.exit(0)
    rl = d.get("rate_limits") or {}
    home = os.path.expanduser("~/.claude")
    os.makedirs(home, exist_ok=True)
    out = os.path.join(home, "rate-limits.json")
    tmp = out + ".tmp"
    with open(tmp, "w") as f:
        json.dump(rl, f)
    os.replace(tmp, out)
    fh = rl.get("five_hour") or {}
    sd = rl.get("seven_day") or {}
    parts = []
    def pct(b):
        if not b: return None
        if "used_percentage" in b: return int(b["used_percentage"])
        if "utilization" in b:
            u = b["utilization"]
            return int(u * 100) if u <= 1.0 else int(u)
        return None
    fp = pct(fh); sp = pct(sd)
    if fp is not None:
        parts.append("5h:%d%%" % fp)
    if sp is not None:
        parts.append("7d:%d%%" % sp)
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
            state = .installed
        } else if let cmd = configured, !cmd.isEmpty, !pointsToOurs {
            state = .foreignStatusline(command: cmd)
        } else {
            state = .notInstalled
        }
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
