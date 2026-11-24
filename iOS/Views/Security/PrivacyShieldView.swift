import SwiftUI
import UIKit
import ClipCore

/// Content of the shield window (SecurityCoordinator): the App Lock screen while locked,
/// otherwise the opaque privacy cover shown in the app switcher. Never shows any clip.
struct PrivacyShieldView: View {
    @ObservedObject var state: PrivacyShieldState
    @ObservedObject var appLock: AppLockController
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
            if appLock.isLocked {
                AppLockScreen(appLock: appLock, onUnlock: onUnlock)
            } else {
                PrivacyCoverContent()
            }
        }
        .accessibilityAddTraits(.isModal)
    }
}

/// "ClipSync is locked" + Unlock with Face ID / Touch ID / passcode.
struct AppLockScreen: View {
    @ObservedObject var appLock: AppLockController
    let onUnlock: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("ClipSync is locked")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("lock.title")
            Text("Your clipboard history is hidden until you unlock.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(action: onUnlock) {
                Label(appLock.unlockButtonTitle, systemImage: appLock.biometryKind.systemImageName)
                    .frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.accent)
            .disabled(appLock.isAuthenticating)
            .accessibilityIdentifier("lock.unlockButton")
            if let message = appLock.lastMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
    }
}

/// Opaque, branded app-switcher cover.
struct PrivacyCoverContent: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(Theme.accent)
            Text("ClipSync")
                .font(.title2.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ClipSync")
    }
}
