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
    let costUSD: Double
}

struct DayHistoryEntry: Sendable {
    let date: String      // "yyyy-MM-dd"
    let messages: Int
    let sessions: Int
    let toolCalls: Int
    let tokens: Int
    let costUSD: Double
}

/// Coût moyen par jour ouvré actif sur une période glissante — « conso moyenne »
/// servant à projeter un coût annuel par ETP.
struct WorkdayCostAverage: Sendable {
    let label: String         // "Total", "90 j", "30 j"
    let perWorkdayUSD: Double
    let workdays: Int         // jours lun–ven avec activité dans la période

    /// Jours travaillés par an retenus pour un ETP.
    static let workdaysPerFTE = 200.0
    var perFTEYearUSD: Double { perWorkdayUSD * Self.workdaysPerFTE }
}

/// Un point du graphe de tendance : moyennes €/jour ouvré actif sur les
/// fenêtres se terminant au jour `date` (UTC). nil tant que la fenêtre n'est
/// pas couverte par l'historique (une moyenne 90 j sur 40 jours tromperait).
struct WorkdayCostPoint: Sendable {
    let date: Date
    let totalUSD: Double?
    let d90USD: Double?
    let d30USD: Double?
}

/// Coût réel d'un mois calendaire (UTC). Le mois en cours porte une projection
/// de fin de mois au prorata du temps écoulé.
struct MonthCost: Sendable {
    let month: Date           // 1er du mois, 00:00 UTC
    let costUSD: Double
    let projectedUSD: Double? // mois en cours uniquement
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
    // Record en coût API (jour le plus cher) — peut différer du record en tokens
    let costRecordDate: String
    let costRecordTokens: Int
    let costRecordCostUSD: Double
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
    let workdayCostAverages: [WorkdayCostAverage]
    let workdayCostTrend: [WorkdayCostPoint]
    let monthlyCosts: [MonthCost]
    /// Durée de l'historique en mois (du 1er jour à maintenant, 30,44 j/mois).
    let monthsOfHistory: Double
    let last7Days: [DayHistoryEntry]

    /// Record selon la métrique choisie (tokens ou coût API).
    func record(byCost: Bool) -> (date: String, tokens: Int, costUSD: Double) {
        byCost
            ? (costRecordDate, costRecordTokens, costRecordCostUSD)
            : (recordDate, recordTokens, recordCostUSD)
    }
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
            let cost = entry.date == today ? todayCost : (costByDate[entry.date] ?? 0)
            return HeatmapEntry(date: d, messageCount: entry.messageCount,
                                tokenCount: tokensByDate[entry.date] ?? 0, costUSD: cost)
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

        // Record day by API cost (today at its live cost)
        var costRecDate = ""
        var costRecCost = 0.0
        for (d, cost) in costByDate where d != today && cost > costRecCost {
            costRecCost = cost
            costRecDate = d
        }
        if todayCost > costRecCost {
            costRecCost = todayCost
            costRecDate = today
        }
        let costRecTokens = tokensByDate[costRecDate] ?? 0

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

        let workdayAverages = Self.workdayCostAverages(costByDate: costByDate, today: today)
        let workdayTrend = Self.workdayCostTrend(costByDate: costByDate, today: today)
        // Aujourd'hui au coût live (plus frais que le cache horaire)
        var costWithToday = costByDate
        costWithToday[today] = todayCost
        let monthly = Self.monthlyCosts(costByDate: costWithToday, now: Date())
        let firstDay = costByDate.keys.min().flatMap { utcDateFormatter.date(from: $0) }
        let months = firstDay.map { max(1 / 30.44, Date().timeIntervalSince($0) / 86400 / 30.44) } ?? 1

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
            costRecordDate: costRecDate,
            costRecordTokens: costRecTokens,
            costRecordCostUSD: costRecCost,
            date: date,
            isToday: isToday,
            heatmapEntries: heatmap,
            lastDayDate: lastDay?.date,
            lastDayMessages: lastDay?.messageCount ?? 0,
            lastDaySessions: lastDay?.sessionCount ?? 0,
            lastDayToolCalls: lastDay?.toolCallCount ?? 0,
            lastDayTokens: lastDayTokenCount,
            lastDayCostUSD: lastDay.flatMap { costByDate[$0.date] } ?? 0,
            workdayCostAverages: workdayAverages,
            workdayCostTrend: workdayTrend,
            monthlyCosts: monthly,
            monthsOfHistory: months,
            last7Days: last7Days
        )
    }
}

extension StatsReader {
    /// Moyennes par jour ouvré actif : tout l'historique, 90 et 30 derniers jours.
    /// Tout le coût de la période (week-ends compris) est réparti sur les seuls
    /// jours lun–ven avec activité : le week-end est du travail « en plus », et
    /// les congés sont exclus comme dans les 200 j/an d'un ETP. Aujourd'hui,
    /// journée incomplète, est exclu. Clés de jour UTC (comme le cache).
    static func workdayCostAverages(costByDate: [String: Double], today: String) -> [WorkdayCostAverage] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let todayDate = utcDateFormatter.date(from: today) else { return [] }

        func average(label: String, days: Int?) -> WorkdayCostAverage {
            let from = days.flatMap { calendar.date(byAdding: .day, value: -$0, to: todayDate) }
            var cost = 0.0
            var workdays = 0
            for (key, usd) in costByDate where key < today {
                guard let date = utcDateFormatter.date(from: key) else { continue }
                if let from, date < from { continue }
                cost += usd
                if usd > 0, !calendar.isDateInWeekend(date) { workdays += 1 }
            }
            return WorkdayCostAverage(label: label, perWorkdayUSD: workdays > 0 ? cost / Double(workdays) : 0,
                                      workdays: workdays)
        }
        return [average(label: "Total", days: nil), average(label: "90 j", days: 90), average(label: "30 j", days: 30)]
    }

    /// Coûts réels par mois calendaire UTC, du plus ancien au mois en cours.
    /// Projection du mois en cours = coût à date ÷ fraction du mois écoulée.
    static func monthlyCosts(costByDate: [String: Double], now: Date) -> [MonthCost] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var byMonth: [Date: Double] = [:]
        for (key, usd) in costByDate {
            guard let date = utcDateFormatter.date(from: key),
                  let month = calendar.dateInterval(of: .month, for: date)?.start else { continue }
            byMonth[month, default: 0] += usd
        }
        guard let current = calendar.dateInterval(of: .month, for: now) else { return [] }
        let elapsed = now.timeIntervalSince(current.start) / current.duration
        return byMonth.keys.sorted().map { month in
            let usd = byMonth[month] ?? 0
            let isCurrent = month == current.start
            return MonthCost(month: month, costUSD: usd,
                             projectedUSD: isCurrent && elapsed > 0 ? usd / elapsed : nil)
        }
    }

    /// Série quotidienne des mêmes moyennes (dernier point = tableau), du premier
    /// jour de l'historique à hier. Sommes préfixes → une seule passe.
    static func workdayCostTrend(costByDate: [String: Double], today: String) -> [WorkdayCostPoint] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let todayDate = utcDateFormatter.date(from: today),
              let firstKey = costByDate.keys.min(),
              let firstDate = utcDateFormatter.date(from: firstKey),
              firstDate < todayDate else { return [] }

        // Jours continus [premier jour, hier] ; cumuls coût et jours ouvrés actifs.
        var dates: [Date] = []
        var cumCost: [Double] = [0]
        var cumWorkdays: [Int] = [0]
        var day = firstDate
        while day < todayDate {
            let usd = costByDate[utcDateFormatter.string(from: day)] ?? 0
            let isWorkday = usd > 0 && !calendar.isDateInWeekend(day)
            dates.append(day)
            cumCost.append(cumCost.last! + usd)
            cumWorkdays.append(cumWorkdays.last! + (isWorkday ? 1 : 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        // Moyenne sur les `window` derniers jours se terminant à l'index i (nil si
        // l'historique ne couvre pas la fenêtre ou sans jour ouvré actif).
        func average(endingAt i: Int, window: Int?) -> Double? {
            let lower = window.map { i + 1 - $0 } ?? 0
            guard lower >= 0 else { return nil }
            let workdays = cumWorkdays[i + 1] - cumWorkdays[lower]
            guard workdays > 0 else { return nil }
            return (cumCost[i + 1] - cumCost[lower]) / Double(workdays)
        }
        return dates.indices.map { i in
            WorkdayCostPoint(date: dates[i],
                             totalUSD: average(endingAt: i, window: nil),
                             d90USD: average(endingAt: i, window: 90),
                             d30USD: average(endingAt: i, window: 30))
        }
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
