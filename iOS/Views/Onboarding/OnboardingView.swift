import SwiftUI
import ClipCore

/// First-run explanation (3 pages). iOS cannot watch the clipboard in the background,
/// so this tells users exactly how clips get in.
struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0
    let lastPage = 2

    var body: some View {
        VStack(spacing: 16) {
            TabView(selection: $page) {
                OnboardingWelcomePage().tag(0)
                OnboardingCapturePage().tag(1)
                OnboardingPrivacyPage().tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: 8) {
                Button {
                    if page < lastPage {
                        withAnimation { page += 1 }
                    } else {
                        onFinish()
                    }
                } label: {
                    Text((page < lastPage ? "Continue" : "Get Started") as String)
                        .font(.headline)
                        .frame(maxWidth: 420)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("onboarding.primary")

                Button("Skip") {
                    onFinish()
                }
                .font(.subheadline)
                .opacity(page < lastPage ? 1 : 0)
                .disabled(page >= lastPage)
                .accessibilityHidden(page >= lastPage)
                .accessibilityIdentifier("onboarding.skip")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Theme.groupedBackground.ignoresSafeArea())
        .interactiveDismissDisabled()
        .accessibilityIdentifier("onboarding")
    }
}

private struct OnboardingPage<Content: View>: View {
    let systemImage: String
    let title: String
    let content: () -> Content

    init(systemImage: String, title: String, @ViewBuilder content: @escaping () -> Content) {
        self.systemImage = systemImage
        self.title = title
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: systemImage)
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                content()
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct OnboardingPoint: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Theme.accent)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingWelcomePage: View {
    var body: some View {
        OnboardingPage(systemImage: "rectangle.stack.badge.plus", title: "Everything you copy, in one place") {
            Text("ClipSync keeps a searchable history of text, links, images and colors, synced between your Mac, iPhone and iPad through your own iCloud.")
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            OnboardingPoint(
                systemImage: "exclamationmark.bubble",
                title: "One thing to know",
                detail: "iOS doesn't let apps watch the clipboard in the background. On iPhone and iPad, clips arrive in the ways shown on the next page — nothing is captured behind your back."
            )
        }
    }
}

private struct OnboardingCapturePage: View {
    var body: some View {
        OnboardingPage(systemImage: "arrow.down.doc", title: "Four ways in") {
            OnboardingPoint(
                systemImage: "doc.on.clipboard",
                title: "Save clipboard",
                detail: "After copying in any app, open ClipSync and tap Paste in the bar at the bottom of History."
            )
            OnboardingPoint(
                systemImage: "square.and.arrow.up",
                title: "Share sheet",
                detail: "In Safari, Photos or any app, tap Share, then Save to ClipSync."
            )
            OnboardingPoint(
                systemImage: "square.2.layers.3d",
                title: "Shortcuts",
                detail: "Use the Save Clipboard, Search and Copy Latest actions in the Shortcuts app, or from the Action button or Back Tap."
            )
            OnboardingPoint(
                systemImage: "laptopcomputer.and.iphone",
                title: "Universal Clipboard",
                detail: "Copy on your iPhone, and your Mac running ClipSync captures it automatically — then it syncs back here."
            )
        }
    }
}

private struct OnboardingPrivacyPage: View {
    var body: some View {
        let cloud = CloudAccountMonitor.shared
        OnboardingPage(systemImage: "lock.icloud", title: "Private by design") {
            OnboardingPoint(
                systemImage: "icloud",
                title: "Your iCloud, not our servers",
                detail: "History stays on your devices and in your private iCloud database. Turn on sync in Settings."
            )
            OnboardingCloudStatusLine(cloud: cloud)
            OnboardingPoint(
                systemImage: "eye.slash",
                title: "No tracking",
                detail: "No accounts, no analytics. Password managers' private copies are skipped."
            )
            OnboardingPoint(
                systemImage: "hand.tap",
                title: "Tap to copy",
                detail: "Tap any clip to copy it. Swipe to pin or delete; touch and hold for more."
            )
        }
    }
}

/// One non-blocking line with this device's iCloud state ("login" = the Apple Account in iCloud).
private struct OnboardingCloudStatusLine: View {
    @ObservedObject var cloud: CloudAccountMonitor

    private var text: String {
        guard cloud.hasChecked else { return "Checking iCloud…" }
        switch cloud.state {
        case .available:
            return "This device is signed in to iCloud."
        case .noAccount:
            return "This device is not signed in to iCloud. ClipSync works locally until you sign in."
        case .unsupportedBuild:
            return "This build can't use iCloud yet. ClipSync works on this device."
        case .restricted, .temporarilyUnavailable, .couldNotDetermine:
            return "iCloud isn't available right now. ClipSync works on this device."
        }
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.leading, 50)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("onboarding.iCloudStatus")
    }
}
