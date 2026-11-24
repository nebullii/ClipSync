import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CoreTransferable
import ClipCore

/// Context menu: Copy, Copy as plain text, Pin, Add to pinboard ▸, Share, Details, Delete.
struct ClipItemMenu: View {
    let item: ClipItem
    let board: Pinboard?
    let onShowDetail: () -> Void

    @EnvironmentObject private var model: AppModel

    private var pinTitle: String { item.isPinned ? "Unpin" : "Pin" }
    private var pinIcon: String { item.isPinned ? "pin.slash" : "pin" }

    var body: some View {
        if item.isAlive {
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
                Label(pinTitle, systemImage: pinIcon)
            }
            PinboardMembershipMenu(item: item, allowsCreate: true)
            if let board = board {
                Button {
                    model.remove(item, from: board)
                } label: {
                    Label("Remove from \(board.name)", systemImage: "minus.circle")
                }
            }
            ClipShareButton(item: item)
            Button(action: onShowDetail) {
                Label("Show Details", systemImage: "info.circle")
            }
            Divider()
            Button(role: .destructive) {
                model.delete(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// "Add to Pinboard ▸" submenu with a checkmark on boards that already contain the item.
struct PinboardMembershipMenu: View {
    let item: ClipItem
    let allowsCreate: Bool

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var directory: PinboardDirectory

    var body: some View {
        Menu {
            if directory.boards.isEmpty {
                Text("No pinboards yet")
            }
            ForEach(directory.boards) { board in
                PinboardToggleButton(item: item, board: board)
            }
            if allowsCreate {
                Divider()
                Button {
                    model.requestNewPinboard(adding: item)
                } label: {
                    Label("New Pinboard…", systemImage: "plus")
                }
            }
        } label: {
            Label("Add to Pinboard", systemImage: "pin.square")
        }
    }
}

private struct PinboardToggleButton: View {
    let item: ClipItem
    let board: Pinboard
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            model.toggle(item, in: board)
        } label: {
            if item.isMember(of: board) {
                Label(board.name, systemImage: "checkmark")
            } else {
                Text(board.name)
            }
        }
    }
}

/// ShareLink for links (URL), images (PNG via Transferable) and text (String).
struct ClipShareButton: View {
    let item: ClipItem

    var body: some View {
        if let url = item.linkURL {
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } else if item.kind == .image {
            ShareLink(item: ClipImageTransfer(itemID: item.id), preview: SharePreview(item.displayTitle)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } else if let text = item.visibleText {
            ShareLink(item: text) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// Lazily exports a clip's image as PNG only when the share sheet asks for it.
struct ClipImageTransfer: Transferable, Sendable {
    let itemID: UUID

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: UTType.png) { (transfer: ClipImageTransfer) async throws -> Data in
            return try await transfer.pngData()
        }
    }

    /// Main-actor store read: (uti, bytes) of the clip's first image representation.
    @MainActor
    private static func imagePayload(for id: UUID) -> ClipDraft.Representation? {
        let store = ClipStore.shared
        guard let item = store.item(withID: id) else { return nil }
        guard let rep = item.pasteableRepresentations.first(where: { ClipUTI.isImage($0.uti) }) else { return nil }
        guard let data = store.data(for: rep) else { return nil }
        return ClipDraft.Representation(uti: rep.uti, data: data)
    }

    func pngData() async throws -> Data {
        guard let found = await ClipImageTransfer.imagePayload(for: itemID) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        if found.uti == UTType.png.identifier {
            return found.data
        }
        guard let image = UIImage(data: found.data), let png = image.pngData() else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return png
    }
}

/// Leading swipe: pin / unpin.
struct ClipPinSwipeButton: View {
    let item: ClipItem
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            model.togglePin(item)
        } label: {
            Label((item.isPinned ? "Unpin" : "Pin") as String, systemImage: item.isPinned ? "pin.slash.fill" : "pin.fill")
        }
        .tint(.orange)
    }
}

/// Trailing swipe: delete (and "Remove" inside a pinboard).
struct ClipTrailingSwipeButtons: View {
    let item: ClipItem
    let board: Pinboard?
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button(role: .destructive) {
            model.delete(item)
        } label: {
            Label("Delete", systemImage: "trash")
        }
        if let board = board {
            Button {
                model.remove(item, from: board)
            } label: {
                Label("Remove", systemImage: "minus.circle")
            }
            .tint(.gray)
        }
    }
}

/// One VoiceOver element per clip: double-tap copies; rotor actions for the rest.
struct ClipAccessibilityModifier: ViewModifier {
    let item: ClipItem
    let onShowDetail: () -> Void
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(item.isAlive ? item.accessibilityDescription : "Deleted clip"))
            .accessibilityHint(Text("Double-tap to copy."))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                model.copy(item)
            }
            .accessibilityAction(named: Text((item.isPinned ? "Unpin" : "Pin") as String)) {
                model.togglePin(item)
            }
            .accessibilityAction(named: Text("Show details")) {
                onShowDetail()
            }
            .accessibilityAction(named: Text("Copy as plain text")) {
                model.copy(item, plainTextOnly: true)
            }
            .accessibilityAction(named: Text("Delete")) {
                model.delete(item)
            }
    }
}
