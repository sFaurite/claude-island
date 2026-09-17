//
//  MenuBarDetector.swift
//  ClaudeIsland
//
//  Detects when macOS menu bar is hidden (fullscreen app on current space)
//

import AppKit
import Combine

// Private CGS API for detecting fullscreen spaces
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ connection: Int32) -> Int

@_silgen_name("CGSSpaceGetType")
private func CGSSpaceGetType(_ connection: Int32, _ space: Int) -> Int

@_silgen_name("CGSManagedDisplayGetCurrentSpace")
private func CGSManagedDisplayGetCurrentSpace(_ connection: Int32, _ displayUUID: CFString) -> Int

@MainActor
final class MenuBarDetector: ObservableObject {
    @Published var isMenuBarHidden: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var safetyTimer: Timer?
    private var activity: NSObjectProtocol?

    // MARK: Ralentissement en inactivité
    //
    // Un passage en plein écran suppose une saisie clavier/souris. Sans saisie
    // depuis `idleAfter`, la vérification coûteuse (CGWindowListCopyWindowInfo,
    // ~1,6 ms) n'est plus faite qu'une fois par `idleInterval` ; le timer, lui,
    // continue à la période réglée (réveil ~15 µs) pour repasser à pleine
    // cadence dès la première saisie, sans latence supplémentaire.
    private static let idleAfter: TimeInterval = 30
    private static let idleInterval: TimeInterval = 2.0
    private static let anyInputEvent = CGEventType(rawValue: ~0)!
    private var lastCheck = Date.distantPast

    init() {
        // Prevent App Nap from suspending our fullscreen detection timer.
        // Without this, the 2s safety timer gets coalesced/delayed indefinitely
        // for LSUIElement apps that are never the frontmost process.
        activity = Foundation.ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Fullscreen detection for notch wings"
        )

        let nc = NSWorkspace.shared.notificationCenter

        nc.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleCheck() }
            .store(in: &cancellables)

        nc.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleCheck() }
            .store(in: &cancellables)

        // Safety timer to catch missed transitions.
        // C'est la SEULE voie de détection du plein écran non natif de Ghostty
        // (macos-non-native-fullscreen) : ni activeSpaceDidChange ni
        // didActivateApplication ne se déclenchent. La période est réglable dans
        // Préférences > System (0,2–10 s, défaut 0,5 s) ; chaque vérification coûte
        // ~1,5 ms (mesure du 17/09/2026), soit ~0,3 % CPU à 0,5 s.
        startSafetyTimer()

        NotificationCenter.default.publisher(for: AppSettings.fullscreenDetectionIntervalDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.startSafetyTimer() }
            .store(in: &cancellables)

        // Initial check
        scheduleCheck()
    }

    private func startSafetyTimer() {
        safetyTimer?.invalidate()
        let interval = AppSettings.fullscreenDetectionInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.timerTick()
            }
        }
        // Un peu de tolérance : laisse le système regrouper les réveils, sans
        // dépasser 10 % de la période (latence perçue inchangée).
        timer.tolerance = interval * 0.1
        safetyTimer = timer
    }

    deinit {
        safetyTimer?.invalidate()
        if let activity { Foundation.ProcessInfo.processInfo.endActivity(activity) }
    }

    private func scheduleCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.check()
        }
    }

    /// Tick du timer : vérification à la cadence réglée si l'utilisateur est
    /// actif, sinon au plus une fois par `idleInterval`.
    private func timerTick() {
        let idleFor = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInputEvent)
        if idleFor > Self.idleAfter, Date().timeIntervalSince(lastCheck) < Self.idleInterval {
            return
        }
        check()
    }

    private func check() {
        lastCheck = Date()
        // Use private CGS API to detect fullscreen space
        // Space type: 0 = desktop/user, 4 = fullscreen
        let conn = CGSMainConnectionID()

        // Query the built-in display's space specifically (where the notch lives)
        // instead of the globally active space, so wings persist when the user
        // clicks on a secondary screen while fullscreen is active on the main one.
        let space: Int
        if let builtIn = Self.builtInScreen,
           let displayID = builtIn.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeUnretainedValue() {
            let uuidString = CFUUIDCreateString(nil, uuid) as CFString
            space = CGSManagedDisplayGetCurrentSpace(conn, uuidString)
        } else {
            space = CGSGetActiveSpace(conn)
        }

        let spaceType = CGSSpaceGetType(conn, space)

        // Native fullscreen OR non-native terminal fullscreen
        let hidden = spaceType == 4 || isTerminalFullscreenOnBuiltIn()
        if hidden != isMenuBarHidden {
            isMenuBarHidden = hidden
        }
    }

    /// Detect a terminal window covering the entire built-in screen
    /// (non-native fullscreen like Ghostty's macos-non-native-fullscreen)
    private func isTerminalFullscreenOnBuiltIn() -> Bool {
        guard let screen = Self.builtInScreen else { return false }

        // CGWindowListCopyWindowInfo uses Quartz coordinates (origin top-left, Y down)
        // NSScreen.frame uses Cocoa coordinates (origin bottom-left, Y up)
        // Convert screen frame to Quartz coordinates for comparison
        let cocoaFrame = screen.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? cocoaFrame.height
        let screenFrame = CGRect(
            x: cocoaFrame.origin.x,
            y: primaryHeight - cocoaFrame.origin.y - cocoaFrame.height,
            width: cocoaFrame.width,
            height: cocoaFrame.height
        )
        let screenArea = screenFrame.width * screenFrame.height

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  TerminalAppRegistry.isTerminal(ownerName),
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary else { continue }

            var winRect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &winRect) else { continue }

            let intersection = winRect.intersection(screenFrame)
            let coverage = (intersection.width * intersection.height) / screenArea
            if coverage >= 0.98 { return true }
        }
        return false
    }

    /// The built-in screen (MacBook display with the notch)
    private static var builtInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }
}
