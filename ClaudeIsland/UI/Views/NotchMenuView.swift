//
//  NotchMenuView.swift
//  ClaudeIsland
//
//  Minimal menu matching Dynamic Island aesthetic
//

import ApplicationServices
import Combine
import SwiftUI
import ServiceManagement
import Sparkle

// MARK: - Settings Tab

enum SettingsTab: String, CaseIterable {
    case appearance, shortcuts, system

    var label: String {
        switch self {
        case .appearance: return "Appearance"
        case .shortcuts:  return "Shortcuts"
        case .system:     return "System"
        }
    }

    var icon: String {
        switch self {
        case .appearance: return "paintbrush"
        case .shortcuts:  return "keyboard"
        case .system:     return "gearshape"
        }
    }
}

// MARK: - NotchMenuView

struct NotchMenuView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var soundSelector = SoundSelector.shared
    @State private var hooksInstalled: Bool = false
    @State private var launchAtLogin: Bool = false
    @State private var showTotalCount: Bool = AppSettings.showTotalSessionCount
    @State private var showActiveCount: Bool = AppSettings.showActiveSessionCount
    @State private var showWings: Bool = AppSettings.showWingsInFullscreen
    @State private var wingsFontSize: CGFloat = AppSettings.wingsFontSize
    @State private var wingsLayout: WingsLayout = AppSettings.wingsLayout
    @State private var wingsElements: [WingElement] = AppSettings.wingsElements

    var body: some View {
        VStack(spacing: 4) {
            // Back button
            MenuRow(
                icon: "chevron.left",
                label: "Back"
            ) {
                viewModel.toggleMenu()
            }

            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.vertical, 4)

            // Tab bar
            SettingsTabBar(selectedTab: $viewModel.selectedSettingsTab)

            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.vertical, 4)

            // Tab content
            Group {
                switch viewModel.selectedSettingsTab {
                case .appearance:
                    appearanceTab
                case .shortcuts:
                    shortcutsTab
                case .system:
                    systemTab
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.15), value: viewModel.selectedSettingsTab)

            Spacer(minLength: 0)

            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.vertical, 4)

            // Footer — always visible
            MenuRow(
                icon: "star",
                label: "Star on GitHub"
            ) {
                if let url = URL(string: "https://github.com/farouqaldori/claude-island") {
                    NSWorkspace.shared.open(url)
                }
            }

            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.vertical, 4)

            MenuRow(
                icon: "xmark.circle",
                label: "Quit",
                isDestructive: true
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            refreshStates()
        }
        .onChange(of: viewModel.contentType) { _, newValue in
            if newValue == .menu {
                refreshStates()
            }
        }
        .onChange(of: viewModel.selectedSettingsTab) { _, _ in
            screenSelector.isPickerExpanded = false
            soundSelector.isPickerExpanded = false
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var appearanceTab: some View {
        ScrollView {
            VStack(spacing: 0) {
                ScreenPickerRow(screenSelector: screenSelector)
                SoundPickerRow(soundSelector: soundSelector)
                MenuToggleRow(
                    icon: "number",
                    label: "Total Sessions",
                    isOn: showTotalCount
                ) {
                    showTotalCount.toggle()
                    AppSettings.showTotalSessionCount = showTotalCount
                }
                MenuToggleRow(
                    icon: "bolt.fill",
                    label: "Active Sessions",
                    isOn: showActiveCount
                ) {
                    showActiveCount.toggle()
                    AppSettings.showActiveSessionCount = showActiveCount
                }
                MenuToggleRow(
                    icon: "sidebar.squares.leading",
                    label: "Fullscreen Wings",
                    isOn: showWings
                ) {
                    showWings.toggle()
                    AppSettings.showWingsInFullscreen = showWings
                    viewModel.showWingsSettings = showWings
                }
                if showWings {
                    WingsLayoutRow(selected: $wingsLayout) { newValue in
                        AppSettings.wingsLayout = newValue
                    }
                    FontSizeRow(value: $wingsFontSize) { newValue in
                        AppSettings.wingsFontSize = newValue
                    }
                    WingsElementsEditor(elements: $wingsElements) { newElements in
                        AppSettings.wingsElements = newElements
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var shortcutsTab: some View {
        ShortcutRecorderRow(
            icon: "keyboard",
            label: "Global Shortcut",
            hotkeyID: 1,
            getEnabled: { AppSettings.isShortcutEnabled },
            setEnabled: { AppSettings.isShortcutEnabled = $0 },
            getShortcut: { AppSettings.toggleShortcut },
            setShortcut: { AppSettings.toggleShortcut = $0 }
        )
        ShortcutRecorderRow(
            icon: "eye.slash",
            label: "Hide Notch",
            hotkeyID: 2,
            getEnabled: { AppSettings.isHideShortcutEnabled },
            setEnabled: { AppSettings.isHideShortcutEnabled = $0 },
            getShortcut: { AppSettings.hideShortcut },
            setShortcut: { AppSettings.hideShortcut = $0 }
        )
    }

    @ViewBuilder
    private var systemTab: some View {
        MenuToggleRow(
            icon: "power",
            label: "Launch at Login",
            isOn: launchAtLogin
        ) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.unregister()
                    launchAtLogin = false
                } else {
                    try SMAppService.mainApp.register()
                    launchAtLogin = true
                }
            } catch {
                print("Failed to toggle launch at login: \(error)")
            }
        }
        MenuToggleRow(
            icon: "arrow.triangle.2.circlepath",
            label: "Hooks",
            isOn: hooksInstalled
        ) {
            if hooksInstalled {
                HookInstaller.uninstall()
                hooksInstalled = false
            } else {
                HookInstaller.installIfNeeded()
                hooksInstalled = true
            }
        }
        AccessibilityRow(isEnabled: AXIsProcessTrusted())
        UpdateRow(updateManager: updateManager)
    }

    private func refreshStates() {
        hooksInstalled = HookInstaller.isInstalled()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        screenSelector.refreshScreens()
        showWings = AppSettings.showWingsInFullscreen
        viewModel.showWingsSettings = showWings
        wingsElements = AppSettings.wingsElements
    }
}

// MARK: - Update Row

struct UpdateRow: View {
    @ObservedObject var updateManager: UpdateManager
    @State private var isHovered = false
    @State private var isSpinning = false

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    var body: some View {
        Button {
            handleTap()
        } label: {
            HStack(spacing: 10) {
                // Icon
                ZStack {
                    if case .installing = updateManager.state {
                        Image(systemName: "gear")
                            .font(.system(size: 12))
                            .foregroundColor(TerminalColors.blue)
                            .rotationEffect(.degrees(isSpinning ? 360 : 0))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isSpinning)
                            .onAppear { isSpinning = true }
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 12))
                            .foregroundColor(iconColor)
                    }
                }
                .frame(width: 16)

                // Label
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(labelColor)

                Spacer()

                // Right side: progress or status
                rightContent
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered && isInteractive ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.2), value: updateManager.state)
    }

    // MARK: - Right Content

    @ViewBuilder
    private var rightContent: some View {
        switch updateManager.state {
        case .idle:
            Text(appVersion)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))

        case .upToDate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(TerminalColors.green)
                Text("Up to date")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .checking, .installing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)

        case .found(let version, _):
            HStack(spacing: 6) {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 60)
                    .tint(TerminalColors.blue)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.blue)
                    .frame(width: 32, alignment: .trailing)
            }

        case .extracting(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 60)
                    .tint(TerminalColors.amber)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.amber)
                    .frame(width: 32, alignment: .trailing)
            }

        case .readyToInstall(let version):
            HStack(spacing: 6) {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .error:
            Text("Retry")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    // MARK: - Computed Properties

    private var icon: String {
        switch updateManager.state {
        case .idle:
            return "arrow.down.circle"
        case .checking:
            return "arrow.down.circle"
        case .upToDate:
            return "checkmark.circle.fill"
        case .found:
            return "arrow.down.circle.fill"
        case .downloading:
            return "arrow.down.circle"
        case .extracting:
            return "doc.zipper"
        case .readyToInstall:
            return "checkmark.circle.fill"
        case .installing:
            return "gear"
        case .error:
            return "exclamationmark.circle"
        }
    }

    private var iconColor: Color {
        switch updateManager.state {
        case .idle:
            return .white.opacity(isHovered ? 1.0 : 0.7)
        case .checking:
            return .white.opacity(0.7)
        case .upToDate:
            return TerminalColors.green
        case .found, .readyToInstall:
            return TerminalColors.green
        case .downloading:
            return TerminalColors.blue
        case .extracting:
            return TerminalColors.amber
        case .installing:
            return TerminalColors.blue
        case .error:
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
    }

    private var label: String {
        switch updateManager.state {
        case .idle:
            return "Check for Updates"
        case .checking:
            return "Checking..."
        case .upToDate:
            return "Check for Updates"
        case .found:
            return "Download Update"
        case .downloading:
            return "Downloading..."
        case .extracting:
            return "Extracting..."
        case .readyToInstall:
            return "Install & Relaunch"
        case .installing:
            return "Installing..."
        case .error:
            return "Update failed"
        }
    }

    private var labelColor: Color {
        switch updateManager.state {
        case .idle, .upToDate:
            return .white.opacity(isHovered ? 1.0 : 0.7)
        case .checking, .downloading, .extracting, .installing:
            return .white.opacity(0.9)
        case .found, .readyToInstall:
            return TerminalColors.green
        case .error:
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
    }

    private var isInteractive: Bool {
        switch updateManager.state {
        case .idle, .upToDate, .found, .readyToInstall, .error:
            return true
        case .checking, .downloading, .extracting, .installing:
            return false
        }
    }

    // MARK: - Actions

    private func handleTap() {
        switch updateManager.state {
        case .idle, .upToDate, .error:
            updateManager.checkForUpdates()
        case .found:
            updateManager.downloadAndInstall()
        case .readyToInstall:
            updateManager.installAndRelaunch()
        default:
            break
        }
    }
}

// MARK: - Accessibility Permission Row

struct AccessibilityRow: View {
    let isEnabled: Bool

    @State private var isHovered = false
    @State private var refreshTrigger = false

    private var currentlyEnabled: Bool {
        // Re-check on each render when refreshTrigger changes
        _ = refreshTrigger
        return isEnabled
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 12))
                .foregroundColor(textColor)
                .frame(width: 16)

            Text("Accessibility")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(textColor)

            Spacer()

            if isEnabled {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)

                Text("On")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                Button(action: openAccessibilitySettings) {
                    Text("Enable")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshTrigger.toggle()
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct MenuRow: View {
    let icon: String
    let label: String
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()
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
    }

    private var textColor: Color {
        if isDestructive {
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
        return .white.opacity(isHovered ? 1.0 : 0.7)
    }
}

// MARK: - Settings Tab Bar

private struct SettingsTabBar: View {
    @Binding var selectedTab: SettingsTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                SettingsTabButton(
                    tab: tab,
                    isSelected: selectedTab == tab
                ) {
                    selectedTab = tab
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12))
                Text(tab.label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isSelected ? TerminalColors.green : .white.opacity(isHovered ? 0.8 : 0.5))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.white.opacity(0.10) : (isHovered ? Color.white.opacity(0.05) : Color.clear))
            )
            .overlay(alignment: .bottom) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(TerminalColors.green)
                        .frame(width: 24, height: 2)
                        .offset(y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Wings Layout Row

private struct WingsLayoutRow: View {
    @Binding var selected: WingsLayout
    let onChange: (WingsLayout) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 16)

            Text("Layout")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.7))

            Spacer()

            HStack(spacing: 2) {
                ForEach(WingsLayout.allCases, id: \.self) { layout in
                    WingsLayoutButton(
                        layout: layout,
                        isSelected: selected == layout
                    ) {
                        selected = layout
                        onChange(layout)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct WingsLayoutButton: View {
    let layout: WingsLayout
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: layout.icon)
                    .font(.system(size: 10))
                Text(layout.label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isSelected ? TerminalColors.green : .white.opacity(isHovered ? 0.7 : 0.4))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.white.opacity(0.10) : (isHovered ? Color.white.opacity(0.05) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Font Size Row

private struct FontSizeRow: View {
    @Binding var value: CGFloat
    let onChange: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "textformat.size")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 16)

            Text("Font Size")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.7))

            Spacer()

            Text("\(Int(value))pt")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 30, alignment: .trailing)

            Slider(value: $value, in: 8...14, step: 1)
                .frame(width: 80)
                .tint(TerminalColors.green)
                .onChange(of: value) { _, newValue in
                    onChange(newValue)
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Wings Elements Editor (drag & drop between two lines)

// Preference key to collect chip frames in the editor coordinate space
private struct WingChipFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// Preference key to collect line frames
private struct WingLineFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct WingsElementsEditor: View {
    @Binding var elements: [WingElement]
    let onChange: ([WingElement]) -> Void

    @State private var draggingId: String?
    @State private var dragLocation: CGPoint = .zero
    @State private var dragGrabOffset: CGSize = .zero
    @State private var chipFrames: [String: CGRect] = [:]
    @State private var lineFrames: [String: CGRect] = [:]

    private var isDefault: Bool {
        elements == WingElement.defaultElements
    }

    var body: some View {
        VStack(spacing: 0) {
            wingLine(label: "Left Wing", icon: "chevron.left", side: .left)
            wingLine(label: "Right Wing", icon: "chevron.right", side: .right)
            if !isDefault {
                WingsResetButton {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        elements = WingElement.defaultElements
                        onChange(elements)
                    }
                }
            }
        }
        .coordinateSpace(name: "wingsEditor")
        .onPreferenceChange(WingChipFrameKey.self) { chipFrames = $0 }
        .onPreferenceChange(WingLineFrameKey.self) { lineFrames = $0 }
        // Gesture on the parent VStack — never destroyed when chips move between sides
        .simultaneousGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .named("wingsEditor"))
                .onChanged { value in
                    if draggingId == nil {
                        // Detect which chip was grabbed from start location
                        for (id, frame) in chipFrames {
                            if frame.contains(value.startLocation) {
                                draggingId = id
                                dragGrabOffset = CGSize(
                                    width: value.startLocation.x - frame.midX,
                                    height: value.startLocation.y - frame.midY
                                )
                                break
                            }
                        }
                        guard draggingId != nil else { return }
                    }
                    dragLocation = value.location
                    computeDropTarget(elementId: draggingId!)
                }
                .onEnded { _ in
                    if draggingId != nil {
                        onChange(elements)
                    }
                    draggingId = nil
                }
        )
        .overlay {
            if let id = draggingId, let element = elements.first(where: { $0.id == id }) {
                floatingChip(element)
                    .position(
                        x: dragLocation.x - dragGrabOffset.width,
                        y: dragLocation.y - dragGrabOffset.height
                    )
            }
        }
        .animation(.easeInOut(duration: 0.15), value: elements)
    }

    // MARK: - Floating chip overlay

    private func floatingChip(_ element: WingElement) -> some View {
        Text(element.label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(element.visible ? TerminalColors.green : .white.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(TerminalColors.green.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
            .scaleEffect(1.1)
    }

    // MARK: - Wing line

    @ViewBuilder
    private func wingLine(label: String, icon: String, side: WingSide) -> some View {
        let sideElements = elements.filter { $0.side == side }

        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 16)

            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.7))

            Spacer()

            HStack(spacing: 2) {
                ForEach(sideElements) { element in
                    wingChip(element: element)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: WingLineFrameKey.self,
                    value: [side.rawValue: geo.frame(in: .named("wingsEditor"))]
                )
            }
        )
    }

    // MARK: - Wing chip (in-flow, no DragGesture — gesture is on parent)

    @ViewBuilder
    private func wingChip(element: WingElement) -> some View {
        let isDragging = draggingId == element.id

        Text(element.label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(element.visible ? TerminalColors.green : .white.opacity(0.4))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isDragging
                          ? TerminalColors.green.opacity(0.08)
                          : (element.visible ? Color.white.opacity(0.10) : Color.clear))
            )
            .opacity(isDragging ? 0.3 : 1.0)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: WingChipFrameKey.self,
                        value: [element.id: geo.frame(in: .named("wingsEditor"))]
                    )
                }
            )
            .onTapGesture {
                guard draggingId == nil else { return }
                if let idx = elements.firstIndex(where: { $0.id == element.id }) {
                    elements[idx].visible.toggle()
                    onChange(elements)
                }
            }
    }

    // MARK: - Drop target computation

    private func computeDropTarget(elementId: String) {
        let leftFrame = lineFrames["left"] ?? .zero
        let rightFrame = lineFrames["right"] ?? .zero
        let cursorY = dragLocation.y - dragGrabOffset.height

        // Determine target side from cursor proximity to each line
        let targetSide: WingSide
        let distToLeft = abs(cursorY - leftFrame.midY)
        let distToRight = abs(cursorY - rightFrame.midY)
        targetSide = distToLeft <= distToRight ? .left : .right

        // Get other chips on target side for X-based positioning
        let sideChips = elements.filter { $0.side == targetSide && $0.id != elementId }
        let cursorX = dragLocation.x - dragGrabOffset.width

        // Find insertion point: before the first chip whose center is right of cursor
        var insertBeforeId: String? = nil
        for chip in sideChips {
            if let frame = chipFrames[chip.id], cursorX < frame.midX {
                insertBeforeId = chip.id
                break
            }
        }

        // Build updated array
        guard let sourceIdx = elements.firstIndex(where: { $0.id == elementId }) else { return }
        var updated = elements
        var el = updated.remove(at: sourceIdx)
        el.side = targetSide

        if let beforeId = insertBeforeId,
           let insertIdx = updated.firstIndex(where: { $0.id == beforeId }) {
            updated.insert(el, at: insertIdx)
        } else {
            if let lastIdx = updated.lastIndex(where: { $0.side == targetSide }) {
                updated.insert(el, at: lastIdx + 1)
            } else if targetSide == .left {
                updated.insert(el, at: 0)
            } else {
                updated.append(el)
            }
        }

        if updated != elements {
            elements = updated
        }
    }
}

private struct WingsResetButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 9))
                Text("Reset")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isHovered ? .white.opacity(0.7) : .white.opacity(0.4))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.05) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

struct MenuToggleRow: View {
    let icon: String
    let label: String
    let isOn: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
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
                    .fill(isOn ? TerminalColors.green : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)

                Text(isOn ? "On" : "Off")
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
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }
}
