import SwiftUI
import UIKit
import ClipCore

/// What the iCloud banner should say, derived from ClipCore's `CloudSyncReadiness`
/// (the same value Settings shows). Everything keeps working locally in every state.
enum CloudBannerState: Equatable {
    case none
    case readiness(CloudSyncReadiness)

    @MainActor
    static func resolve(store: ClipStore, settings: AppSettings, cloud: CloudStatusMonitor) -> CloudBannerState {
        // Don't flash "checking" states; wait for the first answer.
        guard cloud.hasChecked else { return .none }
        let readiness = cloud.readiness(store: store, settings: settings)
        if readiness == .syncing {
            return .none
        }
        return .readiness(readiness)
    }

    /// The readiness to show, or nil for no banner.
    var readiness: CloudSyncReadiness? {
        switch self {
        case .none:
            return nil
        case .readiness(let value):
            return value
        }
    }
}

/// Non-blocking banner shown above History when iCloud is off or sync is inactive.
struct CloudBanner: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var cloud: CloudStatusMonitor

    var body: some View {
        let state = CloudBannerState.resolve(store: store, settings: settings, cloud: cloud)
        if let readiness = state.readiness, !cloud.isBannerDismissed, !model.isUITest {
            CloudBannerContent(readiness: readiness, onDismiss: { cloud.isBannerDismissed = true })
        }
    }
}

private struct CloudBannerContent: View {
    let readiness: CloudSyncReadiness
    let onDismiss: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    private var icon: String {
        switch readiness {
        case .syncing: return "icloud"
        case .readyButOff: return "icloud"
        case .needsRelaunch: return "arrow.clockwise.icloud"
        case .signedOut: return "icloud.slash"
        case .unsupportedBuild: return "icloud.slash"
        case .error: return "exclamationmark.icloud"
        }
    }

    private var message: String {
        if readiness == .needsRelaunch {
            return "Quit and reopen ClipSync to apply the sync setting. History keeps working on this device."
        }
        return readiness.explanation
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(readiness.title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if readiness == .readyButOff {
                    Button("Turn On iCloud Sync") {
                        settings.cloudSyncEnabled = true
                        model.toasts.show("Sync turns on next time ClipSync opens", systemImage: "icloud", style: .info)
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
                } else if readiness == .signedOut {
                    Button("Open Settings") {
                        CloudSettingsLink.openAppSettings()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss iCloud notice")
        }
        .padding(12)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal)
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.cloudBanner")
    }
}

/// Opens the Settings app (this app's page; iCloud sign-in is at the top of Settings).
enum CloudSettingsLink {
    @MainActor
    static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
