//
//  MonthlyCostChart.swift
//  ClaudeIsland
//
//  Coût réel par mois calendaire (panneau « Tokens — All Time », mode mois).
//  Le mois en cours montre le coût à date (plein) et sa projection de fin de
//  mois (partie estompée), comme un compteur mensuel d'énergie.
//

import Charts
import SwiftUI

struct MonthlyCostChart: View {
    let months: [MonthCost]
    let fontSize: CGFloat

    @State private var hovered: MonthCost?

    /// Slot 1 de la palette catégorielle sombre validée (cf. WorkdayCostChart).
    private static let barColor = Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255)

    private var smallFont: Font { .system(size: fontSize - 1, weight: .medium, design: .monospaced) }
    private var boldFont: Font { .system(size: fontSize - 1, weight: .bold, design: .monospaced) }
    private var charWidth: CGFloat { (fontSize - 1) * 0.62 }

    var body: some View {
        let shown = hovered ?? months.last

        VStack(alignment: .leading, spacing: 4) {
            // Légende à largeurs réservées : ne bouge pas pendant le survol.
            HStack(spacing: 6) {
                Capsule().fill(Self.barColor).frame(width: 10, height: 2)
                Text(shown.map { Self.monthFormatter.string(from: $0.month) } ?? "")
                    .foregroundColor(.white.opacity(0.45))
                    .frame(width: charWidth * 11, alignment: .leading)  // « sept. 2026 »
                Text(shown.map { Self.formatEur($0.costUSD * ModelPricing.usdToEur) } ?? "—")
                    .font(boldFont).foregroundColor(.white.opacity(0.75))
                    .frame(width: charWidth * 7, alignment: .leading)
                Text(shown?.projectedUSD.map { "→ ~" + Self.formatEur($0 * ModelPricing.usdToEur) + " projeté" } ?? "")
                    .foregroundColor(.white.opacity(0.45))
                Spacer(minLength: 0)
            }
            .font(smallFont)
            .lineLimit(1)

            Chart {
                ForEach(months, id: \.month) { month in
                    let eur = month.costUSD * ModelPricing.usdToEur
                    let isHovered = hovered?.month == month.month
                    BarMark(x: .value("Mois", month.month, unit: .month),
                            yStart: .value("€", 0), yEnd: .value("€", eur), width: .ratio(0.7))
                        .foregroundStyle(Self.barColor.opacity(hovered == nil || isHovered ? 1 : 0.55))
                        .cornerRadius(2)
                    if let projected = month.projectedUSD.map({ $0 * ModelPricing.usdToEur }), projected > eur {
                        BarMark(x: .value("Mois", month.month, unit: .month),
                                yStart: .value("€", eur), yEnd: .value("€", projected), width: .ratio(0.7))
                            .foregroundStyle(Self.barColor.opacity(0.25))
                            .cornerRadius(2)
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
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
                                hovered = months.last { $0.month <= date } ?? months.first
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .frame(height: 90)
            .environment(\.locale, Locale(identifier: "fr_FR"))  // mois de l'axe en français

            Text("Coût réel par mois · mois en cours : à date + projection estompée")
                .font(.system(size: fontSize - 2, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
        }
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "MMM yyyy"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func formatEur(_ eur: Double) -> String {
        eur >= 1_000 ? String(format: "%.1fk €", eur / 1_000) : String(format: "%.0f €", eur)
    }
}
