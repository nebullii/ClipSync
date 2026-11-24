import SwiftUI
import UIKit
import ClipCore

/// Asynchronously downsampled preview image of a clip (never decodes full-size images in a cell).
struct ClipThumbnailView<Placeholder: View>: View {
    let item: ClipItem
    let maxPixelSize: Int
    let large: Bool
    let placeholder: () -> Placeholder

    @EnvironmentObject private var model: AppModel
    @State private var image: UIImage? = nil

    init(item: ClipItem, maxPixelSize: Int, large: Bool = false, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.item = item
        self.maxPixelSize = maxPixelSize
        self.large = large
        self.placeholder = placeholder
    }

    var body: some View {
        ZStack {
            if let image = image {
                Color.clear
                    .overlay(
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    )
                    .clipped()
            } else {
                placeholder()
            }
        }
        .task(id: item.id) {
            if image == nil {
                image = await ThumbnailLoader.load(item: item, store: model.store, maxPixelSize: maxPixelSize, large: large)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Rounded tile with the kind's SF Symbol.
struct KindIconTile: View {
    let kind: ClipKind
    let size: CGFloat

    var body: some View {
        let tint = Theme.tint(for: kind)
        RoundedRectangle(cornerRadius: Theme.rowIconCornerRadius, style: .continuous)
            .fill(tint.opacity(0.15))
            .overlay(
                Image(systemName: kind.systemImageName)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(tint)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Color swatch with a checkerboard hint for translucent colors.
struct ColorSwatchView: View {
    let hex: String
    var cornerRadius: CGFloat = Theme.rowIconCornerRadius
    var showsLabel = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(clipHex: hex, fallback: .gray))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
            .overlay(alignment: .bottomLeading) {
                if showsLabel {
                    Text(hex)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(ColorMath.prefersDarkText(onHex: hex) ? Color.black : Color.white)
                        .padding(8)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Color \(hex)")
    }
}

/// Leading visual of a list row: thumbnail, swatch, link icon or kind tile.
struct ClipLeadingVisual: View {
    let item: ClipItem
    let size: CGFloat

    var body: some View {
        Group {
            switch item.kind {
            case .color:
                ColorSwatchView(hex: item.colorHex ?? "#888888")
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            case .image, .pdf, .link:
                ClipThumbnailView(item: item, maxPixelSize: 180) {
                    KindIconTile(kind: item.kind, size: size)
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rowIconCornerRadius, style: .continuous))
            case .text, .richText, .file:
                KindIconTile(kind: item.kind, size: size)
            }
        }
    }
}
