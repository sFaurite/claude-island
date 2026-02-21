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

@MainActor
final class MenuBarDetector: ObservableObject {
    @Published var isMenuBarHidden: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var safetyTimer: Timer?

    init() {
        let nc = NSWorkspace.shared.notificationCenter

        nc.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleCheck() }
            .store(in: &cancellables)

        nc.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleCheck() }
            .store(in: &cancellables)

        // Safety timer to catch missed transitions
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.check()
            }
        }

        // Initial check
        scheduleCheck()
    }

    deinit {
        safetyTimer?.invalidate()
    }

    private func scheduleCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.check()
        }
    }

    private func check() {
        // Use private CGS API to detect fullscreen space
        // Space type: 0 = desktop/user, 4 = fullscreen
        let conn = CGSMainConnectionID()
        let activeSpace = CGSGetActiveSpace(conn)
        let spaceType = CGSSpaceGetType(conn, activeSpace)

        let hidden = spaceType == 4
        if hidden != isMenuBarHidden {
            isMenuBarHidden = hidden
        }
    }
}
