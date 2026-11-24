import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ClipCore

/// Persistent, thumb-reachable bar at the bottom of History. The system paste control reads
/// the clipboard without the "Allow Paste" prompt because the user tapped it.
struct SaveClipboardBar: View {
    @EnvironmentObject private var model: AppModel
    @ScaledMetric(relativeTo: .body) private var controlHeight: CGFloat = 44

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Save clipboard")
                    .font(.headline)
                Text("Tap Paste to keep what you copied")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            PasteControlView(onPaste: { providers in
                model.saveFromPaste(providers)
            })
            .frame(width: 124, height: min(max(controlHeight, 44), 60))
            .accessibilityIdentifier("history.pasteControl")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.saveBar")
    }
}

/// `UIPasteControl` hosted in SwiftUI. The host view is the control's `target`: it carries the
/// `pasteConfiguration` and receives `paste(itemProviders:)`.
struct PasteControlView: UIViewRepresentable {
    let onPaste: ([NSItemProvider]) -> Void

    func makeUIView(context: Context) -> PasteTargetView {
        let view = PasteTargetView(frame: .zero)
        view.onPaste = onPaste
        return view
    }

    func updateUIView(_ uiView: PasteTargetView, context: Context) {
        uiView.onPaste = onPaste
    }
}

final class PasteTargetView: UIView {
    var onPaste: (([NSItemProvider]) -> Void)?

    private let control: UIPasteControl

    /// Text, URLs, images and rich text.
    static let acceptedTypeIdentifiers: [String] = [
        UTType.plainText.identifier,
        UTType.utf8PlainText.identifier,
        UTType.text.identifier,
        UTType.url.identifier,
        UTType.image.identifier,
        UTType.png.identifier,
        UTType.jpeg.identifier,
        UTType.heic.identifier,
        UTType.tiff.identifier,
        UTType.gif.identifier,
        UTType.rtf.identifier,
        UTType.flatRTFD.identifier,
        UTType.html.identifier
    ]

    override init(frame: CGRect) {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = Theme.pasteControlBackground
        configuration.baseForegroundColor = .white
        control = UIPasteControl(configuration: configuration)
        super.init(frame: frame)

        backgroundColor = .clear
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: PasteTargetView.acceptedTypeIdentifiers)
        control.target = self
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        control.accessibilityIdentifier = "history.pasteButton"
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        return !itemProviders.isEmpty
    }

    override func paste(itemProviders: [NSItemProvider]) {
        onPaste?(itemProviders)
    }
}
