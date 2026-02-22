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

struct DailyStats: Sendable {
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int
    let totalTokens: Int
    let totalSessionsAllTime: Int
    let totalMessagesAllTime: Int
    let totalTokensAllTime: Int
    let todayLiveTokens: Int  // computed from JSONL files
    let recordDate: String    // day with most tokens
    let recordTokens: Int
    let date: String
    let isToday: Bool
    let heatmapEntries: [HeatmapEntry]
}

struct StatsReader: Sendable {
    private static let logger = Logger(subsystem: "com.claudeisland", category: "StatsReader")
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
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

        let today = dateFormatter.string(from: Date())

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

        // All-time tokens: sum inputTokens + outputTokens across all models
        let allTimeCacheTokens = cache.modelUsage.values.reduce(0) { sum, usage in
            sum + usage.inputTokens + usage.outputTokens
        }

        // Build token lookup by date
        var tokensByDate: [String: Int] = [:]
        for entry in cache.dailyModelTokens {
            tokensByDate[entry.date] = entry.tokensByModel.values.reduce(0, +)
        }

        // Heatmap entries from dailyActivity
        let heatmap = cache.dailyActivity.compactMap { entry -> HeatmapEntry? in
            guard let d = dateFormatter.date(from: entry.date) else { return nil }
            return HeatmapEntry(date: d, messageCount: entry.messageCount, tokenCount: tokensByDate[entry.date] ?? 0)
        }

        let liveTokens = readTodayLiveTokens()

        // All-time = cache total + any live tokens beyond what cache already knows for today
        let allTimeTokens = allTimeCacheTokens + max(0, liveTokens - dayTokens)

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

        return DailyStats(
            messageCount: activity?.messageCount ?? 0,
            sessionCount: activity?.sessionCount ?? 0,
            toolCallCount: activity?.toolCallCount ?? 0,
            totalTokens: dayTokens,
            totalSessionsAllTime: cache.totalSessions,
            totalMessagesAllTime: cache.totalMessages,
            totalTokensAllTime: allTimeTokens,
            todayLiveTokens: liveTokens,
            recordDate: recDate,
            recordTokens: recTokens,
            date: date,
            isToday: isToday,
            heatmapEntries: heatmap
        )
    }

    // MARK: - Live Today Tokens (from JSONL files)

    /// Scans ~/.claude/projects/*/*.jsonl files modified today to compute live token usage
    private static func readTodayLiveTokens() -> Int {
        let fm = FileManager.default
        let projectsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

        guard let projectDirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else {
            return 0
        }

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let todayPrefix = dateFormatter.string(from: Date()) // "yyyy-MM-dd"

        var totalTokens = 0

        for projDir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(at: projDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
                continue
            }

            for file in files {
                guard file.pathExtension == "jsonl" else { continue }

                // Only read files modified today
                guard let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modDate = attrs.contentModificationDate,
                      modDate >= todayStart else { continue }

                totalTokens += scanJsonlForTodayTokens(file: file, todayPrefix: todayPrefix)
            }
        }

        return totalTokens
    }

    private static func scanJsonlForTodayTokens(file: URL, todayPrefix: String) -> Int {
        guard let data = try? Data(contentsOf: file),
              let content = String(data: data, encoding: .utf8) else { return 0 }

        var tokens = 0

        for line in content.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  line.contains("\"assistant\""),
                  line.contains("\"usage\"") else { continue }

            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let timestamp = obj["timestamp"] as? String,
                  timestamp.hasPrefix(todayPrefix),
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            tokens += input + output
        }

        return tokens
    }
}

// MARK: - Codable Models

private struct StatsCache: Codable {
    let dailyActivity: [DailyActivityEntry]
    let dailyModelTokens: [DailyModelTokenEntry]
    let modelUsage: [String: ModelUsageEntry]
    let totalSessions: Int
    let totalMessages: Int
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
}

private struct ModelUsageEntry: Codable {
    let inputTokens: Int
    let outputTokens: Int
}
