import XCTest
import SwiftData
@testable import ClipCore

@MainActor
final class ClipStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(settings: AppSettings? = nil) -> ClipStore {
        let store = ClipStore.makeShared(inMemory: true)
        store.settings = settings
        return store
    }

    private func makeSettings() -> AppSettings {
        let suite = "ClipCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? UserDefaults.standard
        return AppSettings(defaults: defaults)
    }

    private func textDraft(_ text: String, ago seconds: TimeInterval = 0, app: String? = nil) -> ClipDraft {
        return ClipDraft.text(text, sourceAppBundleID: app, createdAt: Date().addingTimeInterval(-seconds))
    }

    // MARK: - Store basics

    func testInMemoryStoreFlags() {
        let store = makeStore()
        XCTAssertTrue(store.isInMemory)
        XCTAssertFalse(store.isCloudSyncActive)
        XCTAssertNil(store.storeError)
        XCTAssertEqual(store.itemCount(), 0)
    }

    func testIngestCreatesItemWithDerivedFields() {
        let store = makeStore()
        let item = store.ingest(ClipDraft.text("  Hello\nWorld", sourceAppBundleID: "com.apple.TextEdit", sourceAppName: "TextEdit"))
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.kind, .text)
        XCTAssertEqual(item?.title, "Hello")
        XCTAssertEqual(item?.sourceAppName, "TextEdit")
        XCTAssertEqual(item?.representations?.count, 1)
        XCTAssertFalse(item?.contentHash.isEmpty ?? true)
        XCTAssertEqual(store.itemCount(), 1)
        XCTAssertNil(store.lastRejection)
    }

    // MARK: - Dedup

    func testDedupBumpsExistingItemInsteadOfDuplicating() {
        let store = makeStore()
        let first = store.ingest(textDraft("alpha", ago: 30))
        _ = store.ingest(textDraft("beta", ago: 20))
        XCTAssertEqual(store.fetchItems().first?.plainText, "beta")

        let result = store.ingestDetailed(textDraft("alpha\r\n"))
        guard case .bumped(let bumped) = result else {
            return XCTFail("expected .bumped, got \(result)")
        }
        XCTAssertTrue(bumped === first)
        XCTAssertEqual(store.itemCount(), 2)
        XCTAssertEqual(store.fetchItems().first?.plainText, "alpha", "bumped item is on top")
    }

    // MARK: - Rejections

    func testIgnoredAppIsRejected() {
        let settings = makeSettings()
        settings.addIgnoredBundleID("com.example.secret")
        let store = makeStore(settings: settings)

        XCTAssertNil(store.ingest(textDraft("pw1", app: "com.1password.1password")))
        XCTAssertEqual(store.lastRejection, .ignoredApp)
        XCTAssertNil(store.ingest(textDraft("pw2", app: "com.example.secret")))
        XCTAssertNotNil(store.ingest(textDraft("ok", app: "com.apple.Safari")))
        XCTAssertEqual(store.itemCount(), 1)
    }

    func testConcealedAndTransientDraftsAreRejected() {
        let store = makeStore()
        var concealed = textDraft("secret")
        concealed.declaredTypes.append(ClipUTI.concealed)
        XCTAssertNil(store.ingest(concealed))
        XCTAssertEqual(store.lastRejection, .markerType)

        var transient = textDraft("temp")
        transient.representations.append(ClipDraft.Representation(uti: ClipUTI.transient, data: Data([0])))
        XCTAssertNil(store.ingest(transient))

        let empty = ClipDraft(kind: .text, plainText: "   \n ")
        XCTAssertNil(store.ingest(empty))
        XCTAssertEqual(store.lastRejection, .empty)
        XCTAssertEqual(store.itemCount(), 0)
    }

    // MARK: - Retention

    func testRetentionKeepsPinnedAndPinboardItems() {
        let store = makeStore()
        let day: TimeInterval = 86_400
        let oldPlain = store.ingest(textDraft("old plain", ago: 10 * day))
        let oldPinned = store.ingest(textDraft("old pinned", ago: 10 * day))
        let oldBoarded = store.ingest(textDraft("old boarded", ago: 10 * day))
        let recent = store.ingest(textDraft("recent", ago: 60))
        XCTAssertNotNil(oldPlain)

        if let oldPinned = oldPinned { store.pin(oldPinned) }
        let board = store.createPinboard(name: "Keep")
        if let oldBoarded = oldBoarded { store.add(oldBoarded, to: board) }

        let removed = store.applyRetention(.week)
        XCTAssertEqual(removed, 1)
        let remaining = Set(store.fetchItems().compactMap { $0.plainText })
        XCTAssertEqual(remaining, ["old pinned", "old boarded", "recent"])
        XCTAssertNotNil(recent)
        XCTAssertEqual(store.applyRetention(.forever), 0)
    }

    func testClearHistoryKeepPinned() {
        let store = makeStore()
        let a = store.ingest(textDraft("a"))
        _ = store.ingest(textDraft("b"))
        _ = store.ingest(textDraft("c"))
        if let a = a { store.pin(a) }
        XCTAssertEqual(store.clearHistory(keepPinned: true), 2)
        XCTAssertEqual(store.itemCount(), 1)
        XCTAssertEqual(store.clearHistory(keepPinned: false), 1)
        XCTAssertEqual(store.itemCount(), 0)
    }

    func testMaxHistoryCountTrimsOldestUnprotected() {
        let settings = makeSettings()
        settings.maxHistoryCount = 3
        let store = makeStore(settings: settings)
        let oldest = store.ingest(textDraft("1", ago: 50))
        if let oldest = oldest { store.pin(oldest) }
        _ = store.ingest(textDraft("2", ago: 40))
        _ = store.ingest(textDraft("3", ago: 30))
        _ = store.ingest(textDraft("4", ago: 20))
        XCTAssertEqual(store.itemCount(), 3)
        let texts = Set(store.fetchItems().compactMap { $0.plainText })
        XCTAssertEqual(texts, ["1", "3", "4"], "pinned oldest survives, '2' trimmed")
    }

    // MARK: - Fetch / search

    func testFetchFiltersByKindSearchAndPaging() {
        let store = makeStore()
        _ = store.ingest(textDraft("https://example.com/cafe-menu", ago: 40))
        _ = store.ingest(textDraft("Café order list", ago: 30, app: nil))
        _ = store.ingest(textDraft("Meeting notes", ago: 20))
        _ = store.ingest(textDraft("#FF8800", ago: 10))

        XCTAssertEqual(store.fetchItems(ClipFilter(kind: .link)).count, 1)
        XCTAssertEqual(store.fetchItems(ClipFilter(kind: .color)).first?.colorHex, "#FF8800")
        XCTAssertEqual(store.fetchItems(ClipFilter(searchText: "CAFE")).count, 2)
        XCTAssertEqual(store.fetchItems(ClipFilter(searchText: "cafe order")).count, 1)
        XCTAssertEqual(store.fetchItems(ClipFilter(searchText: "cafe zebra")).count, 0)
        XCTAssertEqual(store.fetchItems(ClipFilter(limit: 2)).count, 2)
        XCTAssertEqual(store.fetchItems(ClipFilter(limit: 2, offset: 3)).count, 1)
        XCTAssertEqual(store.latestItem()?.plainText, "#FF8800")
    }

    func testMarkUsedMovesItemToTopAndPinnedOnlyFilter() {
        let store = makeStore()
        let old = store.ingest(textDraft("old", ago: 100))
        _ = store.ingest(textDraft("new", ago: 10))
        guard let item = old else { return XCTFail("ingest failed") }
        store.markUsed(item)
        XCTAssertEqual(store.latestItem()?.plainText, "old")
        store.togglePin(item)
        XCTAssertTrue(item.isPinned)
        XCTAssertEqual(store.fetchItems(ClipFilter(pinnedOnly: true)).count, 1)
        store.unpin(item)
        XCTAssertEqual(store.fetchItems(ClipFilter(pinnedOnly: true)).count, 0)
    }

    func testOCRTextIsSearchable() {
        let store = makeStore()
        let draft = ClipDraft(
            kind: .image,
            representations: [ClipDraft.Representation(uti: ClipUTI.png, data: Data([0x89, 0x50, 0x4E, 0x47]))]
        )
        guard let item = store.ingest(draft) else { return XCTFail("ingest failed") }
        XCTAssertEqual(store.fetchItems(ClipFilter(searchText: "receipt")).count, 0)
        store.setOCRText("Grocery RECEIPT", for: item)
        XCTAssertEqual(store.fetchItems(ClipFilter(searchText: "receipt")).count, 1)
        XCTAssertEqual(item.displayTitle, "Grocery RECEIPT")
    }

    // MARK: - Pinboards

    func testPinboardOrderingAndMembership() {
        let store = makeStore()
        let work = store.createPinboard(name: "Work")
        let home = store.createPinboard(name: "Home", colorHex: "#22c55e")
        let code = store.createPinboard(name: "Code")
        XCTAssertEqual(store.pinboards().map { $0.name }, ["Work", "Home", "Code"])
        XCTAssertEqual(home.colorHex, "#22C55E")

        store.movePinboards(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(store.pinboards().map { $0.name }, ["Code", "Work", "Home"])

        store.movePinboard(from: 0, to: 2)
        XCTAssertEqual(store.pinboards().map { $0.name }, ["Work", "Home", "Code"])

        store.reorderPinboards([home, code, work])
        XCTAssertEqual(store.pinboards().map { $0.sortOrder }, [0, 1, 2])
        XCTAssertEqual(store.pinboards().first?.name, "Home")

        store.renamePinboard(work, to: "Office")
        XCTAssertEqual(work.name, "Office")

        guard let item = store.ingest(textDraft("snippet")) else { return XCTFail("ingest failed") }
        store.add(item, to: code)
        store.add(item, to: code)
        XCTAssertEqual(store.items(in: code).count, 1)
        XCTAssertTrue(item.isInPinboard)
        XCTAssertEqual(store.fetchItems(ClipFilter(pinboardID: code.id)).count, 1)

        store.remove(item, from: code)
        XCTAssertEqual(store.items(in: code).count, 0)

        store.add(item, to: home)
        store.deletePinboard(home)
        XCTAssertEqual(store.pinboards().map { $0.name }, ["Code", "Office"])
        XCTAssertEqual(store.pinboards().map { $0.sortOrder }, [0, 1])
        XCTAssertNotNil(store.item(withID: item.id), "deleting a pinboard keeps its items")
    }

    // MARK: - Blobs & size policy

    func testLargeRepresentationGoesToBlobStoreAndRoundTrips() {
        let store = makeStore()
        var bytes = [UInt8](repeating: 0, count: 300 * 1024)
        for index in 0..<bytes.count { bytes[index] = UInt8(index % 251) }
        let payload = Data(bytes)
        let draft = ClipDraft(kind: .image, representations: [ClipDraft.Representation(uti: ClipUTI.png, data: payload)])

        guard let item = store.ingest(draft), let rep = item.representation(forUTI: ClipUTI.png) else {
            return XCTFail("ingest failed")
        }
        XCTAssertTrue(rep.isStoredInBlob)
        XCTAssertNil(rep.inlineData)
        XCTAssertEqual(rep.byteSize, payload.count)
        XCTAssertEqual(store.data(for: rep), payload)
        XCTAssertTrue(item.hasLocalBlobs)
        XCTAssertEqual(store.pasteboardPayload(for: item).first?.data, payload)

        let fileName = rep.fileName ?? ""
        XCTAssertTrue(store.blobStore.exists(fileName))
        store.delete(item)
        XCTAssertFalse(store.blobStore.exists(fileName), "orphaned blob removed with its item")
    }

    func testSmallRepresentationStaysInline() {
        let store = makeStore()
        guard let item = store.ingest(textDraft("tiny")), let rep = item.representations?.first else {
            return XCTFail("ingest failed")
        }
        XCTAssertFalse(rep.isStoredInBlob)
        XCTAssertEqual(store.data(for: rep), Data("tiny".utf8))
    }

    func testSizeCapFlagsLocalOnly() {
        XCTAssertEqual(StoragePolicy().syncSizeCapBytes, 20 * 1024 * 1024)
        let store = makeStore()
        store.storagePolicy.syncSizeCapBytes = 1_000
        let big = ClipDraft(kind: .file, plainText: "/tmp/big.bin", representations: [ClipDraft.Representation(uti: "public.data", data: Data(count: 2_000))])
        let small = ClipDraft(kind: .file, plainText: "/tmp/small.bin", representations: [ClipDraft.Representation(uti: "public.data", data: Data(count: 10))])
        XCTAssertEqual(store.ingest(big)?.isLocalOnly, true)
        XCTAssertEqual(store.ingest(small)?.isLocalOnly, false)

        store.storagePolicy.maxIngestBytes = 1_500
        XCTAssertNil(store.ingest(ClipDraft(kind: .file, plainText: "/tmp/huge.bin", representations: [ClipDraft.Representation(uti: "public.data", data: Data(count: 1_600))])))
        XCTAssertEqual(store.lastRejection, .tooLarge)
    }

    func testBlobStoreDirectRoundTrip() throws {
        let blobs = BlobStore.temporary()
        let data = Data("blob-content".utf8)
        let name = try blobs.write(data)
        XCTAssertEqual(name, ContentHasher.sha256Hex(data))
        XCTAssertEqual(try blobs.write(data), name, "content-addressed, idempotent")
        XCTAssertEqual(blobs.read(name), data)
        XCTAssertNil(blobs.read("../etc/passwd"))
        blobs.delete(name)
        XCTAssertNil(blobs.read(name))
    }
}

@MainActor
final class AppSettingsTests: XCTestCase {
    func testSettingsPersistAcrossInstances() {
        let suite = "ClipCoreTests.settings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("no suite") }
        let first = AppSettings(defaults: defaults)
        XCTAssertEqual(first.retention, .month)
        XCTAssertEqual(first.maxHistoryCount, AppSettings.defaultMaxHistoryCount)
        XCTAssertFalse(first.capturePaused)

        first.retention = .week
        first.capturePaused = true
        first.maxHistoryCount = 500
        first.addIgnoredBundleID("com.example.app")
        first.hasCompletedOnboarding = true

        let second = AppSettings(defaults: defaults)
        XCTAssertEqual(second.retention, .week)
        XCTAssertTrue(second.capturePaused)
        XCTAssertEqual(second.maxHistoryCount, 500)
        XCTAssertEqual(second.ignoredBundleIDs, ["com.example.app"])
        XCTAssertTrue(second.ignoreRules.shouldIgnore(bundleID: "com.example.app"))
        XCTAssertTrue(second.hasCompletedOnboarding)

        second.resetToDefaults()
        let third = AppSettings(defaults: defaults)
        XCTAssertEqual(third.retention, .month)
        XCTAssertEqual(third.ignoredBundleIDs, [])
        defaults.removePersistentDomain(forName: suite)
    }
}
