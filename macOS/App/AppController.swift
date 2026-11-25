import AppKit
import Combine
import UniformTypeIdentifiers
import ClipCore
import KeyboardShortcuts
import os   // Logger interpolation (privacy:) used via ServicesLog

/// Owns every Mac service and wires them into `AppEnvironment.shared` at launch.
///
/// Created on first access of `shared` (from `ClipSyncMacApp.init`), which first
/// swaps in an in-memory store when `CLIPSYNC_UITEST=1`. `start()` runs from
/// `applicationDidFinishLaunching`.
@MainActor
final class AppController: NSObject, ObservableObject {
    static let shared: AppController = {
        AppController.prepareSharedStore(options: LaunchOptions.current)
        return AppController(options: LaunchOptions.current)
    }()

    let options: LaunchOptions
    let environment: AppEnvironment
    let accessibility: AccessibilityPermission
    let launchAtLogin: LaunchAtLoginController
    let tracker: FrontmostAppTracker
    let monitor: ClipboardMonitor
    let hotkey: HotkeyController
    let maintenance: MaintenanceScheduler
    let statusWriter: StatusFileWriter
    /// App Lock (same instance as `environment.appLock`).
    let appLock: AppLockController
    private(set) lazy var windows = WindowCoordinator(controller: self)

    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false
    private var didOfferAccessibilityHelp = false
    /// Re-checks the App Lock timeout while the lock is on (nil while it is off).
    private var lockTimer: Timer?
    #if DEBUG
    /// E2E test hook; nil unless CLIPSYNC_UITEST=1 + CLIPSYNC_E2E_DIR (see LaunchOptions).
    /// Not compiled into Release / Signed builds.
    private var e2eDriver: E2EDriver?
    #endif

    var store: ClipStore { return environment.store }
    var settings: AppSettings { return environment.settings }

    /// Must run before anything touches `AppEnvironment.shared` / `ClipStore.shared` /
    /// `AppSettings.shared`. UI-test mode gets an in-memory store AND isolated, wiped
    /// settings, so the real user's pause state / ignore list never leak into a test run
    /// (and the test never writes into the user's settings).
    private static func prepareSharedStore(options: LaunchOptions) {
        guard options.isUITest else { return }
        let settings = AppSettings.ephemeral(suiteName: "com.thingbits.clipsync.uitest")
        AppSettings.setShared(settings)
        let store = ClipStore.makeShared(inMemory: true, cloudSync: false)
        store.settings = settings
        ClipStore.setShared(store)
    }

    private init(options: LaunchOptions) {
        self.options = options
        let env = AppEnvironment.shared
        self.environment = env
        self.accessibility = AccessibilityPermission()
        self.launchAtLogin = LaunchAtLoginController(settings: env.settings)
        self.tracker = FrontmostAppTracker()
        self.monitor = ClipboardMonitor(store: env.store, settings: env.settings)
        self.hotkey = HotkeyController()
        self.maintenance = MaintenanceScheduler(store: env.store)
        self.statusWriter = StatusFileWriter(isEnabled: options.writesStatusFile)
        self.appLock = env.appLock
        super.init()
        // UI-test mode never opens the system authentication prompt by itself.
        appLock.autoPromptOnShow = !options.isUITest
    }

    // MARK: - Copy sound

    /// Plays the chosen macOS sound after a capture, unless it is turned off or this is a UI-test run.
    private func playCopySoundIfEnabled() {
        guard settings.playCopySound, !options.isUITest else { return }
        CopySound.play(named: settings.copySoundName, customFilePath: settings.copySoundFilePath)
    }

    // MARK: - Launch

    func start() {
        guard !isStarted else { return }
        isStarted = true

        // Contract launch sequence (docs/API.md §8).
        let env = environment
        tracker.start()   // before the panel exists, so the first paste has a target
        env.store.deviceName = Host.current().localizedName
        env.store.media = .live()
        let monitor = self.monitor
        let paster = PasteService(environment: env, tracker: tracker) { changeCount in
            monitor.noteOwnWrite(changeCount: changeCount)
        }
        paster.onAccessibilityMissing = { [weak self] in
            self?.accessibilityMissingDuringPaste()
        }
        env.paster = paster
        env.panel = PanelFactory.makePanel(environment: env)
        hotkey.register(environment: env)
        maintenance.start()

        monitor.onCapture = { [weak self] _ in
            self?.playCopySoundIfEnabled()
            self?.writeStatus()
        }
        monitor.start()
        launchAtLogin.start()
        observeSettings()
        observeSystemLockEvents()
        appLock.addLockStateObserver { [weak self] _ in
            self?.writeStatus()
        }
        updateLockTimer()
        applyWindowPrivacy()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettingsRequested(_:)),
            name: .clipSyncOpenSettings,
            object: nil
        )

        if !options.isUITest && !settings.hasCompletedOnboarding {
            windows.showOnboarding(step: .welcome)
        }
        if options.showPanelAfterLaunch {
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.environment.panel.show()
            }
        }
        writeStatus()
        #if DEBUG
        e2eDriver = E2EDriver.startIfEnabled(controller: self)   // E2E test hook (no-op normally)
        #endif
        ServicesLog.app.info("ClipSync started (uiTest: \(self.options.isUITest, privacy: .public))")
    }

    private func observeSettings() {
        settings.$retention
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.maintenance.runNow() }
            .store(in: &cancellables)

        settings.$maxHistoryCount
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.maintenance.runNow() }
            .store(in: &cancellables)

        settings.$capturePaused
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.writeStatus() }
            .store(in: &cancellables)

        accessibility.$isGranted
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.writeStatus() }
            .store(in: &cancellables)

        // receive(on:) delivers after the new value is stored (@Published emits in willSet).
        settings.$appLockEnabled
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateLockTimer()
                self?.writeStatus()
            }
            .store(in: &cancellables)

        settings.$hideFromScreenCapture
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyWindowPrivacy() }
            .store(in: &cancellables)
    }

    // MARK: - App Lock & window privacy

    /// Lock on screen lock, sleep, display sleep and fast user switching.
    private func observeSystemLockEvents() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let workspaceNames: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ]
        for name in workspaceNames {
            workspaceCenter.addObserver(self, selector: #selector(systemLockEvent(_:)), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemLockEvent(_:)),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
    }

    @objc private func systemLockEvent(_ notification: Notification) {
        if Thread.isMainThread {
            lockNow()
        } else {
            Task { @MainActor in
                self.lockNow()
            }
        }
    }

    /// A 15 s repeating check while the lock is on (none while it is off, so idle CPU is unchanged).
    private func updateLockTimer() {
        if appLock.isEnabled {
            guard lockTimer == nil else { return }
            let timer = Timer(
                timeInterval: 15,
                target: self,
                selector: #selector(lockTimerFired(_:)),
                userInfo: nil,
                repeats: true
            )
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            lockTimer = timer
        } else {
            lockTimer?.invalidate()
            lockTimer = nil
        }
    }

    @objc private func lockTimerFired(_ timer: Timer) {
        appLock.checkTimeout()
    }

    /// Menu bar "Lock ClipSync Now", screen lock, sleep. No-op while App Lock is off.
    func lockNow() {
        appLock.lockNow()
    }

    /// True when ClipSync windows ask macOS to be left out of screen capture. Always false
    /// in UI-test mode: the E2E harness renders windows in-process.
    var hidesWindowsFromCapture: Bool {
        return settings.hideFromScreenCapture && !options.isUITest
    }

    /// Applies `hidesWindowsFromCapture` to every ClipSync window (panel included).
    func applyWindowPrivacy() {
        for window in NSApp.windows {
            applyWindowPrivacy(to: window)
        }
    }

    func applyWindowPrivacy(to window: NSWindow) {
        let wanted: NSWindow.SharingType = hidesWindowsFromCapture ? .none : .readOnly
        if window.sharingType != wanted {
            window.sharingType = wanted
        }
    }

    /// Called from applicationWillTerminate: "Clear history when I quit ClipSync".
    func prepareForTermination() {
        guard settings.clearHistoryOnQuit, !store.isInMemory else { return }
        let removed = store.clearHistory(keepPinned: true)
        ServicesLog.app.info("Cleared \(removed) items on quit")
    }

    /// `.clipSyncOpenSettings`; optional `userInfo["tab"]` (String) = a `SettingsTab`
    /// raw value ("general", "history", "privacy", "sync", "about"). Unknown → current tab.
    @objc private func openSettingsRequested(_ notification: Notification) {
        let tabName = notification.userInfo?[ClipSyncNotificationKey.settingsTab] as? String
        let tab = tabName.flatMap { SettingsTab(rawValue: $0.lowercased()) }
        // Posters should use the main thread; hop there if one did not.
        if Thread.isMainThread {
            openSettings(tab: tab)
        } else {
            Task { @MainActor in
                self.openSettings(tab: tab)
            }
        }
    }

    private func writeStatus() {
        #if DEBUG
        // Test hook (CLIPSYNC_UITEST=1 + CLIPSYNC_STATUS_FILE=1, Debug builds only).
        guard statusWriter.isEnabled else { return }
        statusWriter.write(
            store: store,
            settings: settings,
            accessibilityGranted: accessibility.isGranted,
            lastCapture: monitor.lastCapture,
            redactContent: appLock.isLocked
        )
        #endif
    }

    // MARK: - Actions (menu bar, settings, onboarding)

    func togglePanel() {
        environment.panel.toggle()
    }

    func toggleCapturePaused() {
        settings.capturePaused.toggle()
    }

    /// Menu bar "recent items": copy only (the menu has no previous app to paste into reliably).
    /// Refused while locked: the panel's lock screen opens instead.
    func quickCopy(_ item: ClipItem) {
        if appLock.checkTimeout() {
            environment.panel.show()
            return
        }
        appLock.noteActivity()
        environment.paster.copyToPasteboard(item, asPlainText: settings.plainTextByDefault)
    }

    func openSettings(tab: SettingsTab? = nil) {
        windows.showSettings(tab: tab)
    }

    func showAccessibilityHelp() {
        windows.showOnboarding(step: .accessibility)
    }

    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        windows.closeOnboarding()
    }

    func runMaintenanceNow() {
        maintenance.runNow()
    }

    /// Asks for confirmation, then deletes unprotected history (pinned / pinboard items stay).
    func confirmClearHistory() {
        // Defer so a menu that triggered this has finished closing before the modal runs.
        Task {
            self.runClearHistoryAlert()
        }
    }

    private func runClearHistoryAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear clipboard history?"
        var info = "Pinned items and items in pinboards are kept. This cannot be undone."
        if store.isCloudSyncActive {
            info += " The items are also removed from your other devices that sync with iCloud."
        }
        alert.informativeText = info
        let clearButton = alert.addButton(withTitle: "Clear History")
        clearButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let removed = store.clearHistory(keepPinned: true)
        ServicesLog.app.info("Cleared \(removed) items")
        writeStatus()
    }

    /// NSOpenPanel on /Applications; adds the chosen apps' bundle IDs to the ignore list.
    func chooseAppsToIgnore() {
        let panel = NSOpenPanel()
        panel.title = "Choose Apps to Ignore"
        panel.message = "ClipSync will not record anything copied in these apps."
        panel.prompt = "Ignore"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [UTType.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        let ownBundleID = Bundle.main.bundleIdentifier
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier, bundleID != ownBundleID else { continue }
            settings.addIgnoredBundleID(bundleID)
        }
    }

    /// Quits and reopens ClipSync (iCloud sync changes need a fresh store).
    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try process.run()
        } catch {
            ServicesLog.app.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Private

    private func accessibilityMissingDuringPaste() {
        // The item was copied; explain once per launch how to enable automatic pasting.
        guard !didOfferAccessibilityHelp, !options.isUITest else { return }
        didOfferAccessibilityHelp = true
        showAccessibilityHelp()
    }
}
