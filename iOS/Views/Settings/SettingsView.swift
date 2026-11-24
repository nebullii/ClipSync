import SwiftUI
import UIKit
import ClipCore

/// iCloud account + sync, retention, clear history, how capture works, privacy, version.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            SettingsSyncSection(cloud: model.cloud)
            SettingsHistorySection()
            SettingsHelpSection()
            SettingsSecuritySection()
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

/// "Login" = the Apple Account signed in to iCloud on this device. Shows its state
/// (same source as the History banner), the sync switch and a link to Settings.
private struct SettingsSyncSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var cloud: CloudStatusMonitor

    private var readiness: CloudSyncReadiness {
        return cloud.readiness(store: model.store, settings: settings)
    }

    /// Turning sync ON is blocked when it cannot work; turning it OFF never is.
    private var toggleDisabled: Bool {
        return !settings.cloudSyncEnabled && !readiness.allowsEnablingSync
    }

    private var title: String {
        if model.store.isInMemory {
            return "Temporary storage"
        }
        return cloud.hasChecked ? readiness.title : "Checking iCloud…"
    }

    private var explanation: String {
        if model.store.isInMemory {
            return "Nothing is saved in this session, and nothing syncs."
        }
        if readiness == .needsRelaunch {
            return "Quit and reopen ClipSync to apply the sync setting. History keeps working on this device."
        }
        return cloud.hasChecked ? readiness.explanation : "Asking iCloud whether this device is signed in."
    }

    private var dotColor: Color {
        if model.store.isInMemory || !cloud.hasChecked {
            return Color.secondary
        }
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

    private var showsStoreError: Bool {
        guard model.store.storeError != nil else { return false }
        switch readiness {
        case .error, .unsupportedBuild:
            return false
        default:
            return true
        }
    }

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                    .padding(.top, 5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.iCloudStatus")

            Toggle("Sync with iCloud", isOn: $settings.cloudSyncEnabled)
                .disabled(toggleDisabled)
                .accessibilityIdentifier("settings.iCloudSync")
            if toggleDisabled, let reason = readiness.disabledReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if readiness == .signedOut || readiness.tone == .problem {
                Button("Open Settings") {
                    CloudSettingsLink.openAppSettings()
                }
                .accessibilityIdentifier("settings.openSystemSettings")
            }
            if showsStoreError, let error = model.store.storeError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text("No separate account: ClipSync uses the Apple Account signed in to iCloud on this device. Changes take effect next launch. Images over 256 KB stay on the device that saved them.")
        }
        .onAppear {
            cloud.refresh()
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

/// App Lock, app-switcher cover, link previews and an honest note on where data lives.
private struct SettingsSecuritySection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appLock: AppLockController

    private var deviceName: String {
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    private var lockTitle: String {
        if let name = appLock.biometryKind.displayName {
            return "App Lock (\(name) or passcode)"
        }
        return "App Lock (passcode)"
    }

    private var lockBinding: Binding<Bool> {
        return Binding(
            get: { settings.appLockEnabled },
            set: { wanted in requestChange(wanted) }
        )
    }

    private func requestChange(_ enabled: Bool) {
        let lock = appLock
        Task { @MainActor in
            _ = await lock.setEnabled(enabled, reason: enabled ? "turn on App Lock" : "turn off App Lock")
        }
    }

    private var locationNote: String {
        let place: String
        if model.store.isInMemory {
            place = "Temporary storage: nothing from this session is saved."
        } else if model.store.isCloudSyncActive {
            place = "On this \(deviceName) and in your private iCloud database."
        } else {
            place = "On this \(deviceName) only."
        }
        // Not "protected whenever locked": with "until first unlock" that would overstate it.
        return place + " Protected by iOS data protection, which is tied to your passcode."
    }

    var body: some View {
        Section {
            Toggle(lockTitle, isOn: lockBinding)
                .disabled(appLock.isAuthenticating)
                .accessibilityIdentifier("settings.appLock")
            Picker("Lock after", selection: $settings.lockTimeout) {
                ForEach(LockTimeout.allCases) { timeout in
                    Text(timeout.displayName).tag(timeout)
                }
            }
            .disabled(!settings.appLockEnabled)
            .accessibilityIdentifier("settings.lockTimeout")
            if let message = appLock.lastMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Toggle("Hide content in the app switcher", isOn: $settings.privacyCoverEnabled)
                .accessibilityIdentifier("settings.privacyCover")
            Toggle("Fetch link titles and icons — contacts the linked website", isOn: $settings.linkPreviewsEnabled)
                .accessibilityIdentifier("settings.linkPreviews")
            VStack(alignment: .leading, spacing: 6) {
                Label(locationNote, systemImage: "lock.iphone")
                Text("ClipSync uses iOS's \u{201C}until first unlock\u{201D} protection so Shortcuts, the share sheet and iCloud sync can save clips while your \(deviceName) is locked. After a restart your history stays encrypted until you first unlock; after that iOS can open it for ClipSync. ClipSync adds no encryption of its own.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.securityNote")
        } header: {
            Text("Security")
        } footer: {
            Text("App Lock hides your history behind \(appLock.biometryKind.displayName ?? "your passcode") when ClipSync opens or returns after the time above, and Shortcuts can't read clips while it's locked. Saving new clips (share sheet, Shortcuts) still works while locked. Link previews are off by default: with them off, ClipSync makes no network requests of its own.")
        }
        .onAppear {
            appLock.refreshAvailability()
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
