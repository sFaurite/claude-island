//
//  GlobalHotkeyManager.swift
//  ClaudeIsland
//
//  Manages system-wide hotkeys using Carbon RegisterEventHotKey
//

import Carbon
import Combine
import Foundation

// Hotkey constants outside the actor-isolated class for safe C callback access
private let hotkeySignature: OSType = 0x434C_4953  // "CLIS"

class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    /// Fires when the toggle hotkey is triggered (ID=1)
    let hotkeyTriggered = PassthroughSubject<Void, Never>()

    /// Fires when the hide hotkey is triggered (ID=2)
    let hideHotkeyTriggered = PassthroughSubject<Void, Never>()

    private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    deinit {
        unregisterAll()
    }

    // MARK: - Public API

    func register(shortcut: KeyboardShortcut, id: UInt32 = 1) {
        // Unregister this specific hotkey if already registered
        unregister(id: id)

        // Install shared Carbon event handler if not yet installed
        installHandlerIfNeeded()

        // Register the hotkey
        var hotkeyID = EventHotKeyID(signature: hotkeySignature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifierFlags,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr, let ref = ref {
            hotkeyRefs[id] = ref
        } else {
            print("[GlobalHotkeyManager] Failed to register hotkey id=\(id): \(status)")
        }
    }

    func unregister(id: UInt32 = 1) {
        if let ref = hotkeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        // Remove shared handler if no hotkeys remain
        if hotkeyRefs.isEmpty, let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    func unregisterAll() {
        for (_, ref) in hotkeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotkeyRefs.removeAll()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    // MARK: - Private

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus in
                guard let userData = userData, let event = event else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )

                guard hkID.signature == hotkeySignature else {
                    return OSStatus(eventNotHandledErr)
                }

                DispatchQueue.main.async {
                    switch hkID.id {
                    case 1:
                        manager.hotkeyTriggered.send()
                    case 2:
                        manager.hideHotkeyTriggered.send()
                    default:
                        break
                    }
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
    }
}
