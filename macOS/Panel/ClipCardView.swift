// Owned by the Mac panel UI engineer.
//
// One card (~220×200): tinted header (kind, source app + icon, relative time, pin),
// a kind-specific body preview, a footer (size / count, ⌘N badge) and a clear
// selected state. PanelCardCell adds gestures, context menu, drag and VoiceOver actions.

import SwiftUI
import AppKit
import ClipCore

// MARK: - Cell (interaction)

struct PanelCardCell: View {
    let row: PanelCardRow
    let isSelected: Bool
    let referenceDate: Date
    let pinboards: [PanelPinboardRow]
    let currentPinboardID: UUID?
    /// Not observed on purpose: cells only re-render when their inputs above change.
    let viewModel: PanelViewModel

    var body: some View {
        if PanelViewModel.isAlive(row.item) {
            interactiveCard
        } else {
            // The item was deleted elsewhere; a reload is already scheduled.
            Color.clear.frame(width: PanelMetrics.cardWidth, height: PanelMetrics.cardHeight)
        }
    }

    private var interactiveCard: some View {
        let item = row.item
        let summary = PanelCardSummary(item: item, index: row.index, referenceDate: referenceDate, store: viewModel.store)
        // Precomputed so the long modifier chain below has no ternaries to type-check.
        let traits: AccessibilityTraits = isSelected ? [.isButton, .isSelected] : [.isButton]
        let pinActionTitle: String = item.isPinned ? "Unpin" : "Pin"
        return PanelClipCard(item: item, summary: summary, isSelected: isSelected, store: viewModel.store)
            .onTapGesture(count: 2) { viewModel.pasteWithDefault(item) }
            .simultaneousGesture(TapGesture().onEnded { viewModel.select(index: row.index) })
            .contextMenu {
                PanelCardMenu(
                    item: item,
                    pinboards: pinboards,
                    currentPinboardID: currentPinboardID,
                    viewModel: viewModel
                )
            }
            .onDrag { viewModel.beginItemDrag(item) }
            .onAppear { viewModel.cardAppeared(at: row.index) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(summary.accessibilityLabel))
            .accessibilityHint(Text("Double-click or press Return to paste"))
            .accessibilityAddTraits(traits)
            .accessibilityAction { viewModel.pasteWithDefault(item) }
            .accessibilityAction(named: Text("Paste as Plain Text")) { viewModel.paste(item, plainText: true) }
            .accessibilityAction(named: Text("Copy")) { viewModel.copy(item) }
            .accessibilityAction(named: Text(pinActionTitle)) { viewModel.togglePin(item) }
            .accessibilityAction(named: Text("Delete")) { viewModel.delete(item) }
    }
}

// MARK: - Precomputed display values

struct PanelCardSummary {
    let kind: ClipKind
    let title: String
    let appName: String?
    let bundleID: String?
    let timeText: String
    let footerText: String
    let isPinned: Bool
    let isLocalOnly: Bool
    let colorHex: String?
    let shortcutNumber: Int?

    @MainActor
    init(item: ClipItem, index: Int, referenceDate: Date, store: ClipStore) {
        kind = item.kind
        title = item.displayTitle
        appName = item.sourceAppName
        bundleID = item.sourceAppBundleID
        timeText = PanelFormat.relativeTime(item.lastUsedAt, now: referenceDate)
        isPinned = item.isPinned
        isLocalOnly = item.isLocalOnly
        colorHex = item.colorHex
        shortcutNumber = index < PanelViewModel.shortcutCount ? index + 1 : nil
        footerText = PanelCardSummary.footer(for: item, store: store)
    }

    @MainActor
    private static func footer(for item: ClipItem, store: ClipStore) -> String {
        switch item.kind {
        case .text, .richText:
            return PanelFormat.characterCount(item.plainText ?? "")
        case .link:
            return PanelFormat.host(of: item.plainText ?? "") ?? "Link"
        case .image, .pdf:
            return PanelFormat.byteCount(item.byteSize)
        case .file:
            let count = PanelFileList.fileURLs(for: item, store: store).count
            if count > 1 { return "\(count) files" }
            return "File · \(PanelFormat.byteCount(item.byteSize))"
        case .color:
            return item.colorHex ?? "Color"
        }
    }

    var accessibilityLabel: String {
        var parts: [String] = [kind.displayName, title]
        if let appName = appName { parts.append("from \(appName)") }
        parts.append(timeText)
        if isPinned { parts.append("pinned") }
        if let number = shortcutNumber { parts.append("shortcut Command \(number)") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Card (visual)

struct PanelClipCard: View {
    let item: ClipItem
    let summary: PanelCardSummary
    let isSelected: Bool
    let store: ClipStore

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PanelMetrics.cardCornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelCardHeader(summary: summary)
            PanelCardBody(item: item, summary: summary, store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            PanelCardFooter(summary: summary)
        }
        .frame(width: PanelMetrics.cardWidth, height: PanelMetrics.cardHeight)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(shape)
        .overlay(selectionBorder)
        .shadow(color: Color.black.opacity(isSelected ? 0.28 : 0.12), radius: isSelected ? 8 : 3, x: 0, y: 2)
        .scaleEffect(isSelected ? 1.0 : 0.97)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .contentShape(shape)
    }

    private var selectionBorder: some View {
        shape.strokeBorder(
            isSelected ? Color.accentColor : Color.primary.opacity(0.10),
            lineWidth: isSelected ? 3 : 1
        )
    }
}

struct PanelCardHeader: View {
    let summary: PanelCardSummary

    private var tint: Color {
        if summary.kind == .color, let hex = summary.colorHex {
            return PanelPalette.color(hex: hex)
        }
        return PanelPalette.tint(for: summary.kind)
    }

    private var foreground: Color {
        if summary.kind == .color, let hex = summary.colorHex, PanelPalette.prefersDarkForeground(hex: hex) {
            return Color.black
        }
        return Color.white
    }

    private var subtitle: String {
        let app = summary.appName ?? "Unknown app"
        return "\(app) · \(summary.timeText)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.kind.displayName)
                    .font(.system(size: 12, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .opacity(0.85)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if summary.isLocalOnly {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 10, weight: .bold))
                    .help("Too large to sync; stays on this Mac")
            }
            if summary.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .bold))
            }
            PanelAppIconView(bundleID: summary.bundleID, kind: summary.kind)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .frame(height: PanelMetrics.headerHeight)
        .frame(maxWidth: .infinity)
        .background(headerBackground)
    }

    private var headerBackground: some View {
        LinearGradient(
            colors: [tint, tint.opacity(0.80)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct PanelAppIconView: View {
    let bundleID: String?
    let kind: ClipKind

    var body: some View {
        if let icon = PanelIconCache.shared.appIcon(forBundleID: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: kind.systemImageName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 26, height: 26)
        }
    }
}

struct PanelCardFooter: View {
    let summary: PanelCardSummary

    var body: some View {
        HStack(spacing: 6) {
            Text(summary.footerText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let number = summary.shortcutNumber {
                Text("⌘\(number)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
    }
}

// MARK: - Bodies per kind

struct PanelCardBody: View {
    let item: ClipItem
    let summary: PanelCardSummary
    let store: ClipStore

    var body: some View {
        switch summary.kind {
        case .text:
            CardTextPreview(text: item.plainText ?? summary.title, monospaced: true)
        case .richText:
            CardTextPreview(text: item.plainText ?? summary.title, monospaced: false)
        case .link:
            CardLinkPreview(item: item, title: summary.title, store: store)
        case .image:
            CardImagePreview(item: item, store: store, fallbackSymbol: ClipKind.image.systemImageName)
        case .pdf:
            CardImagePreview(item: item, store: store, fallbackSymbol: ClipKind.pdf.systemImageName)
        case .file:
            CardFilePreview(urls: PanelFileList.fileURLs(for: item, store: store), fallbackTitle: summary.title)
        case .color:
            CardColorPreview(hex: summary.colorHex, text: item.plainText ?? "")
        }
    }
}

struct CardTextPreview: View {
    let text: String
    let monospaced: Bool

    /// Never lay out megabytes of text for a card.
    private var excerpt: String {
        return String(text.prefix(600))
    }

    var body: some View {
        Text(excerpt)
            .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12))
            .lineLimit(monospaced ? 9 : 8)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }
}

struct CardLinkPreview: View {
    let item: ClipItem
    let title: String
    let store: ClipStore

    private var urlString: String {
        return (item.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasPreviewImage: Bool {
        return item.representation(forUTI: ClipUTI.linkPreviewImage) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasPreviewImage {
                CardThumbnailView(item: item, role: .linkImage, store: store, fallbackSymbol: nil)
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            HStack(spacing: 6) {
                CardThumbnailView(item: item, role: .linkIcon, store: store, fallbackSymbol: "link")
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                Text(PanelFormat.host(of: urlString) ?? "Link")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(hasPreviewImage ? 2 : 3)
            Text(urlString)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(hasPreviewImage ? 1 : 2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

struct CardImagePreview: View {
    let item: ClipItem
    let store: ClipStore
    let fallbackSymbol: String

    var body: some View {
        CardThumbnailView(item: item, role: .content, store: store, fallbackSymbol: fallbackSymbol)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(Color.primary.opacity(0.04))
    }
}

/// Async, cached thumbnail. Shows a cached image synchronously when available.
struct CardThumbnailView: View {
    let item: ClipItem
    let role: PanelThumbnailRole
    let store: ClipStore
    let fallbackSymbol: String?
    @State private var loaded: NSImage?
    @State private var loadedKey: String?

    var body: some View {
        let key = PanelThumbnailLoader.shared.cacheKey(for: item, role: role)
        content(for: key)
            .task(id: key ?? "") {
                await load(key: key)
            }
    }

    @ViewBuilder
    private func content(for key: String?) -> some View {
        if let image = displayedImage(for: key) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: role == .content ? .fit : .fill)
        } else if let symbol = fallbackSymbol {
            Image(systemName: symbol)
                .font(.system(size: role == .content ? 28 : 11, weight: .light))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }

    private func displayedImage(for key: String?) -> NSImage? {
        guard let key = key else { return nil }
        if loadedKey == key, let image = loaded { return image }
        return PanelThumbnailLoader.shared.cachedImage(forKey: key)
    }

    private func load(key: String?) async {
        guard let key = key else {
            loaded = nil
            loadedKey = nil
            return
        }
        if loadedKey == key, loaded != nil { return }
        guard PanelViewModel.isAlive(item) else { return }
        let image = await PanelThumbnailLoader.shared.loadImage(for: item, role: role, store: store)
        if Task.isCancelled { return }
        loaded = image
        loadedKey = key
    }
}

struct CardFilePreview: View {
    let urls: [URL]
    let fallbackTitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            fileIcon
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                if urls.isEmpty {
                    Text(fallbackTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(3)
                } else {
                    ForEach(Array(urls.prefix(5).enumerated()), id: \.offset) { entry in
                        Text(entry.element.lastPathComponent)
                            .font(.system(size: 12, weight: entry.offset == 0 ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if urls.count > 5 {
                        Text("+\(urls.count - 5) more")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var fileIcon: some View {
        if let first = urls.first {
            Image(nsImage: PanelIconCache.shared.fileIcon(for: first))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: ClipKind.file.systemImageName)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
        }
    }
}

struct CardColorPreview: View {
    let hex: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(PanelPalette.color(hex: hex ?? "#000000"))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .frame(maxWidth: .infinity)
                .frame(height: 70)
            Text(hex ?? text)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
            if let hex = hex, text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != hex {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Context menu

struct PanelCardMenu: View {
    let item: ClipItem
    let pinboards: [PanelPinboardRow]
    let currentPinboardID: UUID?
    let viewModel: PanelViewModel

    var body: some View {
        Button("Paste") { viewModel.pasteWithDefault(item) }
        Button("Paste as Plain Text") { viewModel.paste(item, plainText: true) }
        Button("Copy") { viewModel.copy(item) }
        Divider()
        Button(item.isPinned ? "Unpin" : "Pin") { viewModel.togglePin(item) }
        Menu("Add to Pinboard") {
            ForEach(pinboards) { board in
                Button(board.name) { viewModel.add(item, toPinboard: board.id) }
            }
            if !pinboards.isEmpty {
                Divider()
            }
            Button("New Pinboard…") { viewModel.beginCreatePinboard(adding: item) }
        }
        if let boardID = currentPinboardID {
            Button("Remove from This Pinboard") { viewModel.remove(item, fromPinboard: boardID) }
        }
        Button("Rename…") { viewModel.beginRename(item) }
        Divider()
        Button("Delete", role: .destructive) { viewModel.delete(item) }
    }
}
