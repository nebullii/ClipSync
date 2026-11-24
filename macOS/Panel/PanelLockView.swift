// Security pass: the panel's lock screen (App Lock). Shows no clipboard content at all.

import SwiftUI
import ClipCore

struct PanelLockView: View {
    @ObservedObject var appLock: AppLockController
    let onUnlock: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("ClipSync is locked")
                .font(.system(size: 16, weight: .semibold))
            Text("Your clipboard history is hidden. Copying still works and is saved in the background.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(action: onUnlock) {
                Label(appLock.unlockButtonTitle, systemImage: appLock.biometryKind.systemImageName)
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .disabled(appLock.isAuthenticating)
            .accessibilityLabel(appLock.unlockButtonTitle)
            .accessibilityHint("Asks for Touch ID or your Mac password")
            if let message = appLock.lastMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            Text("Press Return to unlock, Esc to close.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("ClipSync is locked")
    }
}
