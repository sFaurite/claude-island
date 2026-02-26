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

    private init() {}

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

        return parseRateLimitHeaders(httpResponse)
    }

    // MARK: - Header Parsing

    private func parseRateLimitHeaders(_ response: HTTPURLResponse) -> RateLimitData {
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
