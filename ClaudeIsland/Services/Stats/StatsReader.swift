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
    // Last non-empty day (excluding today)
    let lastDayDate: String?
    let lastDayMessages: Int
    let lastDaySessions: Int
    let lastDayToolCalls: Int
    let lastDayTokens: Int
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

        // All-time tokens: sum inputTokens + outputTokens across all models
        let allTimeCacheTokens = cache.modelUsage.values.reduce(0) { sum, usage in
            sum + usage.inputTokens + usage.outputTokens
        }

        let liveTokens = readTodayLiveTokens()

        // Build token lookup by date
        var tokensByDate: [String: Int] = [:]
        for entry in cache.dailyModelTokens {
            tokensByDate[entry.date] = entry.tokensByModel.values.reduce(0, +)
        }
        // Use live tokens for today if higher than cache
        if liveTokens > (tokensByDate[today] ?? 0) {
            tokensByDate[today] = liveTokens
        }

        // Heatmap entries from dailyActivity
        let heatmap = cache.dailyActivity.compactMap { entry -> HeatmapEntry? in
            guard let d = dateFormatter.date(from: entry.date) else { return nil }
            return HeatmapEntry(date: d, messageCount: entry.messageCount, tokenCount: tokensByDate[entry.date] ?? 0)
        }

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
                    tokens: tokensByDate[entry.date] ?? 0
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
            recordDate: recDate,
            recordTokens: recTokens,
            date: date,
            isToday: isToday,
            heatmapEntries: heatmap,
            lastDayDate: lastDay?.date,
            lastDayMessages: lastDay?.messageCount ?? 0,
            lastDaySessions: lastDay?.sessionCount ?? 0,
            lastDayToolCalls: lastDay?.toolCallCount ?? 0,
            lastDayTokens: lastDayTokenCount,
            last7Days: last7Days
        )
    }

    // MARK: - Live Today Tokens (from JSONL files)

    /// Scans JSONL files modified today to compute live token usage.
    /// Sources: CLI sessions (Mac local + VM mirror via sandbox-sync), subagents,
    /// workflows, and Desktop local-agent-mode sessions.
    ///
    /// Aligné sur refresh-claude-stats.mjs (correctifs juin 2026) :
    ///   1. Scan récursif complet — attrape aussi les transcripts subagents
    ///      (<session>/subagents/) ET workflows (subagents/workflows/wf_*/),
    ///      qu'un scan à profondeur fixe ratait (~1M tokens/jour workflow).
    ///   2. Dédup des blocs usage par message.id en gardant l'usage FINAL :
    ///      une réponse est écrite sur N lignes (tool-calls parallèles à usage
    ///      identique, ou blocs streamés dont output_tokens croît ligne à ligne).
    ///      On compte input/cache une seule fois puis seulement le delta d'output
    ///      révélé ensuite — « garder la 1re ligne » figeait l'output partiel.
    ///   3. Jour identifié en UTC (comme toISOString côté .mjs) : les timestamps
    ///      JSONL sont en UTC, on compare donc un préfixe UTC.
    private static func readTodayLiveTokens() -> Int {
        let fm = FileManager.default
        let calendar = Calendar.current
        // Pré-filtre mtime volontairement permissif : minuit local ≤ début du
        // jour UTC en CEST, donc aucun fichier du jour UTC n'est écarté. Le
        // filtre fin se fait sur le préfixe de timestamp, ligne par ligne.
        let todayStart = calendar.startOfDay(for: Date())
        let todayPrefix = utcDateFormatter.string(from: Date()) // "yyyy-MM-dd" UTC

        // Dédup globale des blocs usage par message.id, partagée sur tout le scan.
        // Valeur = output_tokens déjà comptabilisé pour la clé (cf. usage FINAL).
        var seenUsage = [String: Int]()
        var totalTokens = 0

        // ── CLI sessions: scan récursif multi-racines (local Mac + miroir VM) ──
        let cliRoots = [
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude-island/projects"),
        ]
        for root in cliRoots {
            totalTokens += scanDirectoryRecursively(dir: root, todayStart: todayStart, todayPrefix: todayPrefix, seenUsage: &seenUsage)
        }

        // ── Desktop local-agent-mode sessions ──
        let desktopAgentDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
        totalTokens += scanDirectoryRecursively(dir: desktopAgentDir, todayStart: todayStart, todayPrefix: todayPrefix, seenUsage: &seenUsage)

        return totalTokens
    }

    /// Recursively scan a directory tree for JSONL files modified today.
    /// Returns 0 silently if `dir` doesn't exist (e.g. user without VM mirror).
    private static func scanDirectoryRecursively(dir: URL, todayStart: Date, todayPrefix: String, seenUsage: inout [String: Int]) -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else {
            return 0
        }
        var tokens = 0
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                tokens += scanDirectoryRecursively(dir: item, todayStart: todayStart, todayPrefix: todayPrefix, seenUsage: &seenUsage)
            } else if item.pathExtension == "jsonl" {
                guard let attrs = try? item.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modDate = attrs.contentModificationDate,
                      modDate >= todayStart else { continue }
                tokens += scanJsonlForTodayTokens(file: item, todayPrefix: todayPrefix, seenUsage: &seenUsage)
            }
        }
        return tokens
    }

    private static func scanJsonlForTodayTokens(file: URL, todayPrefix: String, seenUsage: inout [String: Int]) -> Int {
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

            // Dédup par message.id (fallback fichier|timestamp) en gardant l'usage
            // FINAL : une réponse est écrite sur N lignes (tool-calls parallèles à
            // usage identique, ou blocs streamés dont output_tokens croît). On
            // compte input une fois puis seulement le delta d'output révélé ensuite.
            let key: String
            if let mid = message["id"] as? String {
                key = "msg:\(mid)"
            } else {
                key = "\(file.path)|\(timestamp)"
            }
            let output = usage["output_tokens"] as? Int ?? 0
            if let prevOut = seenUsage[key] {
                // Doublon strict ou état antérieur du streaming : ajouter le delta.
                if output > prevOut {
                    tokens += output - prevOut
                    seenUsage[key] = output
                }
            } else {
                let input = usage["input_tokens"] as? Int ?? 0
                tokens += input + output
                seenUsage[key] = output
            }
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
