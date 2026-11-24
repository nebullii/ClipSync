import SwiftUI
import UIKit
import ClipCore

/// What the shield window shows when it is up.
@MainActor
final class PrivacyShieldState: ObservableObject {
    /// True while the app is inactive / in the background (app-switcher snapshot).
    @Published var showsCover = false
}

/// iOS App Lock + privacy cover (security pass).
///
/// - App Lock: a full-screen lock view whenever `appLock.isLocked` — on launch (when the
///   lock is on) and when the app returns to the foreground after the timeout. It lives
///   in its own UIWindow above everything (sheets, full-screen covers, alerts), so no
///   presented screen can show through. Face ID / Touch ID with passcode fallback
///   (`NSFaceIDUsageDescription` is in the Info.plist).
/// - Privacy cover: an opaque branded view while the scene is inactive / in the
///   background, so the app-switcher snapshot never shows clipboard content.
/// - Locks when the device locks (`protectedDataWillBecomeUnavailable`, passcode devices).
/// - `-uitest-seed`: App Lock is off (wiped settings) and the cover is disabled, so UI tests
///   never meet a blocking screen.
@MainActor
final class SecurityCoordinator: NSObject {
    let appLock: AppLockController
    let settings: AppSettings
    let isUITest: Bool
    let shieldState = PrivacyShieldState()

    private var shieldWindows: [ObjectIdentifier: UIWindow] = [:]
    /// Auto-prompt at most once per trip to the foreground (a cancelled Face ID prompt
    /// makes the app active again; it must not prompt in a loop).
    private var didAutoPromptThisForeground = false

    init(appLock: AppLockController, settings: AppSettings, isUITest: Bool) {
        self.appLock = appLock
        self.settings = settings
        self.isUITest = isUITest
        super.init()
        appLock.autoPromptOnShow = !isUITest

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appWillResignActive(_:)),
                           name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidEnterBackground(_:)),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillEnterForeground(_:)),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidBecomeActive(_:)),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidActivate(_:)),
                           name: UIScene.didActivateNotification, object: nil)
        center.addObserver(self, selector: #selector(deviceWillLock(_:)),
                           name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)

        appLock.addLockStateObserver { [weak self] _ in
            self?.updateShield()
        }
    }

    /// The app-switcher cover: on by default, never in UI-test mode.
    var coverEnabled: Bool {
        return !isUITest && settings.privacyCoverEnabled
    }

    // MARK: Lifecycle (UIKit posts these on the main thread)

    @objc private func appWillResignActive(_ notification: Notification) {
        if coverEnabled {
            shieldState.showsCover = true
        }
        updateShield()
    }

    @objc private func appDidEnterBackground(_ notification: Notification) {
        didAutoPromptThisForeground = false
        if coverEnabled {
            shieldState.showsCover = true
        }
        appLock.noteInterfaceHidden()   // "Immediately" locks now; others start the timeout
        updateShield()
    }

    @objc private func appWillEnterForeground(_ notification: Notification) {
        appLock.checkTimeout()
        updateShield()
    }

    @objc private func appDidBecomeActive(_ notification: Notification) {
        sceneBecameActive()
    }

    /// Also called by RootView (onAppear / scenePhase .active), so the lock screen is up
    /// even if the first didBecomeActive notification fired before this object existed.
    func sceneBecameActive() {
        if shieldState.showsCover {
            shieldState.showsCover = false
        }
        appLock.checkTimeout()
        updateShield()
        autoPromptIfNeeded()
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        // A new iPad window: cover it too while locked.
        updateShield()
    }

    @objc private func deviceWillLock(_ notification: Notification) {
        appLock.lockNow()
    }

    // MARK: Unlock

    func requestUnlock() {
        guard appLock.isLocked, !appLock.isAuthenticating else { return }
        let lock = appLock
        Task { @MainActor in
            _ = await lock.unlock(reason: "show your clipboard history")
        }
    }

    private func autoPromptIfNeeded() {
        guard appLock.isLocked, appLock.autoPromptOnShow, !didAutoPromptThisForeground,
              !appLock.isAuthenticating,
              UIApplication.shared.applicationState == .active else { return }
        didAutoPromptThisForeground = true
        requestUnlock()
    }

    // MARK: Shield windows

    /// Shows one opaque shield window per window scene while locked or covered; removes them otherwise.
    func updateShield() {
        let locked = appLock.isLocked
        let needed = locked || shieldState.showsCover
        guard needed else {
            removeShieldWindows()
            return
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            let key = ObjectIdentifier(windowScene)
            let window: UIWindow
            if let existing = shieldWindows[key] {
                window = existing
            } else {
                window = makeShieldWindow(for: windowScene)
                shieldWindows[key] = window
            }
            if locked {
                // Key window: hardware-keyboard typing and VoiceOver go to the lock view,
                // never to a search field underneath.
                if !window.isKeyWindow {
                    window.makeKeyAndVisible()
                }
            } else if window.isHidden {
                window.isHidden = false
            }
        }
        if locked {
            _ = UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    private func makeShieldWindow(for scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level.alert + 1
        let root = PrivacyShieldView(
            state: shieldState,
            appLock: appLock,
            onUnlock: { [weak self] in self?.requestUnlock() }
        )
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = UIColor.systemBackground
        window.rootViewController = host
        window.isHidden = false
        return window
    }

    private func removeShieldWindows() {
        guard !shieldWindows.isEmpty else { return }
        for (_, window) in shieldWindows {
            let scene = window.windowScene
            window.isHidden = true
            window.rootViewController = nil
            // Hand key status back to the app's own window.
            if let main = scene?.windows.first(where: { $0 !== window && !$0.isHidden }) {
                main.makeKey()
            }
        }
        shieldWindows.removeAll()
    }
}
