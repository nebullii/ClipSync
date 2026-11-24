import SwiftUI
import ClipCore

struct HistorySettingsTab: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ClipStore

    private static let standardMaxCounts = [100, 500, 1_000, 5_000, 10_000, 50_000, 0]

    private var maxCountOptions: [Int] {
        var options = HistorySettingsTab.standardMaxCounts
        if !options.contains(settings.maxHistoryCount) {
            options.insert(settings.maxHistoryCount, at: max(0, options.count - 1))
        }
        return options
    }

    private func label(forMaxCount count: Int) -> String {
        if count == 0 { return "Unlimited" }
        return "\(count.formatted()) items"
    }

    var body: some View {
        Form {
            Section("Keep") {
                Picker("Keep history for", selection: $settings.retention) {
                    ForEach(RetentionPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .accessibilityLabel("Keep history for")

                Picker("Maximum number of items", selection: $settings.maxHistoryCount) {
                    ForEach(maxCountOptions, id: \.self) { count in
                        Text(label(forMaxCount: count)).tag(count)
                    }
                }
                .accessibilityLabel("Maximum number of items in history")

                SettingsFootnote("Older items are removed automatically. Pinned items and items in pinboards are always kept.")
            }

            Section("History") {
                LabeledContent("Items in history") {
                    Text(store.itemCount().formatted())
                        .monospacedDigit()
                }
                .id(store.revision)
                .accessibilityElement(children: .combine)

                HStack {
                    Button("Clean Up Now") {
                        controller.runMaintenanceNow()
                    }
                    .accessibilityLabel("Clean up history now")
                    .accessibilityHint("Removes items older than the retention setting")

                    Spacer()

                    Button("Clear History…", role: .destructive) {
                        controller.confirmClearHistory()
                    }
                    .accessibilityLabel("Clear history")
                    .accessibilityHint("Asks for confirmation. Pinned items are kept.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
