import SwiftUI
import UIKit
import ClipCore

/// Full content + metadata of one clip. Presented in a sheet (wrapped in a NavigationStack).
struct ClipDetailView: View {
    let item: ClipItem

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if item.isAlive {
                ClipDetailForm(item: item, onDelete: { confirmingDelete = true })
            } else {
                ContentUnavailableView("Clip deleted", systemImage: "trash")
            }
        }
        .navigationTitle(item.isAlive ? item.kind.displayName : "Clip")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("detail.done")
            }
            ToolbarItem(placement: .topBarLeading) {
                if item.isAlive {
                    Button {
                        model.copy(item)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("detail.copy")
                }
            }
        }
        .confirmationDialog("Delete this clip?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                deleteAndDismiss()
            }
        } message: {
            Text("It will be removed from this device and, with sync on, from your other devices.")
        }
    }

    private func deleteAndDismiss() {
        let appModel = model
        let target = item
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            appModel.delete(target)
        }
    }
}

private struct ClipDetailForm: View {
    let item: ClipItem
    let onDelete: () -> Void

    var body: some View {
        Form {
            Section {
                ClipDetailPreview(item: item)
            }
            ClipDetailActionsSection(item: item, onDelete: onDelete)
            ClipDetailMetadataSection(item: item)
        }
    }
}

// MARK: - Preview by kind

private struct ClipDetailPreview: View {
    let item: ClipItem

    var body: some View {
        switch item.kind {
        case .text, .richText:
            DetailTextPreview(item: item)
        case .link:
            DetailLinkPreview(item: item)
        case .image, .pdf:
            DetailImagePreview(item: item)
        case .color:
            DetailColorPreview(item: item)
        case .file:
            DetailFilePreview(item: item)
        }
    }
}

private struct DetailTextPreview: View {
    let item: ClipItem
    private let inlineLimit = 1_500

    var body: some View {
        let text = item.plainText ?? item.displayTitle
        VStack(alignment: .leading, spacing: 10) {
            Text(text.count > inlineLimit ? String(text.prefix(inlineLimit)) + "…" : text)
                .font(item.looksLikeCode ? Font.callout.monospaced() : Font.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("detail.text")
            NavigationLink {
                FullTextView(text: text, monospaced: item.looksLikeCode)
            } label: {
                Label(viewerTitle(for: text), systemImage: "text.viewfinder")
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }

    private func viewerTitle(for text: String) -> String {
        if text.count > inlineLimit {
            return "Show full text (\(text.count) characters)"
        }
        return "Open in text viewer"
    }
}

private struct DetailLinkPreview: View {
    let item: ClipItem
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ClipThumbnailView(item: item, maxPixelSize: 1_000, large: true) {
                EmptyView()
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(item.displayTitle)
                .font(.headline)
            Text(item.plainText ?? "")
                .font(.callout)
                .foregroundStyle(Theme.accent)
                .textSelection(.enabled)
            if let url = item.linkURL {
                Button {
                    openURL(url)
                } label: {
                    Label("Open Link", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("detail.openLink")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DetailImagePreview: View {
    let item: ClipItem
    @EnvironmentObject private var model: AppModel
    @State private var showingZoom = false

    var body: some View {
        VStack(spacing: 8) {
            ClipThumbnailView(item: item, maxPixelSize: 1_200, large: true) {
                KindIconTile(kind: item.kind, size: 64)
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { showingZoom = true }
            .accessibilityElement()
            .accessibilityLabel("Image preview")
            .accessibilityHint("Double-tap to view full screen and zoom.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { showingZoom = true }
            if let ocr = item.ocrText, !ocr.isEmpty {
                Text(ocr)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
        .fullScreenCover(isPresented: $showingZoom) {
            ImageZoomScreen(item: item)
                .environmentObject(model)
        }
    }
}

private struct DetailColorPreview: View {
    let item: ClipItem

    var body: some View {
        let hex = item.colorHex ?? "#888888"
        VStack(alignment: .leading, spacing: 10) {
            ColorSwatchView(hex: hex, cornerRadius: 14, showsLabel: false)
                .frame(height: 140)
            Text(hex)
                .font(.title3.monospaced().weight(.semibold))
                .textSelection(.enabled)
            if let rgb = ColorMath.rgbDescription(forHex: hex) {
                Text(rgb)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let original = item.plainText, original.uppercased() != hex {
                Text(original)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DetailFilePreview: View {
    let item: ClipItem

    var body: some View {
        let names = item.fileNames
        VStack(alignment: .leading, spacing: 8) {
            if names.isEmpty {
                Text(item.displayTitle)
            }
            ForEach(Array(names.prefix(200).enumerated()), id: \.offset) { _, name in
                Label(name, systemImage: "doc")
                    .textSelection(.enabled)
            }
            if names.count > 200 {
                Text("+ \(names.count - 200) more files")
                    .foregroundStyle(.secondary)
            }
            Text("Files copied on a Mac are listed by name; their contents stay on that Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Actions

private struct ClipDetailActionsSection: View {
    let item: ClipItem
    let onDelete: () -> Void
    @EnvironmentObject private var model: AppModel

    private var pinTitle: String {
        return item.isPinned ? "Unpin" : "Pin"
    }

    var body: some View {
        Section {
            Button {
                model.copy(item)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            if item.hasPlainText && item.kind != .text {
                Button {
                    model.copy(item, plainTextOnly: true)
                } label: {
                    Label("Copy as Plain Text", systemImage: "textformat")
                }
            }
            Button {
                model.togglePin(item)
            } label: {
                Label(pinTitle, systemImage: item.isPinned ? "pin.slash" : "pin")
            }
            PinboardMembershipMenu(item: item, allowsCreate: false)
            ClipShareButton(item: item)
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("detail.delete")
        }
    }
}

// MARK: - Metadata

private struct ClipDetailMetadataSection: View {
    let item: ClipItem

    var body: some View {
        Section("Details") {
            LabeledContent("Kind", value: item.kind.displayName)
            LabeledContent("Source app", value: item.sourceAppName ?? "Unknown")
            LabeledContent("Device", value: item.deviceName ?? "Unknown")
            LabeledContent("Copied", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Last used", value: item.lastUsedAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Size", value: item.byteSizeDescription)
            LabeledContent("Sync", value: syncDescription)
            if !boardNames.isEmpty {
                LabeledContent("Pinboards", value: boardNames)
            }
            if !formats.isEmpty {
                LabeledContent("Formats", value: formats)
            }
        }
    }

    private var syncDescription: String {
        if item.isLocalOnly {
            return "This device only (over 20 MB)"
        }
        if item.hasLocalBlobs {
            return "Large data stays on the device that saved it"
        }
        return "Syncs with iCloud when sync is on"
    }

    private var boardNames: String {
        return (item.pinboards ?? []).map { $0.name }.sorted().joined(separator: ", ")
    }

    private var formats: String {
        return item.pasteableRepresentations.map { $0.uti }.joined(separator: ", ")
    }
}

// MARK: - Full text

/// Large texts render in a UITextView (fast for multi-MB strings, selectable, Dynamic Type).
struct FullTextView: View {
    let text: String
    let monospaced: Bool

    var body: some View {
        SelectableTextView(text: text, monospaced: monospaced)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: text)
                }
            }
    }
}

struct SelectableTextView: UIViewRepresentable {
    let text: String
    let monospaced: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        view.accessibilityIdentifier = "detail.fullText"
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let font: UIFont
        if monospaced {
            let mono = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
            font = UIFontMetrics(forTextStyle: .body).scaledFont(for: mono)
        } else {
            font = UIFont.preferredFont(forTextStyle: .body)
        }
        if uiView.text != text {
            uiView.text = text
        }
        uiView.font = font
        uiView.textColor = .label
    }
}

// MARK: - Zoomable image

private struct ImageZoomScreen: View {
    let item: ClipItem
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = image {
                    ZoomableImageView(image: image)
                        .ignoresSafeArea()
                        .accessibilityLabel("Image, zoomable")
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    ClipShareButton(item: item)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .task {
            // Large but bounded: never decode a 50 MP original at full size.
            image = await ThumbnailLoader.load(item: item, store: model.store, maxPixelSize: 3_000, large: true)
        }
    }
}

/// UIScrollView-based pinch / double-tap zoom.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        return Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .black

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Image"
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return imageView
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let scale = min(scrollView.maximumZoomScale, 3)
                let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
                let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}
