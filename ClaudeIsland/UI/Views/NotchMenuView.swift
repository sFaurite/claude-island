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

private struct WingsElementsEditor: View {
    @Binding var elements: [WingElement]
    let onChange: ([WingElement]) -> Void

    @State private var draggingId: String?
    @State private var dragOffset: CGSize = .zero

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
    }

    @ViewBuilder
    private func wingLine(label: String, icon: String, side: WingSide) -> some View {
        let sideElements = elements.filter { $0.side == side }
        // Highlight the other line when dragging from the opposite side
        let isDropTarget = draggingId != nil
            && elements.first(where: { $0.id == draggingId })?.side != side

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
                    wingChip(element: element, side: side)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTarget ? Color.white.opacity(0.06) : Color.clear)
        )
    }

    @ViewBuilder
    private func wingChip(element: WingElement, side: WingSide) -> some View {
        let isDragging = draggingId == element.id

        Text(element.label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(element.visible ? TerminalColors.green : .white.opacity(0.4))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(element.visible ? Color.white.opacity(0.10) : Color.clear)
            )
            .opacity(isDragging ? 0.4 : 1.0)
            .offset(isDragging ? dragOffset : .zero)
            .zIndex(isDragging ? 10 : 0)
            .animation(.easeInOut(duration: 0.15), value: isDragging)
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        draggingId = element.id
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            handleDragEnd(
                                elementId: element.id,
                                translation: value.translation,
                                fromSide: side
                            )
                            draggingId = nil
                            dragOffset = .zero
                        }
                    }
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    guard draggingId == nil else { return }
                    if let idx = elements.firstIndex(where: { $0.id == element.id }) {
                        elements[idx].visible.toggle()
                        onChange(elements)
                    }
                }
            )
    }

    // MARK: - Drag Logic

    private func handleDragEnd(elementId: String, translation: CGSize, fromSide: WingSide) {
        // Vertical drag (> 25pt) → switch side
        if abs(translation.height) > 25 {
            moveToSide(elementId: elementId, newSide: fromSide == .left ? .right : .left)
            return
        }
        // Horizontal drag (> 30pt) → reorder within same side
        if abs(translation.width) > 30 {
            let steps = max(1, Int(abs(translation.width) / 40))
            let direction: Int = translation.width > 0 ? 1 : -1
            reorder(elementId: elementId, side: fromSide, direction: direction, steps: steps)
        }
    }

    private func moveToSide(elementId: String, newSide: WingSide) {
        guard let idx = elements.firstIndex(where: { $0.id == elementId }) else { return }
        var el = elements.remove(at: idx)
        el.side = newSide
        if let lastIdx = elements.lastIndex(where: { $0.side == newSide }) {
            elements.insert(el, at: lastIdx + 1)
        } else if newSide == .left {
            elements.insert(el, at: 0)
        } else {
            elements.append(el)
        }
        onChange(elements)
    }

    private func reorder(elementId: String, side: WingSide, direction: Int, steps: Int) {
        let sideIds = elements.filter { $0.side == side }.map(\.id)
        guard let sideIdx = sideIds.firstIndex(of: elementId) else { return }

        let targetSideIdx = min(max(sideIdx + direction * steps, 0), sideIds.count - 1)
        guard targetSideIdx != sideIdx else { return }

        guard let fromIdx = elements.firstIndex(where: { $0.id == elementId }),
              let toIdx = elements.firstIndex(where: { $0.id == sideIds[targetSideIdx] }) else { return }

        elements.move(fromOffsets: IndexSet(integer: fromIdx),
                      toOffset: toIdx > fromIdx ? toIdx + 1 : toIdx)
        onChange(elements)
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
