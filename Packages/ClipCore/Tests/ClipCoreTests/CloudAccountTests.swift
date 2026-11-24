import XCTest
@testable import ClipCore

/// Pure readiness mapping + monitor with an injected status provider. No CloudKit here:
/// the test process is unentitled, so CloudKit must never be touched.
@MainActor
final class CloudAccountTests: XCTestCase {

    private func readiness(_ state: CloudAccountState, enabled: Bool, active: Bool,
                           storeError: String? = nil) -> CloudSyncReadiness {
        return CloudSyncReadiness.resolve(state: state, cloudSyncEnabled: enabled,
                                          isCloudSyncActive: active, storeError: storeError)
    }

    private func makeSettings() -> AppSettings {
        let suite = "ClipCoreTests.cloud.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? UserDefaults.standard
        return AppSettings(defaults: defaults)
    }

    // MARK: - Mapping

    func testUnsupportedBuildWinsOverEverything() {
        XCTAssertEqual(readiness(.unsupportedBuild, enabled: false, active: false), .unsupportedBuild)
        XCTAssertEqual(readiness(.unsupportedBuild, enabled: true, active: false), .unsupportedBuild)
        XCTAssertEqual(readiness(.unsupportedBuild, enabled: true, active: false, storeError: "x"), .unsupportedBuild)
        XCTAssertEqual(readiness(.unsupportedBuild, enabled: true, active: true), .unsupportedBuild)
    }

    func testAvailableAccount() {
        XCTAssertEqual(readiness(.available, enabled: true, active: true), .syncing)
        XCTAssertEqual(readiness(.available, enabled: false, active: false), .readyButOff)
        XCTAssertEqual(readiness(.available, enabled: true, active: false), .needsRelaunch)
        XCTAssertEqual(readiness(.available, enabled: false, active: true), .needsRelaunch)
    }

    func testSignedOut() {
        XCTAssertEqual(readiness(.noAccount, enabled: false, active: false), .signedOut)
        XCTAssertEqual(readiness(.noAccount, enabled: true, active: false), .signedOut)
        XCTAssertEqual(readiness(.noAccount, enabled: true, active: true), .signedOut)
        // Turning sync off still needs a relaunch, even when signed out.
        XCTAssertEqual(readiness(.noAccount, enabled: false, active: true), .needsRelaunch)
    }

    func testStoreFallbackIsAnErrorNotARelaunch() {
        let result = readiness(.available, enabled: true, active: false, storeError: "iCloud sync unavailable")
        XCTAssertEqual(result, .error("iCloud sync unavailable"))
        // Empty error strings are ignored.
        XCTAssertEqual(readiness(.available, enabled: true, active: false, storeError: ""), .needsRelaunch)
    }

    func testRestrictedAndUnknownStates() {
        if case .error = readiness(.restricted, enabled: false, active: false) {} else {
            XCTFail("restricted should map to .error")
        }
        if case .error = readiness(.temporarilyUnavailable, enabled: true, active: true) {} else {
            XCTFail("temporarilyUnavailable while syncing should map to .error")
        }
        XCTAssertEqual(readiness(.couldNotDetermine("boom"), enabled: false, active: false), .error("boom"))
        XCTAssertEqual(readiness(.couldNotDetermine("boom"), enabled: true, active: true), .error("boom"))
        // Wish is on but this session is local: relaunching is the actionable answer.
        XCTAssertEqual(readiness(.temporarilyUnavailable, enabled: true, active: false), .needsRelaunch)
    }

    func testTitlesAndToggleRules() {
        let all: [CloudSyncReadiness] = [.syncing, .readyButOff, .needsRelaunch, .signedOut, .unsupportedBuild, .error("e")]
        for value in all {
            XCTAssertFalse(value.title.isEmpty)
            XCTAssertFalse(value.explanation.isEmpty)
        }
        XCTAssertFalse(CloudSyncReadiness.unsupportedBuild.allowsEnablingSync)
        XCTAssertFalse(CloudSyncReadiness.signedOut.allowsEnablingSync)
        XCTAssertNotNil(CloudSyncReadiness.unsupportedBuild.disabledReason)
        XCTAssertTrue(CloudSyncReadiness.readyButOff.allowsEnablingSync)
        XCTAssertNil(CloudSyncReadiness.readyButOff.disabledReason)
        XCTAssertEqual(CloudSyncReadiness.syncing.tone, .good)
        XCTAssertEqual(CloudSyncReadiness.error("e").tone, .problem)
    }

    // MARK: - Monitor

    func testUnsupportedMonitorNeverUsesProvider() async {
        let monitor = CloudAccountMonitor(isSupportedBuild: false,
                                          provider: { CloudAccountState.available },
                                          observesAccountChanges: false,
                                          refreshesImmediately: false)
        XCTAssertEqual(monitor.state, .unsupportedBuild)
        XCTAssertTrue(monitor.hasChecked)
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .unsupportedBuild)
        XCTAssertEqual(monitor.syncReadiness, .unsupportedBuild)
    }

    func testSupportedMonitorUsesInjectedProvider() async {
        let monitor = CloudAccountMonitor(isSupportedBuild: true,
                                          provider: { CloudAccountState.noAccount },
                                          observesAccountChanges: false,
                                          refreshesImmediately: false)
        XCTAssertFalse(monitor.hasChecked)
        await monitor.refresh()
        XCTAssertTrue(monitor.hasChecked)
        XCTAssertFalse(monitor.isRefreshing)
        XCTAssertEqual(monitor.state, .noAccount)
        XCTAssertEqual(monitor.syncReadiness, .signedOut)
    }

    func testMonitorCombinesSettingsAndStore() async {
        let monitor = CloudAccountMonitor(isSupportedBuild: true,
                                          provider: { CloudAccountState.available },
                                          observesAccountChanges: false,
                                          refreshesImmediately: false)
        await monitor.refresh()
        let settings = makeSettings()
        let store = ClipStore.makeShared(inMemory: true)
        monitor.attach(settings: settings, store: store)

        XCTAssertFalse(settings.cloudSyncEnabled, "custom suites must default to sync OFF")
        XCTAssertEqual(monitor.syncReadiness, .readyButOff)
        settings.cloudSyncEnabled = true
        XCTAssertEqual(monitor.syncReadiness, .needsRelaunch)
        XCTAssertEqual(monitor.readiness(settings: settings, store: store), .needsRelaunch)
    }

    // MARK: - Build gate

    func testTestProcessIsNotCloudKitEntitled() {
        // swift test / xctest is never signed with our iCloud container.
        XCTAssertFalse(CloudBuildSupport.isCloudKitAvailable)
        XCTAssertFalse(CloudBuildSupport.defaultCloudSyncEnabled)
    }

    func testProvisioningProfileParsing() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Entitlements</key><dict>
        <key>com.apple.developer.icloud-container-identifiers</key>
        <array><string>iCloud.com.thingbits.clipsync</string></array>
        </dict></dict></plist>
        """
        var data = Data([0x30, 0x82, 0x01, 0x02, 0x06, 0x09])   // fake CMS header bytes
        data.append(Data(plist.utf8))
        data.append(Data([0xA0, 0x82, 0x00, 0x00]))              // fake CMS trailer bytes
        XCTAssertTrue(CloudBuildSupport.profileGrantsICloud(data, containerID: "iCloud.com.thingbits.clipsync"))
        XCTAssertFalse(CloudBuildSupport.profileGrantsICloud(data, containerID: "iCloud.com.example.other"))
        XCTAssertFalse(CloudBuildSupport.profileGrantsICloud(Data("not a profile".utf8), containerID: "iCloud.com.thingbits.clipsync"))
    }
}
