import SwiftUI
import UIKit

struct Toast: Identifiable, Equatable {
    enum Style: Equatable {
        case success, info, warning
    }

    let id = UUID()
    let message: String
    let systemImage: String
    let style: Style
}

/// Brief, non-blocking feedback ("Copied", "Saved"). Also announced to VoiceOver.
@MainActor
final class ToastCenter: ObservableObject {
    @Published private(set) var current: Toast? = nil
    private var dismissTask: Task<Void, Never>? = nil

    func show(_ message: String, systemImage: String = "checkmark.circle.fill", style: Toast.Style = .success) {
        let toast = Toast(message: message, systemImage: systemImage, style: style)
        current = toast
        UIAccessibility.post(notification: .announcement, argument: message)
        dismissTask?.cancel()
        let toastID = toast.id
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            if Task.isCancelled { return }
            self?.dismiss(id: toastID)
        }
    }

    func dismiss(id: UUID) {
        if current?.id == id {
            current = nil
        }
    }
}

/// Top overlay. Never placed over the bottom save bar: the system paste control must
/// stay unobscured or it ignores taps.
struct ToastOverlay: View {
    @ObservedObject var center: ToastCenter

    var body: some View {
        VStack {
            if let toast = center.current {
                ToastBubble(toast: toast)
                    .id(toast.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: center.current)
        .allowsHitTesting(false)
    }
}

private struct ToastBubble: View {
    let toast: Toast

    private var iconColor: Color {
        switch toast.style {
        case .success: return Theme.accent
        case .info: return .secondary
        case .warning: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.systemImage)
                .foregroundStyle(iconColor)
            Text(toast.message)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toast")
    }
}
