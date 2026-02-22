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

    /// Default toggle shortcut: ⌘⇧N
    static let `default` = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_N),
        modifierFlags: UInt32(cmdKey | shiftKey)
    )

    /// Default hide shortcut: ⌘⇧H
    static let defaultHide = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_H),
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

// MARK: - Wing Elements

enum WingSide: String, Codable {
    case left, right
}

struct WingElement: Codable, Identifiable, Equatable {
    let id: String        // "5h", "7j", "heatmap", "tokensAllTime", "tokensToday", "lastDay", "record"
    var side: WingSide    // .left or .right
    var visible: Bool     // toggle on/off

    /// Display label for the element chip
    var label: String {
        switch id {
        case "5h":            return "5h"
        case "7j":            return "7j"
        case "heatmap":       return "Heatmap"
        case "tokensAllTime": return "All Time"
        case "tokensToday":   return "Today"
        case "lastDay":       return "Last Day"
        case "record":        return "Record"
        default:              return id
        }
    }

    static let defaultElements: [WingElement] = [
        WingElement(id: "5h",            side: .left,  visible: true),
        WingElement(id: "7j",            side: .left,  visible: true),
        WingElement(id: "heatmap",       side: .right, visible: true),
        WingElement(id: "tokensAllTime", side: .right, visible: true),
        WingElement(id: "tokensToday",   side: .right, visible: true),
        WingElement(id: "lastDay",       side: .right, visible: true),
        WingElement(id: "record",        side: .right, visible: true),
    ]
}

/// Which wings to display in fullscreen mode
enum WingsLayout: String, CaseIterable {
    case both, left, right

    var label: String {
        switch self {
        case .both:  return "Both"
        case .left:  return "Left"
        case .right: return "Right"
        }
    }

    var icon: String {
        switch self {
        case .both:  return "rectangle.split.3x1"
        case .left:  return "rectangle.lefthalf.filled"
        case .right: return "rectangle.righthalf.filled"
        }
    }

    var showLeft: Bool { self == .both || self == .left }
    var showRight: Bool { self == .both || self == .right }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let toggleShortcut = "toggleShortcut"
        static let isShortcutEnabled = "isShortcutEnabled"
        static let hideShortcut = "hideShortcut"
        static let isHideShortcutEnabled = "isHideShortcutEnabled"
        static let showTotalSessionCount = "showTotalSessionCount"
        static let showActiveSessionCount = "showActiveSessionCount"
        static let maxNotificationVolume = "maxNotificationVolume"
        static let showWingsInFullscreen = "showWingsInFullscreen"
        static let wingsFontSize = "wingsFontSize"
        static let wingsLayout = "wingsLayout"
        static let wingsElements = "wingsElements"
        // Legacy keys (used for migration only)
        static let wingsShow5h = "wingsShow5h"
        static let wingsShow7j = "wingsShow7j"
        static let wingsShowHeatmap = "wingsShowHeatmap"
        static let wingsShowTokens = "wingsShowTokens"
        static let wingsShowDaily = "wingsShowDaily"
        static let wingsShowRecord = "wingsShowRecord"
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

    // MARK: - Hide Shortcut

    /// Whether the hide shortcut is enabled
    static var isHideShortcutEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.isHideShortcutEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.isHideShortcutEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.isHideShortcutEnabled)
        }
    }

    /// The keyboard shortcut used to hide/show the notch window
    static var hideShortcut: KeyboardShortcut {
        get {
            guard let data = defaults.data(forKey: Keys.hideShortcut),
                  let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) else {
                return .defaultHide
            }
            return shortcut
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.hideShortcut)
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

    // MARK: - Wings (Fullscreen)

    /// Whether to show the notch wings in fullscreen mode
    static var showWingsInFullscreen: Bool {
        get {
            if defaults.object(forKey: Keys.showWingsInFullscreen) == nil { return true }
            return defaults.bool(forKey: Keys.showWingsInFullscreen)
        }
        set {
            defaults.set(newValue, forKey: Keys.showWingsInFullscreen)
        }
    }

    /// Font size for the notch wings content (8.0–14.0)
    static var wingsFontSize: CGFloat {
        get {
            if defaults.object(forKey: Keys.wingsFontSize) == nil { return 10 }
            return CGFloat(defaults.float(forKey: Keys.wingsFontSize))
        }
        set {
            defaults.set(Float(newValue), forKey: Keys.wingsFontSize)
        }
    }

    /// Which wings to show (both, left only, right only)
    static var wingsLayout: WingsLayout {
        get {
            guard let rawValue = defaults.string(forKey: Keys.wingsLayout),
                  let layout = WingsLayout(rawValue: rawValue) else {
                return .both
            }
            return layout
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.wingsLayout)
        }
    }

    // MARK: - Wings Elements (ordered, side-assignable)

    /// Ordered list of wing elements with side and visibility
    static var wingsElements: [WingElement] {
        get {
            if let data = defaults.data(forKey: Keys.wingsElements),
               var elements = try? JSONDecoder().decode([WingElement].self, from: data) {
                // Migrate old "tokens" → "tokensAllTime" + "tokensToday"
                if let idx = elements.firstIndex(where: { $0.id == "tokens" }) {
                    let old = elements[idx]
                    let allTime = WingElement(id: "tokensAllTime", side: old.side, visible: old.visible)
                    let today = WingElement(id: "tokensToday", side: old.side, visible: old.visible)
                    elements.replaceSubrange(idx...idx, with: [allTime, today])
                    if let data = try? JSONEncoder().encode(elements) {
                        defaults.set(data, forKey: Keys.wingsElements)
                    }
                }
                return elements
            }
            // Migration: build from legacy booleans
            return migrateWingsElements()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.wingsElements)
            }
        }
    }

    /// Migrate from legacy individual booleans to the new ordered array
    private static func migrateWingsElements() -> [WingElement] {
        func legacyBool(_ key: String) -> Bool {
            if defaults.object(forKey: key) == nil { return true }
            return defaults.bool(forKey: key)
        }

        let tokensVisible = legacyBool(Keys.wingsShowTokens)
        let elements: [WingElement] = [
            WingElement(id: "5h",            side: .left,  visible: legacyBool(Keys.wingsShow5h)),
            WingElement(id: "7j",            side: .left,  visible: legacyBool(Keys.wingsShow7j)),
            WingElement(id: "heatmap",       side: .right, visible: legacyBool(Keys.wingsShowHeatmap)),
            WingElement(id: "tokensAllTime", side: .right, visible: tokensVisible),
            WingElement(id: "tokensToday",   side: .right, visible: tokensVisible),
            WingElement(id: "lastDay",       side: .right, visible: legacyBool(Keys.wingsShowDaily)),
            WingElement(id: "record",        side: .right, visible: legacyBool(Keys.wingsShowRecord)),
        ]

        // Persist the migrated data
        if let data = try? JSONEncoder().encode(elements) {
            defaults.set(data, forKey: Keys.wingsElements)
        }

        return elements
    }

    // MARK: - Max Notification Volume

    /// Maximum volume for notification sounds (0.0–1.0). Acts as a cap over system volume.
    static var maxNotificationVolume: Float {
        get {
            if defaults.object(forKey: Keys.maxNotificationVolume) == nil { return 0.5 }
            return defaults.float(forKey: Keys.maxNotificationVolume)
        }
        set {
            defaults.set(newValue, forKey: Keys.maxNotificationVolume)
        }
    }
}
