//
//  WorkdayCostChart.swift
//  ClaudeIsland
//
//  Tendance du coût par jour ouvré actif (panneau « Tokens — All Time ») :
//  moyenne depuis le début, glissantes 90 j et 30 j — comme la conso moyenne
//  projetée d'un véhicule électrique. 30 j au-dessus de 90 j = l'usage accélère.
//

import Charts
import SwiftUI

struct WorkdayCostChart: View {
    let points: [WorkdayCostPoint]
    let fontSize: CGFloat

    @State private var hovered: WorkdayCostPoint?

    /// Séries dans l'ordre de lecture ; couleurs = palette catégorielle sombre
    /// validée (bleu / orange / aqua, contraste ≥ 3:1, ΔE daltonisme ≥ 9).
    private enum Series: String, CaseIterable {
        case d30 = "30 j", d90 = "90 j", total = "Total"

        var color: Color {
            switch self {
            case .d30:   return Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255)
            case .d90:   return Color(red: 0xD9 / 255, green: 0x59 / 255, blue: 0x26 / 255)
            case .total: return Color(red: 0x19 / 255, green: 0x9E / 255, blue: 0x70 / 255)
            }
        }

        func eur(_ point: WorkdayCostPoint) -> Double? {
            let usd: Double?
            switch self {
            case .d30:   usd = point.d30USD
            case .d90:   usd = point.d90USD
            case .total: usd = point.totalUSD
            }
            return usd.map { $0 * ModelPricing.usdToEur }
        }
    }

    private var smallFont: Font { .system(size: fontSize - 1, weight: .medium, design: .monospaced) }
    private var boldFont: Font { .system(size: fontSize - 1, weight: .bold, design: .monospaced) }
    /// Chasse d'un caractère monospace (≈ 0,6 em) à la taille des valeurs.
    private var charWidth: CGFloat { (fontSize - 1) * 0.62 }

    var body: some View {
        let shown = hovered ?? points.last

        VStack(alignment: .leading, spacing: 4) {
            // Légende = valeurs du point survolé (sinon d'hier) : l'identité ne
            // repose jamais sur la seule couleur, le texte reste en encre neutre.
            // Largeurs réservées (police à chasse fixe) : la légende ne change
            // jamais de taille ni ne passe à la ligne pendant le survol.
            HStack(spacing: 0) {
                ForEach(Series.allCases, id: \.self) { series in
                    HStack(spacing: 4) {
                        Capsule().fill(series.color).frame(width: 10, height: 2)
                        Text(series.rawValue).foregroundColor(.white.opacity(0.45))
                        Text(shown.flatMap(series.eur).map(Self.formatEur) ?? "—")
                            .font(boldFont).foregroundColor(.white.opacity(0.75))
                            .frame(width: charWidth * 6, alignment: .leading)
                    }
                    .lineLimit(1)
                    .fixedSize()
                    Spacer(minLength: 8)
                }
                Text(shown.map { Self.dayFormatter.string(from: $0.date) } ?? "")
                    .foregroundColor(.white.opacity(hovered == nil ? 0.3 : 0.6))
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(smallFont)

            Chart {
                ForEach(Series.allCases, id: \.self) { series in
                    ForEach(points, id: \.date) { point in
                        if let value = series.eur(point) {
                            LineMark(
                                x: .value("Jour", point.date, unit: .day),
                                y: .value("€/j ouvré", value),
                                series: .value("Série", series.rawValue)
                            )
                            .foregroundStyle(series.color)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                        }
                    }
                }
                if let hovered {
                    RuleMark(x: .value("Jour", hovered.date, unit: .day))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    ForEach(Series.allCases, id: \.self) { series in
                        if let value = series.eur(hovered) {
                            PointMark(x: .value("Jour", hovered.date, unit: .day), y: .value("€/j ouvré", value))
                                .foregroundStyle(series.color)
                                .symbolSize(24)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartXScale(range: .plotDimension(startPadding: 0, endPadding: 14))
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel(format: .dateTime.month(.abbreviated), centered: false)
                        .font(.system(size: fontSize - 2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel {
                        if let eur = value.as(Double.self) {
                            Text(Self.formatEur(eur))
                                .font(.system(size: fontSize - 2, design: .monospaced))
                                .foregroundColor(.white.opacity(0.35))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plot = proxy.plotFrame else { return }
                                let x = location.x - geo[plot].origin.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                hovered = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .frame(height: 90)

            Text("€ par jour ouvré actif · ETP = ×200")
                .font(.system(size: fontSize - 2, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func formatEur(_ eur: Double) -> String {
        eur >= 1_000 ? String(format: "%.1fk €", eur / 1_000) : String(format: "%.0f €", eur)
    }
}
