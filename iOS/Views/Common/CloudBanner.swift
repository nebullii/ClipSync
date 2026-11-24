import SwiftUI
import ClipCore

/// What the iCloud banner should say. Everything keeps working locally in every state.
enum CloudBannerState: Equatable {
    case none
    case storeFallback(String)
    case signedOut(syncWanted: Bool)
    case syncOff
    case syncInactive

    @MainActor
    static func resolve(store: ClipStore, settings: AppSettings, signedIn: Bool) -> CloudBannerState {
        if let error = store.storeError, !error.isEmpty {
            return .storeFallback(error)
        }
        if settings.cloudSyncEnabled {
            if !signedIn {
                return .signedOut(syncWanted: true)
            }
            if !store.isCloudSyncActive {
                return .syncInactive
            }
            return .none
        }
        if !signedIn {
            return .signedOut(syncWanted: false)
        }
        return .syncOff
    }
}

/// Non-blocking banner shown above History when iCloud is off or sync is inactive.
struct CloudBanner: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var cloud: CloudStatusMonitor

    var body: some View {
        let state = CloudBannerState.resolve(store: store, settings: settings, signedIn: cloud.isICloudSignedIn)
        if state != .none && !cloud.isBannerDismissed && !model.isUITest {
            CloudBannerContent(state: state, onDismiss: { cloud.isBannerDismissed = true })
        }
    }
}

private struct CloudBannerContent: View {
    let state: CloudBannerState
    let onDismiss: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    private var icon: String {
        switch state {
        case .storeFallback: return "exclamationmark.icloud"
        case .signedOut: return "icloud.slash"
        case .syncOff: return "icloud"
        case .syncInactive: return "arrow.clockwise.icloud"
        case .none: return "icloud"
        }
    }

    private var title: String {
        switch state {
        case .storeFallback: return "Using local storage"
        case .signedOut(let wanted): return wanted ? "Sign in to iCloud to sync" : "iCloud is off"
        case .syncOff: return "iCloud sync is off"
        case .syncInactive: return "Sync starts after a relaunch"
        case .none: return ""
        }
    }

    private var message: String {
        switch state {
        case .storeFallback(let detail):
            return detail
        case .signedOut:
            return "Your history stays on this device until you sign in to iCloud in the Settings app."
        case .syncOff:
            return "History stays on this device. Turn on sync to see what you copy on your Mac."
        case .syncInactive:
            return "Quit and reopen ClipSync. Sync also needs a signed build with iCloud enabled."
        case .none:
            return ""
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if state == .syncOff {
                    Button("Turn On iCloud Sync") {
                        settings.cloudSyncEnabled = true
                        model.toasts.show("Sync turns on next time ClipSync opens", systemImage: "icloud", style: .info)
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
