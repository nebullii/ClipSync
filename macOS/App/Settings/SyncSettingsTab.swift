import SwiftUI
import ClipCore

struct SyncSettingsTab: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ClipStore

    private var needsRelaunch: Bool {
        return settings.cloudSyncEnabled != store.isCloudSyncActive
    }

    var body: some View {
        Form {
            Section("iCloud") {
                Toggle("Sync history with iCloud", isOn: $settings.cloudSyncEnabled)
                    .accessibilityLabel("Sync history with iCloud")
                SettingsFootnote("History syncs through your own private iCloud database to your other Macs, iPhone and iPad. Nothing goes to any other server.")
                SettingsFootnote("Sync needs a signed build of ClipSync with iCloud enabled; development builds always stay local. Turning sync on or off takes effect after ClipSync relaunches.")
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

                if let error = store.storeError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsFootnote("Items larger than 20 MB stay on this Mac. In this version, large payloads (over 256 KB, such as most images) are also kept on this Mac only.")
            }
        }
        .formStyle(.grouped)
    }
}
