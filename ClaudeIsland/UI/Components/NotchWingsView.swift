//
//  NotchWingsView.swift
//  ClaudeIsland
//
//  Wings displayed on each side of the notch when menu bar is hidden (fullscreen)
//  Left wing: Anthropic rate limits  |  Right wing: activity heatmap + daily stats
//

import Combine
import SwiftUI
import os.log

// MARK: - Controller

@MainActor
final class NotchWingsController: ObservableObject {
    @Published var rateLimits: RateLimitData?
    @Published var stats: DailyStats?
    @Published var tick: Bool = false // forces view refresh for staleness check

    private static let logger = Logger(subsystem: "com.claudeisland", category: "NotchWingsController")
    private var refreshTimer: Timer?
    private var tickTimer: Timer?

    func refresh() {
        Task {
            async let rl = fetchRateLimits()
            async let st = Task.detached { StatsReader.read() }.value

            rateLimits = await rl
            stats = await st
        }
    }

    func startAutoRefresh() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        // Tick every 30s to re-evaluate staleness in the view
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick.toggle()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func fetchRateLimits() async -> RateLimitData? {
        do {
            let data = try await RateLimitService.shared.fetch()
            return data
        } catch {
            Self.logger.warning("Rate limit fetch failed: \(error.localizedDescription)")
            return rateLimits
        }
    }
}

// MARK: - Wing Section

enum WingSection: Equatable {
    case rateLimit5h, rateLimit7j, overage
    case heatmap, tokens, daily, record

    var isLeft: Bool {
        switch self {
        case .rateLimit5h, .rateLimit7j, .overage: return true
        case .heatmap, .tokens, .daily, .record: return false
        }
    }
}

// MARK: - Wings View

struct NotchWingsView: View {
    let rateLimits: RateLimitData?
    let stats: DailyStats?
    let notchWidth: CGFloat
    let height: CGFloat
    var tick: Bool = false // triggers re-render for staleness
    @Binding var expandedSection: WingSection?
    @Binding var expandedHeight: CGFloat

    @AppStorage("wingsLayout") private var wingsLayoutRaw: String = WingsLayout.both.rawValue
    @AppStorage("wingsFontSize") private var fontSizeRaw: Double = 10
    @AppStorage("wingsShow5h") private var show5h: Bool = true
    @AppStorage("wingsShow7j") private var show7j: Bool = true
    @AppStorage("wingsShowHeatmap") private var showHeatmap: Bool = true
    @AppStorage("wingsShowTokens") private var showTokens: Bool = true
    @AppStorage("wingsShowDaily") private var showDaily: Bool = true
    @AppStorage("wingsShowRecord") private var showRecord: Bool = true

    private var layout: WingsLayout { WingsLayout(rawValue: wingsLayoutRaw) ?? .both }
    private var fontSize: CGFloat { CGFloat(fontSizeRaw) }
    private var wingFont: Font { Font.system(size: fontSize, weight: .medium, design: .monospaced) }
    private var smallFont: Font { Font.system(size: fontSize - 1, weight: .medium, design: .monospaced) }
    private var boldFont: Font { Font.system(size: fontSize - 1, weight: .bold, design: .monospaced) }
    private let wingPadding: CGFloat = 8
    private let wingCornerRadius: CGFloat = 6
    private let detailPanelHeight: CGFloat = 108

    var body: some View {
        let _ = tick // consumed to trigger re-render for staleness
        HStack(alignment: .top, spacing: 0) {
            if layout.showLeft {
                VStack(alignment: .trailing, spacing: 4) {
                    leftWingBar
                    if let section = expandedSection, section.isLeft {
                        leftDetailPanel(for: section)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }

            Color.clear
                .frame(width: notchWidth + 16, height: height)
                .allowsHitTesting(false)

            if layout.showRight {
                VStack(alignment: .leading, spacing: 4) {
                    rightWingBar
                    if let section = expandedSection, !section.isLeft {
                        rightDetailPanel(for: section)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 8)
        .background(alignment: .top) {
            Color.black
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: expandedSection)
        .onChange(of: expandedSection) { _, newValue in
            expandedHeight = newValue != nil ? detailPanelHeight + 8 : 0
        }
    }

    // MARK: - Toggle

    private func toggleSection(_ section: WingSection) {
        if expandedSection == section {
            expandedSection = nil
        } else {
            expandedSection = section
        }
    }

    private var wingBackground: some View {
        RoundedRectangle(cornerRadius: wingCornerRadius)
            .fill(.black.opacity(0.7))
            .background(
                RoundedRectangle(cornerRadius: wingCornerRadius)
                    .fill(.ultraThinMaterial)
            )
    }

    // MARK: - Left Wing Bar (Rate Limits)

    private let staleThreshold: TimeInterval = 600 // 10 minutes

    private var leftWingBar: some View {
        HStack(spacing: 8) {
            if let rl = rateLimits {
                // Stale warning at the far left
                if rl.fetchedAt.timeIntervalSinceNow < -staleThreshold {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: fontSize - 2))
                        Text(formatElapsed(since: rl.fetchedAt))
                            .font(smallFont)
                    }
                    .foregroundColor(TerminalColors.amber)
                    .allowsHitTesting(false)
                }

                if show5h {
                    rateLimitPill(label: "5h", utilization: rl.fiveHourUtilization, reset: rl.fiveHourReset, forceUnit: nil, windowSeconds: 5 * 3600)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleSection(.rateLimit5h) }
                }
                if show7j {
                    rateLimitPill(label: "7j", utilization: rl.sevenDayUtilization, reset: rl.sevenDayReset, forceUnit: .days, windowSeconds: 7 * 86400)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleSection(.rateLimit7j) }
                }
                if rl.overageUtilization > 0 {
                    overagePill(utilization: rl.overageUtilization)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleSection(.overage) }
                }
            } else {
                Text("—")
                    .font(wingFont)
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, wingPadding)
        .padding(.vertical, 4)
        .frame(height: height)
        .background(wingBackground)
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    // MARK: - Right Wing Bar (Heatmap + Stats)

    private var rightWingBar: some View {
        HStack(spacing: 6) {
            if let st = stats {
                rightWingBarContent(st)
            } else {
                Text("—")
                    .font(wingFont)
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, wingPadding)
        .padding(.vertical, 4)
        .frame(height: height)
        .background(wingBackground)
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    @ViewBuilder
    private func rightWingBarContent(_ st: DailyStats) -> some View {
        if showHeatmap {
            ActivityHeatmap(entries: st.heatmapEntries)
                .contentShape(Rectangle())
                .onTapGesture { toggleSection(.heatmap) }
        }

        if showHeatmap && (showTokens || showDaily || showRecord) {
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 20)
                .allowsHitTesting(false)
        }

        if showTokens {
            HStack(spacing: 4) {
                Text("Σ " + formatTokens(st.totalTokensAllTime))
                    .font(boldFont).foregroundColor(.white.opacity(0.5))
                if st.todayLiveTokens > 0 {
                    Text("·").font(wingFont).foregroundColor(.white.opacity(0.2))
                    Text("⇡ " + formatTokens(st.todayLiveTokens))
                        .font(boldFont).foregroundColor(.white.opacity(0.7))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleSection(.tokens) }
        }

        if showTokens && (showDaily || showRecord) {
            Text("·").font(wingFont).foregroundColor(.white.opacity(0.2))
                .allowsHitTesting(false)
        }

        if showDaily, let lastDate = st.lastDayDate {
            HStack(spacing: 4) {
                Text(formatShortDate(lastDate))
                    .font(boldFont).foregroundColor(.white.opacity(0.35))
                Text("\(st.lastDayMessages) msgs")
                    .font(wingFont).foregroundColor(.white.opacity(0.5))
                Text("·").font(wingFont).foregroundColor(.white.opacity(0.2))
                Text("\(st.lastDaySessions) sess")
                    .font(wingFont).foregroundColor(.white.opacity(0.5))
                Text("·").font(wingFont).foregroundColor(.white.opacity(0.2))
                Text(formatTokens(st.lastDayTokens))
                    .font(wingFont).foregroundColor(.white.opacity(0.5))
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleSection(.daily) }
        }

        if showRecord && st.recordTokens > 0 {
            if showDaily || showTokens || showHeatmap {
                Text("·").font(wingFont).foregroundColor(.white.opacity(0.2))
                    .allowsHitTesting(false)
            }
            HStack(spacing: 2) {
                Text("🏆").font(.system(size: fontSize - 3))
                Text(formatShortDate(st.recordDate) + " " + formatTokens(st.recordTokens))
                    .font(smallFont)
            }
            .foregroundColor(TerminalColors.amber.opacity(0.7))
            .contentShape(Rectangle())
            .onTapGesture { toggleSection(.record) }
        }
    }

    // MARK: - Left Detail Panel

    @ViewBuilder
    private func leftDetailPanel(for section: WingSection) -> some View {
        if let rl = rateLimits {
            switch section {
            case .rateLimit5h:
                rateLimitDetail(title: "Rate Limit 5h", utilization: rl.fiveHourUtilization, reset: rl.fiveHourReset, windowSeconds: 5 * 3600)
            case .rateLimit7j:
                rateLimitDetail(title: "Rate Limit 7j", utilization: rl.sevenDayUtilization, reset: rl.sevenDayReset, windowSeconds: 7 * 86400)
            case .overage:
                overageDetail(utilization: rl.overageUtilization)
            default:
                EmptyView()
            }
        }
    }

    private func rateLimitDetail(title: String, utilization: Double, reset: Date, windowSeconds: TimeInterval) -> some View {
        let timeRemaining = max(0, reset.timeIntervalSinceNow)
        let elapsed = windowSeconds - timeRemaining
        let expectedUtil = min(1.0, max(0, elapsed / windowSeconds))
        let isOverExpected = utilization > expectedUtil

        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))

            progressBar(utilization: utilization, expectedUtilization: expectedUtil, barWidth: 180, barHeight: 5)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Utilisé").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text("\(Int(utilization * 100))%")
                        .font(boldFont)
                        .foregroundColor(colorForUtilization(utilization, expected: expectedUtil))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Attendu").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text("\(Int(expectedUtil * 100))%")
                        .font(boldFont).foregroundColor(.white.opacity(0.6))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reset").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text(formatDetailedResetTime(reset))
                        .font(boldFont).foregroundColor(.white.opacity(0.6))
                }
            }

            if isOverExpected {
                Text("▲ +\(Int((utilization - expectedUtil) * 100))% au-dessus de l'attendu")
                    .font(smallFont).foregroundColor(TerminalColors.red.opacity(0.8))
            } else {
                Text("✓ Sous le rythme attendu")
                    .font(smallFont).foregroundColor(TerminalColors.green.opacity(0.8))
            }
        }
        .padding(10)
        .background(wingBackground)
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    private func overageDetail(utilization: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(TerminalColors.red)
                Text("Overage Actif")
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundColor(TerminalColors.red.opacity(0.9))
            }

            progressBar(utilization: utilization, expectedUtilization: 0, barWidth: 180, barHeight: 5)

            Text("Utilisation : \(Int(utilization * 100))%")
                .font(boldFont).foregroundColor(TerminalColors.red.opacity(0.8))

            Text("Dépassement du quota inclus")
                .font(smallFont).foregroundColor(.white.opacity(0.5))
        }
        .padding(10)
        .background(wingBackground)
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    // MARK: - Right Detail Panel

    @ViewBuilder
    private func rightDetailPanel(for section: WingSection) -> some View {
        if let st = stats {
            switch section {
            case .heatmap:
                heatmapDetail(st)
            case .tokens:
                tokensDetail(st)
            case .daily:
                dailyDetail(st)
            case .record:
                recordDetail(st)
            default:
                EmptyView()
            }
        }
    }

    private func heatmapDetail(_ st: DailyStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activité")
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))

            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 1) {
                    ForEach(Array(["L", "Ma", "Me", "J", "V", "S", "D"].enumerated()), id: \.offset) { _, day in
                        Text(day)
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 12, height: 6)
                    }
                }
                DetailActivityHeatmap(
                    entries: st.heatmapEntries,
                    recordDate: parseDate(st.recordDate),
                    cellSize: 6,
                    cellGap: 1
                )
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, 10)
        .padding(.trailing, 20)
        .background(wingBackground)
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    private func tokensDetail(_ st: DailyStats) -> some View {
        let dayCount = max(1, st.heatmapEntries.count)
        let avgPerDay = st.totalTokensAllTime / dayCount

        return VStack(alignment: .leading, spacing: 8) {
            Text("Tokens")
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("All-time").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text(formatTokens(st.totalTokensAllTime))
                        .font(boldFont).foregroundColor(.white.opacity(0.7))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aujourd'hui").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text(formatTokens(st.todayLiveTokens > 0 ? st.todayLiveTokens : st.totalTokens))
                        .font(boldFont).foregroundColor(.white.opacity(0.7))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Moy/jour").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text("~" + formatTokens(avgPerDay))
                        .font(boldFont).foregroundColor(.white.opacity(0.6))
                }
            }

            HStack(spacing: 4) {
                Text("\(dayCount) jours d'activité")
                    .font(smallFont).foregroundColor(.white.opacity(0.4))
                Text("·").font(smallFont).foregroundColor(.white.opacity(0.2))
                Text("\(st.totalMessagesAllTime) msgs all-time")
                    .font(smallFont).foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(10)
        .background(wingBackground)
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    private func dailyDetail(_ st: DailyStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lastDate = st.lastDayDate {
                Text(formatShortDate(lastDate))
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Messages").font(smallFont).foregroundColor(.white.opacity(0.4))
                        Text("\(st.lastDayMessages)")
                            .font(boldFont).foregroundColor(.white.opacity(0.7))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sessions").font(smallFont).foregroundColor(.white.opacity(0.4))
                        Text("\(st.lastDaySessions)")
                            .font(boldFont).foregroundColor(.white.opacity(0.7))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tool calls").font(smallFont).foregroundColor(.white.opacity(0.4))
                        Text("\(st.lastDayToolCalls)")
                            .font(boldFont).foregroundColor(.white.opacity(0.7))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tokens").font(smallFont).foregroundColor(.white.opacity(0.4))
                        Text(formatTokens(st.lastDayTokens))
                            .font(boldFont).foregroundColor(.white.opacity(0.7))
                    }
                }
            } else {
                Text("Pas de données")
                    .font(smallFont).foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(10)
        .background(wingBackground)
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    private func recordDetail(_ st: DailyStats) -> some View {
        let todayTokens = st.todayLiveTokens > 0 ? st.todayLiveTokens : st.totalTokens
        let pctOfRecord = st.recordTokens > 0 ? Double(todayTokens) / Double(st.recordTokens) * 100 : 0

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("🏆").font(.system(size: fontSize))
                Text("Record")
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundColor(TerminalColors.amber.opacity(0.9))
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Date").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text(formatShortDate(st.recordDate))
                        .font(boldFont).foregroundColor(TerminalColors.amber.opacity(0.7))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tokens").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text(formatTokens(st.recordTokens))
                        .font(boldFont).foregroundColor(TerminalColors.amber.opacity(0.7))
                }
            }

            if st.isToday {
                Text("Aujourd'hui : \(formatTokens(todayTokens)) (\(Int(pctOfRecord))% du record)")
                    .font(smallFont).foregroundColor(.white.opacity(0.5))
            }
        }
        .padding(10)
        .background(wingBackground)
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    // MARK: - Rate Limit Pill

    private enum ResetUnit { case days }

    private func rateLimitPill(label: String, utilization: Double, reset: Date, forceUnit: ResetUnit?, windowSeconds: TimeInterval) -> some View {
        let timeRemaining = max(0, reset.timeIntervalSinceNow)
        let elapsed = windowSeconds - timeRemaining
        let expectedUtil = min(1.0, max(0, elapsed / windowSeconds))

        return HStack(spacing: 4) {
            Text(label)
                .font(boldFont)
                .foregroundColor(.white.opacity(0.5))

            progressBar(utilization: utilization, expectedUtilization: expectedUtil)

            (Text("\(Int(utilization * 100))%")
                .foregroundColor(colorForUtilization(utilization, expected: expectedUtil).opacity(0.9))
            + Text(" \(formatResetTime(reset, forceUnit: forceUnit))")
                .foregroundColor(.white.opacity(0.4)))
                .font(smallFont)

            Text("↻")
                .font(smallFont)
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private func overagePill(utilization: Double) -> some View {
        HStack(spacing: 4) {
            Text("ovg")
                .font(boldFont)
                .foregroundColor(TerminalColors.red.opacity(0.7))

            Text("\(Int(utilization * 100))%")
                .font(smallFont)
                .foregroundColor(TerminalColors.red.opacity(0.9))
        }
    }

    // MARK: - Progress Bar

    private func progressBar(utilization: Double, expectedUtilization: Double, barWidth: CGFloat = 40, barHeight: CGFloat = 3) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let actual = min(utilization, 1.0)
            let expected = min(expectedUtilization, 1.0)
            let isOver = actual > expected

            ZStack(alignment: .leading) {
                // Background
                Capsule()
                    .fill(.white.opacity(0.15))
                    .frame(height: barHeight)

                if isOver {
                    // Green portion up to expected
                    Capsule()
                        .fill(TerminalColors.green)
                        .frame(width: max(1, w * expected), height: barHeight)

                    // Red overshoot from expected to actual
                    Capsule()
                        .fill(TerminalColors.red)
                        .frame(width: max(1, w * actual), height: barHeight)
                        .mask(
                            HStack(spacing: 0) {
                                Color.clear.frame(width: w * expected)
                                Color.white
                            }
                        )
                } else {
                    // All green — under expected
                    Capsule()
                        .fill(TerminalColors.green)
                        .frame(width: max(1, w * actual), height: barHeight)
                }

                // Amber marker line at expected position
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(TerminalColors.amber)
                    .frame(width: 1, height: barHeight + 2)
                    .offset(x: w * expected - 0.5)
            }
        }
        .frame(width: barWidth, height: barHeight + 2)
    }

    // MARK: - Helpers

    private func colorForUtilization(_ util: Double, expected: Double? = nil) -> Color {
        if let exp = expected, util > exp {
            return TerminalColors.red
        }
        if util < 0.5 { return TerminalColors.green }
        if util < 0.8 { return TerminalColors.amber }
        return TerminalColors.red
    }

    private func formatResetTime(_ date: Date, forceUnit: ResetUnit? = nil) -> String {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "" }

        if forceUnit == .days {
            let days = interval / 86400
            if days >= 1 {
                return String(format: "%.0fj", days)
            }
            // Less than 1 day: fall through to h/m format
        }

        let minutes = Int(interval) / 60
        if minutes < 60 { return "\(max(1, minutes))m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)j"
    }

    private func formatShortDate(_ dateStr: String) -> String {
        let parts = dateStr.split(separator: "-")
        guard parts.count == 3 else { return dateStr }
        return "\(parts[2])/\(parts[1])"
    }

    private func formatDetailedResetTime(_ date: Date) -> String {
        let interval = max(0, date.timeIntervalSinceNow)
        let totalMinutes = Int(interval) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(max(1, minutes))m"
    }

    private func formatElapsed(since date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return "\(hours)h"
    }

    private func parseDate(_ dateStr: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current
        return fmt.date(from: dateStr)
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// MARK: - Activity Heatmap

private struct ActivityHeatmap: View {
    let entries: [HeatmapEntry]
    var cellSize: CGFloat = 3
    var cellGap: CGFloat = 1

    var body: some View {
        let grid = buildGrid()
        let maxCount = entries.map(\.tokenCount).max() ?? 1
        let step = cellSize + cellGap

        Canvas { context, size in
            for col in 0..<grid.count {
                for row in 0..<7 {
                    let x = CGFloat(col) * step
                    let y = CGFloat(row) * step
                    let rect = CGRect(x: x, y: y, width: cellSize, height: cellSize)
                    let count = grid[col][row]
                    context.fill(
                        RoundedRectangle(cornerRadius: cellSize > 4 ? 1 : 0.5).path(in: rect),
                        with: .color(colorForCount(count, max: maxCount))
                    )
                }
            }
        }
        .frame(
            width: CGFloat(max(1, grid.count)) * step - cellGap,
            height: 7 * step - cellGap
        )
    }

    /// Build a calendar grid: columns = weeks, rows = day of week (Mon=0 .. Sun=6)
    private func buildGrid() -> [[Int]] {
        guard let firstEntry = entries.min(by: { $0.date < $1.date }),
              let lastEntry = entries.max(by: { $0.date < $1.date }) else {
            return []
        }

        let calendar = Calendar.current

        // Build lookup: day -> tokenCount
        var lookup: [Date: Int] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            lookup[day] = entry.tokenCount
        }

        // Find the Monday on or before the first entry
        let firstDay = calendar.startOfDay(for: firstEntry.date)
        let lastDay = calendar.startOfDay(for: lastEntry.date)
        let firstWeekday = (calendar.component(.weekday, from: firstDay) + 5) % 7 // Mon=0
        let startDate = calendar.date(byAdding: .day, value: -firstWeekday, to: firstDay)!

        // Build columns from startDate to lastDay
        var grid: [[Int]] = []
        var current = startDate

        while current <= lastDay {
            var column = [Int](repeating: 0, count: 7)
            for row in 0..<7 {
                let day = calendar.date(byAdding: .day, value: row, to: current)!
                if day >= firstDay && day <= lastDay {
                    column[row] = lookup[day] ?? 0
                } else {
                    column[row] = -1 // Outside range — won't be drawn
                }
            }
            grid.append(column)
            current = calendar.date(byAdding: .day, value: 7, to: current)!
        }

        return grid
    }

    private func colorForCount(_ count: Int, max: Int) -> Color {
        if count < 0 { return .clear } // Outside range
        if count == 0 { return .white.opacity(0.06) }
        let ratio = Double(count) / Double(max)
        if ratio < 0.25 { return TerminalColors.prompt.opacity(0.35) }
        if ratio < 0.50 { return TerminalColors.prompt.opacity(0.55) }
        if ratio < 0.75 { return TerminalColors.prompt.opacity(0.75) }
        return TerminalColors.prompt
    }
}

// MARK: - Detail Activity Heatmap (with tooltips)

private struct DetailActivityHeatmap: View {
    let entries: [HeatmapEntry]
    let recordDate: Date?
    var cellSize: CGFloat = 6
    var cellGap: CGFloat = 1

    @State private var hoveredInfo: String = ""
    @State private var isRecord: Bool = false

    struct Cell {
        let date: Date
        let messageCount: Int
        let tokenCount: Int
        let inRange: Bool
        let isRecord: Bool
    }

    private static let tooltipDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "E dd/MM"
        f.locale = Locale(identifier: "fr_FR")
        return f
    }()

    var body: some View {
        let grid = buildGrid()
        let maxCount = entries.map(\.tokenCount).max() ?? 1

        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: cellGap) {
                ForEach(0..<grid.count, id: \.self) { col in
                    VStack(spacing: cellGap) {
                        ForEach(0..<7, id: \.self) { row in
                            let cell = grid[col][row]
                            RoundedRectangle(cornerRadius: 1)
                                .fill(colorForCell(cell, max: maxCount))
                                .frame(width: cellSize, height: cellSize)
                                .overlay(
                                    cell.isRecord
                                        ? RoundedRectangle(cornerRadius: 1)
                                            .stroke(TerminalColors.amber, lineWidth: 1)
                                        : nil
                                )
                                .onHover { hovering in
                                    if hovering && cell.inRange {
                                        hoveredInfo = cellText(for: cell)
                                        isRecord = cell.isRecord
                                    } else if !hovering && hoveredInfo == cellText(for: cell) {
                                        hoveredInfo = ""
                                        isRecord = false
                                    }
                                }
                        }
                    }
                }
            }

            // Legend
            HStack(spacing: 8) {
                Text("Moins").font(.system(size: 7)).foregroundColor(.white.opacity(0.4))
                ForEach([0.06, 0.35, 0.55, 0.75, 1.0], id: \.self) { opacity in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(opacity == 0.06 ? .white.opacity(0.06) : TerminalColors.prompt.opacity(opacity))
                        .frame(width: 8, height: 8)
                }
                Text("Plus").font(.system(size: 7)).foregroundColor(.white.opacity(0.4))
            }

            // Hover info (two lines, fixed height to avoid layout shifts)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if isRecord {
                        Text("🏆")
                            .font(.system(size: 8))
                    }
                    Text(hoveredDate)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(isRecord ? TerminalColors.amber : .white.opacity(0.7))
                }
                .opacity(hoveredInfo.isEmpty ? 0 : 1)
                Text(hoveredStats)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(isRecord ? TerminalColors.amber.opacity(0.7) : .white.opacity(0.5))
                    .opacity(hoveredInfo.isEmpty ? 0 : 1)
            }
            .frame(height: 20, alignment: .leading)
            .animation(.easeOut(duration: 0.15), value: hoveredInfo)
        }
    }

    private var hoveredDate: String {
        guard !hoveredInfo.isEmpty else { return " " }
        return String(hoveredInfo.split(separator: "\n").first ?? " ")
    }

    private var hoveredStats: String {
        guard !hoveredInfo.isEmpty else { return " " }
        return String(hoveredInfo.split(separator: "\n").last ?? " ")
    }

    private func cellText(for cell: Cell) -> String {
        let dateStr = Self.tooltipDateFormatter.string(from: cell.date)
        let tokenStr = formatTokensCompact(cell.tokenCount)
        if cell.isRecord {
            return "\(dateStr) — Record !\n\(cell.messageCount) msgs · \(tokenStr) tokens"
        }
        return "\(dateStr)\n\(cell.messageCount) msgs · \(tokenStr) tokens"
    }

    private func formatTokensCompact(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private func colorForCell(_ cell: Cell, max: Int) -> Color {
        guard cell.inRange else { return .clear }
        if cell.tokenCount == 0 { return .white.opacity(0.06) }
        let ratio = Double(cell.tokenCount) / Double(max)
        if ratio < 0.25 { return TerminalColors.prompt.opacity(0.35) }
        if ratio < 0.50 { return TerminalColors.prompt.opacity(0.55) }
        if ratio < 0.75 { return TerminalColors.prompt.opacity(0.75) }
        return TerminalColors.prompt
    }

    private func buildGrid() -> [[Cell]] {
        guard let firstEntry = entries.min(by: { $0.date < $1.date }),
              let lastEntry = entries.max(by: { $0.date < $1.date }) else {
            return []
        }

        let calendar = Calendar.current
        let recordDay = recordDate.map { calendar.startOfDay(for: $0) }
        var msgLookup: [Date: Int] = [:]
        var tokLookup: [Date: Int] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            msgLookup[day] = entry.messageCount
            tokLookup[day] = entry.tokenCount
        }

        let firstDay = calendar.startOfDay(for: firstEntry.date)
        let lastDay = calendar.startOfDay(for: lastEntry.date)
        let firstWeekday = (calendar.component(.weekday, from: firstDay) + 5) % 7
        let startDate = calendar.date(byAdding: .day, value: -firstWeekday, to: firstDay)!

        var grid: [[Cell]] = []
        var current = startDate

        while current <= lastDay {
            var column: [Cell] = []
            for row in 0..<7 {
                let day = calendar.date(byAdding: .day, value: row, to: current)!
                let inRange = day >= firstDay && day <= lastDay
                column.append(Cell(
                    date: day,
                    messageCount: inRange ? (msgLookup[day] ?? 0) : 0,
                    tokenCount: inRange ? (tokLookup[day] ?? 0) : 0,
                    inRange: inRange,
                    isRecord: recordDay != nil && day == recordDay
                ))
            }
            grid.append(column)
            current = calendar.date(byAdding: .day, value: 7, to: current)!
        }

        return grid
    }
}
