import SwiftUI

struct StatusTab: View {
    @Environment(SessionsStore.self) private var sessions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Claude Code", value: sessions.version ?? "—")
            row("Status", value: sessions.activitySummary)
            row("Active sessions", value: "\(sessions.activeCount)")
            launchAtLoginRow
            Divider().padding(.top, 4)
            statuslineRow
            Divider()
            updatesSection
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

    @ViewBuilder
    private var launchAtLoginRow: some View {
        let loginItem = LoginItem.shared
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Launch at login").foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .font(.body)

            if loginItem.requiresApproval {
                HStack(spacing: 6) {
                    Text("Approve in System Settings to enable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open") { loginItem.openSettings() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
        }
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

    @ViewBuilder
    private var updatesSection: some View {
        let updater = Updater.shared
        VStack(alignment: .leading, spacing: 6) {
            Text("Updates").sectionHeaderStyle()

            HStack {
                Text("ClaudeBar \(updater.currentVersion.description)")
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { updater.automatic },
                    set: { updater.automatic = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .font(.body)

            HStack(spacing: 6) {
                updateStatus(updater)
                Spacer()
                switch updater.state {
                case .checking, .downloading, .installing, .relaunching:
                    EmptyView()
                case .available:
                    Button("Install and restart") {
                        Task { await updater.installAvailable() }
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                case .idle, .failed:
                    Button("Check now") {
                        Task { await updater.check(userInitiated: true) }
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }

            if let page = updater.manualDownload, updater.state.isFailure {
                Button("Open release page") { NSWorkspace.shared.open(page) }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func updateStatus(_ updater: Updater) -> some View {
        Group {
            switch updater.state {
            case .idle:
                if let checked = updater.lastChecked {
                    Text("Up to date — checked \(checked.formatted(.relative(presentation: .numeric)))")
                } else if updater.automatic {
                    Text("Checks hourly.")
                } else {
                    Text("Automatic updates are off.")
                }
            case .checking:
                Text("Checking…")
            case .available(let version):
                Text("Version \(version) is available.")
            case .downloading(let version):
                Text("Downloading \(version)…")
            case .installing(let version):
                Text("Installing \(version)…")
            case .relaunching:
                Text("Restarting…")
            case .failed(let reason):
                Text(reason)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
}

private extension Updater.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
