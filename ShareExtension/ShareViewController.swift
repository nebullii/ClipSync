// Owned by the extensions engineer.
// Principal class of the ClipSyncShare extension (Info.plist: $(PRODUCT_MODULE_NAME).ShareViewController).
//
// No-input flow: the sheet appears, attachments are loaded one at a time and ingested
// into the shared App Group store, "Saved to ClipSync" shows briefly, then the request
// completes. No OCR / thumbnails / link previews here (memory limit); the app's
// `store.enrich(_:)` fills those in later.

import UIKit
import SwiftUI
import ClipCore

final class ShareViewController: UIViewController {
    private let model = ShareModel()
    private var work: Task<Void, Never>?
    private var didFinish = false

    private static let maxInputs = 20
    private static let successDisplayNanoseconds: UInt64 = 900_000_000
    private static let failureDisplayNanoseconds: UInt64 = 2_500_000_000

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let root = ShareStatusView(
            model: model,
            onDone: { [weak self] in self?.complete() },
            onCancel: { [weak self] in self?.cancel() }
        )
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard work == nil else { return }
        let inputs = collectInputs()
        work = Task { [weak self] in
            await self?.save(inputs)
        }
    }

    // MARK: - Inputs

    private enum ShareInput {
        case provider(NSItemProvider)
        case text(String)
    }

    private func collectInputs() -> [ShareInput] {
        let items = (extensionContext?.inputItems ?? []).compactMap { $0 as? NSExtensionItem }
        var inputs: [ShareInput] = []
        for item in items {
            let providers = item.attachments ?? []
            if providers.isEmpty {
                if let text = item.attributedContentText?.string,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    inputs.append(.text(text))
                }
            } else {
                for provider in providers {
                    inputs.append(.provider(provider))
                }
            }
        }
        return Array(inputs.prefix(ShareViewController.maxInputs))
    }

    // MARK: - Saving

    private func save(_ inputs: [ShareInput]) async {
        guard !inputs.isEmpty else {
            await show(.failed(message: "Nothing to save", detail: "This item has no text, link, image or file ClipSync can store."))
            return
        }

        // Unsigned / unentitled build (e.g. the default Simulator Debug build): there is no
        // App Group container, so StoreLocation.resolve() would fall back to this extension's
        // OWN Application Support folder, which the app never reads. Do not pretend: save
        // nothing and say why. Checked before touching ClipStore.shared so no orphan store
        // is created inside the extension's container.
        guard AppGroup.containerURL() != nil else {
            await show(.failed(
                message: "Can't reach ClipSync from here",
                detail: "This build isn't signed with the ClipSync App Group, so the share extension can't write to the app's history. Nothing was saved. Copy the item and tap Paste in ClipSync instead, or use a signed build."
            ))
            return
        }

        let store = ClipStore.shared
        if store.isInMemory {
            // The shared database could not be opened; anything saved now would be lost.
            await show(.failed(
                message: "Couldn't open ClipSync's history",
                detail: store.storeError ?? "Nothing was saved."
            ))
            return
        }
        if store.deviceName == nil {
            store.deviceName = UIDevice.current.name
        }

        var saved = 0
        var alreadySaved = 0
        var problems: [String] = []

        for (index, input) in inputs.enumerated() {
            if Task.isCancelled { return }
            if inputs.count > 1 {
                model.phase = .working("Saving \(index + 1) of \(inputs.count)\u{2026}")
            }

            // Loads off the main actor (nonisolated async), one attachment at a time.
            let outcome: ShareLoadOutcome
            switch input {
            case .provider(let provider):
                outcome = await ShareAttachmentLoader.load(provider)
            case .text(let text):
                outcome = ShareAttachmentLoader.textOutcome(text)
            }
            if Task.isCancelled { return }

            switch outcome {
            case .draft(let draft):
                switch store.ingestDetailed(draft) {
                case .inserted:
                    saved += 1
                case .bumped:
                    alreadySaved += 1
                case .rejected(let reason):
                    problems.append(ShareViewController.message(for: reason))
                }
            case .skipped(let reason):
                problems.append(reason)
            }
        }

        var notes: [String] = []
        if alreadySaved > 0 {
            notes.append(alreadySaved == 1 ? "1 item was already in your history." : "\(alreadySaved) items were already in your history.")
        }
        if !problems.isEmpty {
            notes.append("Skipped: " + problems.prefix(3).joined(separator: "; "))
        }
        if let error = store.storeError {
            notes.append(error)
        }
        let detail = notes.isEmpty ? nil : notes.joined(separator: "\n")

        if saved + alreadySaved > 0 {
            await show(.saved(detail: detail))
        } else {
            await show(.failed(message: "Nothing was saved", detail: detail))
        }
    }

    private func show(_ phase: ShareModel.Phase) async {
        model.phase = phase
        let delay: UInt64
        switch phase {
        case .saved:
            delay = ShareViewController.successDisplayNanoseconds
        case .failed:
            delay = ShareViewController.failureDisplayNanoseconds
        case .working:
            return
        }
        try? await Task.sleep(nanoseconds: delay)
        complete()
    }

    private static func message(for rejection: IngestRejection) -> String {
        switch rejection {
        case .ignoredApp: return "ignored app"
        case .markerType: return "marked as sensitive"
        case .empty: return "empty item"
        case .tooLarge: return "too large"
        }
    }

    // MARK: - Completion

    private func complete() {
        guard !didFinish else { return }
        didFinish = true
        work?.cancel()
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancel() {
        guard !didFinish else { return }
        didFinish = true
        work?.cancel()
        let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
        extensionContext?.cancelRequest(withError: error)
    }
}
