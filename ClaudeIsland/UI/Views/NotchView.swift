//
//  NotchView.swift
//  ClaudeIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

struct NotchView: View {
    #if DEBUG
    /// Build timestamp from the executable's modification date
    private static let buildHash: String = {
        guard let execURL = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
              let modDate = attrs[.modificationDate] as? Date else { return "?" }
        let fmt = DateFormatter()
        fmt.dateFormat = "dd/MM HH:mm:ss"
        return fmt.string(from: modDate)
    }()
    #endif

    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitor = ClaudeSessionMonitor()
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @StateObject private var menuBarDetector = MenuBarDetector()
    @StateObject private var wingsController = NotchWingsController()
    @State private var previousPendingIds: Set<String> = []
    @State private var previousWaitingForInputIds: Set<String> = []
    @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false
    @State private var expandedWingSection: WingSection? = nil
    @AppStorage("showWingsInFullscreen") private var showWingsInFullscreen: Bool = true

    @Namespace private var activityNamespace

    /// Whether any Claude session is currently processing or compacting
    private var isAnyProcessing: Bool {
        sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
    }

    /// Whether any Claude session has a pending permission request
    private var hasPendingPermission: Bool {
        sessionMonitor.instances.contains { $0.phase.isWaitingForApproval }
    }

    /// Whether any Claude session is waiting for user input (done/ready state) within the display window
    private var hasWaitingForInput: Bool {
        let now = Date()
        let displayDuration: TimeInterval = 30  // Show checkmark for 30 seconds

        return sessionMonitor.instances.contains { session in
            guard session.phase == .waitingForInput else { return false }
            // Only show if within the 30-second display window
            if let enteredAt = waitingForInputTimestamps[session.stableId] {
                return now.timeIntervalSince(enteredAt) < displayDuration
            }
            return false
        }
    }

    private var totalSessionCount: Int { AppSettings.showTotalSessionCount ? sessionMonitor.instances.count : 0 }
    private var activeSessionCount: Int { AppSettings.showActiveSessionCount ? sessionMonitor.instances.filter { $0.phase.isActive }.count : 0 }

    private var processingCount: Int {
        sessionMonitor.instances.filter { $0.phase.isActive }.count
    }

    private var permissionCount: Int {
        sessionMonitor.instances.filter { $0.phase.isWaitingForApproval }.count
    }

    private var waitingForInputCount: Int {
        let now = Date()
        let displayDuration: TimeInterval = 30
        return sessionMonitor.instances.filter { session in
            guard session.phase == .waitingForInput else { return false }
            if let enteredAt = waitingForInputTimestamps[session.stableId] {
                return now.timeIntervalSince(enteredAt) < displayDuration
            }
            return false
        }.count
    }

    private var rightPillCount: Int {
        (isAnyProcessing ? 1 : 0) + (hasPendingPermission ? 1 : 0) + (hasWaitingForInput ? 1 : 0)
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        CGSize(
            width: viewModel.deviceNotchRect.width,
            height: viewModel.deviceNotchRect.height
        )
    }

    /// Extra width for expanding activities (like Dynamic Island)
    private var expansionWidth: CGFloat {
        guard showClosedActivity else { return 0 }
        let pillSpacing: CGFloat = 6
        let leftWidth = sideWidth
        let rightWidth = CGFloat(rightPillCount) * sideWidth + CGFloat(max(0, rightPillCount - 1)) * pillSpacing
        // Each side needs its content width PLUS the horizontal padding (14px)
        // so content lands outside the physical notch (no-pixel zone)
        let perSide = max(leftWidth, rightWidth) + cornerRadiusInsets.closed.bottom
        return 2 * perSide
    }

    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }

    /// Width of the closed content (notch + any expansion)
    private var closedContentWidth: CGFloat {
        closedNotchSize.width + expansionWidth
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Wings — behind the notch, visible when menu bar is hidden (fullscreen)
            if menuBarDetector.isMenuBarHidden && showWingsInFullscreen {
                NotchWingsView(
                    rateLimits: wingsController.rateLimits,
                    stats: wingsController.stats,
                    notchWidth: closedContentWidth,
                    height: closedNotchSize.height,
                    tick: wingsController.tick,
                    expandedSection: $expandedWingSection,
                    expandedHeight: Binding(
                        get: { viewModel.wingsExpandedHeight },
                        set: { viewModel.wingsExpandedHeight = $0 }
                    )
                )
                .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            }

            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                notchLayout
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        alignment: .top
                    )
                    .padding(
                        .horizontal,
                        viewModel.status == .opened
                            ? cornerRadiusInsets.opened.top
                            : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], viewModel.status == .opened ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: (viewModel.status == .opened || isHovering) ? .black.opacity(0.7) : .clear,
                        radius: 6
                    )
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        maxHeight: viewModel.status == .opened ? notchSize.height : nil,
                        alignment: .top
                    )
                    .animation(viewModel.status == .opened ? openAnimation : closeAnimation, value: viewModel.status)
                    .animation(openAnimation, value: notchSize) // Animate container size changes between content types
                    .animation(.smooth, value: activityCoordinator.expandingActivity)
                    .animation(.smooth, value: hasPendingPermission)
                    .animation(.smooth, value: hasWaitingForInput)
                    .animation(.smooth, value: isAnyProcessing)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            isHovering = hovering
                        }
                    }
                    .onTapGesture {
                        if viewModel.status != .opened {
                            viewModel.notchOpen(reason: .click)
                        }
                    }
            }
        }
        .opacity(isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            sessionMonitor.startMonitoring()
            // On non-notched devices, keep visible so users have a target to interact with
            if !viewModel.hasPhysicalNotch {
                isVisible = true
            }
            // Sync wings visibility
            viewModel.wingsVisible = menuBarDetector.isMenuBarHidden && showWingsInFullscreen
        }
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            handleStatusChange(from: oldStatus, to: newStatus)
            // Collapse expanded wing when notch opens
            if newStatus == .opened {
                expandedWingSection = nil
            }
        }
        .onChange(of: showWingsInFullscreen) { _, newValue in
            viewModel.wingsVisible = menuBarDetector.isMenuBarHidden && newValue
            if !newValue { expandedWingSection = nil }
        }
        .onChange(of: sessionMonitor.pendingInstances) { _, sessions in
            handlePendingSessionsChange(sessions)
        }
        .onChange(of: sessionMonitor.instances) { _, instances in
            handleProcessingChange()
            handleWaitingForInputChange(instances)
        }
        .onChange(of: menuBarDetector.isMenuBarHidden) { _, isHidden in
            if isHidden {
                wingsController.startAutoRefresh()
                isVisible = true
            } else {
                wingsController.stopAutoRefresh()
                expandedWingSection = nil
                // Let handleProcessingChange decide visibility
                handleProcessingChange()
            }
            viewModel.wingsVisible = isHidden && showWingsInFullscreen
        }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        activityCoordinator.expandingActivity.show && activityCoordinator.expandingActivity.type == .claude
    }

    /// Whether to show the expanded closed state (processing, pending permission, or waiting for input)
    private var showClosedActivity: Bool {
        isProcessing || hasPendingPermission || hasWaitingForInput
    }

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains crab and spinner that persist across states
            headerRow
                .frame(height: max(24, closedNotchSize.height))

            // Main content only when opened
            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 24) // Fixed width to prevent reflow
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )

                #if DEBUG
                Text("build \(Self.buildHash)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
                #endif
            }
        }
    }

    // MARK: - Header Row (persists across states)

    /// Width of the closed header content area (notch + expansion, minus horizontal padding)
    private var closedHeaderWidth: CGFloat {
        closedContentWidth - 2 * cornerRadiusInsets.closed.bottom
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 0) {
            // Left side - crab only (with total count below)
            if showClosedActivity {
                VStack(spacing: 1) {
                    ClaudeCrabIcon(size: 14, animateLegs: isAnyProcessing)
                        .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: showClosedActivity)

                    if totalSessionCount > 0 {
                        Text("\(totalSessionCount)")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.85, green: 0.47, blue: 0.34))
                    }
                }
                .frame(width: viewModel.status == .opened ? nil : sideWidth)
                .padding(.leading, viewModel.status == .opened ? 8 : 0)
            }

            // Center content
            if viewModel.status == .opened {
                // Opened: show header content
                openedHeaderContent
            } else if !showClosedActivity {
                // Closed without activity: empty space
                Rectangle()
                    .fill(.clear)
                    .frame(width: closedNotchSize.width - 20)
            } else {
                // Closed with activity: flexible spacer pushes left/right to edges
                Spacer(minLength: 0)
            }

            // Right side - HStack of conditional indicator pills
            if showClosedActivity {
                HStack(spacing: 6) {
                    if isAnyProcessing {
                        VStack(spacing: 1) {
                            ProcessingSpinner()
                                .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                            if processingCount > 0 {
                                Text("\(processingCount)")
                                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color(red: 0.85, green: 0.47, blue: 0.34))
                            }
                        }
                        .frame(width: viewModel.status == .opened ? nil : sideWidth)
                    }
                    if hasPendingPermission {
                        VStack(spacing: 1) {
                            PermissionIndicatorIcon(size: 14, color: Color(red: 0.85, green: 0.47, blue: 0.34))
                            if permissionCount > 0 {
                                Text("\(permissionCount)")
                                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color(red: 0.85, green: 0.47, blue: 0.34))
                            }
                        }
                        .frame(width: viewModel.status == .opened ? nil : sideWidth)
                    }
                    if hasWaitingForInput {
                        VStack(spacing: 1) {
                            ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
                            if waitingForInputCount > 0 {
                                Text("\(waitingForInputCount)")
                                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color(red: 0.85, green: 0.47, blue: 0.34))
                            }
                        }
                        .frame(width: viewModel.status == .opened ? nil : sideWidth)
                    }
                }
            }
        }
        .frame(
            width: showClosedActivity && viewModel.status != .opened
                ? closedHeaderWidth + (isBouncing ? 16 : 0)
                : nil,
            height: closedNotchSize.height
        )
    }

    private var sideWidth: CGFloat {
        max(0, closedNotchSize.height - 12) + 10
    }

    // MARK: - Opened Header Content

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 12) {
            // Total session count (left of crab)
            if totalSessionCount > 0 && !showClosedActivity {
                Text("\(totalSessionCount)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.85, green: 0.47, blue: 0.34))
                    .padding(.leading, 8)
            }

            // Show static crab only if not showing activity in headerRow
            // (headerRow handles crab + indicator when showClosedActivity is true)
            if !showClosedActivity {
                ClaudeCrabIcon(size: 14)
                    .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: !showClosedActivity)
                    .padding(.leading, totalSessionCount > 0 ? 0 : 8)
            }

            Spacer()

            // Menu toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.toggleMenu()
                    if viewModel.contentType == .menu {
                        updateManager.markUpdateSeen()
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())

                    // Green dot for unseen update
                    if updateManager.hasUnseenUpdate && viewModel.contentType != .menu {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        Group {
            switch viewModel.contentType {
            case .instances:
                ClaudeInstancesView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            case .menu:
                NotchMenuView(viewModel: viewModel)
            case .chat(let session):
                ChatView(
                    sessionId: session.sessionId,
                    initialSession: session,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            }
        }
        .frame(width: notchSize.width - 24) // Fixed width to prevent text reflow
        // Removed .id() - was causing view recreation and performance issues
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        if isAnyProcessing || hasPendingPermission {
            // Show claude activity when processing or waiting for permission
            activityCoordinator.showActivity(type: .claude)
            isVisible = true
        } else if hasWaitingForInput {
            // Keep visible for waiting-for-input but hide the processing spinner
            activityCoordinator.hideActivity()
            isVisible = true
        } else {
            // Hide activity when done
            activityCoordinator.hideActivity()

            // Delay hiding the notch until animation completes
            // Don't hide on non-notched devices - users need a visible target
            if viewModel.status == .closed && viewModel.hasPhysicalNotch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput && !menuBarDetector.isMenuBarHidden && viewModel.status == .closed {
                        isVisible = false
                    }
                }
            }
        }
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
            // Clear waiting-for-input timestamps only when manually opened (user acknowledged)
            if viewModel.openReason == .click || viewModel.openReason == .hover {
                waitingForInputTimestamps.removeAll()
            }
        case .closed:
            // Don't hide on non-notched devices - users need a visible target
            guard viewModel.hasPhysicalNotch else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if viewModel.status == .closed && !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput && !menuBarDetector.isMenuBarHidden && !activityCoordinator.expandingActivity.show {
                    isVisible = false
                }
            }
        }
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIds = Set(sessions.map { $0.stableId })
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        if !newPendingIds.isEmpty &&
           viewModel.status == .closed &&
           !TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace() {
            viewModel.notchOpen(reason: .notification)
        }

        previousPendingIds = currentIds
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        // Get sessions that are now waiting for input
        let waitingForInputSessions = instances.filter { $0.phase == .waitingForInput }
        let currentIds = Set(waitingForInputSessions.map { $0.stableId })
        let newWaitingIds = currentIds.subtracting(previousWaitingForInputIds)

        // Track timestamps for newly waiting sessions
        let now = Date()
        for session in waitingForInputSessions where newWaitingIds.contains(session.stableId) {
            waitingForInputTimestamps[session.stableId] = now
        }

        // Clean up timestamps for sessions no longer waiting
        let staleIds = Set(waitingForInputTimestamps.keys).subtracting(currentIds)
        for staleId in staleIds {
            waitingForInputTimestamps.removeValue(forKey: staleId)
        }

        // Bounce the notch when a session newly enters waitingForInput state
        if !newWaitingIds.isEmpty {
            // Get the sessions that just entered waitingForInput
            let newlyWaitingSessions = waitingForInputSessions.filter { newWaitingIds.contains($0.stableId) }

            // Play notification sound if the session is not actively focused
            if let soundName = AppSettings.notificationSound.soundName {
                // Check if we should play sound (async check for tmux pane focus)
                Task {
                    let shouldPlaySound = await shouldPlayNotificationSound(for: newlyWaitingSessions)
                    if shouldPlaySound {
                        await MainActor.run {
                            NotificationSoundPlayer.shared.play(sound: soundName)
                        }
                    }
                }
            }

            // Trigger bounce animation to get user's attention
            DispatchQueue.main.async {
                isBouncing = true
                // Bounce back after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isBouncing = false
                }
            }

            // Schedule hiding the checkmark after 30 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [self] in
                // Trigger a UI update to re-evaluate hasWaitingForInput
                handleProcessingChange()
            }
        }

        previousWaitingForInputIds = currentIds
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if ANY session is not actively focused
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus, assume not focused
                return true
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }

        return false
    }
}
