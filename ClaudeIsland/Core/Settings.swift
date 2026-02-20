//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import AppKit
import Carbon
import Foundation

// MARK: - KeyboardShortcut

/// A global keyboard shortcut (key code + modifier flags), persistable via Codable
struct KeyboardShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifierFlags: UInt32

    /// Default shortcut: ⌘⇧N
    static let `default` = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_N),
        modifierFlags: UInt32(cmdKey | shiftKey)
    )

    /// Human-readable display string (e.g. "⌘⇧N")
    var displayString: String {
        var parts: [String] = []
        if modifierFlags & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifierFlags & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifierFlags & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifierFlags & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Self.carbonKeyCodeToString(keyCode))
        return parts.joined()
    }

    /// Convert a Carbon key code to a readable string
    static func carbonKeyCodeToString(_ keyCode: UInt32) -> String {
        let specialKeys: [UInt32: String] = [
            UInt32(kVK_Return): "↩",
            UInt32(kVK_Tab): "⇥",
            UInt32(kVK_Space): "Space",
            UInt32(kVK_Delete): "⌫",
            UInt32(kVK_Escape): "⎋",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        ]
        if let special = specialKeys[keyCode] { return special }

        // Use TISCopyCurrentKeyboardInputSource to map keyCode → character
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self)
            let layoutPtr = CFDataGetBytePtr(layoutData)!
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length: Int = 0
            let status = UCKeyTranslate(
                layoutPtr.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 },
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0, UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            if status == noErr && length > 0 {
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
        }
        return "?"
    }

    /// Convert NSEvent modifier flags to Carbon modifier flags
    static func nsModifiersToCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }
}

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let toggleShortcut = "toggleShortcut"
        static let isShortcutEnabled = "isShortcutEnabled"
        static let showTotalSessionCount = "showTotalSessionCount"
        static let showActiveSessionCount = "showActiveSessionCount"
    }

    // MARK: - Notification Sound

    // MARK: - Global Shortcut

    /// Whether the global shortcut is enabled
    static var isShortcutEnabled: Bool {
        get {
            // Default to true if never set
            if defaults.object(forKey: Keys.isShortcutEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.isShortcutEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.isShortcutEnabled)
        }
    }

    /// The keyboard shortcut used to toggle the notch
    static var toggleShortcut: KeyboardShortcut {
        get {
            guard let data = defaults.data(forKey: Keys.toggleShortcut),
                  let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) else {
                return .default
            }
            return shortcut
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.toggleShortcut)
            }
        }
    }

    // MARK: - Session Counters

    /// Whether to show the total session count in the notch
    static var showTotalSessionCount: Bool {
        get {
            if defaults.object(forKey: Keys.showTotalSessionCount) == nil { return true }
            return defaults.bool(forKey: Keys.showTotalSessionCount)
        }
        set {
            defaults.set(newValue, forKey: Keys.showTotalSessionCount)
        }
    }

    /// Whether to show the active session count in the notch
    static var showActiveSessionCount: Bool {
        get {
            if defaults.object(forKey: Keys.showActiveSessionCount) == nil { return true }
            return defaults.bool(forKey: Keys.showActiveSessionCount)
        }
        set {
            defaults.set(newValue, forKey: Keys.showActiveSessionCount)
        }
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }
}
