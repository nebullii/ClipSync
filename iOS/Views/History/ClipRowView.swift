import SwiftUI
import ClipCore

/// A History list row with tap-to-copy, swipe actions and the context menu.
struct ClipListRow: View {
    let item: ClipItem
    let index: Int
    let board: Pinboard?
    let onShowDetail: (ClipItem) -> Void

    @EnvironmentObject private var model: AppModel

    var body: some View {
        if item.isAlive {
            ClipRowView(item: item, onShowDetail: { onShowDetail(item) })
                .contentShape(Rectangle())
                .onTapGesture {
                    model.copy(item)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    ClipPinSwipeButton(item: item)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    ClipTrailingSwipeButtons(item: item, board: board)
                }
                .contextMenu {
                    ClipItemMenu(item: item, board: board, onShowDetail: { onShowDetail(item) })
                }
                .modifier(ClipAccessibilityModifier(item: item, onShowDetail: { onShowDetail(item) }))
                .accessibilityIdentifier("history.row.\(index)")
        }
    }
}

/// Visual content of a row: leading visual, title, meta line, pin badge, details button.
struct ClipRowView: View {
    let item: ClipItem
    let onShowDetail: () -> Void

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 44

    var body: some View {
        HStack(spacing: 12) {
            ClipLeadingVisual(item: item, size: min(iconSize, 72))
            ClipRowText(item: item)
            Spacer(minLength: 4)
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
            Button(action: onShowDetail) {
                Image(systemName: "info.circle")
                    .imageScale(.large)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Details")
        }
        .padding(.vertical, 4)
    }
}

private struct ClipRowText: View {
    let item: ClipItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(item.looksLikeCode ? Font.body.monospaced() : Font.body)
                .lineLimit(2)
                .foregroundStyle(.primary)
            Text(item.metaLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var title: String {
        switch item.kind {
        case .color:
            return item.colorHex ?? item.displayTitle
        case .file:
            let names = item.fileNames
            if names.count > 1 {
                return "\(names[0]) + \(names.count - 1) more"
            }
            return names.first ?? item.displayTitle
        default:
            return item.displayTitle
        }
    }
}
