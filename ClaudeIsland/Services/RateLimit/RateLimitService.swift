//
//  RateLimitService.swift
//  ClaudeIsland
//
//  Fetches Anthropic API rate limit utilization via a minimal API call
//

import Foundation
import os.log

struct RateLimitData: Sendable, Codable {
    let fiveHourUtilization: Double    // 0.0–1.0
    let fiveHourReset: Date
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

    /// Dernière valeur Fable connue — réutilisée quand /api/oauth/usage échoue
    /// transitoirement (429, 5xx, timeout), pour éviter que la pill disparaisse.
    private var lastFable: (utilization: Double, reset: Date, fetchedAt: Date)?

    /// Durée max de réutilisation d'une valeur Fable en cas d'échecs répétés.
    /// Au-delà, la pill se masque (comportement des plans sans limite Fable).
    private static let fableStaleTTL: TimeInterval = 2 * 3600

    /// Chemin du cache disque
    static let cacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/rate-limit-cache.json")

    private init() {
        if let cached = Self.loadFromDisk(),
           let utilization = cached.fableUtilization,
           let reset = cached.fableReset {
            lastFable = (utilization, reset, cached.fetchedAt)
        }
    }

    func fetch() async throws -> RateLimitData {
        let token: String
        if let cached = cachedToken {
            token = cached
        } else {
            token = try await readOAuthToken()
            cachedToken = token
        }

        do {
            let data = try await fetchRateLimits(token: token)
            saveToDisk(data)
            return data
        } catch RateLimitError.unauthorized {
            // Token expiré → relire le keychain, retry une fois
            cachedToken = nil
            let freshToken = try await readOAuthToken()
            cachedToken = freshToken
            let data = try await fetchRateLimits(token: freshToken)
            saveToDisk(data)
            return data
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

    private func fetchRateLimits(token: String) async throws -> RateLimitData {
        // La limite hebdo Fable vient d'un endpoint distinct : on la récupère en
        // parallèle de l'appel /v1/messages (best-effort, nil si indisponible).
        async let fableTask = fetchFableWeekly(token: token)

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RateLimitError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw RateLimitError.unauthorized
            }
            throw RateLimitError.apiError(statusCode: httpResponse.statusCode)
        }

        let fable: (utilization: Double, reset: Date)?
        do {
            // nil ici = l'endpoint a répondu mais le plan n'a pas de limite Fable
            // → on oublie aussi la dernière valeur (masquage légitime de la pill).
            fable = try await fableTask
            lastFable = fable.map { ($0.utilization, $0.reset, Date()) }
        } catch {
            // Échec transitoire (429, 5xx, timeout…) : on réutilise la dernière
            // valeur connue tant qu'elle est fraîche, au lieu de masquer la pill.
            let fallback = freshLastFable()
            Self.logger.warning("Fable weekly fetch failed: \(error.localizedDescription) — \(fallback != nil ? "reusing last known value" : "no fresh fallback, pill hidden")")
            fable = fallback
        }
        return parseRateLimitHeaders(httpResponse, fable: fable)
    }

    /// Dernière valeur Fable connue, si encore exploitable : pas plus vieille que
    /// fableStaleTTL et dont la fenêtre n'est pas déjà réinitialisée.
    private func freshLastFable() -> (utilization: Double, reset: Date)? {
        guard let last = lastFable,
              Date().timeIntervalSince(last.fetchedAt) < Self.fableStaleTTL,
              last.reset > Date() else {
            return nil
        }
        return (last.utilization, last.reset)
    }

    /// Récupère la limite hebdomadaire propre au modèle Fable via /api/oauth/usage.
    /// Renvoie nil uniquement quand l'endpoint répond sans limite « weekly_scoped »
    /// Fable (plans sans cette limite) ; lève une erreur sur tout échec transitoire
    /// (statut ≠ 200, payload invalide, erreur réseau).
    private func fetchFableWeekly(token: String) async throws -> (utilization: Double, reset: Date)? {
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
            throw RateLimitError.apiError(statusCode: http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = json["limits"] as? [[String: Any]] else {
            throw RateLimitError.invalidResponse
        }

        func isFableScoped(_ entry: [String: Any]) -> Bool {
            guard (entry["kind"] as? String) == "weekly_scoped" else { return false }
            let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
            return (model?["display_name"] as? String) == "Fable"
        }

        // Priorité à l'entrée explicitement Fable, sinon toute limite hebdo scopée.
        guard let entry = limits.first(where: isFableScoped)
                ?? limits.first(where: { ($0["kind"] as? String) == "weekly_scoped" }) else {
            // Réponse valide mais aucune limite hebdo scopée : plan sans limite Fable.
            return nil
        }
        guard let percent = (entry["percent"] as? NSNumber)?.doubleValue else {
            throw RateLimitError.invalidResponse
        }

        // `resets_at` est nul tant qu'aucune activité n'a ancré la fenêtre hebdo
        // Fable (semaine encore vierge). La fenêtre Fable étant calée sur la
        // fenêtre hebdo générale, on retombe alors sur son reset (seven_day),
        // ce qui permet d'afficher la pill à 0 % dès le début de semaine.
        let reset: Date
        if let resetStr = entry["resets_at"] as? String,
           let parsed = Self.isoFormatter.date(from: resetStr) {
            reset = parsed
        } else if let weeklyStr = (json["seven_day"] as? [String: Any])?["resets_at"] as? String,
                  let weeklyReset = Self.isoFormatter.date(from: weeklyStr) {
            reset = weeklyReset
        } else {
            throw RateLimitError.invalidResponse
        }

        return (utilization: percent / 100.0, reset: reset)
    }

    /// Parse les timestamps ISO-8601 avec fraction de seconde (ex. « 2026-07-07T06:00:00.283853+00:00 »).
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Header Parsing

    private func parseRateLimitHeaders(_ response: HTTPURLResponse, fable: (utilization: Double, reset: Date)?) -> RateLimitData {
        let fiveHourUtil = parseDouble(response.value(forHTTPHeaderField: "anthropic-ratelimit-unified-5h-utilization"))
        let fiveHourReset = parseTimestamp(response.value(forHTTPHeaderField: "anthropic-ratelimit-unified-5h-reset"))
        let sevenDayUtil = parseDouble(response.value(forHTTPHeaderField: "anthropic-ratelimit-unified-7d-utilization"))
        let sevenDayReset = parseTimestamp(response.value(forHTTPHeaderField: "anthropic-ratelimit-unified-7d-reset"))
        let overageUtil = parseDouble(response.value(forHTTPHeaderField: "anthropic-ratelimit-unified-overage-utilization"))

        return RateLimitData(
            fiveHourUtilization: fiveHourUtil,
            fiveHourReset: fiveHourReset,
            sevenDayUtilization: sevenDayUtil,
            sevenDayReset: sevenDayReset,
            overageUtilization: overageUtil,
            fableUtilization: fable?.utilization,
            fableReset: fable?.reset,
            fetchedAt: Date()
        )
    }

    private func parseDouble(_ value: String?) -> Double {
        guard let str = value, let val = Double(str) else { return 0 }
        return val
    }

    private func parseTimestamp(_ value: String?) -> Date {
        guard let str = value, let ts = TimeInterval(str) else { return Date() }
        return Date(timeIntervalSince1970: ts)
    }

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
        }
    }
}
