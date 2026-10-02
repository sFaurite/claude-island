//
//  ModelBreakdown.swift
//  ClaudeIsland
//
//  Détail de l'usage par modèle (panneau « Tokens — All Time », vue Modèles) :
//  identification d'un id de modèle (famille, version), agrégation par période
//  et filtres. Données issues de dailyModelTokens (tokens et, depuis l'ajout de
//  costByModel, coût par modèle et par jour).
//

import Foundation

enum ModelFamily: String, CaseIterable, Sendable {
    case fable, opus, sonnet, haiku, other

    var label: String {
        switch self {
        case .fable:  return "Fable"
        case .opus:   return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku:  return "Haiku"
        case .other:  return "Autres"
        }
    }
}

struct ModelInfo: Hashable, Sendable {
    let id: String
    let family: ModelFamily
    /// « Opus 4.6 », « Haiku 4.5 »… ; id brut si non reconnu.
    let label: String
    /// Version numérique pour trier les modèles d'une même famille (5.5 > 5 > 4.8).
    let version: [Int]

    static func parse(_ raw: String) -> ModelInfo {
        let id = raw.lowercased()
        if id == "vm-archive" {
            return ModelInfo(id: raw, family: .other, label: "Archive VM", version: [])
        }
        let parts = id.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let families: [(key: String, family: ModelFamily, name: String)] = [
            ("fable", .fable, "Fable"), ("opus", .opus, "Opus"), ("sonnet", .sonnet, "Sonnet"),
            ("haiku", .haiku, "Haiku"), ("mythos", .other, "Mythos"),
        ]
        guard let found = families.first(where: { parts.contains($0.key) }) else {
            return ModelInfo(id: raw, family: .other, label: raw, version: [])
        }
        // Chiffres courts avant ou après le nom de famille (« claude-3-5-haiku »,
        // « claude-opus-4-6-2026… ») ; les groupes longs sont des dates.
        let numbers = parts.compactMap { $0.count <= 2 ? Int($0) : nil }
        let label = numbers.isEmpty ? found.name : found.name + " " + numbers.map(String.init).joined(separator: ".")
        return ModelInfo(id: raw, family: found.family, label: label, version: numbers)
    }
}

/// Usage d'une journée (UTC), par modèle.
struct ModelDayUsage: Sendable {
    let date: String                  // "yyyy-MM-dd"
    let tokens: [String: Int]
    let costUSD: [String: Double]
}

enum ModelMetric: String, CaseIterable, Sendable {
    case cost, tokens
}

/// Lecture des courbes du graphe par modèle.
enum ModelCurve: String, CaseIterable, Sendable {
    /// Valeur par jour (moyenne glissante 7 j) ou par mois.
    case value
    /// Cumul depuis le début de la période.
    case cumulative
    /// Part de chaque modèle dans le total du jour (lissé 7 j) ou du mois.
    case share

    var label: String {
        switch self {
        case .value:      return "valeur"
        case .cumulative: return "cumul"
        case .share:      return "part %"
        }
    }
}

enum ModelPeriod: String, CaseIterable, Sendable {
    case d7, d30, d90, all

    var label: String {
        switch self {
        case .d7:  return "7 j"
        case .d30: return "30 j"
        case .d90: return "90 j"
        case .all: return "Tout"
        }
    }

    var days: Int? {
        switch self {
        case .d7:  return 7
        case .d30: return 30
        case .d90: return 90
        case .all: return nil
        }
    }
}

/// Total d'un modèle (ou du regroupement « Reste ») sur la période filtrée.
struct ModelTotal: Identifiable, Sendable {
    let info: ModelInfo
    let tokens: Int
    let costUSD: Double
    var id: String { info.id }

    func value(_ metric: ModelMetric) -> Double {
        metric == .cost ? costUSD : Double(tokens)
    }
}

/// Un point d'une courbe du graphe : valeur d'un modèle un jour ou un mois.
struct ModelBucketValue: Identifiable, Sendable {
    let date: Date                    // jour, ou 1er du mois (UTC)
    let info: ModelInfo
    let value: Double
    var id: String { "\(date.timeIntervalSince1970)|\(info.id)" }
}

struct ModelSelection: Sendable {
    var period: ModelPeriod = .all
    var metric: ModelMetric = .cost
    var hiddenFamilies: Set<ModelFamily> = []
    /// Nombre maximal de modèles affichés séparément ; le reste est regroupé.
    var maxModels: Int = 8
}

enum ModelBreakdown {
    /// Id du regroupement des modèles au-delà du top N.
    static let restId = "__rest__"
    static let restInfo = ModelInfo(id: restId, family: .other, label: "Reste", version: [])

    private static let utc: TimeZone = TimeZone(identifier: "UTC")!

    private static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = utc
        return f
    }

    /// Jours retenus par la période (fenêtre glissante se terminant aujourd'hui inclus).
    static func filterDays(_ days: [ModelDayUsage], period: ModelPeriod, now: Date = Date()) -> [ModelDayUsage] {
        guard let n = period.days else { return days }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        guard let cutoff = calendar.date(byAdding: .day, value: -(n - 1), to: now) else { return days }
        let key = dayFormatter().string(from: cutoff)
        return days.filter { $0.date >= key }
    }

    private static func visible(_ id: String, hidden: Set<ModelFamily>) -> ModelInfo? {
        if id == "<synthetic>" { return nil }
        let info = ModelInfo.parse(id)
        return hidden.contains(info.family) ? nil : info
    }

    /// Modèles présents (hors filtre de famille) sur la période, avec leurs totaux,
    /// triés par la métrique choisie. Sert aussi de base aux pastilles de famille.
    static func totals(_ days: [ModelDayUsage], selection: ModelSelection, now: Date = Date()) -> [ModelTotal] {
        var tokens: [String: Int] = [:]
        var cost: [String: Double] = [:]
        for day in filterDays(days, period: selection.period, now: now) {
            for (id, t) in day.tokens { tokens[id, default: 0] += t }
            for (id, c) in day.costUSD { cost[id, default: 0] += c }
        }
        return Set(tokens.keys).union(cost.keys).compactMap { id -> ModelTotal? in
            guard let info = visible(id, hidden: selection.hiddenFamilies) else { return nil }
            let total = ModelTotal(info: info, tokens: tokens[id] ?? 0, costUSD: cost[id] ?? 0)
            return total.value(.tokens) > 0 || total.value(.cost) > 0 ? total : nil
        }
        .sorted { $0.value(selection.metric) > $1.value(selection.metric) }
    }

    /// Totaux par famille sur la période (avant filtre de famille) — pastilles.
    static func familyTotals(_ days: [ModelDayUsage], period: ModelPeriod, metric: ModelMetric,
                             now: Date = Date()) -> [ModelFamily: Double] {
        var selection = ModelSelection()
        selection.period = period
        selection.metric = metric
        var result: [ModelFamily: Double] = [:]
        for total in totals(days, selection: selection, now: now) {
            result[total.info.family, default: 0] += total.value(metric)
        }
        return result
    }

    /// Top N + regroupement « Reste » (histogramme).
    static func ranked(_ totals: [ModelTotal], maxModels: Int, metric: ModelMetric) -> [ModelTotal] {
        guard totals.count > maxModels else { return totals }
        let head = Array(totals.prefix(maxModels))
        let tail = totals.dropFirst(maxModels)
        let rest = ModelTotal(info: restInfo,
                              tokens: tail.reduce(0) { $0 + $1.tokens },
                              costUSD: tail.reduce(0) { $0 + $1.costUSD })
        return rest.value(metric) > 0 ? head + [rest] : head
    }

    /// Fenêtre de la moyenne glissante des courbes quotidiennes.
    static let smoothingDays = 7

    /// Séries continues du graphe en courbes : un point par (jour ou mois, modèle
    /// du top N ; les autres cumulés sous « Reste »), jours sans usage à 0.
    /// Le lissage quotidien est calculé sur tout l'historique puis coupé à la
    /// période (le 1er jour d'une fenêtre 7 j a bien 7 j derrière lui) ; le
    /// cumul repart de 0 au début de la période. Part : ratio 0…1.
    static func series(_ days: [ModelDayUsage], selection: ModelSelection, monthly: Bool,
                       curve: ModelCurve, now: Date = Date()) -> [ModelBucketValue] {
        // « Reste » = modèles de la période au-delà du top N, exactement comme
        // `ranked` : un modèle absent de la période (usage plus ancien, lu ici
        // pour le lissage) ne doit pas faire naître un « Reste » hors légende.
        let periodTotals = totals(days, selection: selection, now: now)
        let top = Set(periodTotals.prefix(selection.maxModels).map(\.info.id))
        let tail = Set(periodTotals.dropFirst(selection.maxModels).map(\.info.id))
        guard !top.isEmpty else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let formatter = dayFormatter()
        func bucket(_ date: Date) -> Date {
            monthly ? (calendar.dateInterval(of: .month, for: date)?.start ?? date) : date
        }

        // Par mois, le 1er mois de la période n'en compte que la partie incluse
        // (sinon 7 j en mois afficherait le mois entier).
        let cutoffKey = monthly ? filterDays(days, period: selection.period, now: now).first?.date : nil

        var grid: [Date: [String: Double]] = [:]
        for day in days {
            if let cutoffKey, day.date < cutoffKey { continue }
            guard let date = formatter.date(from: day.date) else { continue }
            for id in Set(day.tokens.keys).union(day.costUSD.keys) {
                guard top.contains(id) || tail.contains(id) else { continue }
                let value = selection.metric == .cost ? (day.costUSD[id] ?? 0) : Double(day.tokens[id] ?? 0)
                guard value > 0 else { continue }
                grid[bucket(date), default: [:]][top.contains(id) ? id : restId, default: 0] += value
            }
        }
        guard let first = grid.keys.min() else { return [] }

        let step: Calendar.Component = monthly ? .month : .day
        let last = bucket(calendar.startOfDay(for: now))
        var dates: [Date] = []
        var cursor = first
        while cursor <= last {
            dates.append(cursor)
            guard let next = calendar.date(byAdding: step, value: 1, to: cursor) else { break }
            cursor = next
        }
        let ids = Set(grid.values.flatMap(\.keys)).sorted()
        var values: [String: [Double]] = [:]
        for id in ids { values[id] = dates.map { grid[$0]?[id] ?? 0 } }

        if !monthly && curve != .cumulative {
            for id in ids {
                let raw = values[id]!
                var sum = 0.0
                values[id] = raw.indices.map { i in
                    sum += raw[i]
                    if i >= smoothingDays { sum -= raw[i - smoothingDays] }
                    // Somme glissante : les soustractions laissent des résidus
                    // négatifs infimes (−1e-13) qui étiraient l'axe sous zéro.
                    return max(0, sum / Double(min(i + 1, smoothingDays)))
                }
            }
        }

        var start = 0
        if let n = selection.period.days,
           let cutoff = calendar.date(byAdding: .day, value: -(n - 1), to: calendar.startOfDay(for: now)) {
            let c = bucket(cutoff)
            start = dates.firstIndex { $0 >= c } ?? dates.count
        }

        var result: [ModelBucketValue] = []
        var running: [String: Double] = [:]
        for i in start..<dates.count {
            let total = ids.reduce(0) { $0 + values[$1]![i] }
            for id in ids {
                let v = values[id]![i]
                let y: Double
                switch curve {
                case .value: y = v
                case .cumulative:
                    running[id, default: 0] += v
                    y = running[id]!
                case .share:
                    guard total > 0 else { continue }
                    y = v / total
                }
                result.append(ModelBucketValue(date: dates[i], info: id == restId ? restInfo : ModelInfo.parse(id), value: y))
            }
        }
        return result
    }
}
