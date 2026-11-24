import XCTest
@testable import ClipCore

// Owned by the extensions engineer.
// Exercises the logic every App Intent's perform() calls (ClipIntentRunner) against an
// in-memory store, with injected pasteboard readers/writers (no system pasteboard).

@MainActor
final class IntentsTests: XCTestCase {

    private func makeStore() -> ClipStore {
        return ClipStore.makeShared(inMemory: true)
    }

    // MARK: Save Text

    func testSaveTextInsertsThenBumpsDuplicate() throws {
        let store = makeStore()
        let first = try ClipIntentRunner.saveText("Hello from Shortcuts", store: store)
        XCTAssertFalse(first.wasDuplicate)
        XCTAssertEqual(first.value, "Hello from Shortcuts")
        XCTAssertEqual(store.itemCount(), 1)
        XCTAssertEqual(store.latestItem()?.sourceAppName, ClipIntentRunner.sourceAppName)

        let second = try ClipIntentRunner.saveText("Hello from Shortcuts\r\n", store: store)
        XCTAssertTrue(second.wasDuplicate)
        XCTAssertEqual(second.itemID, first.itemID)
        XCTAssertEqual(store.itemCount(), 1)
    }

    func testSaveTextRejectsBlankText() {
        let store = makeStore()
        XCTAssertThrowsError(try ClipIntentRunner.saveText("   \n", store: store)) { error in
            XCTAssertEqual(error as? ClipIntentError, .emptyText)
        }
        XCTAssertEqual(store.itemCount(), 0)
    }

    func testSaveTextClassifiesLinks() throws {
        let store = makeStore()
        _ = try ClipIntentRunner.saveText("https://example.com/page", store: store)
        XCTAssertEqual(store.latestItem()?.kind, .link)
    }

    // MARK: Save Clipboard (injected reader)

    func testSaveClipboardUsesReaderDraft() throws {
        let store = makeStore()
        let reply = try ClipIntentRunner.saveClipboard(store: store, reader: {
            try SystemPasteboard.makeDraft(
                types: [ClipUTI.utf8PlainText],
                payloads: [ClipDraft.Representation(uti: ClipUTI.utf8PlainText, data: Data("clip text".utf8))],
                string: "clip text"
            )
        })
        XCTAssertEqual(reply.value, "clip text")
        XCTAssertEqual(store.itemCount(), 1)
    }

    func testMakeDraftRefusesConcealedAndEmptyPasteboards() {
        XCTAssertThrowsError(try SystemPasteboard.makeDraft(
            types: [ClipUTI.utf8PlainText, ClipUTI.concealed],
            payloads: [ClipDraft.Representation(uti: ClipUTI.utf8PlainText, data: Data("hunter2".utf8))],
            string: "hunter2"
        )) { error in
            XCTAssertEqual(error as? ClipIntentError, .sensitiveContent)
        }
        XCTAssertThrowsError(try SystemPasteboard.makeDraft(types: [], payloads: [], string: nil)) { error in
            XCTAssertEqual(error as? ClipIntentError, .emptyClipboard)
        }
    }

    func testSaveClipboardMapsMarkerRejectionToSensitiveContent() {
        let store = makeStore()
        // A draft whose marker slipped past classification is still rejected by the store.
        let draft = ClipDraft(
            kind: .text,
            plainText: "secret",
            representations: [ClipDraft.Representation(uti: ClipUTI.utf8PlainText, data: Data("secret".utf8))],
            declaredTypes: [ClipUTI.transient]
        )
        XCTAssertThrowsError(try ClipIntentRunner.saveClipboard(store: store, reader: { draft })) { error in
            XCTAssertEqual(error as? ClipIntentError, .sensitiveContent)
        }
        XCTAssertEqual(store.itemCount(), 0)
    }

    // MARK: Search

    func testSearchReturnsMatchingEntitiesNewestFirst() throws {
        let store = makeStore()
        store.ingest(ClipDraft.text("alpha apple", createdAt: Date().addingTimeInterval(-30)))
        store.ingest(ClipDraft.text("beta banana", createdAt: Date().addingTimeInterval(-20)))
        store.ingest(ClipDraft.text("apple pie", createdAt: Date().addingTimeInterval(-10)))

        let reply = ClipIntentRunner.search("apple", limit: 10, store: store)
        XCTAssertEqual(reply.texts, ["apple pie", "alpha apple"])
        XCTAssertEqual(reply.entities.map { $0.text }, ["apple pie", "alpha apple"])
        XCTAssertEqual(reply.dialog, "Found 2 clips.")

        let none = ClipIntentRunner.search("zebra", limit: 10, store: store)
        XCTAssertTrue(none.entities.isEmpty)

        let recent = ClipIntentRunner.search("", limit: 2, store: store)
        XCTAssertEqual(recent.texts, ["apple pie", "beta banana"])

        let clamped = ClipIntentRunner.search("", limit: 0, store: store)
        XCTAssertEqual(clamped.texts.count, 1)
    }

    func testEntityRoundTripByID() throws {
        let store = makeStore()
        let item = try XCTUnwrap(store.ingest(ClipDraft.text("round trip")))
        let entity = ClipIntentRunner.entity(for: item)
        XCTAssertEqual(entity.id, item.id)
        XCTAssertEqual(entity.title, "round trip")
        XCTAssertEqual(entity.kindName, ClipKind.text.displayName)

        let resolved = ClipIntentRunner.entities(for: [UUID(), item.id], store: store)
        XCTAssertEqual(resolved.map { $0.id }, [item.id])
        XCTAssertEqual(ClipIntentRunner.suggestedEntities(store: store).count, 1)
    }

    // MARK: Copy Latest (injected writer)

    func testCopyLatestWritesPayloadAndMarksUsed() throws {
        let store = makeStore()
        store.ingest(ClipDraft.text("older", createdAt: Date().addingTimeInterval(-60)))
        let newest = try XCTUnwrap(store.ingest(ClipDraft.text("newest", createdAt: Date().addingTimeInterval(-30))))
        let before = newest.lastUsedAt

        var written: [ClipDraft.Representation] = []
        var writtenText: String?
        let reply = try ClipIntentRunner.copyLatest(store: store, writer: { reps, text in
            written = reps
            writtenText = text
            return true
        })
        XCTAssertEqual(reply.value, "newest")
        XCTAssertEqual(reply.itemID, newest.id)
        XCTAssertEqual(written.first?.uti, ClipUTI.utf8PlainText)
        XCTAssertEqual(written.first.flatMap { String(data: $0.data, encoding: .utf8) }, "newest")
        XCTAssertEqual(writtenText, "newest")
        XCTAssertGreaterThan(newest.lastUsedAt, before)
    }

    func testCopyLatestOnEmptyHistoryThrows() {
        let store = makeStore()
        XCTAssertThrowsError(try ClipIntentRunner.copyLatest(store: store, writer: { _, _ in true })) { error in
            XCTAssertEqual(error as? ClipIntentError, .noItems)
        }
    }

    func testCopyLatestReportsWriteFailure() {
        let store = makeStore()
        store.ingest(ClipDraft.text("x"))
        XCTAssertThrowsError(try ClipIntentRunner.copyLatest(store: store, writer: { _, _ in false })) { error in
            XCTAssertEqual(error as? ClipIntentError, .pasteboardWriteFailed)
        }
    }

    func testCopyItemByMissingIDThrows() {
        let store = makeStore()
        XCTAssertThrowsError(try ClipIntentRunner.copyItem(id: UUID(), store: store, writer: { _, _ in true })) { error in
            XCTAssertEqual(error as? ClipIntentError, .itemNotFound)
        }
    }
}
