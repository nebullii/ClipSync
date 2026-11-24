import SwiftUI
import ClipCore

/// A History grid card with tap-to-copy and the context menu (grids have no swipe actions).
struct ClipCardCell: View {
    let item: ClipItem
    let index: Int
    let board: Pinboard?
    let onShowDetail: (ClipItem) -> Void

    @EnvironmentObject private var model: AppModel

    var body: some View {
        if item.isAlive {
            ClipCardView(item: item, onShowDetail: { onShowDetail(item) })
                .contentShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
                .onTapGesture {
                    model.copy(item)
                }
                .contextMenu {
                    ClipItemMenu(item: item, board: board, onShowDetail: { onShowDetail(item) })
                }
                .modifier(ClipAccessibilityModifier(item: item, onShowDetail: { onShowDetail(item) }))
                .accessibilityIdentifier("history.card.\(index)")
        }
    }
}

/// Card: kind header strip, content preview, footer with source and time.
struct ClipCardView: View {
    let item: ClipItem
    let onShowDetail: () -> Void

    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 184

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ClipCardHeader(item: item, onShowDetail: onShowDetail)
            ClipCardBody(item: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            ClipCardFooter(item: item)
        }
        .frame(height: min(cardHeight, 360))
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 2)
    }
}

private struct ClipCardHeader: View {
    let item: ClipItem
    let onShowDetail: () -> Void

    var body: some View {
        let tint = Theme.tint(for: item.kind)
        HStack(spacing: 6) {
            Image(systemName: item.kind.systemImageName)
                .font(.caption.weight(.semibold))
            Text(item.kind.displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Button(action: onShowDetail) {
                Image(systemName: "ellipsis.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Details")
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(0.12))
    }
}

private struct ClipCardBody: View {
    let item: ClipItem

    var body: some View {
        switch item.kind {
        case .image, .pdf:
            ClipThumbnailView(item: item, maxPixelSize: 600) {
                KindIconTile(kind: item.kind, size: 56)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .color:
            ColorSwatchView(hex: item.colorHex ?? "#888888", cornerRadius: 0, showsLabel: true)
        case .link:
            ClipCardLinkBody(item: item)
        case .file:
            ClipCardFileBody(item: item)
        case .text, .richText:
            Text(item.previewText(maxCharacters: 320))
                .font(item.looksLikeCode ? Font.caption.monospaced() : Font.callout)
                .foregroundStyle(.primary)
                .lineLimit(7)
                .padding(10)
        }
    }
}

private struct ClipCardLinkBody: View {
    let item: ClipItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ClipThumbnailView(item: item, maxPixelSize: 500, large: true) {
                Color.clear
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .clipped()
            Text(item.displayTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .padding(.horizontal, 10)
            if let host = item.linkHost {
                Text(host)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
            }
        }
    }
}

private struct ClipCardFileBody: View {
    let item: ClipItem

    var body: some View {
        let names = item.fileNames
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(names.prefix(4).enumerated()), id: \.offset) { _, name in
                Label(name, systemImage: "doc")
                    .font(.callout)
                    .lineLimit(1)
            }
            if names.count > 4 {
                Text("+ \(names.count - 4) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if names.isEmpty {
                Text(item.displayTitle)
                    .font(.callout)
                    .lineLimit(3)
            }
        }
        .padding(10)
    }
}

private struct ClipCardFooter: View {
    let item: ClipItem

    var body: some View {
        Text(footerText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footerText: String {
        var parts: [String] = []
        if let app = item.sourceAppName, !app.isEmpty {
            parts.append(app)
        }
        parts.append(item.lastUsedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}
