//
//  GlobalHotkeyManager.swift
//  ClaudeIsland
//
//  Manages a system-wide hotkey using Carbon RegisterEventHotKey
//

import Carbon
import Combine
import Foundation

// Hotkey constants outside the actor-isolated class for safe C callback access
private let hotkeySignature: OSType = 0x434C_4953  // "CLIS"
private let hotkeyIDValue: UInt32 = 1

class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    /// Fires when the registered hotkey is triggered
    let hotkeyTriggered = PassthroughSubject<Void, Never>()

    private var hotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    deinit {
        unregister()
    }

    // MARK: - Public API

    func register(shortcut: KeyboardShortcut) {
        // Unregister any existing hotkey first
        unregister()

        // Install Carbon event handler
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

                if hkID.signature == hotkeySignature && hkID.id == hotkeyIDValue {
                    DispatchQueue.main.async {
                        manager.hotkeyTriggered.send()
                    }
                    return noErr
                }
                return OSStatus(eventNotHandledErr)
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        // Register the hotkey
        var id = EventHotKeyID(signature: hotkeySignature, id: hotkeyIDValue)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifierFlags,
            id,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if status != noErr {
            print("[GlobalHotkeyManager] Failed to register hotkey: \(status)")
        }
    }

    func unregister() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }
}
