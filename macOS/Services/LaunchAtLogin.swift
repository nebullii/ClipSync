import AppKit
import Combine
import ServiceManagement
import ClipCore
import os   // Logger interpolation (privacy:) used via ServicesLog

/// Applies `AppSettings.launchAtLogin` with `SMAppService.mainApp`.
///
/// The system's login-item state is the source of truth: at start the setting is
/// reconciled from it (the user may have removed ClipSync in System Settings), and
/// afterwards every change of the setting is applied. If registering fails the
/// setting is reverted and `lastError` explains why.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var lastError: String?

    private let settings: AppSettings
    private let service = SMAppService.mainApp
    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false

    init(settings: AppSettings) {
        self.settings = settings
        self.status = SMAppService.mainApp.status
    }

    /// True when ClipSync is registered (or registered and waiting for the user's approval).
    var isEnabledInSystem: Bool {
        return status == .enabled || status == .requiresApproval
    }

    var requiresApproval: Bool {
        return status == .requiresApproval
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        refreshStatus()
        if settings.launchAtLogin != isEnabledInSystem {
            settings.launchAtLogin = isEnabledInSystem
        }
        settings.$launchAtLogin
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] desired in
                self?.apply(desired)
            }
            .store(in: &cancellables)
    }

    /// Registers / unregisters to match `desired`.
    func apply(_ desired: Bool) {
        refreshStatus()
        guard desired != isEnabledInSystem else {
            lastError = nil
            return
        }
        do {
            if desired {
                try service.register()
            } else {
                try service.unregister()
            }
            lastError = nil
        } catch {
            lastError = desired
                ? "Could not turn on Open at Login: \(error.localizedDescription)"
                : "Could not turn off Open at Login: \(error.localizedDescription)"
            ServicesLog.app.error("SMAppService failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshStatus()
        let actual = isEnabledInSystem
        if settings.launchAtLogin != actual {
            // Published emits in willSet; the sink runs on the next run-loop turn, so
            // this revert does not fight the write that triggered it.
            settings.launchAtLogin = actual
        }
    }

    func refreshStatus() {
        let current = service.status
        if current != status {
            status = current
        }
    }

    /// Opens System Settings › General › Login Items (for `.requiresApproval`).
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    var statusDescription: String {
        switch status {
        case .enabled: return "ClipSync opens when you log in."
        case .requiresApproval: return "Waiting for your approval in System Settings › General › Login Items."
        case .notRegistered: return "ClipSync does not open at login."
        case .notFound: return "Open at Login is unavailable for this copy of ClipSync (move it to Applications)."
        @unknown default: return "Open at Login status is unknown."
        }
    }
}
