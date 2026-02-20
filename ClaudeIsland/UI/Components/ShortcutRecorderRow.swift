//
//  ShortcutRecorderRow.swift
//  ClaudeIsland
//
//  Configurable global keyboard shortcut row for the settings menu
//

import Carbon
import SwiftUI

struct ShortcutRecorderRow: View {
    let icon: String
    let label: String
    let hotkeyID: UInt32
    let getEnabled: () -> Bool
    let setEnabled: (Bool) -> Void
    let getShortcut: () -> KeyboardShortcut
    let setShortcut: (KeyboardShortcut) -> Void

    @State private var isEnabled: Bool = true
    @State private var shortcut: KeyboardShortcut = .default
    @State private var isRecording = false
    @State private var isHovered = false
    @State private var localMonitor: Any?

    var body: some View {
        VStack(spacing: 4) {
            // Toggle row
            Button {
                isEnabled.toggle()
                setEnabled(isEnabled)
                if isEnabled {
                    GlobalHotkeyManager.shared.register(shortcut: shortcut, id: hotkeyID)
                } else {
                    GlobalHotkeyManager.shared.unregister(id: hotkeyID)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Circle()
                        .fill(isEnabled ? TerminalColors.green : Color.white.opacity(0.3))
                        .frame(width: 6, height: 6)

                    Text(isEnabled ? "On" : "Off")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            // Shortcut recorder sub-row (only if enabled)
            if isEnabled {
                ShortcutRecorderField(
                    shortcut: $shortcut,
                    isRecording: $isRecording,
                    localMonitor: $localMonitor,
                    hotkeyID: hotkeyID,
                    getEnabled: getEnabled,
                    setShortcut: setShortcut
                )
                .padding(.leading, 28)
            }
        }
        .onAppear {
            isEnabled = getEnabled()
            shortcut = getShortcut()
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }

    private func stopRecording() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        isRecording = false
        // Re-register hotkey if enabled
        if isEnabled {
            GlobalHotkeyManager.shared.register(shortcut: shortcut, id: hotkeyID)
        }
    }
}

// MARK: - Shortcut Recorder Field

private struct ShortcutRecorderField: View {
    @Binding var shortcut: KeyboardShortcut
    @Binding var isRecording: Bool
    @Binding var localMonitor: Any?
    let hotkeyID: UInt32
    let getEnabled: () -> Bool
    let setShortcut: (KeyboardShortcut) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            HStack(spacing: 8) {
                if isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                    Text("Press shortcut…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                } else {
                    Text(shortcut.displayString)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                }

                Spacer()

                Text(isRecording ? "Esc to cancel" : "Click to change")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isRecording ? Color.white.opacity(0.12) : Color.white.opacity(isHovered ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isRecording ? Color.white.opacity(0.3) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private func startRecording() {
        // Unregister this hotkey during recording to avoid conflicts
        GlobalHotkeyManager.shared.unregister(id: hotkeyID)
        isRecording = true

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Require at least one modifier key
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])

            // Bare Escape (no modifiers) cancels recording
            if event.keyCode == UInt16(kVK_Escape) && modifiers.isEmpty {
                stopRecording()
                return nil
            }

            guard !modifiers.isEmpty else { return nil }

            let carbonModifiers = KeyboardShortcut.nsModifiersToCarbonModifiers(modifiers)
            let newShortcut = KeyboardShortcut(
                keyCode: UInt32(event.keyCode),
                modifierFlags: carbonModifiers
            )
            shortcut = newShortcut
            setShortcut(newShortcut)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        isRecording = false
        // Re-register hotkey
        if getEnabled() {
            GlobalHotkeyManager.shared.register(shortcut: shortcut, id: hotkeyID)
        }
    }
}
