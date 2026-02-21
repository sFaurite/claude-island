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

// MARK: - Wings View

struct NotchWingsView: View {
    let rateLimits: RateLimitData?
    let stats: DailyStats?
    let notchWidth: CGFloat
    let height: CGFloat
    var tick: Bool = false // triggers re-render for staleness

    private let wingFont = Font.system(size: 10, weight: .medium, design: .monospaced)
    private let wingPadding: CGFloat = 8
    private let wingCornerRadius: CGFloat = 6

    var body: some View {
        let _ = tick // consumed to trigger re-render for staleness
        HStack(spacing: 0) {
            leftWing
                .frame(maxWidth: .infinity, alignment: .trailing)

            Color.clear
                .frame(width: notchWidth + 16)

            rightWing
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .padding(.horizontal, 8)
    }

    // MARK: - Left Wing (Rate Limits)

    private let staleThreshold: TimeInterval = 600 // 10 minutes

    private var leftWing: some View {
        HStack(spacing: 8) {
            if let rl = rateLimits {
                // Stale warning at the far left
                if rl.fetchedAt.timeIntervalSinceNow < -staleThreshold {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                        Text(formatElapsed(since: rl.fetchedAt))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(TerminalColors.amber)
                }

                rateLimitPill(label: "5h", utilization: rl.fiveHourUtilization, reset: rl.fiveHourReset, forceUnit: nil, windowSeconds: 5 * 3600)
                rateLimitPill(label: "7j", utilization: rl.sevenDayUtilization, reset: rl.sevenDayReset, forceUnit: .days, windowSeconds: 7 * 86400)
                if rl.overageUtilization > 0 {
                    overagePill(utilization: rl.overageUtilization)
                }
            } else {
                Text("—")
                    .font(wingFont)
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, wingPadding)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: wingCornerRadius)
                .fill(.black.opacity(0.7))
                .background(
                    RoundedRectangle(cornerRadius: wingCornerRadius)
                        .fill(.ultraThinMaterial)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    // MARK: - Right Wing (Heatmap + Stats)

    private var rightWing: some View {
        HStack(spacing: 6) {
            if let st = stats {
                // Mini activity heatmap
                ActivityHeatmap(entries: st.heatmapEntries)

                // Separator
                Rectangle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 1, height: 20)

                // All-time tokens + today live tokens
                Text("Σ " + formatTokens(st.totalTokensAllTime))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))

                if st.todayLiveTokens > 0 {
                    Text("·")
                        .font(wingFont)
                        .foregroundColor(.white.opacity(0.2))

                    Text("⇡ " + formatTokens(st.todayLiveTokens))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }

                Text("·")
                    .font(wingFont)
                    .foregroundColor(.white.opacity(0.2))

                // Daily stats (with date prefix if not today)
                if !st.isToday {
                    Text(formatShortDate(st.date))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                }

                Text("\(st.messageCount) msgs")
                    .font(wingFont)
                    .foregroundColor(.white.opacity(st.isToday ? 0.7 : 0.5))

                Text("·")
                    .font(wingFont)
                    .foregroundColor(.white.opacity(0.2))

                Text("\(st.sessionCount) sess")
                    .font(wingFont)
                    .foregroundColor(.white.opacity(st.isToday ? 0.7 : 0.5))

                Text("·")
                    .font(wingFont)
                    .foregroundColor(.white.opacity(0.2))

                Text(formatTokens(st.totalTokens))
                    .font(wingFont)
                    .foregroundColor(.white.opacity(st.isToday ? 0.7 : 0.5))

                if st.recordTokens > 0 {
                    Text("·")
                        .font(wingFont)
                        .foregroundColor(.white.opacity(0.2))

                    HStack(spacing: 2) {
                        Text("🏆")
                            .font(.system(size: 7))
                        Text(formatShortDate(st.recordDate) + " " + formatTokens(st.recordTokens))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(TerminalColors.amber.opacity(0.7))
                }
            } else {
                Text("—")
                    .font(wingFont)
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, wingPadding)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: wingCornerRadius)
                .fill(.black.opacity(0.7))
                .background(
                    RoundedRectangle(cornerRadius: wingCornerRadius)
                        .fill(.ultraThinMaterial)
                )
        )
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
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))

            progressBar(utilization: utilization, expectedUtilization: expectedUtil)

            Text("\(Int(utilization * 100))%")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(colorForUtilization(utilization, expected: expectedUtil).opacity(0.9))

            Text(formatReset(reset, forceUnit: forceUnit))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private func overagePill(utilization: Double) -> some View {
        HStack(spacing: 4) {
            Text("ovg")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(TerminalColors.red.opacity(0.7))

            Text("\(Int(utilization * 100))%")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(TerminalColors.red.opacity(0.9))
        }
    }

    // MARK: - Progress Bar

    private func progressBar(utilization: Double, expectedUtilization: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let actual = min(utilization, 1.0)
            let expected = min(expectedUtilization, 1.0)
            let isOver = actual > expected

            ZStack(alignment: .leading) {
                // Background
                Capsule()
                    .fill(.white.opacity(0.15))
                    .frame(height: 3)

                if isOver {
                    // Green portion up to expected
                    Capsule()
                        .fill(TerminalColors.green)
                        .frame(width: max(1, w * expected), height: 3)

                    // Red overshoot from expected to actual
                    Capsule()
                        .fill(TerminalColors.red)
                        .frame(width: max(1, w * actual), height: 3)
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
                        .frame(width: max(1, w * actual), height: 3)
                }

                // Amber marker line at expected position
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(TerminalColors.amber)
                    .frame(width: 1, height: 5)
                    .offset(x: w * expected - 0.5)
            }
        }
        .frame(width: 40, height: 5)
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

    private func formatReset(_ date: Date, forceUnit: ResetUnit? = nil) -> String {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "↻" }

        if forceUnit == .days {
            let days = interval / 86400
            if days >= 1 {
                return String(format: "%.0fj ↻", days)
            }
            // Less than 1 day: fall through to h/m format
        }

        let minutes = Int(interval) / 60
        if minutes < 60 { return "\(max(1, minutes))m ↻" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ↻" }
        return "\(hours / 24)j ↻"
    }

    private func formatShortDate(_ dateStr: String) -> String {
        let parts = dateStr.split(separator: "-")
        guard parts.count == 3 else { return dateStr }
        return "\(parts[2])/\(parts[1])"
    }

    private func formatElapsed(since date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return "\(hours)h"
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

    private let cellSize: CGFloat = 3
    private let cellGap: CGFloat = 1

    var body: some View {
        let grid = buildGrid()
        let maxCount = entries.map(\.messageCount).max() ?? 1

        Canvas { context, size in
            let step = cellSize + cellGap
            for col in 0..<grid.count {
                for row in 0..<7 {
                    let x = CGFloat(col) * step
                    let y = CGFloat(row) * step
                    let rect = CGRect(x: x, y: y, width: cellSize, height: cellSize)
                    let count = grid[col][row]
                    context.fill(
                        RoundedRectangle(cornerRadius: 0.5).path(in: rect),
                        with: .color(colorForCount(count, max: maxCount))
                    )
                }
            }
        }
        .frame(
            width: CGFloat(max(1, buildGrid().count)) * (cellSize + cellGap) - cellGap,
            height: 7 * (cellSize + cellGap) - cellGap
        )
    }

    /// Build a calendar grid: columns = weeks, rows = day of week (Mon=0 .. Sun=6)
    private func buildGrid() -> [[Int]] {
        guard let firstEntry = entries.min(by: { $0.date < $1.date }),
              let lastEntry = entries.max(by: { $0.date < $1.date }) else {
            return []
        }

        let calendar = Calendar.current

        // Build lookup: daysSinceEpoch -> messageCount
        var lookup: [Date: Int] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            lookup[day] = entry.messageCount
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
