//
//  NotificationSoundPlayer.swift
//  ClaudeIsland
//
//  Plays notification sounds with a configurable volume cap (relative to system volume).
//

import AppKit
import Foundation

/// Plays notification sounds at a volume relative to the system volume.
/// The slider value (0.0–1.0) controls the fraction of system volume used.
class NotificationSoundPlayer {
    static let shared = NotificationSoundPlayer()

    private init() {}

    /// Play a system sound at the configured relative volume
    /// - Parameters:
    ///   - name: System sound name (e.g. "Pop", "Tink")
    ///   - volume: Relative volume (0.0–1.0). Defaults to AppSettings value.
    func play(sound name: String, volume: Float? = nil) {
        let vol = volume ?? AppSettings.maxNotificationVolume
        let sound = NSSound(named: name)
        sound?.volume = vol
        sound?.play()
    }
}
