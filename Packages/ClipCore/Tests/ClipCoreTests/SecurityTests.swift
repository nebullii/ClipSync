import XCTest
@testable import ClipCore

// Security pass: App Lock state machine (fake authenticator + fake clock), the
// link-preview network gate, sensitive-content markers / ignore list and file permissions.
// Nothing here touches LocalAuthentication or the network.

@MainActor
final class FakeAuthenticator: AppLockAuthenticating {
    var availabilityValue = AppLockAvailability(canAuthenticate: true, biometryKind: .touchID)
    /// Results returned by successive authenticate calls (last one repeats).
    var results: [AppLockAuthResult] = [.success]
    private(set) var calls = 0
    private(set) var reasons: [String] = []

    func availability() -> AppLockAvailability {
        return availabilityValue
    }

    func authenticate(reason: String) async -> AppLockAuthResult {
        calls += 1
        reasons.append(reason)
        if results.isEmpty { return .success }
        if results.count == 1 { return results[0] }
        return results.removeFirst()
    }
}

final class FakeLockClock: AppLockClock {
    var seconds: TimeInterval = 1_000

    func now() -> TimeInterval {
        return seconds
    }

    func advance(_ delta: TimeInterval) {
        seconds += delta
    }
}

/// Counts fetch calls; returns a fixed title. Sendable via a lock.
final class SpyLinkFetcher: LinkMetadataFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func fetchMetadata(for url: URL) async -> LinkMetadata? {
        lock.lock()
        count += 1
        lock.unlock()
        return LinkMetadata(title: "Spy Title")
    }
}

@MainActor
final class AppLockTests: XCTestCase {
    /// One fixed suite, wiped by every `ephemeral` call (no leftovers per run).
    private func makeSettings() -> AppSettings {
        return AppSettings.ephemeral(suiteName: "ClipCoreTests.security")
    }

    private func makeController(
        settings: AppSettings? = nil,
        auth: FakeAuthenticator? = nil,
        clock: FakeLockClock? = nil
    ) -> (AppLockController, FakeAuthenticator, FakeLockClock, AppSettings) {
        let resolvedSettings = settings ?? makeSettings()
        let resolvedAuth = auth ?? FakeAuthenticator()
        let resolvedClock = clock ?? FakeLockClock()
        let controller = AppLockController(settings: resolvedSettings, authenticator: resolvedAuth, clock: resolvedClock)
        return (controller, resolvedAuth, resolvedClock, resolvedSettings)
    }

    // MARK: Defaults

    func testSecurityDefaults() {
        let settings = makeSettings()
        XCTAssertFalse(settings.appLockEnabled)
        XCTAssertEqual(settings.lockTimeout, .after5Minutes)
        XCTAssertFalse(settings.linkPreviewsEnabled)
        XCTAssertTrue(settings.hideFromScreenCapture)
        XCTAssertTrue(settings.privacyCoverEnabled)
        XCTAssertFalse(settings.clearHistoryOnQuit)
        XCTAssertTrue(settings.playCopySound)
        settings.playCopySound = false
        settings.resetToDefaults()
        XCTAssertTrue(settings.playCopySound, "reset turns the copy sound back on")
        XCTAssertEqual(settings.copySoundName, "Tink")
        settings.copySoundName = "Glass"
        settings.resetToDefaults()
        XCTAssertEqual(settings.copySoundName, "Tink")
        XCTAssertTrue(AppSettings.allKeys.contains(AppSettings.Keys.playCopySound))
        XCTAssertTrue(AppSettings.allKeys.contains(AppSettings.Keys.appLockEnabled))
        XCTAssertTrue(AppSettings.allKeys.contains(AppSettings.Keys.linkPreviewsEnabled))
    }

    func testDisabledLockNeverLocks() {
        let (lock, auth, clock, _) = makeController()
        XCTAssertFalse(lock.isLocked)
        lock.lockNow()
        XCTAssertFalse(lock.isLocked, "lockNow is a no-op while App Lock is off")
        clock.advance(10 * 3600)
        XCTAssertFalse(lock.checkTimeout())
        lock.noteInterfaceHidden()
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(auth.calls, 0)
    }

    func testTimeoutRawValuesAndIntervals() {
        XCTAssertEqual(LockTimeout.allCases.map { $0.rawValue },
                       ["immediately", "after1Minute", "after5Minutes", "after15Minutes", "after1Hour"])
        XCTAssertNil(LockTimeout.immediately.interval)
        XCTAssertEqual(LockTimeout.after1Minute.interval, 60)
        XCTAssertEqual(LockTimeout.after1Hour.interval, 3600)
    }

    // MARK: Enabling / disabling require authentication

    func testEnablingRequiresAuthentication() async {
        let (lock, auth, _, settings) = makeController()
        auth.results = [.cancelled]
        let cancelled = await lock.setEnabled(true, reason: "turn on App Lock")
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertFalse(settings.appLockEnabled)

        auth.results = [.failed("nope")]
        let failed = await lock.setEnabled(true, reason: "turn on App Lock")
        XCTAssertEqual(failed, .failed("nope"))
        XCTAssertFalse(settings.appLockEnabled)
        XCTAssertEqual(lock.lastMessage, "nope")

        auth.results = [.success]
        let changed = await lock.setEnabled(true, reason: "turn on App Lock")
        XCTAssertEqual(changed, .changed)
        XCTAssertTrue(settings.appLockEnabled)
        XCTAssertFalse(lock.isLocked, "the user just authenticated")
        XCTAssertEqual(auth.calls, 3)
    }

    func testEnablingIsRefusedWithoutPasscode() async {
        let auth = FakeAuthenticator()
        auth.availabilityValue = AppLockAvailability(canAuthenticate: false, biometryKind: .none, unavailableReason: "No passcode.")
        let (lock, _, _, settings) = makeController(auth: auth)
        let result = await lock.setEnabled(true, reason: "turn on App Lock")
        XCTAssertEqual(result, .unavailable("No passcode."))
        XCTAssertFalse(settings.appLockEnabled)
        XCTAssertEqual(auth.calls, 0, "no prompt when the device cannot authenticate")
        XCTAssertFalse(lock.canAuthenticate)
    }

    func testDisablingRequiresAuthentication() async {
        let (lock, auth, _, settings) = makeController()
        _ = await lock.setEnabled(true, reason: "on")
        XCTAssertTrue(settings.appLockEnabled)

        auth.results = [.cancelled]
        let cancelled = await lock.setEnabled(false, reason: "off")
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertTrue(settings.appLockEnabled, "cancelling must keep the lock on")

        auth.results = [.success]
        let changed = await lock.setEnabled(false, reason: "off")
        XCTAssertEqual(changed, .changed)
        XCTAssertFalse(settings.appLockEnabled)
        XCTAssertFalse(lock.isLocked)
    }

    // MARK: State machine

    func testStartsLockedWhenEnabled() async {
        let (first, _, _, settings) = makeController()
        _ = await first.setEnabled(true, reason: "on")
        // A new process (app relaunch / intent launch) with the same settings starts locked.
        let (second, _, _, _) = makeController(settings: settings)
        XCTAssertTrue(second.isLocked)
    }

    func testTimeoutRelocksAfterInterval() async {
        let (lock, auth, clock, settings) = makeController()
        _ = await lock.setEnabled(true, reason: "on")
        settings.lockTimeout = .after5Minutes
        XCTAssertFalse(lock.isLocked)

        lock.noteInterfaceHidden()
        clock.advance(4 * 60 + 59)
        XCTAssertFalse(lock.checkTimeout(), "4:59 < 5 minutes")
        clock.advance(1)
        XCTAssertTrue(lock.checkTimeout(), "5:00 ≥ 5 minutes")
        XCTAssertTrue(lock.isLocked)

        auth.results = [.success]
        let unlocked = await lock.unlock(reason: "unlock")
        XCTAssertTrue(unlocked)
        XCTAssertFalse(lock.isLocked)
    }

    func testActivityPostponesTimeout() async {
        let (lock, _, clock, settings) = makeController()
        _ = await lock.setEnabled(true, reason: "on")
        settings.lockTimeout = .after1Minute
        clock.advance(50)
        lock.noteActivity()
        clock.advance(50)
        XCTAssertFalse(lock.checkTimeout(), "only 50 s since the last activity")
        clock.advance(10)
        XCTAssertTrue(lock.checkTimeout())
    }

    func testImmediatelyLocksWhenHidden() async {
        let (lock, _, clock, settings) = makeController()
        _ = await lock.setEnabled(true, reason: "on")
        settings.lockTimeout = .immediately
        clock.advance(3600)
        XCTAssertFalse(lock.checkTimeout(), "immediately = lock on hide, not on elapsed time while shown")
        lock.noteInterfaceHidden()
        XCTAssertTrue(lock.isLocked)
    }

    func testLockNowAndFailedUnlock() async {
        let (lock, auth, _, _) = makeController()
        _ = await lock.setEnabled(true, reason: "on")
        lock.lockNow()
        XCTAssertTrue(lock.isLocked)

        auth.results = [.cancelled]
        let cancelled = await lock.unlock(reason: "unlock")
        XCTAssertFalse(cancelled)
        XCTAssertTrue(lock.isLocked)

        auth.results = [.failed("Try again.")]
        let failed = await lock.unlock(reason: "unlock")
        XCTAssertFalse(failed)
        XCTAssertTrue(lock.isLocked)
        XCTAssertEqual(lock.lastMessage, "Try again.")

        auth.results = [.success]
        let unlocked = await lock.unlock(reason: "unlock")
        XCTAssertTrue(unlocked)
        XCTAssertFalse(lock.isLocked)
        XCTAssertNil(lock.lastMessage)
    }

    func testObserversSeeEveryChange() async {
        let (lock, _, _, _) = makeController()
        var seen: [Bool] = []
        lock.addLockStateObserver { value in seen.append(value) }
        _ = await lock.setEnabled(true, reason: "on")   // stays unlocked: no change
        lock.lockNow()
        lock.lockNow()                                  // already locked: no duplicate
        _ = await lock.unlock(reason: "unlock")
        XCTAssertEqual(seen, [true, false])
    }

    func testUnlockButtonTitleFollowsBiometry() {
        let auth = FakeAuthenticator()
        auth.availabilityValue = AppLockAvailability(canAuthenticate: true, biometryKind: .faceID)
        let (lock, _, _, _) = makeController(auth: auth)
        XCTAssertEqual(lock.biometryKind, .faceID)
        XCTAssertEqual(lock.unlockButtonTitle, "Unlock with Face ID")
        auth.availabilityValue = AppLockAvailability(canAuthenticate: true, biometryKind: .none)
        lock.refreshAvailability()
        XCTAssertEqual(lock.unlockButtonTitle, "Unlock")
    }

    func testIntentGateRefusesWhileLocked() async throws {
        let (lock, _, _, _) = makeController()
        XCTAssertNoThrow(try ClipIntentRunner.requireUnlocked(lock: lock))
        _ = await lock.setEnabled(true, reason: "on")
        lock.lockNow()
        XCTAssertThrowsError(try ClipIntentRunner.requireUnlocked(lock: lock)) { error in
            XCTAssertEqual(error as? ClipIntentError, .locked)
        }
        // Saving still works while locked (write-only).
        let store = ClipStore.makeShared(inMemory: true)
        let reply = try ClipIntentRunner.saveText("saved while locked", store: store)
        XCTAssertFalse(reply.wasDuplicate)
        XCTAssertEqual(store.itemCount(), 1)
    }
}

@MainActor
final class LinkPreviewGateTests: XCTestCase {
    private func makeStore(spy: SpyLinkFetcher, settings: AppSettings?) -> ClipStore {
        let store = ClipStore.makeShared(inMemory: true)
        store.settings = settings
        store.media = MediaServices(
            thumbnails: NoopThumbnailGenerator(),
            textRecognizer: NoopTextRecognizer(),
            linkMetadata: spy
        )
        return store
    }

    func testEnrichDoesNotFetchLinksWhenSettingIsOff() async throws {
        let settings = AppSettings.ephemeral(suiteName: "ClipCoreTests.linkgate")
        XCTAssertFalse(settings.linkPreviewsEnabled, "default must be off")

        let spy = SpyLinkFetcher()
        let store = makeStore(spy: spy, settings: settings)
        let item = try XCTUnwrap(store.ingest(.text("https://example.com/clipsync-gate")))
        XCTAssertEqual(item.kind, .link)

        await store.enrich(item)
        XCTAssertEqual(spy.calls, 0, "no network fetch with link previews off")
        XCTAssertEqual(store.linkFetchAttempts, 0)
        XCTAssertNil(item.representation(forUTI: ClipUTI.linkIcon))

        settings.linkPreviewsEnabled = true
        await store.enrich(item)
        XCTAssertEqual(spy.calls, 1, "fetches once the user opted in")
        XCTAssertEqual(store.linkFetchAttempts, 1)
        XCTAssertEqual(item.title, "Spy Title")
    }

    func testEnrichDoesNotFetchLinksWithoutSettings() async throws {
        let spy = SpyLinkFetcher()
        let store = makeStore(spy: spy, settings: nil)
        let item = try XCTUnwrap(store.ingest(.text("https://example.com/no-settings")))
        await store.enrich(item)
        XCTAssertEqual(spy.calls, 0)
        XCTAssertEqual(store.linkFetchAttempts, 0)
    }
}

final class SensitiveContentTests: XCTestCase {
    func testLegacyAndVendorMarkersAreSkipped() {
        let markers = [
            "com.agilebits.onepassword",
            "de.petermaurer.TransientPasteboardType",
            "Pasteboard generator type",
            "com.typeit4me.clipping",
            ClipUTI.concealed,
            ClipUTI.transient,
            ClipUTI.autoGenerated
        ]
        for marker in markers {
            XCTAssertNotNil(PasteboardTypeClassifier.markerSkipReason(for: [ClipUTI.utf8PlainText, marker]), marker)
            XCTAssertTrue(PasteboardTypeClassifier.classify(types: [ClipUTI.utf8PlainText, marker], string: "secret").isSkipped, marker)
        }
        XCTAssertNil(PasteboardTypeClassifier.markerSkipReason(for: [ClipUTI.utf8PlainText, ClipUTI.source]))
    }

    @MainActor
    func testStoreRejectsMarkedDrafts() {
        let store = ClipStore.makeShared(inMemory: true)
        var draft = ClipDraft.text("hunter2")
        draft.declaredTypes = [ClipUTI.utf8PlainText, "com.agilebits.onepassword"]
        XCTAssertNil(store.ingest(draft))
        XCTAssertEqual(store.lastRejection, .markerType)
        XCTAssertEqual(store.itemCount(), 0)
    }

    func testPasswordManagersAreIgnoredByDefault() {
        let rules = IgnoreRules()
        let ignored = [
            "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
            "org.keepassxc.keepassxc", "com.lastpass.LastPass", "com.lastpass.lastpassmacdesktop",
            "com.dashlane.dashlanephonefinal", "com.dashlane.Dashlane", "me.proton.pass.electron",
            "in.sinew.Enpass-Desktop", "in.sinew.Walletx", "com.markmcguill.strongbox",
            "com.markmcguill.strongbox.mac", "com.apple.Passwords", "com.apple.keychainaccess"
        ]
        for bundleID in ignored {
            XCTAssertTrue(rules.shouldIgnore(bundleID: bundleID), bundleID)
        }
        let allowed = ["com.apple.TextEdit", "me.proton.mail", "com.apple.Safari", "com.markmcguill.other"]
        for bundleID in allowed {
            XCTAssertFalse(rules.shouldIgnore(bundleID: bundleID), bundleID)
        }
        XCTAssertFalse(IgnoreRules(includeDefaults: false).shouldIgnore(bundleID: "com.lastpass.LastPass"))
    }
}

final class FileProtectionTests: XCTestCase {
    func testBlobFilesAreOwnerOnly() throws {
        let blobs = BlobStore.temporary()
        let name = try blobs.write(Data(repeating: 7, count: 1024))
        let fileURL = blobs.fileURL(for: name)
        XCTAssertEqual(StoreFileProtection.permissions(of: fileURL), 0o600)
        XCTAssertEqual(StoreFileProtection.permissions(of: blobs.directory), 0o700)
    }

    func testProtectTreeTightensExistingFiles() throws {
        let location = StoreLocation.temporary()
        let fm = FileManager.default
        try fm.createDirectory(at: location.blobsDirectory, withIntermediateDirectories: true)
        let file = location.directory.appendingPathComponent("db.sqlite")
        try Data("x".utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: file.path)
        StoreFileProtection.protectTree(at: location.directory)
        XCTAssertEqual(StoreFileProtection.permissions(of: file), 0o600)
        XCTAssertEqual(StoreFileProtection.permissions(of: location.directory), 0o700)
        XCTAssertEqual(StoreFileProtection.permissions(of: location.blobsDirectory), 0o700)
    }

    @MainActor
    func testClearHistoryRemovesBlobsAndThumbnails() throws {
        let store = ClipStore.makeShared(inMemory: true)
        store.storagePolicy = StoragePolicy(inlineThresholdBytes: 16)
        let payload = Data(repeating: 1, count: 4096)
        let draft = ClipDraft(
            kind: .image,
            representations: [ClipDraft.Representation(uti: ClipUTI.png, data: payload)],
            declaredTypes: [ClipUTI.png]
        )
        let item = try XCTUnwrap(store.ingest(draft))
        store.setInternalRepresentation(Data(repeating: 2, count: 2048), uti: ClipUTI.thumbnail, for: item)
        XCTAssertEqual(store.blobStore.allFileNames().count, 2, "payload + thumbnail stored as blob files")

        XCTAssertEqual(store.clearHistory(keepPinned: true), 1)
        XCTAssertEqual(store.itemCount(), 0)
        XCTAssertEqual(store.blobStore.allFileNames(), [], "clearing history deletes blob files (payloads and thumbnails)")
    }
}
