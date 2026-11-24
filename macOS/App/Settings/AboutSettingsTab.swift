import AppKit
import SwiftUI

struct AboutSettingsTab: View {
    private var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("ClipSync")
                    .font(.title2.weight(.semibold))
                Text(versionText)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Your privacy", systemImage: "lock.shield")
                        .font(.headline)
                    Text("Your clipboard history stays on this Mac and, if you turn on sync, in your own private iCloud account. ClipSync has no servers, no accounts, no analytics and no tracking.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Passwords and other items that apps mark as private are never recorded, and you can ignore any app or pause capture at any time.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            .accessibilityElement(children: .combine)

            Text("Uses KeyboardShortcuts by Sindre Sorhus (MIT License).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
