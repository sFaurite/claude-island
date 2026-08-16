import AppKit


import Sparkle
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private var updateCheckTimer: Timer?
    private var rateLimitRefreshTimer: Timer?
    private var rateLimitActivity: NSObjectProtocol?

    static var shared: AppDelegate?
    let updater: SPUUpdater
    private let userDriver: NotchUserDriver

    var windowController: NotchWindowController? {
        windowManager?.windowController
    }

    override init() {
        userDriver = NotchUserDriver()
        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: nil
        )
        super.init()
        AppDelegate.shared = self

        do {
            try updater.start()
        } catch {
            print("Failed to start Sparkle updater: \(error)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        // Mixpanel analytics removed

        HookInstaller.installIfNeeded()
        NSApplication.shared.setActivationPolicy(.accessory)

        // Applique les migrations de config au démarrage (ex. injection de la barre
        // « fable »). NotchWingsView lit wingsElements directement depuis UserDefaults,
        // donc la migration doit être persistée avant le premier rendu des ailes.
        _ = AppSettings.wingsElements

        windowManager = WindowManager()
        _ = windowManager?.setupNotchWindow()

        screenObserver = ScreenObserver { [weak self] in
            self?.handleScreenChange()
        }

        // Register global hotkeys if enabled
        if AppSettings.isShortcutEnabled {
            GlobalHotkeyManager.shared.register(shortcut: AppSettings.toggleShortcut, id: 1)
        }
        if AppSettings.isHideShortcutEnabled {
            GlobalHotkeyManager.shared.register(shortcut: AppSettings.hideShortcut, id: 2)
        }
        if AppSettings.isHideAllShortcutEnabled {
            GlobalHotkeyManager.shared.register(shortcut: AppSettings.hideAllShortcut, id: 3)
        }

        if updater.canCheckForUpdates {
            updater.checkForUpdates()
        }

        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let updater = self?.updater, updater.canCheckForUpdates else { return }
            updater.checkForUpdates()
        }

        startRateLimitBackgroundRefresh()
    }

    /// Relevé de quota en tâche de fond, indépendant de l'affichage des ailes.
    /// Sans lui, ~/.claude/rate-limit-cache.json n'était réécrit que lorsque la
    /// barre de menus est masquée (mode plein écran) : hors plein écran, les
    /// consommateurs du cache (MonA) lisaient des valeurs figées pendant des heures.
    private func startRateLimitBackgroundRefresh() {
        // Même parade anti-App Nap que NotchWingsController : sans activité
        // déclarée, les timers d'une app LSUIElement sont coalescés indéfiniment.
        if rateLimitActivity == nil {
            rateLimitActivity = Foundation.ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Background rate-limit cache refresh"
            )
        }

        Task { _ = try? await RateLimitService.shared.fetch() }
        rateLimitRefreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { _ = try? await RateLimitService.shared.fetch() }
        }
        timer.tolerance = 60
        rateLimitRefreshTimer = timer
    }

    private func handleScreenChange() {
        _ = windowManager?.setupNotchWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkeyManager.shared.unregisterAll()
        updateCheckTimer?.invalidate()
        rateLimitRefreshTimer?.invalidate()
        if let rateLimitActivity {
            Foundation.ProcessInfo.processInfo.endActivity(rateLimitActivity)
            self.rateLimitActivity = nil
        }
        screenObserver = nil
    }

    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.farouqaldori.ClaudeIsland"
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        if runningApps.count > 1 {
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                existingApp.activate()
            }
            return false
        }

        return true
    }
}
