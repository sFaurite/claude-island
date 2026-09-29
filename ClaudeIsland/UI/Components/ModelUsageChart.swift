//
//  ModelUsageChart.swift
//  ClaudeIsland
//
//  Détail par modèle du panneau « Tokens — All Time » (vue Modèles) :
//  histogramme horizontal (classement) et courbes par modèle dans le temps.
//

import Charts
import SwiftUI

/// Mise en forme partagée des deux vues.
enum ModelUsageStyle {
    /// Hauteur du corps : l'histogramme tient ses 9 lignes au plus ; le
    /// graphe (légende 3 lignes + courbes + note) demande davantage.
    static func bodyHeight(fontSize: CGFloat, graph: Bool) -> CGFloat {
        graph ? 14 * (fontSize + 5) : 9 * (fontSize + 5)
    }

    private static let familyColors: [ModelFamily: Color] = [
        .fable:  Color(red: 0x9B / 255, green: 0x6B / 255, blue: 0xDF / 255),
        .opus:   Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255),
        .sonnet: Color(red: 0x19 / 255, green: 0x9E / 255, blue: 0x70 / 255),
        .haiku:  Color(red: 0xD9 / 255, green: 0x59 / 255, blue: 0x26 / 255),
        .other:  Color(red: 0x8A / 255, green: 0x8F / 255, blue: 0x98 / 255),
    ]

    /// Une teinte par famille ; les modèles d'une même famille s'en distinguent
    /// par l'intensité (le plus utilisé = pleine teinte). L'identité passe aussi
    /// par le libellé, jamais par la seule couleur.
    static func colors(for infos: [ModelInfo]) -> [String: Color] {
        var rank: [ModelFamily: Int] = [:]
        var result: [String: Color] = [:]
        for info in infos where result[info.id] == nil {
            let i = rank[info.family, default: 0]
            rank[info.family] = i + 1
            let base = familyColors[info.family] ?? .gray
            result[info.id] = base.opacity(max(0.4, 1 - 0.2 * Double(i)))
        }
        return result
    }

    static func formatEur(_ usd: Double) -> String {
        let eur = usd * ModelPricing.usdToEur
        if eur >= 1_000 { return String(format: "%.1fk €", eur / 1_000) }
        if eur >= 10 { return String(format: "%.0f €", eur) }
        return String(format: "%.1f €", eur)
    }

    static func formatTokens(_ count: Double) -> String {
        if count >= 1_000_000_000 { return String(format: "%.1fB", count / 1_000_000_000) }
        if count >= 1_000_000 { return String(format: "%.1fM", count / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", count / 1_000) }
        return String(format: "%.0f", count)
    }

    static func format(_ value: Double, metric: ModelMetric) -> String {
        metric == .cost ? formatEur(value) : formatTokens(value)
    }

    static func formatPercent(_ ratio: Double) -> String {
        String(format: ratio > 0 && ratio < 0.01 ? "<1%%" : "%.0f%%", ratio * 100)
    }
}

// MARK: - Histogramme

struct ModelHistogram: View {
    let totals: [ModelTotal]          // déjà classés, « Reste » compris
    let metric: ModelMetric
    let fontSize: CGFloat

    private var smallFont: Font { .system(size: fontSize - 1, weight: .medium, design: .monospaced) }
    private var boldFont: Font { .system(size: fontSize - 1, weight: .bold, design: .monospaced) }
    private var charWidth: CGFloat { (fontSize - 1) * 0.62 }

    var body: some View {
        let colors = ModelUsageStyle.colors(for: totals.map(\.info))
        let maxValue = max(totals.map { $0.value(metric) }.max() ?? 1, 1)
        let sum = max(totals.reduce(0) { $0 + $1.value(metric) }, 1)

        VStack(alignment: .leading, spacing: 5) {
            ForEach(totals) { total in
                let value = total.value(metric)
                HStack(spacing: 6) {
                    Text(total.info.label)
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                        .frame(width: charWidth * 12, alignment: .leading)
                    GeometryReader { geo in
                        Capsule()
                            .fill(colors[total.info.id] ?? .gray)
                            .frame(width: max(2, geo.size.width * value / maxValue))
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: fontSize - 2)
                    Text(ModelUsageStyle.format(value, metric: metric))
                        .font(boldFont).foregroundColor(.white.opacity(0.75))
                        .frame(width: charWidth * 8, alignment: .trailing)
                    Text(ModelUsageStyle.formatPercent(value / sum))
                        .foregroundColor(.white.opacity(0.35))
                        .frame(width: charWidth * 4, alignment: .trailing)
                }
                .frame(height: fontSize)
            }
        }
        .font(smallFont)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Graphe en courbes

struct ModelLineChart: View {
    let points: [ModelBucketValue]    // séries continues (ModelBreakdown.series)
    let totals: [ModelTotal]          // légende (ordre de lecture) ; « Reste » compris
    let metric: ModelMetric
    let curve: ModelCurve
    let monthly: Bool
    let shortPeriod: Bool             // ≤ 90 j : axe en jours plutôt qu'en mois
    let fontSize: CGFloat

    @State private var hoveredDate: Date?
    /// Modèle mis en avant au survol de sa légende (les autres s'estompent).
    @State private var highlighted: String?

    private var smallFont: Font { .system(size: fontSize - 1, weight: .medium, design: .monospaced) }
    private var boldFont: Font { .system(size: fontSize - 1, weight: .bold, design: .monospaced) }
    private var legendRows: Int { (totals.count + 2) / 3 }
    private var legendHeight: CGFloat { CGFloat(max(1, legendRows)) * (fontSize + 3) }
    private var dates: [Date] { Array(Set(points.map(\.date))).sorted() }

    private func format(_ value: Double) -> String {
        curve == .share ? ModelUsageStyle.formatPercent(value) : ModelUsageStyle.format(value, metric: metric)
    }

    /// Valeur affichée en légende : point survolé, sinon total de la période
    /// (le cumul finit sur ce total ; la part, sur la part du total).
    private func legendValue(_ total: ModelTotal) -> String {
        if let date = hoveredDate {
            let v = points.first { $0.date == date && $0.info.id == total.info.id }?.value
            return v.map(format) ?? "—"
        }
        if curve == .share {
            let sum = totals.reduce(0) { $0 + $1.value(metric) }
            return format(sum > 0 ? total.value(metric) / sum : 0)
        }
        return ModelUsageStyle.format(total.value(metric), metric: metric)
    }

    private var caption: String {
        switch curve {
        case .value:      return monthly ? "Total par mois" : "Par jour · moyenne glissante \(ModelBreakdown.smoothingDays) j"
        case .cumulative: return "Cumul depuis le début de la période"
        case .share:      return monthly ? "Part de chaque modèle par mois" : "Part par jour · lissée \(ModelBreakdown.smoothingDays) j"
        }
    }

    var body: some View {
        let colors = ModelUsageStyle.colors(for: totals.map(\.info))
        let labels = totals.map(\.info.label)
        let range = totals.map { colors[$0.info.id] ?? .gray }
        let captionHeight = fontSize + 2
        let chartHeight = ModelUsageStyle.bodyHeight(fontSize: fontSize, graph: true) - legendHeight - captionHeight - 12

        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .leading), count: 3),
                      alignment: .leading, spacing: 3) {
                ForEach(totals) { total in
                    let dimmed = highlighted != nil && highlighted != total.info.id
                    HStack(spacing: 4) {
                        Capsule().fill(colors[total.info.id] ?? .gray).frame(width: 10, height: 2)
                        Text(total.info.label).foregroundColor(.white.opacity(0.45)).lineLimit(1)
                        Text(legendValue(total))
                            .font(boldFont).foregroundColor(.white.opacity(0.75)).lineLimit(1)
                    }
                    .opacity(dimmed ? 0.4 : 1)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onHover { highlighted = $0 ? total.info.id : (highlighted == total.info.id ? nil : highlighted) }
                }
            }
            .font(smallFont)
            .frame(height: legendHeight, alignment: .top)

            Chart {
                ForEach(points) { point in lineMarks(point) }
                if let hoveredDate { hoverMarks(hoveredDate) }
            }
            .chartForegroundStyleScale(domain: labels, range: range)
            .chartLegend(.hidden)
            .chartYScale(domain: 0...yMax)
            .chartXScale(range: .plotDimension(startPadding: 0, endPadding: 6))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel(format: axisFormat)
                        .font(.system(size: fontSize - 2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(format(v))
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
                                hoveredDate = dates.min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
                            case .ended:
                                hoveredDate = nil
                            }
                        }
                }
            }
            .frame(height: max(70, chartHeight))

            HStack(spacing: 6) {
                Text(caption)
                Spacer(minLength: 0)
                if let hoveredDate {
                    Text((monthly ? Self.monthFormatter : Self.dayFormatter).string(from: hoveredDate))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .font(.system(size: fontSize - 2, design: .monospaced))
            .foregroundColor(.white.opacity(0.3))
            .lineLimit(1)
            .frame(height: captionHeight)
        }
        .frame(height: ModelUsageStyle.bodyHeight(fontSize: fontSize, graph: true), alignment: .top)
    }

    private var axisFormat: Date.FormatStyle {
        shortPeriod && !monthly
            ? .dateTime.day().month(.abbreviated).locale(Self.frLocale)
            : .dateTime.month(.abbreviated).locale(Self.frLocale)
    }

    /// Haut de l'axe Y : plancher à 0 explicite (valeurs toujours ≥ 0), petite
    /// marge au-dessus du maximum ; part % plafonnée à 100 %.
    private var yMax: Double {
        if curve == .share { return 1 }
        let peak = points.map(\.value).max() ?? 0
        return peak > 0 ? peak * 1.05 : 1
    }

    private var dateUnit: Calendar.Component { monthly ? .month : .day }

    @ChartContentBuilder
    private func lineMarks(_ point: ModelBucketValue) -> some ChartContent {
        let isOn = highlighted == nil || highlighted == point.info.id
        let width: CGFloat = highlighted == point.info.id ? 2.5 : 1.5
        LineMark(x: .value("Date", point.date, unit: dateUnit),
                 y: .value("Valeur", point.value),
                 series: .value("Série", point.info.id))
            .foregroundStyle(by: .value("Modèle", point.info.label))
            .lineStyle(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            .interpolationMethod(curve == .cumulative ? .linear : .monotone)
            .opacity(isOn ? 1 : 0.15)
        // Mois : peu de points, on les marque pour lire chaque valeur.
        if monthly {
            PointMark(x: .value("Date", point.date, unit: .month), y: .value("Valeur", point.value))
                .foregroundStyle(by: .value("Modèle", point.info.label))
                .symbolSize(14)
                .opacity(isOn ? 1 : 0.15)
        }
    }

    @ChartContentBuilder
    private func hoverMarks(_ date: Date) -> some ChartContent {
        RuleMark(x: .value("Date", date, unit: dateUnit))
            .foregroundStyle(.white.opacity(0.35))
            .lineStyle(StrokeStyle(lineWidth: 1))
        ForEach(points.filter { $0.date == date }) { point in
            PointMark(x: .value("Date", point.date, unit: dateUnit), y: .value("Valeur", point.value))
                .foregroundStyle(by: .value("Modèle", point.info.label))
                .symbolSize(24)
        }
    }

    /// Locale explicite : l'app n'étant pas localisée en français, Locale.current
    /// y vaut l'anglais, et les étiquettes d'axe ignorent `.environment(\.locale)`.
    private static let frLocale = Locale(identifier: "fr_FR")

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = frLocale
        f.dateFormat = "EEE dd/MM"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = frLocale
        f.dateFormat = "MMM yyyy"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
