// Owned by the extensions engineer.
// Compact status card hosted by ShareViewController in a UIHostingController.

import SwiftUI

@MainActor
final class ShareModel: ObservableObject {
    enum Phase: Equatable {
        case working(String)
        case saved(detail: String?)
        case failed(message: String, detail: String?)
    }

    @Published var phase: Phase = .working("Saving to ClipSync\u{2026}")
}

struct ShareStatusView: View {
    @ObservedObject var model: ShareModel
    let onDone: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
            card
                .frame(maxWidth: 320)
                .padding(24)
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            icon
                .font(.system(size: 40, weight: .semibold))
                .frame(height: 44)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let detail = detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
            }
            button
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch model.phase {
        case .working:
            ProgressView()
                .controlSize(.large)
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var button: some View {
        switch model.phase {
        case .working:
            Button("Cancel", role: .cancel) { onCancel() }
                .buttonStyle(.bordered)
        case .saved, .failed:
            Button("Done") { onDone() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var title: String {
        switch model.phase {
        case .working(let message):
            return message
        case .saved:
            return "Saved to ClipSync"
        case .failed(let message, _):
            return message
        }
    }

    private var detail: String? {
        switch model.phase {
        case .working:
            return nil
        case .saved(let detail):
            return detail
        case .failed(_, let detail):
            return detail
        }
    }
}
