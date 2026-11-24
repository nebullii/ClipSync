import XCTest
import UIKit

/// End-to-end UI tests for the ClipSync iOS app, run on the iPhone Simulator.
///
/// Every test launches the app with `-uitest-seed`: in-memory store, 12 sample clips
/// (row 0 = "Meeting notes"), pinboards "Work" and "Design", onboarding skipped and
/// the History layout forced to the list. Each test starts from that same state.
///
/// Screenshots: attached to the result bundle at every key step, and also written as PNGs
/// to `$CLIPSYNC_E2E_SHOTS` when the runner has that variable (xcodebuild passes
/// `TEST_RUNNER_CLIPSYNC_E2E_SHOTS` through as `CLIPSYNC_E2E_SHOTS`).
final class ClipSyncIOSUITests: XCTestCase {

    private var shotIndex = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        shotIndex = 0
    }

    // MARK: - Tests

    @MainActor
    func test01_HistoryShowsSeededClips() throws {
        let app = launchSeededApp()

        XCTAssertTrue(waitForElement(app, id: "history.row.0", timeout: 30).exists, "history.row.0 never appeared")
        XCTAssertTrue(waitForElement(app, id: "history.row.1", timeout: 10).exists, "history.row.1 never appeared")
        XCTAssertTrue(waitForElement(app, id: "history.row.2", timeout: 10).exists, "history.row.2 never appeared")
        XCTAssertTrue(rowContaining(app, "Meeting notes").waitForExistence(timeout: 10),
                      "the newest seeded clip (\"Meeting notes…\") is not shown")
        snap("history-top")

        var seen = Set<String>()
        var swipes = 0
        while swipes < 10 {
            for row in rowsQuery(app).allElementsBoundByIndex where row.exists {
                seen.insert(row.identifier)
            }
            if seen.contains("history.row.11") {
                break
            }
            historyScrollContainer(app).swipeUp()
            swipes += 1
        }
        snap("history-scrolled")

        var missing: [String] = []
        for index in 0..<12 where !seen.contains("history.row.\(index)") {
            missing.append("history.row.\(index)")
        }
        XCTAssertTrue(missing.isEmpty, "rows not reachable by scrolling: \(missing.joined(separator: ", ")); seen: \(seen.sorted())")
        XCTAssertFalse(seen.contains("history.row.12"), "more than 12 rows are shown for the 12 seeded clips")
    }

    @MainActor
    func test02_SearchFindsClip() throws {
        let app = launchSeededApp()
        XCTAssertTrue(rowContaining(app, "Meeting notes").waitForExistence(timeout: 30), "History did not load")

        guard let search = findSearchField(app) else {
            snap("search-field-missing")
            XCTFail("no search field \"Search clips\" found")
            return
        }
        search.tap()
        search.typeText("swift")
        snap("search-typed")

        XCTAssertTrue(rowContaining(app, "swift.org").waitForExistence(timeout: 10),
                      "searching \"swift\" does not show the swift.org link")
        XCTAssertTrue(waitForNonExistence(rowContaining(app, "Meeting notes"), timeout: 10),
                      "searching \"swift\" still shows the \"Meeting notes\" clip")
        snap("search-results")

        clearSearch(app, field: search)
        XCTAssertTrue(rowContaining(app, "Meeting notes").waitForExistence(timeout: 10),
                      "clearing the search does not bring back \"Meeting notes\"")
        snap("search-cleared")
    }

    @MainActor
    func test03_FilterChips() throws {
        let app = launchSeededApp()
        XCTAssertTrue(rowContaining(app, "Meeting notes").waitForExistence(timeout: 30), "History did not load")

        tapFilter(app, raw: "links", title: "Links")
        XCTAssertTrue(rowContaining(app, "swift.org").waitForExistence(timeout: 10), "Links filter does not show the swift.org link")
        XCTAssertTrue(waitForNonExistence(rowContaining(app, "Meeting notes"), timeout: 10), "Links filter still shows a text clip")
        let linkLabels = visibleRowLabels(app)
        XCTAssertFalse(linkLabels.isEmpty, "Links filter shows no rows")
        for label in linkLabels {
            XCTAssertTrue(label.contains("Link"), "non-link row under the Links filter: \(label)")
        }
        snap("filter-links")

        tapFilter(app, raw: "images", title: "Images")
        let imageRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "history.row.", "Image"))
            .firstMatch
        XCTAssertTrue(imageRow.waitForExistence(timeout: 10), "Images filter does not show the image clip")
        XCTAssertTrue(waitForNonExistence(rowContaining(app, "swift.org"), timeout: 10), "Images filter still shows the link")
        snap("filter-images")

        tapFilter(app, raw: "all", title: "All")
        XCTAssertTrue(rowContaining(app, "Meeting notes").waitForExistence(timeout: 10), "All filter does not show \"Meeting notes\" again")
        snap("filter-all")
    }

    @MainActor
    func test04_TapCopiesToClipboard() throws {
        let app = launchSeededApp()
        let monitor = addUIInterruptionMonitor(withDescription: "Paste permission") { (alert: XCUIElement) -> Bool in
            let allow = alert.buttons["Allow Paste"]
            if allow.exists {
                allow.tap()
                return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor) }

        let row = waitForElement(app, id: "history.row.0", timeout: 30)
        XCTAssertTrue(row.exists, "history.row.0 never appeared")
        XCTAssertTrue(row.label.contains("Meeting notes"), "row 0 is not the \"Meeting notes\" clip: \(row.label)")

        row.tap()
        let toast = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR label CONTAINS %@", "toast", "Copied"))
            .firstMatch
        let toastShown = toast.waitForExistence(timeout: 5)
        snap("copied-toast")
        XCTAssertTrue(toastShown, "no \"Copied\" toast after tapping row 0")

        // Sub-check: the runner reads the system pasteboard. Recent iOS may ask "Allow Paste"
        // (or return nothing to a background process), so an unavailable string is an
        // expected failure, not a test failure.
        let pasted = readPasteboardString(timeout: 10)
        note("pasteboard-read", pasted.map { "UIPasteboard.general.string = \($0)" } ?? "UIPasteboard.general.string unavailable to the test runner")
        if let pasted = pasted {
            XCTAssertTrue(pasted.contains("Meeting notes"), "pasteboard holds \"\(pasted)\" instead of the Meeting notes clip")
        } else {
            XCTExpectFailure("The UI test runner cannot read the pasteboard on this iOS version (paste permission)") {
                XCTFail("UIPasteboard.general.string was unavailable to the test runner")
            }
        }
    }

    @MainActor
    func test05_SwipeToPinAndDelete() throws {
        let app = launchSeededApp()
        let meeting = rowContaining(app, "Meeting notes")
        XCTAssertTrue(meeting.waitForExistence(timeout: 30), "History did not load")
        XCTAssertFalse(meeting.label.hasPrefix("Pinned"), "\"Meeting notes\" is already pinned in the seed: \(meeting.label)")

        // Pin: leading swipe.
        meeting.swipeRight()
        snap("swipe-right")
        let pinButton = app.buttons["Pin"]
        if pinButton.waitForExistence(timeout: 2) && pinButton.isHittable {
            pinButton.tap()
        }
        let pinnedRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND label BEGINSWITH %@",
                                  "history.row.", "Meeting notes", "Pinned"))
            .firstMatch
        XCTAssertTrue(pinnedRow.waitForExistence(timeout: 10), "\"Meeting notes\" row does not show as pinned after the swipe")
        snap("pinned")

        // It is listed under Pinboards > Pinned.
        openTab(app, title: "Pinboards", id: "tab.pinboards")
        let pinnedLink = firstExisting([element(app, id: "pinboards.pinned"), app.buttons["Pinned"]], timeout: 10)
        XCTAssertNotNil(pinnedLink, "Pinboards tab has no \"Pinned\" entry")
        pinnedLink?.tap()
        XCTAssertTrue(rowContaining(app, "Meeting notes").waitForExistence(timeout: 10), "\"Meeting notes\" is not in Pinned")
        snap("pinned-list")
        openTab(app, title: "History", id: "tab.history")
        XCTAssertTrue(rowContaining(app, "Meeting notes").waitForExistence(timeout: 10), "could not return to History")

        // Delete: trailing swipe, under the Links filter so every row is on screen.
        tapFilter(app, raw: "links", title: "Links")
        let linkRow = rowContaining(app, "swift.org")
        XCTAssertTrue(linkRow.waitForExistence(timeout: 10), "Links filter does not show the swift.org link")
        let before = visibleRowLabels(app).count
        linkRow.swipeLeft()
        snap("swipe-left")
        let deleteButton = app.buttons["Delete"]
        if deleteButton.waitForExistence(timeout: 2) && deleteButton.isHittable {
            deleteButton.tap()
        }
        XCTAssertTrue(waitForNonExistence(rowContaining(app, "swift.org"), timeout: 10), "swift.org row still present after delete")
        let after = visibleRowLabels(app).count
        XCTAssertLessThan(after, before, "row count did not drop after delete (before \(before), after \(after))")
        snap("deleted")
        tapFilter(app, raw: "all", title: "All")
    }

    @MainActor
    func test06_Pinboards() throws {
        let app = launchSeededApp()
        XCTAssertTrue(rowContaining(app, "Meeting notes").waitForExistence(timeout: 30), "History did not load")

        openTab(app, title: "Pinboards", id: "tab.pinboards")
        let work = labelPrefix(app, "Work")
        let design = labelPrefix(app, "Design")
        XCTAssertTrue(work.waitForExistence(timeout: 10), "pinboard \"Work\" not listed")
        XCTAssertTrue(design.waitForExistence(timeout: 10), "pinboard \"Design\" not listed")
        snap("pinboards")

        work.tap()
        let opened = firstExisting([app.navigationBars["Work"], rowContaining(app, "Meeting notes")], timeout: 10)
        XCTAssertNotNil(opened, "opening \"Work\" did not show the pinboard")
        XCTAssertTrue(rowContaining(app, "Meeting notes").waitForExistence(timeout: 10), "\"Work\" does not contain the Meeting notes clip")
        snap("pinboard-work")
        goBack(app)
        XCTAssertTrue(labelPrefix(app, "Design").waitForExistence(timeout: 10), "did not return to the pinboard list")

        // New pinboard through the editor sheet.
        guard let newButton = firstExisting([element(app, id: "pinboards.new"), app.buttons["New pinboard"], app.buttons["New Pinboard"]], timeout: 10) else {
            snap("new-pinboard-missing")
            XCTFail("no New Pinboard button")
            return
        }
        newButton.tap()
        guard let nameField = firstExisting([app.textFields["pinboardEditor.name"], app.textFields["Pinboard name"], app.textFields.firstMatch], timeout: 10) else {
            snap("editor-missing")
            XCTFail("pinboard editor did not open")
            return
        }
        nameField.tap()
        nameField.typeText("Demo")
        snap("editor-filled")
        guard let create = firstExisting([app.buttons["pinboardEditor.save"], app.buttons["Create"]], timeout: 5) else {
            XCTFail("no Create button in the pinboard editor")
            return
        }
        create.tap()
        XCTAssertTrue(labelPrefix(app, "Demo").waitForExistence(timeout: 10), "new pinboard \"Demo\" is not listed")
        snap("pinboard-demo")
    }

    @MainActor
    func test07_DetailView() throws {
        let app = launchSeededApp()
        let linkRow = rowContaining(app, "swift.org")
        XCTAssertTrue(linkRow.waitForExistence(timeout: 30), "swift.org link row not shown")

        XCTAssertTrue(openDetail(app, row: linkRow), "could not open the detail view of the swift.org link")
        snap("detail-open")

        XCTAssertNotNil(firstExisting([element(app, id: "detail.openLink"), app.buttons["Open Link"]], timeout: 5),
                        "detail view has no Open Link button")
        let sourceApp = labelContains(app, "Source app")
        var swipes = 0
        while !sourceApp.exists && swipes < 5 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(sourceApp.waitForExistence(timeout: 5), "detail metadata (\"Source app\") not visible")
        XCTAssertTrue(labelContains(app, "Safari").exists, "detail metadata does not name the source app Safari")
        snap("detail-metadata")

        guard let done = firstExisting([element(app, id: "detail.done"), app.buttons["Done"]], timeout: 5) else {
            XCTFail("detail view has no Done button")
            return
        }
        done.tap()
        XCTAssertTrue(waitForNonExistence(element(app, id: "detail.done"), timeout: 10), "detail view did not close")
        XCTAssertTrue(rowContaining(app, "swift.org").waitForExistence(timeout: 10), "History not visible after closing detail")
        snap("detail-closed")
    }

    @MainActor
    func test08_SaveClipboardBar() throws {
        let app = launchSeededApp()
        XCTAssertTrue(rowContaining(app, "Meeting notes").waitForExistence(timeout: 30), "History did not load")

        let bar = firstExisting([element(app, id: "history.saveBar"), labelContains(app, "Save clipboard")], timeout: 10)
        XCTAssertNotNil(bar, "Save clipboard bar not found")
        guard let paste = firstExisting([element(app, id: "history.pasteButton"),
                                         element(app, id: "history.pasteControl"),
                                         app.buttons["Paste"]], timeout: 10) else {
            snap("paste-missing")
            XCTFail("Paste control not found")
            return
        }
        XCTAssertTrue(paste.isHittable, "Paste control is not hittable")
        snap("save-bar")

        // Informational only: UIPasteControl is a secure control that synthesized taps may not drive.
        UIPasteboard.general.string = "ClipSync UI test paste"
        let firstBefore = waitForElement(app, id: "history.row.0", timeout: 5)
        let labelBefore = firstBefore.exists ? firstBefore.label : ""
        paste.tap()
        Thread.sleep(forTimeInterval: 1.0)
        let firstAfter = waitForElement(app, id: "history.row.0", timeout: 5)
        let labelAfter = firstAfter.exists ? firstAfter.label : ""
        let newRow = labelContains(app, "ClipSync UI test paste").exists || (labelAfter != labelBefore && !labelAfter.isEmpty)
        snap("after-paste-tap")
        note("paste-control-result",
             "new row after tapping Paste: \(newRow ? "yes" : "no")\nrow 0 before: \(labelBefore)\nrow 0 after: \(labelAfter)")
    }

    @MainActor
    func test09_SettingsAndOnboarding() throws {
        let app = launchSeededApp()
        XCTAssertTrue(rowContaining(app, "Meeting notes").waitForExistence(timeout: 30), "History did not load")

        openTab(app, title: "Settings", id: "tab.settings")
        let retention = firstExisting([element(app, id: "settings.retention"), labelContains(app, "Keep history")], timeout: 10)
        XCTAssertNotNil(retention, "Settings has no retention (\"Keep history\") control")
        snap("settings")

        let how = firstExisting([element(app, id: "settings.howCaptureWorks"), app.buttons["How capture works"]], timeout: 3)
            ?? scrollToFind(app, candidates: [element(app, id: "settings.howCaptureWorks"), app.buttons["How capture works"]])
        guard let howButton = how else {
            snap("how-missing")
            XCTFail("Settings has no \"How capture works\" button")
            return
        }
        howButton.tap()

        XCTAssertTrue(labelExact(app, "Everything you copy, in one place").waitForExistence(timeout: 10), "onboarding page 1 not shown")
        snap("onboarding-1")
        tapOnboardingPrimary(app, title: "Continue")
        XCTAssertTrue(labelExact(app, "Four ways in").waitForExistence(timeout: 10), "onboarding page 2 not shown")
        snap("onboarding-2")
        tapOnboardingPrimary(app, title: "Continue")
        XCTAssertTrue(labelExact(app, "Private by design").waitForExistence(timeout: 10), "onboarding page 3 not shown")
        XCTAssertTrue(app.buttons["Get Started"].waitForExistence(timeout: 10), "last onboarding page has no Get Started button")
        snap("onboarding-3")
        tapOnboardingPrimary(app, title: "Get Started")
        XCTAssertTrue(waitForNonExistence(app.buttons["Get Started"], timeout: 10), "onboarding did not close")
        XCTAssertNotNil(firstExisting([element(app, id: "settings.retention"), labelContains(app, "Keep history"), app.navigationBars["Settings"]], timeout: 10),
                        "Settings not visible after closing onboarding")
        snap("onboarding-closed")
    }

    @MainActor
    func test10_GridLayoutToggle() throws {
        let app = launchSeededApp()
        XCTAssertTrue(waitForElement(app, id: "history.row.0", timeout: 30).exists, "History did not load as a list")

        guard let toggle = firstExisting([element(app, id: "history.layoutToggle"), app.buttons["Show as grid"]], timeout: 10) else {
            XCTFail("no layout toggle")
            return
        }
        toggle.tap()
        XCTAssertTrue(waitForElement(app, id: "history.card.0", timeout: 10).exists, "grid cards (history.card.0) not shown")
        XCTAssertTrue(waitForElement(app, id: "history.card.1", timeout: 5).exists, "grid shows only one card")
        snap("grid")

        guard let back = firstExisting([element(app, id: "history.layoutToggle"), app.buttons["Show as list"]], timeout: 10) else {
            XCTFail("no layout toggle in grid mode")
            return
        }
        back.tap()
        XCTAssertTrue(waitForElement(app, id: "history.row.0", timeout: 10).exists, "list rows not back after toggling")
        XCTAssertTrue(waitForNonExistence(element(app, id: "history.card.0"), timeout: 5), "grid cards still shown in list mode")
        snap("list-again")
    }

    @MainActor
    func test11_LaunchPerformance() throws {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        let app = XCUIApplication()
        app.launchArguments = ClipSyncIOSUITests.launchArguments
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            app.launch()
        }
        snap("after-launch-measure")
    }

    /// Security pass: Settings shows the Security section with the App Lock switch (OFF in
    /// -uitest-seed mode) and the link-preview switch (OFF by default). The lock itself is
    /// never turned on here: the system Face ID / passcode UI cannot be driven reliably.
    @MainActor
    func test12_SecuritySettings() throws {
        let app = launchSeededApp()
        XCTAssertTrue(rowContaining(app, "Meeting notes").waitForExistence(timeout: 30), "History did not load")
        XCTAssertFalse(element(app, id: "lock.unlockButton").exists, "a lock screen is shown in -uitest-seed mode")

        openTab(app, title: "Settings", id: "tab.settings")
        XCTAssertNotNil(firstExisting([element(app, id: "settings.retention"), labelContains(app, "Keep history")], timeout: 10),
                        "Settings did not open")

        let lockCandidates = [app.switches["settings.appLock"], element(app, id: "settings.appLock")]
        guard let lockToggle = firstExisting(lockCandidates, timeout: 3) ?? scrollToFind(app, candidates: lockCandidates) else {
            snap("security-applock-missing")
            XCTFail("Settings has no App Lock switch (settings.appLock)")
            return
        }
        XCTAssertNotNil(firstExisting([labelContains(app, "Security"), element(app, id: "settings.securityNote")], timeout: 5),
                        "Settings has no Security section")
        snap("security-settings")
        let lockValue = switchValue(app, id: "settings.appLock", fallback: lockToggle)
        XCTAssertTrue(lockValue == "0" || lockValue == "false", "App Lock must be off in -uitest-seed mode (value: \(lockValue))")

        let linkCandidates = [app.switches["settings.linkPreviews"], element(app, id: "settings.linkPreviews")]
        guard let linkToggle = firstExisting(linkCandidates, timeout: 3) ?? scrollToFind(app, candidates: linkCandidates) else {
            snap("security-linkpreviews-missing")
            XCTFail("Settings has no link-preview switch (settings.linkPreviews)")
            return
        }
        let linkValue = switchValue(app, id: "settings.linkPreviews", fallback: linkToggle)
        XCTAssertTrue(linkValue == "0" || linkValue == "false", "link previews must be off by default (value: \(linkValue))")
        snap("security-linkpreviews")
    }

    /// The switch's value ("0"/"1"), preferring the real switch element over a matching cell.
    @MainActor
    private func switchValue(_ app: XCUIApplication, id: String, fallback: XCUIElement) -> String {
        let control = app.switches[id]
        let target = control.exists ? control : fallback
        if let text = target.value as? String {
            return text
        }
        if let number = target.value as? NSNumber {
            return number.stringValue
        }
        return "<nil>"
    }

    // MARK: - Launch

    static let launchArguments: [String] = ["-uitest-seed", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

    @MainActor
    private func launchSeededApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ClipSyncIOSUITests.launchArguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "ClipSync did not reach the foreground")
        return app
    }

    // MARK: - Queries

    @MainActor
    private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
        return app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func waitForElement(_ app: XCUIApplication, id: String, timeout: TimeInterval) -> XCUIElement {
        let found = element(app, id: id)
        _ = found.waitForExistence(timeout: timeout)
        return found
    }

    @MainActor
    private func rowsQuery(_ app: XCUIApplication) -> XCUIElementQuery {
        return app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.row."))
    }

    /// A History row whose VoiceOver label contains `text`; falls back to any element with that label.
    @MainActor
    private func rowContaining(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@", "history.row.", text))
            .firstMatch
        if row.exists {
            return row
        }
        let any = labelContains(app, text)
        if any.exists {
            return any
        }
        return row
    }

    @MainActor
    private func labelContains(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        return app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    @MainActor
    private func labelPrefix(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        return app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    @MainActor
    private func labelExact(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        return app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    /// Labels of the History rows currently in the accessibility tree, one per identifier.
    @MainActor
    private func visibleRowLabels(_ app: XCUIApplication) -> [String] {
        var byID: [String: String] = [:]
        for row in rowsQuery(app).allElementsBoundByIndex where row.exists {
            if byID[row.identifier] == nil {
                byID[row.identifier] = row.label
            }
        }
        return byID.keys.sorted().map { byID[$0] ?? "" }
    }

    @MainActor
    private func firstExisting(_ candidates: [XCUIElement], timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for candidate in candidates where candidate.exists {
                return candidate
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    @MainActor
    private func waitForNonExistence(_ target: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while target.exists {
            if Date() >= deadline {
                return false
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return true
    }

    @MainActor
    private func historyScrollContainer(_ app: XCUIApplication) -> XCUIElement {
        let list = element(app, id: "history.list")
        if list.exists {
            return list
        }
        let table = app.collectionViews.firstMatch
        if table.exists {
            return table
        }
        return app
    }

    @MainActor
    private func scrollToFind(_ app: XCUIApplication, candidates: [XCUIElement]) -> XCUIElement? {
        var swipes = 0
        while swipes < 6 {
            for candidate in candidates where candidate.exists && candidate.isHittable {
                return candidate
            }
            app.swipeUp()
            swipes += 1
        }
        return firstExisting(candidates, timeout: 2)
    }

    // MARK: - Actions

    @MainActor
    private func openTab(_ app: XCUIApplication, title: String, id: String) {
        let candidates = [app.tabBars.buttons[title], element(app, id: id), app.buttons[title]]
        guard let tab = firstExisting(candidates, timeout: 10) else {
            snap("tab-\(title)-missing")
            XCTFail("tab \"\(title)\" not found")
            return
        }
        tab.tap()
    }

    @MainActor
    private func tapFilter(_ app: XCUIApplication, raw: String, title: String) {
        let candidates = [app.buttons["filter.\(raw)"], element(app, id: "filter.\(raw)"), app.buttons[title]]
        guard let chip = firstExisting(candidates, timeout: 10) else {
            snap("filter-\(raw)-missing")
            XCTFail("filter chip \"\(title)\" not found")
            return
        }
        chip.tap()
    }

    @MainActor
    private func goBack(_ app: XCUIApplication) {
        let named = app.navigationBars.buttons["Pinboards"]
        if named.exists {
            named.tap()
            return
        }
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        if back.exists {
            back.tap()
        }
    }

    @MainActor
    private func findSearchField(_ app: XCUIApplication) -> XCUIElement? {
        let candidates = [app.searchFields["Search clips"], app.searchFields.firstMatch]
        if let field = firstExisting(candidates, timeout: 10) {
            return field
        }
        // The field can be collapsed into the navigation bar until the list is pulled down.
        historyScrollContainer(app).swipeDown()
        if let field = firstExisting(candidates, timeout: 5) {
            return field
        }
        let searchButton = app.buttons["Search"]
        if searchButton.exists {
            searchButton.tap()
        }
        return firstExisting(candidates, timeout: 5)
    }

    @MainActor
    private func clearSearch(_ app: XCUIApplication, field: XCUIElement) {
        let clear = field.buttons["Clear text"]
        if clear.exists && clear.isHittable {
            clear.tap()
        } else if field.exists {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        }
        let cancel = app.buttons["Cancel"]
        if cancel.exists && cancel.isHittable {
            cancel.tap()
        }
    }

    /// Context menu > Show Details; falls back to tapping the row's trailing info button.
    @MainActor
    private func openDetail(_ app: XCUIApplication, row: XCUIElement) -> Bool {
        let done = element(app, id: "detail.done")
        row.press(forDuration: 1.2)
        let showDetails = app.buttons["Show Details"]
        if showDetails.waitForExistence(timeout: 5) {
            showDetails.tap()
            if done.waitForExistence(timeout: 10) || app.buttons["Done"].waitForExistence(timeout: 2) {
                return true
            }
        } else {
            // Close a menu that opened without the item.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        }
        let target = rowContaining(app, "swift.org")
        if target.waitForExistence(timeout: 5) {
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        return done.waitForExistence(timeout: 10) || app.buttons["Done"].waitForExistence(timeout: 2)
    }

    @MainActor
    private func tapOnboardingPrimary(_ app: XCUIApplication, title: String) {
        let candidates = [app.buttons[title], element(app, id: "onboarding.primary")]
        guard let button = firstExisting(candidates, timeout: 10) else {
            snap("onboarding-\(title)-missing")
            XCTFail("onboarding button \"\(title)\" not found")
            return
        }
        button.tap()
    }

    // MARK: - Pasteboard

    /// Reads `UIPasteboard.general.string` off the main thread (a paste-permission prompt
    /// would block the caller) while the main thread taps "Allow Paste" if it appears.
    @MainActor
    private func readPasteboardString(timeout: TimeInterval) -> String? {
        if !UIPasteboard.general.hasStrings {
            return nil
        }
        let probe = PasteboardProbe()
        DispatchQueue.global(qos: .userInitiated).async {
            probe.finish(ClipSyncIOSUITests.currentPasteboardString())
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while !probe.isDone && Date() < deadline {
            let allow = springboard.buttons["Allow Paste"]
            if allow.exists {
                allow.tap()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return probe.value
    }

    private static func currentPasteboardString() -> String? {
        return UIPasteboard.general.string
    }

    // MARK: - Evidence

    /// Screenshot attached to the result bundle and, if `CLIPSYNC_E2E_SHOTS` is set, saved as PNG.
    @MainActor
    private func snap(_ step: String) {
        shotIndex += 1
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(testShortName)-\(step)"
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let dir = ProcessInfo.processInfo.environment["CLIPSYNC_E2E_SHOTS"], !dir.isEmpty else {
            return
        }
        let fileName = String(format: "%@_%02d_%@.png", testShortName, shotIndex, ClipSyncIOSUITests.safeFileName(step))
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
            try screenshot.pngRepresentation.write(to: folder.appendingPathComponent(fileName))
        } catch {
            // Best effort only: the attachment above is the primary record.
        }
    }

    /// Text attachment for informational results.
    private func note(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "\(testShortName)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[ClipSyncIOSUITests] \(testShortName) \(name): \(text)")
    }

    /// "test04_TapCopiesToClipboard" from "-[ClipSyncIOSUITests test04_TapCopiesToClipboard]".
    private var testShortName: String {
        var text = name
        if let space = text.lastIndex(of: " ") {
            text = String(text[text.index(after: space)...])
        }
        text = text.replacingOccurrences(of: "]", with: "")
        text = text.replacingOccurrences(of: "()", with: "")
        if let dot = text.lastIndex(of: ".") {
            text = String(text[text.index(after: dot)...])
        }
        return text
    }

    private static func safeFileName(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var result = String.UnicodeScalarView()
        let dash: Unicode.Scalar = "-"
        for scalar in text.unicodeScalars {
            result.append(allowed.contains(scalar) ? scalar : dash)
        }
        return String(result)
    }
}

/// Thread-safe holder for the background pasteboard read.
private final class PasteboardProbe {
    private let lock = NSLock()
    private var done = false
    private var result: String? = nil

    func finish(_ value: String?) {
        lock.lock()
        result = value
        done = true
        lock.unlock()
    }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
