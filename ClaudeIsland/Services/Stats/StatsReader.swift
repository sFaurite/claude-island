//
//  StatsReader.swift
//  ClaudeIsland
//
//  Reads daily stats from ~/.claude/stats-cache.json
//

import Foundation
import os.log

struct HeatmapEntry: Sendable {
    let date: Date
    let messageCount: Int
    let tokenCount: Int
}

struct DayHistoryEntry: Sendable {
    let date: String      // "yyyy-MM-dd"
    let messages: Int
    let sessions: Int
    let toolCalls: Int
    let tokens: Int
    let costUSD: Double
}

struct DailyStats: Sendable {
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int
    let totalTokens: Int
    let totalSessionsAllTime: Int
    let totalMessagesAllTime: Int
    let totalTokensAllTime: Int
    let todayLiveTokens: Int  // computed from JSONL files
    // Coût équivalent API (USD) — cf. ModelPricing
    let todayCostUSD: Double
    let totalCostAllTimeUSD: Double
    let recordDate: String    // day with most tokens
    let recordTokens: Int
    let recordCostUSD: Double
    let date: String
    let isToday: Bool
    let heatmapEntries: [HeatmapEntry]
    // Last non-empty day (excluding today)
    let lastDayDate: String?
    let lastDayMessages: Int
    let lastDaySessions: Int
    let lastDayToolCalls: Int
    let lastDayTokens: Int
    let lastDayCostUSD: Double
    let last7Days: [DayHistoryEntry]
}

struct StatsReader: Sendable {
    private static let logger = Logger(subsystem: "com.claudeisland", category: "StatsReader")
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
    // Le cache (refresh-claude-stats.mjs) regroupe les jours via toISOString,
    // donc en UTC. On utilise ce formateur UTC pour identifier « aujourd'hui »
    // côté app, afin de viser exactement la même clé de jour que le cache.
    private static let utcDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func read() -> DailyStats? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/stats-cache.json")

        guard let data = try? Data(contentsOf: path) else {
            logger.warning("stats-cache.json not found")
            return nil
        }

        guard let cache = try? JSONDecoder().decode(StatsCache.self, from: data) else {
            logger.warning("Failed to decode stats-cache.json")
            return nil
        }

        let today = utcDateFormatter.string(from: Date())

        // Try today first, then fall back to most recent day
        let activity: DailyActivityEntry?
        let modelTokens: DailyModelTokenEntry?
        let isToday: Bool
        let date: String

        if let todayActivity = cache.dailyActivity.first(where: { $0.date == today }) {
            activity = todayActivity
            modelTokens = cache.dailyModelTokens.first { $0.date == today }
            isToday = true
            date = today
        } else if let lastActivity = cache.dailyActivity.last {
            activity = lastActivity
            modelTokens = cache.dailyModelTokens.last { $0.date == lastActivity.date }
            isToday = false
            date = lastActivity.date
        } else {
            return nil
        }

        let dayTokens = modelTokens?.tokensByModel.values.reduce(0, +) ?? 0

        // All-time tokens (intensité) : input + écritures de cache + output
        let allTimeCacheTokens = cache.modelUsage.values.reduce(0) { sum, usage in
            sum + usage.inputTokens + usage.outputTokens + (usage.cacheCreationInputTokens ?? 0)
        }
        let allTimeCacheCost = cache.modelUsage.values.reduce(0) { $0 + ($1.costUSD ?? 0) }

        let live = TodayTokensCache.shared.today(pricing: cache.pricing ?? .empty)
        let liveTokens = live.tokens

        // Build token / cost lookup by date
        var tokensByDate: [String: Int] = [:]
        var costByDate: [String: Double] = [:]
        for entry in cache.dailyModelTokens {
            tokensByDate[entry.date] = entry.tokensByModel.values.reduce(0, +)
            costByDate[entry.date] = entry.costUSD ?? 0
        }
        let cachedTodayCost = costByDate[today] ?? 0
        // Use live values for today if higher than cache
        if liveTokens > (tokensByDate[today] ?? 0) {
            tokensByDate[today] = liveTokens
        }
        let todayCost = max(live.costUSD, cachedTodayCost)

        // Heatmap entries from dailyActivity
        let heatmap = cache.dailyActivity.compactMap { entry -> HeatmapEntry? in
            guard let d = dateFormatter.date(from: entry.date) else { return nil }
            return HeatmapEntry(date: d, messageCount: entry.messageCount, tokenCount: tokensByDate[entry.date] ?? 0)
        }

        // All-time = cache total + any live tokens beyond what cache already knows for today
        let allTimeTokens = allTimeCacheTokens + max(0, liveTokens - dayTokens)
        let allTimeCost = allTimeCacheCost + max(0, live.costUSD - cachedTodayCost)

        // Record day (most tokens in a single day)
        var recDate = ""
        var recTokens = 0
        for entry in cache.dailyModelTokens {
            let total = entry.tokensByModel.values.reduce(0, +)
            if total > recTokens {
                recTokens = total
                recDate = entry.date
            }
        }
        // Compare with today's live tokens
        if liveTokens > recTokens {
            recTokens = liveTokens
            recDate = today
        }
        let recCost = recDate == today ? todayCost : (costByDate[recDate] ?? 0)

        // Last non-empty day excluding today
        let lastDay = cache.dailyActivity
            .filter { $0.date != today && $0.messageCount > 0 }
            .last
        let lastDayTokenCount = lastDay.flatMap { tokensByDate[$0.date] } ?? 0

        // Last 7 non-empty days excluding today (most recent first)
        let recentDays = cache.dailyActivity
            .filter { $0.date != today && $0.messageCount > 0 }
            .suffix(7)
            .reversed()
            .map { entry in
                DayHistoryEntry(
                    date: entry.date,
                    messages: entry.messageCount,
                    sessions: entry.sessionCount,
                    toolCalls: entry.toolCallCount,
                    tokens: tokensByDate[entry.date] ?? 0,
                    costUSD: costByDate[entry.date] ?? 0
                )
            }
        let last7Days = Array(recentDays)

        return DailyStats(
            messageCount: activity?.messageCount ?? 0,
            sessionCount: activity?.sessionCount ?? 0,
            toolCallCount: activity?.toolCallCount ?? 0,
            totalTokens: dayTokens,
            totalSessionsAllTime: cache.totalSessions,
            totalMessagesAllTime: cache.totalMessages,
            totalTokensAllTime: allTimeTokens,
            todayLiveTokens: liveTokens,
            todayCostUSD: todayCost,
            totalCostAllTimeUSD: allTimeCost,
            recordDate: recDate,
            recordTokens: recTokens,
            recordCostUSD: recCost,
            date: date,
            isToday: isToday,
            heatmapEntries: heatmap,
            lastDayDate: lastDay?.date,
            lastDayMessages: lastDay?.messageCount ?? 0,
            lastDaySessions: lastDay?.sessionCount ?? 0,
            lastDayToolCalls: lastDay?.toolCallCount ?? 0,
            lastDayTokens: lastDayTokenCount,
            lastDayCostUSD: lastDay.flatMap { costByDate[$0.date] } ?? 0,
            last7Days: last7Days
        )
    }
}

// MARK: - Codable Models

private struct StatsCache: Codable {
    let dailyActivity: [DailyActivityEntry]
    let dailyModelTokens: [DailyModelTokenEntry]
    let modelUsage: [String: ModelUsageEntry]
    let totalSessions: Int
    let totalMessages: Int
    let pricing: ModelPricing?    // absent avant le cache v3
}

private struct DailyActivityEntry: Codable {
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int
}

private struct DailyModelTokenEntry: Codable {
    let date: String
    let tokensByModel: [String: Int]
    let costUSD: Double?          // absent avant le cache v3
}

private struct ModelUsageEntry: Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int?
    let costUSD: Double?
}
