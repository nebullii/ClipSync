import SwiftUI
import ClipCore
import KeyboardShortcuts

/// First-run window: 1) what ClipSync does, 2) Accessibility, 3) shortcut + login item.
/// Environment objects (set by `WindowCoordinator`): AppController, AppSettings,
/// AccessibilityPermission, LaunchAtLoginController.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @EnvironmentObject private var controller: AppController

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome:
                    WelcomeStep()
                case .accessibility:
                    AccessibilityStep()
                case .finish:
                    FinishStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.top, 28)

            Divider()

            HStack {
                StepIndicator(current: model.step)
                Spacer()
                if model.step != .welcome {
                    Button("Back") {
                        goBack()
                    }
                    .accessibilityLabel("Back to the previous step")
                }
                if model.step == .finish {
                    Button("Done") {
                        controller.completeOnboarding()
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Finish setup")
                } else {
                    Button("Continue") {
                        goForward()
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Continue to the next step")
                }
            }
            .padding(16)
        }
        .frame(width: 540, height: 440)
    }

    private func goForward() {
        if let next = OnboardingStep(rawValue: model.step.rawValue + 1) {
            model.step = next
        }
    }

    private func goBack() {
        if let previous = OnboardingStep(rawValue: model.step.rawValue - 1) {
            model.step = previous
        }
    }
}

private struct StepIndicator: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Circle()
                    .fill(step == current ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }
}

private struct OnboardingHeader: View {
    let systemImage: String
    let title: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FeatureRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 22)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct WelcomeStep: View {
    private var shortcutText: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .togglePanel) {
            return shortcut.description
        }
        return "your shortcut"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingHeader(systemImage: "doc.on.clipboard", title: "Welcome to ClipSync")
            FeatureRow(systemImage: "tray.full", text: "ClipSync quietly keeps everything you copy: text, rich text, links, images, files and colors.")
            FeatureRow(systemImage: "keyboard", text: "Press \(shortcutText) in any app to search your history and paste an item.")
            FeatureRow(systemImage: "lock.shield", text: "Your history stays on this Mac and in your own iCloud. Passwords and apps you ignore are never recorded.")
        }
    }
}

private struct AccessibilityStep: View {
    @EnvironmentObject private var accessibility: AccessibilityPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeader(systemImage: "hand.tap", title: "Let ClipSync paste for you")
            Text("To paste an item straight into the app you are using, ClipSync needs Accessibility access. It is only used to press ⌘V for you.")
                .fixedSize(horizontal: false, vertical: true)

            AccessibilityStatusRow()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )

            if !accessibility.isGranted {
                Button("Open System Settings") {
                    accessibility.requestPrompt()
                    accessibility.openSystemSettings()
                }
                .accessibilityLabel("Open System Settings to allow Accessibility access")
                Text("In Privacy & Security › Accessibility, turn on ClipSync. If it is already on but pasting does not work, remove it with − and add it again. You can also skip this step: ClipSync will copy items and you press ⌘V yourself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct FinishStep: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var launchAtLogin: LaunchAtLoginController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingHeader(systemImage: "checkmark.seal", title: "Make it yours")

            HStack {
                Text("Shortcut to open ClipSync")
                Spacer()
                KeyboardShortcuts.Recorder("", name: .togglePanel)
                    .accessibilityLabel("Keyboard shortcut that opens ClipSync")
                    .accessibilityHint("Click, then press the new shortcut")
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Open ClipSync at login", isOn: $settings.launchAtLogin)
                    .accessibilityLabel("Open ClipSync at login")
                if let error = launchAtLogin.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if launchAtLogin.requiresApproval {
                    Text(launchAtLogin.statusDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Text("ClipSync lives in the menu bar. Settings, pause and recent items are in its menu.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
