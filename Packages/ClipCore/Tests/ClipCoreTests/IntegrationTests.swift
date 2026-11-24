import XCTest
@testable import ClipCore

// Added by the integration pass: covers the additive APIs (ClipFilter.kinds,
// ClipFileList / store.fileURLs(for:), AppSettings.setShared / ephemeral).

@MainActor
final class IntegrationTests: XCTestCase {

    private func makeStore() -> ClipStore {
        return ClipStore.makeShared(inMemory: true)
    }

    private func ingest(_ store: ClipStore, kind: ClipKind, text: String, ago seconds: TimeInterval) {
        let rep = ClipDraft.Representation(uti: ClipUTI.utf8PlainText, data: Data(text.utf8))
        let draft = ClipDraft(
            kind: kind,
            plainText: text,
            representations: [rep],
            createdAt: Date().addingTimeInterval(-seconds)
        )
        XCTAssertNotNil(store.ingest(draft), "ingest \(text)")
    }

    // MARK: ClipFilter.kinds

    func testKindsFilterUnionAndExactPaging() {
        let store = makeStore()
        let cycle: [ClipKind] = [.richText, .text, .link]
        for index in 0..<30 {
            ingest(store, kind: cycle[index % 3], text: "item \(index)", ago: TimeInterval(1_000 - index * 10))
        }
        let textual = ClipFilter(kinds: [.text, .richText])
        let all = store.fetchItems(textual)
        XCTAssertEqual(all.count, 20)
        XCTAssertTrue(all.allSatisfy { $0.kind == .text || $0.kind == .richText })

        // Paging must equal slicing the unpaged result.
        var paged: [ClipItem] = []
        var offset = 0
        while true {
            let page = store.fetchItems(ClipFilter(kinds: [.text, .richText], limit: 7, offset: offset))
            if page.isEmpty { break }
            paged.append(contentsOf: page)
            offset += page.count
        }
        XCTAssertEqual(paged.map { $0.id }, all.map { $0.id })

        // One-element set == kind; empty set == nothing; nil == everything.
        XCTAssertEqual(store.fetchItems(ClipFilter(kinds: [.link])).count, 10)
        XCTAssertEqual(store.fetchItems(ClipFilter(kind: .link)).count, 10)
        XCTAssertEqual(store.fetchItems(ClipFilter(kinds: [])).count, 0)
        XCTAssertEqual(store.fetchItems(ClipFilter(kinds: nil)).count, 30)

        // kind ∩ kinds.
        var both = ClipFilter(kind: .text)
        both.kinds = [.text, .richText]
        XCTAssertEqual(store.fetchItems(both).count, 10)
        both.kinds = [.link]
        XCTAssertEqual(store.fetchItems(both).count, 0)

        // With a multi-token search.
        let searched = store.fetchItems(ClipFilter(kinds: [.text, .richText], searchText: "item 1"))
        XCTAssertFalse(searched.isEmpty)
        XCTAssertTrue(searched.allSatisfy { ($0.plainText ?? "").contains("1") && $0.kind != .link })
    }

    // MARK: ClipFileList

    func testFileListRoundTripAndTolerantDecode() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a file.txt"),
            URL(fileURLWithPath: "/tmp/b.png"),
            URL(fileURLWithPath: "/tmp/a file.txt")
        ]
        let data = ClipFileList.encode(urls)
        XCTAssertEqual(ClipFileList.decode(data).map { $0.path }, ["/tmp/a file.txt", "/tmp/b.png"])
        XCTAssertEqual(ClipFileList.decode(Data("/tmp/x\u{0}/tmp/y\r\n".utf8)).map { $0.path }, ["/tmp/x", "/tmp/y"])
        let plist = try? PropertyListSerialization.data(fromPropertyList: ["/tmp/p", "/tmp/q"], format: .xml, options: 0)
        XCTAssertEqual(ClipFileList.decode(plist ?? Data()).map { $0.path }, ["/tmp/p", "/tmp/q"])
        XCTAssertEqual(ClipFileList.decode(Data("https://example.com".utf8)), [])
    }

    func testStoreFileURLsPrefersFullListAndHidesItFromPaste() {
        let store = makeStore()
        let urls = [URL(fileURLWithPath: "/tmp/one.txt"), URL(fileURLWithPath: "/tmp/two.txt")]
        let draft = ClipDraft(
            kind: .file,
            plainText: urls.map { $0.path }.joined(separator: "\n"),
            representations: [
                ClipDraft.Representation(uti: ClipUTI.fileURL, data: Data(urls[0].absoluteString.utf8)),
                ClipDraft.Representation(uti: ClipUTI.fileURLList, data: ClipFileList.encode(urls))
            ]
        )
        guard let item = store.ingest(draft) else { return XCTFail("ingest failed") }
        XCTAssertEqual(store.fileURLs(for: item).map { $0.path }, ["/tmp/one.txt", "/tmp/two.txt"])
        XCTAssertTrue(ClipUTI.isInternal(ClipUTI.fileURLList))
        XCTAssertTrue(ClipUTI.isInternal(ClipUTI.ownWrite))
        XCTAssertFalse(store.pasteboardPayload(for: item).contains { $0.uti == ClipUTI.fileURLList })

        // Share-extension style draft: contents only, no URL → [].
        let contentsOnly = ClipDraft(
            kind: .file,
            title: "Report.docx",
            representations: [ClipDraft.Representation(uti: "org.openxmlformats.wordprocessingml.document", data: Data([1, 2, 3]))]
        )
        guard let shared = store.ingest(contentsOnly) else { return XCTFail("ingest failed") }
        XCTAssertEqual(store.fileURLs(for: shared), [])
        XCTAssertEqual(shared.displayTitle, "Report.docx")
    }

    // MARK: AppSettings

    func testEphemeralSettingsAreIsolatedAndSwappable() {
        let first = AppSettings.ephemeral(suiteName: "com.thingbits.clipsync.tests.ephemeral")
        first.capturePaused = true
        first.addIgnoredBundleID("com.example.leak")
        let second = AppSettings.ephemeral(suiteName: "com.thingbits.clipsync.tests.ephemeral")
        XCTAssertFalse(second.capturePaused, "ephemeral() starts from a wiped suite")
        XCTAssertEqual(second.ignoredBundleIDs, [])

        let original = AppSettings.shared
        AppSettings.setShared(second)
        XCTAssertTrue(AppSettings.shared === second)
        AppSettings.setShared(original)
        XCTAssertTrue(AppSettings.shared === original)
        second.defaults.removePersistentDomain(forName: "com.thingbits.clipsync.tests.ephemeral")
    }
}
