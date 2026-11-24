// End-to-end test driver — owned by the Mac test-automation engineer.
//
// COMPILED ONLY INTO DEBUG BUILDS (the whole file is inside `#if DEBUG`): Release and
// Signed builds contain no file-command channel and no status writer.
//
// ACTIVE ONLY when the app is launched with BOTH
//     CLIPSYNC_UITEST=1  and  CLIPSYNC_E2E_DIR=<absolute path>
// (see LaunchOptions.e2eDirectory). A normal launch never creates this object, so
// none of the code below runs and nothing is written anywhere.
//
// What it does (driven by scripts/e2e-mac.sh):
//   <dir>/status.json   pretty JSON snapshot of app + panel state (for humans / reports)
//   <dir>/status.kv     the same as flat `key=value` lines (for the bash 3.2 test script;
//                       newlines in values are written as \n, backslashes as \\)
//       rewritten after every store change / panel state change (debounced 100 ms),
//       after every processed command, and whenever a 200 ms tick sees a changed
//       fingerprint (panel shown/hidden, selection, search text, windows, ...).
//   <dir>/commands/NNN-<name>.cmd   one command line; polled every 200 ms, processed in
//       name order, then replaced by NNN-<name>.ok or .err holding a one-line result.
//   <dir>/shots/<name>-<window>.png  in-process renders of ClipSync's own windows.
//
// Commands go through the same PanelViewModel / PanelController / AppController
// methods that the panel's key monitor, mouse actions and menu bar use (and through
// env.paster), so the product code paths are what is tested. The only shortcut is
// `seed <n> [tag]`, which ingests drafts straight into ClipStore for the scale test.
//
// App Lock (security pass): `lock` turns the lock on WITHOUT authentication (test only) and
// locks; `unlock-for-test` unlocks without the system prompt and turns the lock off again.
// While locked, every content command is refused with "locked", and the status files
// redact item / capture / paste text (only counts and kinds are written).

#if DEBUG

import AppKit
import ApplicationServices
import Combine
import QuartzCore
import ClipCore

@MainActor
final class E2EDriver: NSObject {
    struct ActionRecord {
        var textPrefix: String
        var asPlainText: Bool
        var mode: String
        var timestamp: Date
    }

    private struct Outcome {
        let ok: Bool
        let message: String
    }

    static let pollInterval: TimeInterval = 0.2
    /// Text written instead of clipboard content while ClipSync is locked.
    static let redacted = "<redacted>"
    /// Panel commands that reach item content; refused while locked.
    static let contentCommands: Set<String> = [
        "search", "select", "select-text", "select-kind", "move-right", "move-left",
        "paste", "paste-plain", "copy", "pin", "unpin", "delete", "filter",
        "create-pinboard", "add-to-pinboard", "open-pinboard", "item-files", "open-history"
    ]

    let directory: URL
    private let commandsDirectory: URL
    private let shotsDirectory: URL
    private unowned let controller: AppController

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var statusWriteScheduled = false
    private var lastFingerprint = ""
    private var statusSequence = 0
    private var commandsProcessed = 0
    private var lastCommand = ""
    private var processedNames = Set<String>()
    private var isProcessingCommands = false

    private(set) var lastPaste: ActionRecord?
    private(set) var lastCopy: ActionRecord?

    private var pendingSearchQuery: String?
    private var pendingSearchStart: CFTimeInterval = 0
    private var lastSearchQuery = ""
    private var lastSearchRoundTripMs: Double = -1
    private var lastSeedMs: Double = -1
    private var lastSeedInserted = 0
    private var axPromptRequested = false
    /// Tracks visible→hidden transitions so a report can say what hid the panel.
    private var panelWasVisible = false
    private var panelHiddenAfterCommand = ""
    private var panelHiddenAt = ""

    // MARK: - Start

    /// Creates and starts the driver when the E2E hooks are enabled; nil otherwise.
    static func startIfEnabled(controller: AppController) -> E2EDriver? {
        guard controller.options.isUITest, let path = controller.options.e2eDirectory else { return nil }
        let driver = E2EDriver(directory: URL(fileURLWithPath: path, isDirectory: true), controller: controller)
        driver.start()
        return driver
    }

    private init(directory: URL, controller: AppController) {
        self.directory = directory
        self.commandsDirectory = directory.appendingPathComponent("commands", isDirectory: true)
        self.shotsDirectory = directory.appendingPathComponent("shots", isDirectory: true)
        self.controller = controller
        super.init()
    }

    private func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: commandsDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: shotsDirectory, withIntermediateDirectories: true)

        // Record paste / copy actions without changing what they do.
        let env = controller.environment
        if !(env.paster is E2ERecordingPaster) {
            env.paster = E2ERecordingPaster(inner: env.paster, driver: self)
        }

        controller.store.$revision
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleStatusWrite()
            }
            .store(in: &cancellables)

        if let model = viewModel {
            model.objectWillChange
                .sink { [weak self] _ in
                    self?.scheduleStatusWrite()
                }
                .store(in: &cancellables)
            model.$rows
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.rowsDidChange()
                }
                .store(in: &cancellables)
        }

        let newTimer = Timer(
            timeInterval: E2EDriver.pollInterval,
            target: self,
            selector: #selector(timerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        newTimer.tolerance = 0.05
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer

        writeStatus()
        NSLog("ClipSync E2E driver active: %@", directory.path)
    }

    // MARK: - Accessors

    private var environment: AppEnvironment { return controller.environment }

    private var panelController: PanelController? {
        return controller.environment.panel as? PanelController
    }

    private var viewModel: PanelViewModel? {
        return panelController?.e2eViewModel
    }

    // MARK: - Recording (called by E2ERecordingPaster)

    func recordPaste(_ record: ActionRecord) {
        lastPaste = record
        writeStatus()
    }

    func recordCopy(_ record: ActionRecord) {
        lastCopy = record
        writeStatus()
    }

    // MARK: - Tick

    @objc private func timerFired(_ timer: Timer) {
        processCommands()
        if fingerprint() != lastFingerprint {
            writeStatus()
        }
    }

    private func scheduleStatusWrite() {
        guard !statusWriteScheduled else { return }
        statusWriteScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self = self else { return }
            self.statusWriteScheduled = false
            self.writeStatus()
        }
    }

    private func rowsDidChange() {
        guard let query = pendingSearchQuery, let model = viewModel else { return }
        guard model.searchText == query else { return }
        lastSearchRoundTripMs = (CACurrentMediaTime() - pendingSearchStart) * 1000
        lastSearchQuery = query
        pendingSearchQuery = nil
        writeStatus()
    }

    private func fingerprint() -> String {
        var parts: [String] = []
        parts.append(String(environment.panel.isVisible))
        parts.append(String(controller.store.revision))
        parts.append(String(controller.settings.capturePaused))
        parts.append(String(controller.appLock.isLocked))
        if let model = viewModel {
            parts.append(String(model.selectedIndex))
            parts.append(model.searchText)
            parts.append(String(model.rows.count))
            parts.append(model.kindFilter.rawValue)
            parts.append(scopeDescription(model))
        }
        parts.append(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        parts.append(openWindowLabels().joined(separator: ","))
        return parts.joined(separator: "|")
    }

    // MARK: - Commands

    private func processCommands() {
        guard !isProcessingCommands else { return }
        isProcessingCommands = true
        defer { isProcessingCommands = false }

        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: commandsDirectory.path) else { return }
        let pending = names.filter { $0.hasSuffix(".cmd") && !processedNames.contains($0) }.sorted()
        for name in pending {
            processedNames.insert(name)
            let fileURL = commandsDirectory.appendingPathComponent(name, isDirectory: false)
            let raw = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let line = (raw.components(separatedBy: .newlines).first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let started = CACurrentMediaTime()
            let outcome = run(line)
            let elapsed = (CACurrentMediaTime() - started) * 1000
            commandsProcessed += 1
            lastCommand = line
            writeStatus()

            let base = String(name.dropLast(4))
            let resultName = base + (outcome.ok ? ".ok" : ".err")
            let flat = outcome.message.replacingOccurrences(of: "\n", with: " ")
            let text = "\(flat) cmdMs=\(E2EDriver.format(elapsed)) seq=\(statusSequence)\n"
            let resultURL = commandsDirectory.appendingPathComponent(resultName, isDirectory: false)
            try? text.write(to: resultURL, atomically: true, encoding: .utf8)
            try? fm.removeItem(at: fileURL)
        }
    }

    private func run(_ line: String) -> Outcome {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let name = parts.first.map { String($0) } ?? ""
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

        // Commands that do not need the panel.
        switch name {
        case "":
            return Outcome(ok: false, message: "empty command")
        case "ping":
            return Outcome(ok: true, message: "pong")
        case "status":
            return Outcome(ok: true, message: "status written")
        case "show":
            environment.panel.show()
            let duration = panelController?.lastShowDurationMs ?? -1
            return Outcome(ok: environment.panel.isVisible,
                           message: "panelVisible=\(environment.panel.isVisible) showMs=\(E2EDriver.format(duration))")
        case "hide":
            environment.panel.hide()
            return Outcome(ok: !environment.panel.isVisible, message: "panelVisible=\(environment.panel.isVisible)")
        case "open-settings":
            controller.openSettings()
            return Outcome(ok: true, message: "windows=\(openWindowLabels().joined(separator: ","))")
        case "open-onboarding":
            controller.windows.showOnboarding(step: .welcome)
            return Outcome(ok: true, message: "windows=\(openWindowLabels().joined(separator: ","))")
        case "close-windows":
            var closed: [String] = []
            for window in NSApp.windows where window.isVisible && !(window is CardStripPanel) {
                if let label = E2EDriver.windowLabel(window) {
                    window.close()
                    closed.append(label)
                }
            }
            return Outcome(ok: true, message: "closed=\(closed.joined(separator: ","))")
        case "pause-capture":
            if !controller.settings.capturePaused {
                controller.toggleCapturePaused()   // same action as the menu bar item
            }
            return Outcome(ok: controller.settings.capturePaused, message: "capturePaused=\(controller.settings.capturePaused)")
        case "resume-capture":
            if controller.settings.capturePaused {
                controller.toggleCapturePaused()
            }
            return Outcome(ok: !controller.settings.capturePaused, message: "capturePaused=\(controller.settings.capturePaused)")
        case "request-ax-prompt":
            // Asks macOS (AXIsProcessTrustedWithOptions + prompt) to list ClipSync under
            // Privacy & Security > Accessibility, so the user has an entry to switch on.
            // Once per launch; the script sends it at the END of a run, because the
            // system dialog takes focus and would disturb the paste scenarios.
            if AXIsProcessTrusted() {
                return Outcome(ok: true, message: "already trusted")
            }
            if axPromptRequested {
                return Outcome(ok: true, message: "prompt already requested this launch")
            }
            axPromptRequested = true
            controller.accessibility.requestPrompt()
            return Outcome(ok: true, message: "prompt requested")
        case "pb-items":
            // ClipSync's own view of the general pasteboard (diagnostics for file capture).
            let pbItems = NSPasteboard.general.pasteboardItems ?? []
            var parts: [String] = ["items=\(pbItems.count)"]
            for (index, pbItem) in pbItems.enumerated() {
                let types = pbItem.types.map { $0.rawValue }.joined(separator: ",")
                let file = pbItem.string(forType: .fileURL) ?? "-"
                parts.append("item\(index)[\(types)] file=\(file)")
            }
            return Outcome(ok: true, message: parts.joined(separator: " "))
        case "seed-files":
            return seedFiles(argument)
        case "snapshot":
            return snapshot(argument)
        case "seed":
            return seed(argument)
        case "lock":
            // Test only: turn App Lock on without the system prompt, then lock (same
            // lockNow() as the menu bar's "Lock ClipSync Now").
            controller.appLock.enableForTesting()
            controller.lockNow()
            return Outcome(ok: controller.appLock.isLocked, message: "locked=\(controller.appLock.isLocked)")
        case "unlock-for-test":
            // Test only (DEBUG + CLIPSYNC_UITEST): unlock WITHOUT authentication and turn
            // the lock off again, so the rest of the suite runs unlocked.
            controller.appLock.unlockAndDisableForTesting()
            return Outcome(ok: !controller.appLock.isLocked, message: "locked=\(controller.appLock.isLocked) appLockEnabled=\(controller.settings.appLockEnabled)")
        default:
            break
        }

        if controller.appLock.isLocked && E2EDriver.contentCommands.contains(name) {
            return Outcome(ok: false, message: "refused: ClipSync is locked (\(name))")
        }

        guard let model = viewModel else {
            return Outcome(ok: false, message: "panel view model unavailable (env.panel is not a PanelController)")
        }

        switch name {
        case "search":
            pendingSearchQuery = argument
            pendingSearchStart = CACurrentMediaTime()
            model.searchText = argument          // what typing into the bound search field does
            return Outcome(ok: true, message: "searchText=\(argument)")
        case "clear-search":
            pendingSearchQuery = nil
            model.clearSearch()                  // Esc with a query
            return Outcome(ok: true, message: "visible=\(model.rows.count)")
        case "select":
            guard let index = Int(argument) else {
                return Outcome(ok: false, message: "select needs an integer index, got '\(argument)'")
            }
            guard model.rows.indices.contains(index) else {
                return Outcome(ok: false, message: "index \(index) out of range (visible=\(model.rows.count))")
            }
            model.select(index: index)           // what a click on a card does
            return Outcome(ok: model.selectedIndex == index, message: "selectedIndex=\(model.selectedIndex)")
        case "select-text":
            guard let index = model.rows.firstIndex(where: { E2EDriver.text(of: $0.item).contains(argument) }) else {
                return Outcome(ok: false, message: "no visible card contains '\(argument)' (visible=\(model.rows.count))")
            }
            model.select(index: index)
            return Outcome(ok: true, message: "selectedIndex=\(model.selectedIndex)")
        case "select-kind":
            guard let index = model.rows.firstIndex(where: { $0.item.kindRaw == argument }) else {
                return Outcome(ok: false, message: "no visible card of kind '\(argument)' (visible=\(model.rows.count))")
            }
            model.select(index: index)
            return Outcome(ok: true, message: "selectedIndex=\(model.selectedIndex)")
        case "move-right":
            model.moveSelection(by: 1)           // → key
            return Outcome(ok: true, message: "selectedIndex=\(model.selectedIndex)")
        case "move-left":
            model.moveSelection(by: -1)          // ← key
            return Outcome(ok: true, message: "selectedIndex=\(model.selectedIndex)")
        case "paste", "paste-plain":
            guard model.selectedItem != nil else {
                return Outcome(ok: false, message: "nothing selected (visible=\(model.rows.count))")
            }
            model.pasteSelected(shiftHeld: name == "paste-plain")   // ↩ / ⇧↩
            let mode = lastPaste?.mode ?? "none"
            return Outcome(ok: true, message: "mode=\(mode) panelVisible=\(environment.panel.isVisible)")
        case "copy":
            guard model.selectedItem != nil else {
                return Outcome(ok: false, message: "nothing selected (visible=\(model.rows.count))")
            }
            model.copySelected()                 // ⌘C
            return Outcome(ok: true, message: "panelVisible=\(environment.panel.isVisible)")
        case "pin", "unpin":
            guard let item = model.selectedItem else {
                return Outcome(ok: false, message: "nothing selected (visible=\(model.rows.count))")
            }
            let wanted = (name == "pin")
            if item.isPinned != wanted {
                model.togglePinSelected()        // ⌘P
            }
            return Outcome(ok: item.isPinned == wanted, message: "isPinned=\(item.isPinned)")
        case "delete":
            guard model.selectedItem != nil else {
                return Outcome(ok: false, message: "nothing selected (visible=\(model.rows.count))")
            }
            let before = controller.store.itemCount()
            model.deleteSelected()               // ⌫
            let after = controller.store.itemCount()
            return Outcome(ok: true, message: "itemCount \(before)->\(after)")
        case "filter":
            guard let filter = PanelKindFilter(rawValue: argument) else {
                return Outcome(ok: false, message: "unknown filter '\(argument)' (all|text|links|images|files|colors)")
            }
            model.setKindFilter(filter)          // kind chip
            return Outcome(ok: true, message: "visible=\(model.rows.count)")
        case "create-pinboard":
            guard !argument.isEmpty else {
                return Outcome(ok: false, message: "create-pinboard needs a name")
            }
            // The "+" tab: inline editor, typed name, Return.
            model.beginCreatePinboard(adding: nil)
            model.editorText = argument
            model.commitEditor()
            let names = model.pinboardRows.map { $0.name }
            return Outcome(ok: names.contains(argument), message: "pinboards=\(names.joined(separator: ","))")
        case "add-to-pinboard":
            guard let board = model.pinboardRows.first(where: { $0.name == argument }) else {
                return Outcome(ok: false, message: "no pinboard named '\(argument)'")
            }
            guard let item = model.selectedItem else {
                return Outcome(ok: false, message: "nothing selected")
            }
            model.add(item, toPinboard: board.id)   // context menu "Add to Pinboard"
            return Outcome(ok: true, message: "inPinboard=\(item.isInPinboard)")
        case "open-pinboard":
            guard let board = model.pinboardRows.first(where: { $0.name == argument }) else {
                return Outcome(ok: false, message: "no pinboard named '\(argument)'")
            }
            model.setScope(.pinboard(board.id))     // pinboard tab
            return Outcome(ok: true, message: "visible=\(model.rows.count)")
        case "item-files":
            // store.fileURLs(for:) of the selected item (what PasteboardWriter writes back).
            guard let item = model.selectedItem, PanelViewModel.isAlive(item) else {
                return Outcome(ok: false, message: "nothing selected")
            }
            let urls = controller.store.fileURLs(for: item)
            let names = urls.map { $0.lastPathComponent }.joined(separator: ",")
            return Outcome(ok: true, message: "kind=\(item.kindRaw) count=\(urls.count) names=\(names)")
        case "open-history":
            model.setScope(.history)
            return Outcome(ok: true, message: "visible=\(model.rows.count)")
        default:
            return Outcome(ok: false, message: "unknown command '\(name)'")
        }
    }

    // MARK: - Seed (scale test only; bypasses the pasteboard on purpose)

    private func seed(_ argument: String) -> Outcome {
        let parts = argument.split(separator: " ").map { String($0) }
        guard let first = parts.first, let count = Int(first), count > 0, count <= 20_000 else {
            return Outcome(ok: false, message: "seed needs a count 1...20000, got '\(argument)'")
        }
        let tag = parts.count > 1 ? parts[1] : "seed"
        let store = controller.store
        let base = Date().addingTimeInterval(-86_400)   // older than every real test item
        let started = CACurrentMediaTime()
        var inserted = 0
        for index in 0..<count {
            let text = "E2E seeded clip \(tag)s\(index)e"
            let draft = ClipDraft.text(text, createdAt: base.addingTimeInterval(Double(index)))
            if case .inserted = store.ingestDetailed(draft) {
                inserted += 1
            }
        }
        lastSeedMs = (CACurrentMediaTime() - started) * 1000
        lastSeedInserted = inserted
        return Outcome(ok: inserted == count,
                       message: "SEEDED inserted=\(inserted) of \(count) seedMs=\(E2EDriver.format(lastSeedMs))")
    }

    /// `seed-files <abs path> <abs path> ...`: a multi-file item built exactly like
    /// PasteboardReader.readFiles builds one (test-only, bypasses the pasteboard).
    private func seedFiles(_ argument: String) -> Outcome {
        let paths = argument.split(separator: " ").map { String($0) }.filter { $0.hasPrefix("/") }
        guard paths.count >= 2 else {
            return Outcome(ok: false, message: "seed-files needs at least two absolute paths")
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let first = urls[0]
        var draft = ClipDraft(
            kind: .file,
            plainText: urls.map { $0.path }.joined(separator: "\n"),
            title: "\(first.lastPathComponent) + \(urls.count - 1) more",
            representations: [
                ClipDraft.Representation(uti: ClipUTI.fileURL, data: Data(first.absoluteString.utf8)),
                ClipDraft.Representation(uti: ClipUTI.fileURLList, data: ClipFileList.encode(urls))
            ],
            declaredTypes: [ClipUTI.fileURL],
            createdAt: Date()
        )
        draft.contentHash = ContentHasher.hash(draft)
        let result = controller.store.ingestDetailed(draft)
        switch result {
        case .inserted:
            return Outcome(ok: true, message: "SEEDED inserted files=\(urls.count)")
        case .bumped:
            return Outcome(ok: true, message: "SEEDED bumped files=\(urls.count)")
        case .rejected(let reason):
            return Outcome(ok: false, message: "SEEDED rejected: \(reason.rawValue)")
        }
    }

    // MARK: - Snapshots

    private func snapshot(_ rawName: String) -> Outcome {
        let name = E2EDriver.sanitize(rawName.isEmpty ? "shot" : rawName)
        var written: [String] = []
        var failed: [String] = []
        for window in NSApp.windows where window.isVisible {
            guard let label = E2EDriver.windowLabel(window), let view = window.contentView else { continue }
            let fileURL = shotsDirectory.appendingPathComponent("\(name)-\(label).png", isDirectory: false)
            if let info = E2ESnapshot.writePNG(of: view, scale: window.backingScaleFactor, to: fileURL) {
                written.append("\(label)[\(info)]")
            } else {
                failed.append(label)
            }
        }
        if written.isEmpty {
            let visible = openWindowLabels().joined(separator: ",")
            if visible.isEmpty {
                return Outcome(ok: false, message: "nothing rendered: no ClipSync window is visible (panelVisible=\(environment.panel.isVisible)); send show / open-settings first")
            }
            return Outcome(ok: false, message: "nothing rendered (visible windows: \(visible); failed: \(failed.joined(separator: ",")))")
        }
        return Outcome(ok: failed.isEmpty, message: "shots=\(written.joined(separator: " ")) failed=\(failed.joined(separator: ","))")
    }

    /// "panel", "settings", "onboarding", or "window-<title>" for any other titled window.
    static func windowLabel(_ window: NSWindow) -> String? {
        if window is CardStripPanel { return "panel" }
        if window.title == "ClipSync Settings" { return "settings" }
        if window.title == "Welcome to ClipSync" { return "onboarding" }
        guard window.styleMask.contains(.titled), !(window is NSPanel) else { return nil }
        return "window-" + sanitize(window.title.isEmpty ? "untitled" : window.title)
    }

    private func openWindowLabels() -> [String] {
        var labels: [String] = []
        for window in NSApp.windows where window.isVisible {
            if let label = E2EDriver.windowLabel(window) {
                labels.append(label)
            }
        }
        return labels
    }

    // MARK: - Status

    private func scopeDescription(_ model: PanelViewModel) -> String {
        switch model.scope {
        case .history:
            return "history"
        case .pinboard(let id):
            let boardName = model.pinboardRows.first(where: { $0.id == id })?.name ?? id.uuidString
            return "pinboard:" + boardName
        }
    }

    private func writeStatus() {
        statusSequence += 1
        lastFingerprint = fingerprint()

        let store = controller.store
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var kv: [(String, String)] = []
        func add(_ key: String, _ value: String) { kv.append((key, value)) }

        let locked = controller.appLock.isLocked
        func content(_ text: String) -> String { return locked ? E2EDriver.redacted : text }

        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String ?? "?") + " (" + (info["CFBundleVersion"] as? String ?? "?") + ")"
        let capture = controller.monitor.lastCapture

        add("seq", String(statusSequence))
        add("timestamp", formatter.string(from: now))
        add("pid", String(ProcessInfo.processInfo.processIdentifier))
        add("appVersion", version)
        add("itemCount", String(store.itemCount()))
        add("capturePaused", String(controller.settings.capturePaused))
        add("accessibilityGranted", String(AXIsProcessTrusted()))
        add("lastCapturedKind", capture?.kind.rawValue ?? "")
        add("lastCapturedTextPrefix", content(String((capture?.plainText ?? "").prefix(40))))
        add("locked", String(locked))
        add("appLockEnabled", String(controller.settings.appLockEnabled))
        add("lockTimeout", controller.settings.lockTimeout.rawValue)
        add("itemsRedacted", String(locked))
        add("linkPreviewsEnabled", String(controller.settings.linkPreviewsEnabled))
        add("linkFetchAttempts", String(store.linkFetchAttempts))
        add("hideFromScreenCapture", String(controller.settings.hideFromScreenCapture))
        add("windowsHiddenFromCapture", String(controller.hidesWindowsFromCapture))
        add("frontmostApp", NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        add("pasteTarget", controller.tracker.pasteTarget?.bundleIdentifier ?? "")
        add("trackerPreviousApp", controller.tracker.previousApp?.bundleIdentifier ?? "")
        add("axPromptRequested", String(axPromptRequested))
        add("openWindows", openWindowLabels().joined(separator: ","))
        add("pinboards", store.pinboards().map { $0.name }.joined(separator: ","))
        let panelVisibleNow = environment.panel.isVisible
        if panelWasVisible && !panelVisibleNow {
            panelHiddenAfterCommand = lastCommand
            panelHiddenAt = formatter.string(from: now)
        }
        panelWasVisible = panelVisibleNow
        add("panelVisible", String(panelVisibleNow))
        add("panelHiddenAfterCommand", panelHiddenAfterCommand)
        add("panelHiddenAt", panelHiddenAt)
        add("lastShowDurationMs", E2EDriver.format(panelController?.lastShowDurationMs ?? -1))
        add("lastSearchQuery", lastSearchQuery)
        add("lastSearchRoundTripMs", E2EDriver.format(lastSearchRoundTripMs))
        add("lastSeedMs", E2EDriver.format(lastSeedMs))
        add("lastSeedInserted", String(lastSeedInserted))
        add("commandsProcessed", String(commandsProcessed))
        add("lastCommand", lastCommand)

        if let model = viewModel {
            add("panelSearchText", model.searchText)
            add("panelSelectedIndex", String(model.selectedIndex))
            add("visibleCardCount", String(model.rows.count))
            add("visibleKinds", model.rows.map { $0.item.kindRaw }.joined(separator: ","))
            add("panelScope", scopeDescription(model))
            add("panelFilter", model.kindFilter.rawValue)
            if let selected = model.selectedItem, PanelViewModel.isAlive(selected) {
                add("selected.kind", selected.kindRaw)
                add("selected.text", content(E2EDriver.prefix(E2EDriver.text(of: selected), 80)))
            }
            for row in model.rows.prefix(10) where PanelViewModel.isAlive(row.item) {
                add("rows.\(row.index).kind", row.item.kindRaw)
                add("rows.\(row.index).text", content(E2EDriver.prefix(E2EDriver.text(of: row.item), 80)))
            }
        }

        let newest = store.fetchItems(ClipFilter(limit: 10))
        for (index, item) in newest.enumerated() {
            add("items.\(index).kind", item.kindRaw)
            add("items.\(index).title", content(E2EDriver.prefix(item.title ?? "", 80)))
            add("items.\(index).plainText", content(E2EDriver.prefix(item.plainText ?? "", 80)))
            add("items.\(index).isPinned", String(item.isPinned))
            add("items.\(index).inPinboard", String(item.isInPinboard))
            add("items.\(index).sourceApp", item.sourceAppName ?? item.sourceAppBundleID ?? "")
        }

        if let paste = lastPaste {
            add("lastPaste.text", content(paste.textPrefix))
            add("lastPaste.asPlainText", String(paste.asPlainText))
            add("lastPaste.mode", paste.mode)
            add("lastPaste.timestamp", formatter.string(from: paste.timestamp))
        }
        if let copy = lastCopy {
            add("lastCopy.text", content(copy.textPrefix))
            add("lastCopy.asPlainText", String(copy.asPlainText))
            add("lastCopy.timestamp", formatter.string(from: copy.timestamp))
        }

        // status.kv
        var kvText = ""
        for (key, value) in kv {
            kvText += key + "=" + E2EDriver.escapeKV(value) + "\n"
        }
        let kvURL = directory.appendingPathComponent("status.kv", isDirectory: false)
        try? kvText.write(to: kvURL, atomically: true, encoding: .utf8)

        // status.json (flat object of the same pairs, plus structured arrays for readability)
        var json: [String: Any] = [:]
        for (key, value) in kv where !key.contains(".") {
            json[key] = E2EDriver.jsonValue(value)
        }
        var itemObjects: [[String: Any]] = []
        for item in newest {
            itemObjects.append([
                "kind": item.kindRaw,
                "title": content(E2EDriver.prefix(item.title ?? "", 80)),
                "plainText": content(E2EDriver.prefix(item.plainText ?? "", 80)),
                "isPinned": item.isPinned,
                "sourceApp": item.sourceAppName ?? item.sourceAppBundleID ?? ""
            ])
        }
        json["items"] = itemObjects
        json["pinboards"] = store.pinboards().map { $0.name }
        json["openWindows"] = openWindowLabels()
        if let paste = lastPaste {
            json["lastPasteAction"] = [
                "itemText": content(paste.textPrefix),
                "asPlainText": paste.asPlainText,
                "mode": paste.mode,
                "timestamp": formatter.string(from: paste.timestamp)
            ] as [String: Any]
        }
        if let copy = lastCopy {
            json["lastCopyAction"] = [
                "itemText": content(copy.textPrefix),
                "asPlainText": copy.asPlainText,
                "timestamp": formatter.string(from: copy.timestamp)
            ] as [String: Any]
        }
        if let model = viewModel {
            var rowObjects: [[String: Any]] = []
            for row in model.rows.prefix(10) where PanelViewModel.isAlive(row.item) {
                rowObjects.append(["kind": row.item.kindRaw, "text": content(E2EDriver.prefix(E2EDriver.text(of: row.item), 80))])
            }
            json["visibleRows"] = rowObjects
        }
        if JSONSerialization.isValidJSONObject(json),
           let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            let jsonURL = directory.appendingPathComponent("status.json", isDirectory: false)
            try? data.write(to: jsonURL, options: .atomic)
        }
    }

    // MARK: - Helpers

    static func text(of item: ClipItem) -> String {
        if let text = item.plainText, !text.isEmpty { return text }
        return item.title ?? ""
    }

    static func prefix(_ text: String, _ length: Int) -> String {
        return String(text.prefix(length))
    }

    static func format(_ value: Double) -> String {
        return String(format: "%.1f", value)
    }

    static func sanitize(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = String(name.map { allowed.contains($0) ? $0 : "_" })
        return String(mapped.prefix(64))
    }

    static func escapeKV(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Numbers and booleans as JSON numbers / booleans, everything else as a string.
    static func jsonValue(_ value: String) -> Any {
        if value == "true" { return true }
        if value == "false" { return false }
        if !value.isEmpty, value.count < 16, let number = Double(value),
           value.allSatisfy({ "0123456789.-".contains($0) }) {
            return number
        }
        return value
    }
}

// MARK: - Paste recording decorator

/// Wraps the real PasteService; forwards every call unchanged and tells the driver
/// what happened. Installed only by E2EDriver.
@MainActor
final class E2ERecordingPaster: PasteActing {
    private let inner: PasteActing
    private weak var driver: E2EDriver?

    init(inner: PasteActing, driver: E2EDriver) {
        self.inner = inner
        self.driver = driver
    }

    var hasAccessibilityPermission: Bool {
        return inner.hasAccessibilityPermission
    }

    func paste(_ item: ClipItem, asPlainText: Bool) {
        // Same decision PasteService makes (it falls back to copy-only without AX).
        let mode = inner.hasAccessibilityPermission ? "paste" : "copyOnly"
        let text = E2EDriver.prefix(E2EDriver.text(of: item), 80)
        inner.paste(item, asPlainText: asPlainText)
        driver?.recordPaste(E2EDriver.ActionRecord(textPrefix: text, asPlainText: asPlainText, mode: mode, timestamp: Date()))
    }

    func copyToPasteboard(_ item: ClipItem, asPlainText: Bool) {
        let text = E2EDriver.prefix(E2EDriver.text(of: item), 80)
        inner.copyToPasteboard(item, asPlainText: asPlainText)
        driver?.recordCopy(E2EDriver.ActionRecord(textPrefix: text, asPlainText: asPlainText, mode: "copy", timestamp: Date()))
    }
}

// MARK: - In-process window rendering (no Screen Recording permission needed)

@MainActor
enum E2ESnapshot {
    /// Renders `view` with cacheDisplay, composites it onto an opaque neutral background
    /// (the panel's NSVisualEffectView renders transparent) and writes a PNG.
    /// When the result looks blank, also writes "<name>-layer.png" rendered through
    /// CALayer.render(in:). Returns "WxH colors=N" or nil on failure.
    static func writePNG(of view: NSView, scale: CGFloat, to url: URL) -> String? {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let cached = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: cached)

        let width = cached.pixelsWide
        let height = cached.pixelsHigh
        guard width > 0, height > 0,
              let output = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: output) else { return nil }

        let target = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let source = NSRect(x: 0, y: 0, width: cached.size.width, height: cached.size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedWhite: 0.86, alpha: 1).setFill()
        NSBezierPath(rect: target).fill()
        _ = cached.draw(in: target, from: source, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = output.representation(using: .png, properties: [:]) else { return nil }
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        let colors = distinctColors(output)
        var info = "\(width)x\(height) colors=\(colors)"
        if colors < 8, let layerInfo = writeLayerPNG(of: view, scale: scale, to: url) {
            info += " layerFallback=\(layerInfo)"
        }
        return info
    }

    private static func writeLayerPNG(of view: NSView, scale: CGFloat, to url: URL) -> String? {
        guard let layer = view.layer else { return nil }
        let factor = max(1, scale)
        let width = Int(view.bounds.width * factor)
        let height = Int(view.bounds.height * factor)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(gray: 0.86, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: factor, y: factor)
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let layerURL = url.deletingPathExtension().appendingPathExtension("layer.png")
        do {
            try png.write(to: layerURL, options: .atomic)
        } catch {
            return nil
        }
        return "\(layerURL.lastPathComponent) colors=\(distinctColors(rep))"
    }

    /// Distinct colors on a 32×32 sample grid (a quick "is this blank?" signal).
    static func distinctColors(_ rep: NSBitmapImageRep) -> Int {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0 else { return 0 }
        var seen = Set<Int>()
        for gy in 0..<32 {
            for gx in 0..<32 {
                let x = min(width - 1, gx * width / 32 + width / 64)
                let y = min(height - 1, gy * height / 32 + height / 64)
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let r = Int(color.redComponent * 255)
                let g = Int(color.greenComponent * 255)
                let b = Int(color.blueComponent * 255)
                seen.insert((r << 16) | (g << 8) | b)
            }
        }
        return seen.count
    }
}

#endif // DEBUG
