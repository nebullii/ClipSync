import SwiftUI
import AppKit
import ClipCore

/// "Login" in ClipSync is the Apple Account signed in to iCloud on this Mac.
/// This tab shows that account's state, the sync switch and what this session does.
struct SyncSettingsTab: View {
    var body: some View {
        // Read the shared monitor inside `body` (main actor) and observe it below.
        SyncSettingsContent(cloud: CloudAccountMonitor.shared)
    }
}

private struct SyncSettingsContent: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ClipStore
    @ObservedObject var cloud: CloudAccountMonitor

    private var needsRelaunch: Bool {
        return settings.cloudSyncEnabled != store.isCloudSyncActive
    }

    private var readiness: CloudSyncReadiness {
        return cloud.readiness(settings: settings, store: store)
    }

    /// Turning sync ON is blocked when it cannot work; turning it OFF never is.
    private var toggleDisabled: Bool {
        return !settings.cloudSyncEnabled && !readiness.allowsEnablingSync
    }

    var body: some View {
        Form {
            Section("iCloud account") {
                CloudAccountStatusRow(cloud: cloud, readiness: readiness)

                HStack {
                    Button("Refresh") {
                        Task { await cloud.refresh() }
                    }
                    .disabled(cloud.isRefreshing || !cloud.isSupportedBuild)
                    .accessibilityLabel("Check the iCloud account again")
                    Button("Open iCloud Settings…") {
                        SyncSettingsContent.openICloudSettings()
                    }
                    .accessibilityLabel("Open iCloud settings in System Settings")
                    Spacer()
                    if cloud.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                SettingsFootnote("ClipSync has no separate account or password. It uses the Apple Account you are signed in to in System Settings, and only your own private iCloud database.")
            }

            Section("iCloud") {
                Toggle("Sync history with iCloud", isOn: $settings.cloudSyncEnabled)
                    .disabled(toggleDisabled)
                    .accessibilityLabel("Sync history with iCloud")
                if toggleDisabled, let reason = readiness.disabledReason {
                    SettingsFootnote(reason)
                }
                SettingsFootnote("History syncs through your own private iCloud database to your other Macs, iPhone and iPad. Nothing goes to any other server.")
                SettingsFootnote("Turning sync on or off takes effect after ClipSync relaunches.")
            }

            Section("Status") {
                LabeledContent("This session") {
                    Text(store.isCloudSyncActive ? "Syncing with iCloud" : "Local only")
                }
                .accessibilityElement(children: .combine)

                if needsRelaunch {
                    HStack {
                        Text(settings.cloudSyncEnabled ? "Relaunch to start syncing." : "Relaunch to stop syncing.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch ClipSync") {
                            controller.relaunch()
                        }
                        .accessibilityLabel("Relaunch ClipSync now")
                    }
                }

                if let error = store.storeError, !SyncSettingsContent.isErrorShownAbove(readiness) {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsFootnote("Items larger than 20 MB stay on this Mac. In this version, large payloads (over 256 KB, such as most images) are also kept on this Mac only.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            cloud.attach(settings: settings, store: store)
            cloud.refreshInBackground()
        }
    }

    /// The status row already shows the store error for `.error` / `.unsupportedBuild`.
    private static func isErrorShownAbove(_ readiness: CloudSyncReadiness) -> Bool {
        switch readiness {
        case .error, .unsupportedBuild:
            return true
        default:
            return false
        }
    }

    /// Opens System Settings › Apple Account (iCloud), falling back to System Settings itself.
    static func openICloudSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings",
            "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
        let app = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        if !NSWorkspace.shared.open(app) {
            _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Preferences.app"))
        }
    }
}

/// Coloured dot + title + explanation for the iCloud account / sync readiness.
struct CloudAccountStatusRow: View {
    @ObservedObject var cloud: CloudAccountMonitor
    let readiness: CloudSyncReadiness

    private var title: String {
        return cloud.hasChecked ? readiness.title : "Checking iCloud…"
    }

    private var explanation: String {
        return cloud.hasChecked ? readiness.explanation : "Asking iCloud whether this Mac is signed in."
    }

    private var dotColor: Color {
        guard cloud.hasChecked else { return Color.secondary }
        switch readiness.tone {
        case .good:
            return Color.green
        case .neutral:
            return Color.secondary
        case .warning:
            return Color.orange
        case .problem:
            return Color.red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("iCloud: \(title). \(explanation)")
    }
}
