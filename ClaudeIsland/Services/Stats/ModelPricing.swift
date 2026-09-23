//
//  ModelPricing.swift
//  ClaudeIsland
//
//  Coût « équivalent API » de l'usage — ce que coûterait l'usage sans forfait.
//  Source unique des tarifs : PRICING dans refresh-claude-stats.mjs, recopié
//  dans stats-cache.json (champ `pricing`) et décodé ici pour chiffrer le
//  compteur live. Cache antérieur au v3 → pas de table → coût 0.
//

import Foundation

struct ModelPrice: Codable, Sendable {
    /// Motif cherché dans l'id du modèle ; le 1er qui correspond l'emporte.
    let match: String
    // USD / million de tokens
    let input: Double
    let write5m: Double
    let write1h: Double
    let read: Double
    let output: Double
}

struct ModelPricing: Codable, Sendable {
    /// Taux USD → EUR figé : moyenne BCE du 23/06 au 22/09/2026 (0,869 ; 0,872 au 22/09).
    static let usdToEur = 0.87

    let webSearchUSD: Double
    let models: [ModelPrice]

    static let empty = ModelPricing(webSearchUSD: 0, models: [])

    /// Coût USD d'un usage dédupliqué. Fast mode : tarif ×2 sur toutes les catégories.
    func costUSD(model: String, input: Int, write5m: Int, write1h: Int,
                 read: Int, output: Int, webSearches: Int, fast: Bool) -> Double {
        guard let p = models.first(where: { model.contains($0.match) }) else { return 0 }
        let tokens = Double(input) * p.input + Double(write5m) * p.write5m
            + Double(write1h) * p.write1h + Double(read) * p.read + Double(output) * p.output
        return (tokens / 1_000_000 + Double(webSearches) * webSearchUSD) * (fast ? 2 : 1)
    }
}
