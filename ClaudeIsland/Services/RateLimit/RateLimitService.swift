//
//  RateLimitService.swift
//  ClaudeIsland
//
//  Fetches Anthropic rate limit utilization from /api/oauth/usage (single GET)
//

import Foundation
import os.log

struct RateLimitData: Sendable, Codable {
    // Fenêtre 5 h — `five_hour` vaut null pour certains plans (Ultra, ex-Max,
    // depuis fin octobre 2026) : nil → pill 5h masquée.
    var fiveHourUtilization: Double?   // 0.0–1.0
    var fiveHourReset: Date?
    let sevenDayUtilization: Double    // 0.0–1.0
    let sevenDayReset: Date
    let overageUtilization: Double     // 0.0–1.0
    // Weekly per-model (Fable) limit — from /api/oauth/usage, absent for some plans.
    // Optionnels : décodage nil quand la clé manque (caches antérieurs compatibles).
    var fableUtilization: Double?      // 0.0–1.0
    var fableReset: Date?
    let fetchedAt: Date
}

actor RateLimitService {
    static let shared = RateLimitService()
    private static let logger = Logger(subsystem: "com.claudeisland", category: "RateLimitService")

    /// Cache token OAuth en mémoire (évite la lecture keychain à chaque refresh)
    private var cachedToken: String?

    /// Chemin du cache disque
    static let cacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/rate-limit-cache.json")

    /// Relevé en cours : les appels concurrents (ex. AppDelegate + ailes au
    /// démarrage) partagent la même requête au lieu d'en lancer deux.
    private var inFlight: Task<RateLimitData, Error>?

    /// Dernier relevé réussi, resservi tel quel pendant `minInterval` : deux timers
    /// (ailes 120 s + fond 600 s) ne peuvent ainsi pas dépasser ~15 requêtes/h.
    /// /api/oauth/usage répond 429 au-delà d'une cadence assez basse (mesuré le
    /// 17/09/2026 : ~22 % de refus à une requête toutes les 2 min, puis plusieurs
    /// minutes de 429 continus après une rafale).
    private var lastSuccess: RateLimitData?
    private static let minInterval: TimeInterval = 240

    /// Après un 429, pas de nouvelle tentative avant `cooldownUntil`. Le délai double
    /// à chaque 429 consécutif (5, 10, 20, puis 30 min) : le 05/11/2026, un délai fixe
    /// de 300 s a relancé le serveur toutes les 6 min pendant un blocage de plus de 1 h 30.
    private var cooldownUntil: Date?
    private var consecutive429s = 0
    private static let baseCooldown: TimeInterval = 300
    private static let maxCooldown: TimeInterval = 1800
    /// Plafond de `Retry-After`, pour qu'un en-tête aberrant ne fige pas le relevé.
    private static let maxRetryAfter: TimeInterval = 6 * 3600

    private init() {}

    /// Délai avant la prochaine tentative après `consecutive429s` refus d'affilée (≥ 1).
    /// `Retry-After` prime sur le palier quand il demande d'attendre plus longtemps.
    static func cooldownDelay(consecutive429s: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let doublings = min(max(consecutive429s - 1, 0), 4)
        let backoff = min(baseCooldown * pow(2, Double(doublings)), maxCooldown)
        return min(max(backoff, retryAfter ?? 0), maxRetryAfter)
    }

    /// `Retry-After` : nombre de secondes ou date HTTP (RFC 9110). nil si absent ou illisible.
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) { return seconds >= 0 && seconds.isFinite ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw).map { max($0.timeIntervalSince(now), 0) }
    }

    func fetch() async throws -> RateLimitData {
        if let last = lastSuccess, Date().timeIntervalSince(last.fetchedAt) < Self.minInterval {
            return last
        }
        if let until = cooldownUntil {
            if Date() < until {
                if let last = lastSuccess { return last }
                throw RateLimitError.rateLimited(retryAfter: until.timeIntervalSinceNow)
            }
            cooldownUntil = nil
        }
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await self.performFetch() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func performFetch() async throws -> RateLimitData {
        do {
            let data = try await fetchWithTokenRefresh()
            consecutive429s = 0
            lastSuccess = data
            saveToDisk(data)
            return data
        } catch RateLimitError.rateLimited(let retryAfter) {
            // Relire le trousseau à la prochaine tentative : le 05/11/2026, les 429 ont
            // commencé 2 min après une écriture du trousseau et cessé dès le premier
            // relevé d'un nouveau processus, qui en a relu le jeton.
            cachedToken = nil
            consecutive429s += 1
            let delay = Self.cooldownDelay(consecutive429s: consecutive429s, retryAfter: retryAfter)
            cooldownUntil = Date().addingTimeInterval(delay)
            Self.logger.warning("/api/oauth/usage: \(self.consecutive429s, privacy: .public) refus d'affilée, cooldown \(Int(delay), privacy: .public) s")
            throw RateLimitError.rateLimited(retryAfter: delay)
        }
    }

    private func fetchWithTokenRefresh() async throws -> RateLimitData {
        let token: String
        if let cached = cachedToken {
            token = cached
        } else {
            token = try await readOAuthToken()
            cachedToken = token
        }

        do {
            return try await fetchRateLimits(token: token)
        } catch RateLimitError.unauthorized {
            // Token expiré → relire le keychain, retry une fois
            cachedToken = nil
            let freshToken = try await readOAuthToken()
            cachedToken = freshToken
            return try await fetchRateLimits(token: freshToken)
        }
    }

    // MARK: - OAuth Token

    private func readOAuthToken() async throws -> String {
        let result = await ProcessExecutor.shared.runWithResult(
            "/usr/bin/security",
            arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        )

        switch result {
        case .success(let processResult):
            let raw = processResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                throw RateLimitError.tokenNotFound
            }
            return try parseAccessToken(from: raw)
        case .failure:
            throw RateLimitError.tokenNotFound
        }
    }

    private func parseAccessToken(from raw: String) throws -> String {
        guard let data = raw.data(using: .utf8) else {
            throw RateLimitError.tokenNotFound
        }

        // The keychain stores a JSON object with various credential types
        // We need .claudeAiOauth.accessToken
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty else {
            throw RateLimitError.tokenNotFound
        }

        return accessToken
    }

    // MARK: - API Call

    /// Une seule requête GET /api/oauth/usage fournit tout : fenêtres 5 h et 7 j
    /// (`five_hour` — null sur les plans sans fenêtre 5 h —, `seven_day`), dépassement (`extra_usage`) et limite hebdo
    /// Fable (`limits[kind == weekly_scoped]`).
    ///
    /// Jusqu'au 17/09/2026, les fenêtres 5 h / 7 j étaient lues dans les en-têtes
    /// d'un POST /v1/messages vers Haiku (max_tokens: 1) toutes les 2 minutes :
    /// un vrai message facturé et comptabilisé dans les quotas, pour rien.
    private func fetchRateLimits(token: String) async throws -> RateLimitData {
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RateLimitError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw RateLimitError.unauthorized }
            if http.statusCode == 429 {
                let rawRetryAfter = http.value(forHTTPHeaderField: "Retry-After")
                let body = String(decoding: data.prefix(500), as: UTF8.self)
                Self.logger.warning("HTTP 429 on /api/oauth/usage — Retry-After: \(rawRetryAfter ?? "absent", privacy: .public) — corps: \(body, privacy: .public)")
                throw RateLimitError.rateLimited(retryAfter: Self.parseRetryAfter(rawRetryAfter))
            }
            throw RateLimitError.apiError(statusCode: http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.logger.error("/api/oauth/usage: réponse non JSON")
            throw RateLimitError.invalidResponse
        }

        // `five_hour` est null sur les plans sans fenêtre 5 h (Ultra) : on ne
        // l'exige plus, sinon tout le relevé échouait en silence.
        let fiveHour: (utilization: Double, reset: Date)? =
            json["five_hour"] is NSNull || json["five_hour"] == nil ? nil : try Self.parseWindow(json["five_hour"])
        let sevenDay = try Self.parseWindow(json["seven_day"])

        // Dépassement : `extra_usage.utilization` (pourcentage) ; absent ou null
        // quand l'option est désactivée → 0 (pill masquée).
        let overage = ((json["extra_usage"] as? [String: Any])?["utilization"] as? NSNumber)?.doubleValue ?? 0

        let fable = Self.parseFableWeekly(json, weeklyReset: sevenDay.reset)

        return RateLimitData(
            fiveHourUtilization: fiveHour?.utilization,
            fiveHourReset: fiveHour?.reset,
            sevenDayUtilization: sevenDay.utilization,
            sevenDayReset: sevenDay.reset,
            overageUtilization: overage / 100.0,
            fableUtilization: fable?.utilization,
            fableReset: fable?.reset,
            fetchedAt: Date()
        )
    }

    /// `{ "utilization": <pourcentage>, "resets_at": <ISO-8601 ou null> }`.
    /// Sans `resets_at` (fenêtre pas encore ancrée), on retombe sur « maintenant »,
    /// comme le faisait l'ancien parsing des en-têtes.
    private static func parseWindow(_ any: Any?) throws -> (utilization: Double, reset: Date) {
        guard let dict = any as? [String: Any],
              let percent = (dict["utilization"] as? NSNumber)?.doubleValue else {
            logger.error("/api/oauth/usage: fenêtre illisible (\(String(describing: any), privacy: .public))")
            throw RateLimitError.invalidResponse
        }
        let reset = (dict["resets_at"] as? String).flatMap { isoFormatter.date(from: $0) } ?? Date()
        return (percent / 100.0, reset)
    }

    /// Limite hebdomadaire propre au modèle Fable dans `limits`. Renvoie nil
    /// quand le plan n'a pas de limite hebdo scopée (pill masquée).
    private static func parseFableWeekly(_ json: [String: Any], weeklyReset: Date) -> (utilization: Double, reset: Date)? {
        guard let limits = json["limits"] as? [[String: Any]] else { return nil }

        func isFableScoped(_ entry: [String: Any]) -> Bool {
            guard (entry["kind"] as? String) == "weekly_scoped" else { return false }
            let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
            return (model?["display_name"] as? String) == "Fable"
        }

        // Priorité à l'entrée explicitement Fable, sinon toute limite hebdo scopée.
        guard let entry = limits.first(where: isFableScoped)
                ?? limits.first(where: { ($0["kind"] as? String) == "weekly_scoped" }),
              let percent = (entry["percent"] as? NSNumber)?.doubleValue else {
            return nil
        }

        // `resets_at` est nul tant qu'aucune activité n'a ancré la fenêtre hebdo
        // Fable (semaine encore vierge) ; la fenêtre Fable étant calée sur la
        // fenêtre hebdo générale, on retombe alors sur son reset.
        let reset = (entry["resets_at"] as? String).flatMap { isoFormatter.date(from: $0) } ?? weeklyReset
        return (utilization: percent / 100.0, reset: reset)
    }

    /// Parse les timestamps ISO-8601 avec fraction de seconde (ex. « 2026-07-07T06:00:00.283853+00:00 »).
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Disk Cache

    private func saveToDisk(_ data: RateLimitData) {
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: Self.cacheURL, options: .atomic)
        } catch {
            Self.logger.warning("Failed to save rate limit cache: \(error.localizedDescription)")
        }
    }

    /// Chargement du cache — nonisolated static pour appel synchrone depuis init()
    nonisolated static func loadFromDisk() -> RateLimitData? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(RateLimitData.self, from: data) else {
            return nil
        }
        return cached
    }
}

// MARK: - Errors

enum RateLimitError: Error, LocalizedError {
    case tokenNotFound
    case unauthorized
    case invalidResponse
    case apiError(statusCode: Int)
    case rateLimited(retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .tokenNotFound:
            return "OAuth token not found in Keychain"
        case .unauthorized:
            return "OAuth token expired or invalid"
        case .invalidResponse:
            return "Invalid API response"
        case .apiError(let code):
            return "API error (HTTP \(code))"
        case .rateLimited(let retryAfter):
            return "Rate limited (HTTP 429), next attempt in \(Int(retryAfter ?? 0)) s"
        }
    }
}
