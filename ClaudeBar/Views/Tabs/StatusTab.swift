import SwiftUI

struct StatusTab: View {
    @Environment(SessionsStore.self) private var sessions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Version", value: sessions.version ?? "—")
            row("Status", value: humanStatus)
            row("Active sessions", value: "\(sessions.activeCount)")
            Divider().padding(.top, 4)
            statuslineRow
        }
    }

    @ViewBuilder
    private func row(_ label: String, value: String, mono: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            (mono ? Text(value).font(.system(.body, design: .monospaced)) : Text(value))
                .foregroundStyle(.primary)
        }
        .font(.body)
    }

    private var humanStatus: String {
        guard !sessions.sessions.isEmpty else { return "Not running" }
        let statuses = sessions.sessions.compactMap { $0.status?.lowercased() }
        let busy = statuses.filter { $0 == "busy" }.count
        if busy > 0 {
            return sessions.sessions.count == 1 ? "Working" : "\(busy) working, \(sessions.sessions.count - busy) idle"
        }
        return "Idle"
    }


    @ViewBuilder
    private var statuslineRow: some View {
        let installer = StatuslineInstaller.shared
        VStack(alignment: .leading, spacing: 6) {
            Text("Statusline").sectionHeaderStyle()
            switch installer.state {
            case .installed:
                HStack {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Installed")
                    Spacer()
                    Button("Uninstall") {
                        try? installer.uninstall()
                    }
                    .buttonStyle(.link)
                }
            case .notInstalled:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not installed")
                        .foregroundStyle(.secondary)
                    Text("Install the relay to populate rate limits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Install statusline") {
                        try? installer.install()
                    }
                    .controlSize(.small)
                }
            case .foreignStatusline(let cmd):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Another statusline is configured")
                        .foregroundStyle(.secondary)
                    Text(cmd)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Button("Replace with ClaudeBar relay") {
                        try? installer.install()
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}
