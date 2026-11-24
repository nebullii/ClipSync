import SwiftUI
import ClipCore

/// Retention, iCloud, clear history, how capture works, privacy, version.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            SettingsHistorySection()
            SettingsSyncSection(cloud: model.cloud)
            SettingsHelpSection()
            SettingsPrivacySection()
            SettingsAboutSection()
        }
        .navigationTitle("Settings")
        .onChange(of: settings.retention) { _, _ in
            model.store.runMaintenance()
        }
        .onChange(of: settings.maxHistoryCount) { _, _ in
            model.store.runMaintenance()
        }
        .accessibilityIdentifier("settings.form")
    }
}

private struct SettingsHistorySection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var itemCount = 0
    @State private var confirmingClear = false

    private let historyLimits = [1_000, 5_000, 10_000, 20_000, 0]

    var body: some View {
        Section {
            Picker("Keep history", selection: $settings.retention) {
                ForEach(RetentionPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .accessibilityIdentifier("settings.retention")
            Picker("Maximum clips", selection: $settings.maxHistoryCount) {
                ForEach(historyLimits, id: \.self) { limit in
                    Text(limit == 0 ? "Unlimited" : limit.formatted()).tag(limit)
                }
            }
            LabeledContent("Clips in history", value: itemCount.formatted())
            Button("Clear History…", role: .destructive) {
                confirmingClear = true
            }
            .accessibilityIdentifier("settings.clearHistory")
        } header: {
            Text("History")
        } footer: {
            Text("Pinned clips and clips in pinboards are never removed by cleanup.")
        }
        .confirmationDialog("Clear history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Unpinned Clips", role: .destructive) {
                model.clearHistory(keepPinned: true)
            }
            Button("Clear Everything", role: .destructive) {
                model.clearHistory(keepPinned: false)
            }
        } message: {
            Text("This can't be undone. With iCloud sync on, clips are also removed from your other devices.")
        }
        .onAppear {
            itemCount = model.store.itemCount()
        }
        .onReceive(model.store.$revision) { _ in
            itemCount = model.store.itemCount()
        }
    }
}

private struct SettingsSyncSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var cloud: CloudStatusMonitor

    private var statusText: String {
        if model.store.isInMemory {
            return "Temporary storage (nothing is saved)"
        }
        if model.store.isCloudSyncActive {
            return cloud.isICloudSignedIn ? "Syncing with iCloud" : "Waiting for iCloud sign-in"
        }
        if settings.cloudSyncEnabled {
            return "Starts after relaunch"
        }
        return "This device only"
    }

    var body: some View {
        Section {
            Toggle("Sync with iCloud", isOn: $settings.cloudSyncEnabled)
                .accessibilityIdentifier("settings.iCloudSync")
            LabeledContent("Status", value: statusText)
            LabeledContent("iCloud account", value: cloud.isICloudSignedIn ? "Signed in" : "Not signed in")
            if let error = model.store.storeError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text("Sync uses your own private iCloud database. Changing this takes effect the next time ClipSync launches, and sync only works in a signed build with iCloud enabled. Images larger than 256 KB currently stay on the device that saved them.")
        }
    }
}

private struct SettingsHelpSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section("Help") {
            Button {
                model.showOnboarding()
            } label: {
                Label("How capture works", systemImage: "questionmark.circle")
            }
            .accessibilityIdentifier("settings.howCaptureWorks")
        }
    }
}

private struct SettingsPrivacySection: View {
    var body: some View {
        Section("Privacy") {
            VStack(alignment: .leading, spacing: 8) {
                Label("Your clips stay on your devices and in your own iCloud account.", systemImage: "lock.shield")
                Label("No accounts, no servers, no analytics, no tracking.", systemImage: "eye.slash")
                Label("ClipSync reads the clipboard only when you tap Paste or share to it.", systemImage: "hand.tap")
            }
            .font(.callout)
            .padding(.vertical, 4)
        }
    }
}

private struct SettingsAboutSection: View {
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        Section("About") {
            LabeledContent("Version", value: versionText)
                .accessibilityIdentifier("settings.version")
        }
    }
}
