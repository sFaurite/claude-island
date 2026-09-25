//
//  NotchWingsView.swift
//  ClaudeIsland
//
//  Wings displayed on each side of the notch when menu bar is hidden (fullscreen)
//  Left wing: Anthropic rate limits  |  Right wing: activity heatmap + daily stats
//

import Combine
import SwiftUI
import os.log

// MARK: - Controller

@MainActor
final class NotchWingsController: ObservableObject {
    @Published var rateLimits: RateLimitData?
    @Published var stats: DailyStats?
    @Published var tick: Bool = false // forces view refresh for staleness check

    private static let logger = Logger(subsystem: "com.claudeisland", category: "NotchWingsController")
    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    private var activity: NSObjectProtocol?

    init() {
        // Rate limits : chargement instantané depuis le cache disque (~1ms)
        self.rateLimits = RateLimitService.loadFromDisk()

        // Stats : chargement depuis le fichier cache (async pour ne pas bloquer le main thread)
        Task { @MainActor [weak self] in
            let loaded = await Task.detached { StatsReader.read() }.value
            // Ne pas écraser si startAutoRefresh() a déjà mis à jour entre-temps
            if self?.stats == nil {
                self?.stats = loaded
            }
        }
    }

    func refresh() {
        Task {
            async let rl = fetchRateLimits()
            async let st = Task.detached { StatsReader.read() }.value

            rateLimits = await rl
            stats = await st
        }
    }

    func startAutoRefresh() {
        // Prevent App Nap from suspending the refresh/tick timers.
        // Without this, LSUIElement apps that are never frontmost see their
        // scheduled timers coalesced indefinitely — the rate-limit pill freezes
        // on a stale value (e.g. "4h") until a UI event wakes the runloop.
        if activity == nil {
            activity = Foundation.ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Notch wings rate-limit refresh"
            )
        }

        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        // Tick every 30s to re-evaluate staleness in the view
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick.toggle()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
        if let activity {
            Foundation.ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func fetchRateLimits() async -> RateLimitData? {
        do {
            let data = try await RateLimitService.shared.fetch()
            return data
        } catch {
            Self.logger.warning("Rate limit fetch failed: \(error.localizedDescription, privacy: .public)")
            return rateLimits
        }
    }
}

// MARK: - Wing Section

enum WingSection: Equatable {
    case rateLimitFable, rateLimit5h, rateLimit7j, overage
    case heatmap, tokensAllTime, tokensToday, daily, record

    /// Map from element id to WingSection
    static func from(elementId: String) -> WingSection? {
        switch elementId {
        case "fable":         return .rateLimitFable
        case "5h":            return .rateLimit5h
        case "7j":            return .rateLimit7j
        case "heatmap":       return .heatmap
        case "tokensAllTime": return .tokensAllTime
        case "tokensToday":   return .tokensToday
        case "lastDay":       return .daily
        case "record":        return .record
        default:              return nil
        }
    }

    /// Determine side dynamically from wingsElements config
    func isLeft(in elements: [WingElement]) -> Bool {
        switch self {
        case .overage:
            return elements.first(where: { $0.id == "5h" })?.side == .left
        case .rateLimitFable:
            return elements.first(where: { $0.id == "fable" })?.side == .left
        case .rateLimit5h:
            return elements.first(where: { $0.id == "5h" })?.side == .left
        case .rateLimit7j:
            return elements.first(where: { $0.id == "7j" })?.side == .left
        case .heatmap:
            return elements.first(where: { $0.id == "heatmap" })?.side == .left
        case .tokensAllTime:
            return elements.first(where: { $0.id == "tokensAllTime" })?.side == .left
        case .tokensToday:
            return elements.first(where: { $0.id == "tokensToday" })?.side == .left
        case .daily:
            return elements.first(where: { $0.id == "lastDay" })?.side == .left
        case .record:
            return elements.first(where: { $0.id == "record" })?.side == .left
        }
    }
}

// MARK: - Wings View

struct NotchWingsView: View {
    let rateLimits: RateLimitData?
    let stats: DailyStats?
    let notchWidth: CGFloat
    let height: CGFloat
    var tick: Bool = false // triggers re-render for staleness
    @Binding var expandedSection: WingSection?
    @Binding var expandedHeight: CGFloat

    @AppStorage("wingsLayout") private var wingsLayoutRaw: String = WingsLayout.both.rawValue
    @AppStorage("wingsFontSize") private var fontSizeRaw: Double = 10
    /// Panneau all-time : affichage par jour (false) ou par mois (true).
    @AppStorage("allTimeCostMonthly") private var allTimeMonthly: Bool = false
    /// Record : jour au plus de tokens (false) ou au coût API le plus élevé (true).
    @AppStorage("recordByCost") private var recordByCost: Bool = false
    @AppStorage("wingsElements") private var wingsElementsData: Data = {
        (try? JSONEncoder().encode(WingElement.defaultElements)) ?? Data()
    }()

    private var layout: WingsLayout { WingsLayout(rawValue: wingsLayoutRaw) ?? .both }
    private var fontSize: CGFloat { CGFloat(fontSizeRaw) }
    private var wingsElements: [WingElement] {
        (try? JSONDecoder().decode([WingElement].self, from: wingsElementsData)) ?? WingElement.defaultElements
    }
    private var leftElements: [WingElement] {
        wingsElements.filter { $0.side == .left && $0.visible }
    }
    private var rightElements: [WingElement] {
        wingsElements.filter { $0.side == .right && $0.visible }
    }
    private var wingFont: Font { Font.system(size: fontSize, weight: .medium, design: .monospaced) }
    private var smallFont: Font { Font.system(size: fontSize - 1, weight: .medium, design: .monospaced) }
    private var boldFont: Font { Font.system(size: fontSize - 1, weight: .bold, design: .monospaced) }
    private let wingPadding: CGFloat = 8
    private let wingCornerRadius: CGFloat = 6
    private var detailPanelHeight: CGFloat {
        guard let section = expandedSection else { return 108 }
        switch section {
        case .daily:
            guard let st = stats, !st.last7Days.isEmpty else { return 108 }
            return CGFloat(20 + 18 + st.last7Days.count * 18)
        case .tokensAllTime:
            // Bloc de base + tableau de projection (titre, en-tête, 3 lignes)
            // + graphe de tendance (légende, 90 pt, note)
            return 108 + 5 * (fontSize + 6) + 8 + 90 + 2 * (fontSize + 6) + 16
        default:
            return 108
        }
    }

    var body: some View {
        let _ = tick // consumed to trigger re-render for staleness
        HStack(alignment: .top, spacing: 0) {
            if layout.showLeft {
                VStack(alignment: .trailing, spacing: 4) {
                    leftWingBar
                    if let section = expandedSection, section.isLeft(in: wingsElements) {
                        leftDetailPanel(for: section)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }

            Color.clear
                .frame(width: notchWidth + 16, height: height)
                .allowsHitTesting(false)

            if layout.showRight {
                VStack(alignment: .leading, spacing: 4) {
                    rightWingBar
                    if let section = expandedSection, !section.isLeft(in: wingsElements) {
                        rightDetailPanel(for: section)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 8)
        .background(alignment: .top) {
            Color.black
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: expandedSection)
        .onChange(of: expandedSection) { _, newValue in
            expandedHeight = newValue != nil ? detailPanelHeight + 8 : 0
        }
    }

    // MARK: - Toggle

    private func toggleSection(_ section: WingSection) {
        if expandedSection == section {
            expandedSection = nil
        } else {
            expandedSection = section
        }
    }

    private var wingBackground: some View {
        RoundedRectangle(cornerRadius: wingCornerRadius)
            .fill(.black.opacity(0.7))
            .background(
                RoundedRectangle(cornerRadius: wingCornerRadius)
                    .fill(.ultraThinMaterial)
            )
    }

    // MARK: - Left Wing Bar (Rate Limits)

    private let staleThreshold: TimeInterval = 600 // 10 minutes

    private var leftWingBar: some View {
        HStack(spacing: 8) {
            dynamicWingContent(for: .left)
        }
        .padding(.horizontal, wingPadding)
        .padding(.vertical, 4)
        .frame(height: height)
        .background(wingBackground)
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    // MARK: - Right Wing Bar (Heatmap + Stats)

    private var rightWingBar: some View {
        HStack(spacing: 6) {
            dynamicWingContent(for: .right)
        }
        .padding(.horizontal, wingPadding)
        .padding(.vertical, 4)
        .frame(height: height)
        .background(wingBackground)
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    // MARK: - Dynamic Wing Content

    @ViewBuilder
    private func dynamicWingContent(for side: WingSide) -> some View {
        let visibleElements = wingsElements.filter { $0.side == side && $0.visible }
        let hasRateLimits = rateLimits != nil
        let hasStats = stats != nil
        let needsData = visibleElements.contains { ["fable", "5h", "7j"].contains($0.id) } ? hasRateLimits : true
        let needsStats = visibleElements.contains { ["heatmap", "tokensAllTime", "tokensToday", "lastDay", "record"].contains($0.id) } ? hasStats : true

        if visibleElements.isEmpty || (!needsData && !needsStats) {
            Text("—")
                .font(wingFont)
                .foregroundColor(.white.opacity(0.4))
        } else {
            // Stale warning for rate limits on this side
            if let rl = rateLimits,
               visibleElements.contains(where: { $0.id == "fable" || $0.id == "5h" || $0.id == "7j" }),
               rl.fetchedAt.timeIntervalSinceNow < -staleThreshold {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: fontSize - 2))
                    Text(formatElapsed(since: rl.fetchedAt))
                        .font(smallFont)
                }
                .foregroundColor(TerminalColors.amber)
                .allowsHitTesting(false)
            }

            ForEach(Array(visibleElements.enumerated()), id: \.element.id) { index, element in
                if index > 0 {
                    // Separator: vertical bar after heatmap, dot between others
                    if element.id == "heatmap" || (index > 0 && visibleElements[index - 1].id == "heatmap") {
                        Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 20)
                            .allowsHitTesting(false)
                    } else {
                        Text("·").font(wingFont).foregroundColor(.white.opacity(0.2))
                            .allowsHitTesting(false)
                    }
                }

                wingElementView(for: element)
            }

            // Overage pill (always follows rate limits if present on this side)
            if let rl = rateLimits, rl.overageUtilization > 0,
               visibleElements.contains(where: { $0.id == "5h" || $0.id == "7j" }) {
                overagePill(utilization: rl.overageUtilization)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleSection(.overage) }
            }
        }
    }

    @ViewBuilder
    private func wingElementView(for element: WingElement) -> some View {
        switch element.id {
        case "fable":
            if let rl = rateLimits, let util = rl.fableUtilization, let reset = rl.fableReset {
                rateLimitPill(label: "Fable", utilization: util, reset: reset, forceUnit: .days, windowSeconds: 7 * 86400)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleSection(.rateLimitFable) }
            }
        case "5h":
            if let rl = rateLimits {
                rateLimitPill(label: "5h", utilization: rl.fiveHourUtilization, reset: rl.fiveHourReset, forceUnit: nil, windowSeconds: 5 * 3600)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleSection(.rateLimit5h) }
            }
        case "7j":
            if let rl = rateLimits {
                rateLimitPill(label: "7j", utilization: rl.sevenDayUtilization, reset: rl.sevenDayReset, forceUnit: .days, windowSeconds: 7 * 86400)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleSection(.rateLimit7j) }
            }
        case "heatmap":
            if let st = stats {
                ActivityHeatmap(entries: st.heatmapEntries)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleSection(.heatmap) }
            }
        case "tokensAllTime":
            if let st = stats {
                Text("Σ " + formatTokens(st.totalTokensAllTime) + " · " + formatEuros(st.totalCostAllTimeUSD))
                    .font(boldFont).foregroundColor(.white.opacity(0.5))
                    .contentShape(Rectangle())
                    .onTapGesture { toggleSection(.tokensAllTime) }
            }
        case "tokensToday":
            if let st = stats {
                let todayTokens = st.todayLiveTokens > 0 ? st.todayLiveTokens : st.totalTokens
                Text("⇡ " + formatTokens(todayTokens) + " · " + formatEuros(st.todayCostUSD))
                    .font(boldFont).foregroundColor(.white.opacity(0.7))
                    .contentShape(Rectangle())
                    .onTapGesture { toggleSection(.tokensToday) }
            }
        case "lastDay":
            if let st = stats, let lastDate = st.lastDayDate {
                HStack(spacing: 4) {
                    Text(formatShortDate(lastDate))
                        .font(boldFont).foregroundColor(.white.opacity(0.35))
                    Text(formatTokens(st.lastDayTokens) + " · " + formatEuros(st.lastDayCostUSD))
                        .font(wingFont).foregroundColor(.white.opacity(0.5))
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleSection(.daily) }
            }
        case "record":
            if let st = stats, st.recordTokens > 0 {
                let rec = st.record(byCost: recordByCost)
                HStack(spacing: 2) {
                    Text("🏆").font(.system(size: fontSize - 3))
                    Text(recordByCost
                         ? formatShortDate(rec.date) + " " + formatEuros(rec.costUSD) + " · " + formatTokens(rec.tokens)
                         : formatShortDate(rec.date) + " " + formatTokens(rec.tokens) + " · " + formatEuros(rec.costUSD))
                        .font(smallFont)
                }
                .foregroundColor(TerminalColors.amber.opacity(0.7))
                .contentShape(Rectangle())
                .onTapGesture { toggleSection(.record) }
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Left Detail Panel

    @ViewBuilder
    private func leftDetailPanel(for section: WingSection) -> some View {
        detailPanel(for: section)
    }

    private func rateLimitDetail(title: String, utilization: Double, reset: Date, windowSeconds: TimeInterval) -> some View {
        let timeRemaining = max(0, reset.timeIntervalSinceNow)
        let elapsed = windowSeconds - timeRemaining
        let expectedUtil = min(1.0, max(0, elapsed / windowSeconds))
        // Fenêtres hebdo : deux attendus supplémentaires qui ne comptent que le
        // temps utile — hors samedi/dimanche, puis heures ouvrées seules
        // (8h–19h hors week-end). Ils dépassent l'attendu linéaire en journée,
        // plafonnent le reste du temps et le rejoignent au reset.
        let weekdayUtil = weekdayExpectedUtilization(reset: reset, windowSeconds: windowSeconds)
        let officeUtil = officeExpectedUtilization(reset: reset, windowSeconds: windowSeconds)

        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))

            progressBar(utilization: utilization, expectedUtilization: expectedUtil, secondaryExpected: weekdayUtil, tertiaryExpected: officeUtil, barWidth: 180, barHeight: 5)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Utilisé").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text(formatPercent1(utilization))
                        .font(boldFont)
                        .foregroundColor(paceColor(utilization, expected: expectedUtil, weekday: weekdayUtil, office: officeUtil))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Attendu").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text(formatPercent1(expectedUtil))
                        .font(boldFont).foregroundColor(TerminalColors.amber.opacity(0.8))
                }
                if let weekdayUtil {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hors WE").font(smallFont).foregroundColor(.white.opacity(0.4))
                        Text(formatPercent1(weekdayUtil))
                            .font(boldFont).foregroundColor(TerminalColors.orange.opacity(0.9))
                    }
                }
                if let officeUtil {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ouvré").font(smallFont).foregroundColor(.white.opacity(0.4))
                        Text(formatPercent1(officeUtil))
                            .font(boldFont).foregroundColor(TerminalColors.red.opacity(0.9))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reset").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text(formatDetailedResetTime(reset))
                        .font(boldFont).foregroundColor(.white.opacity(0.6))
                }
            }

            Text("Reset le \(formatExactResetDateTime(reset))")
                .font(smallFont).foregroundColor(.white.opacity(0.4))

            paceSummary(utilization: utilization, expected: expectedUtil, weekday: weekdayUtil, office: officeUtil)
        }
        .padding(10)
        .background(wingBackground)
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    /// Attendus nommés, triés par valeur croissante.
    private static func orderedMarks(expected: Double, weekday: Double?, office: Double?) -> [(name: String, value: Double)] {
        var marks: [(name: String, value: Double)] = [(name: "linéaire", value: expected)]
        if let weekday { marks.append((name: "hors week-end", value: weekday)) }
        if let office { marks.append((name: "heures ouvrées", value: office)) }
        return marks.sorted { $0.value < $1.value }
    }

    /// Phrase de synthèse : quel attendu est dépassé, et de combien.
    /// Les repères n'étant pas ordonnés entre eux (la nuit, l'attendu heures
    /// ouvrées repasse sous l'attendu hors week-end), on les trie par valeur.
    @ViewBuilder
    private func paceSummary(utilization: Double, expected: Double, weekday: Double?, office: Double?) -> some View {
        let marks = Self.orderedMarks(expected: expected, weekday: weekday, office: office)
        let exceeded = marks.filter { utilization > $0.value }

        if let highest = marks.last, utilization > highest.value {
            Text("▲ +\(formatPercent1(utilization - highest.value)) au-dessus de l'attendu \(highest.name)")
                .font(smallFont).foregroundColor(TerminalColors.red.opacity(0.8))
        } else if let lastExceeded = exceeded.last,
                  let nextMark = marks.first(where: { utilization <= $0.value }) {
            Text("◆ +\(formatPercent1(utilization - lastExceeded.value)) vs \(lastExceeded.name), dans la marge \(nextMark.name)")
                .font(smallFont)
                .foregroundColor((exceeded.count >= 2 ? TerminalColors.orange : TerminalColors.yellow).opacity(0.9))
        } else {
            Text("✓ Sous le rythme attendu")
                .font(smallFont).foregroundColor(TerminalColors.green.opacity(0.8))
        }
    }

    private func overageDetail(utilization: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(TerminalColors.red)
                Text("Overage Actif")
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundColor(TerminalColors.red.opacity(0.9))
            }

            progressBar(utilization: utilization, expectedUtilization: 0, barWidth: 180, barHeight: 5)

            Text("Utilisation : \(Int(utilization * 100))%")
                .font(boldFont).foregroundColor(TerminalColors.red.opacity(0.8))

            Text("Dépassement du quota inclus")
                .font(smallFont).foregroundColor(.white.opacity(0.5))
        }
        .padding(10)
        .background(wingBackground)
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    // MARK: - Right Detail Panel

    @ViewBuilder
    private func rightDetailPanel(for section: WingSection) -> some View {
        detailPanel(for: section)
    }

    // MARK: - Unified Detail Panel

    @ViewBuilder
    private func detailPanel(for section: WingSection) -> some View {
        switch section {
        case .rateLimitFable:
            if let rl = rateLimits, let util = rl.fableUtilization, let reset = rl.fableReset {
                rateLimitDetail(title: "Current week (Fable)", utilization: util, reset: reset, windowSeconds: 7 * 86400)
            }
        case .rateLimit5h:
            if let rl = rateLimits {
                rateLimitDetail(title: "Rate Limit 5h", utilization: rl.fiveHourUtilization, reset: rl.fiveHourReset, windowSeconds: 5 * 3600)
            }
        case .rateLimit7j:
            if let rl = rateLimits {
                rateLimitDetail(title: "Rate Limit 7j", utilization: rl.sevenDayUtilization, reset: rl.sevenDayReset, windowSeconds: 7 * 86400)
            }
        case .overage:
            if let rl = rateLimits {
                overageDetail(utilization: rl.overageUtilization)
            }
        case .heatmap:
            if let st = stats {
                heatmapDetail(st)
            }
        case .tokensAllTime:
            if let st = stats {
                tokensAllTimeDetail(st)
            }
        case .tokensToday:
            if let st = stats {
                tokensTodayDetail(st)
            }
        case .daily:
            if let st = stats {
                dailyDetail(st)
            }
        case .record:
            if let st = stats {
                recordDetail(st)
            }
        }
    }

    private func heatmapDetail(_ st: DailyStats) -> some View {
        VStack(spacing: 8) {
            Text("Activité")
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))

            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 1.5) {
                    ForEach(Array(["L", "Ma", "Me", "J", "V", "S", "D"].enumerated()), id: \.offset) { _, day in
                        Text(day)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 14, height: 8)
                    }
                }
                DetailActivityHeatmap(
                    entries: st.heatmapEntries,
                    recordDate: parseDate(st.record(byCost: recordByCost).date),
                    cellSize: 8,
                    cellGap: 1.5
                )
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(wingBackground)
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    private func tokensAllTimeDetail(_ st: DailyStats) -> some View {
        let dayCount = max(1, st.heatmapEntries.count)
        let monthly = allTimeMonthly
        // Par jour : moyenne sur les jours d'activité ; par mois : sur la durée
        // de l'historique en mois (30,44 j).
        let divisor = monthly ? st.monthsOfHistory : Double(dayCount)
        let avgTokens = Int(Double(st.totalTokensAllTime) / divisor)
        let unit = monthly ? "mois" : "jour"

        // Largeur fixe (graphe + légende sur une ligne) ; le haut se répartit dessus.
        let panelWidth = allTimePanelWidth

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tokens — All Time")
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                periodToggle
            }

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text(formatTokens(st.totalTokensAllTime))
                        .font(boldFont).foregroundColor(.white.opacity(0.7))
                }
                Spacer(minLength: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Moy/\(unit)").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text("~" + formatTokens(avgTokens))
                        .font(boldFont).foregroundColor(.white.opacity(0.6))
                }
                Spacer(minLength: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Coût API").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text(formatEuros(st.totalCostAllTimeUSD))
                        .font(boldFont).foregroundColor(.white.opacity(0.7))
                }
                Spacer(minLength: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text("€/\(unit)").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text("~" + formatEuros(st.totalCostAllTimeUSD / divisor))
                        .font(boldFont).foregroundColor(.white.opacity(0.6))
                }
            }

            HStack(spacing: 4) {
                Text("\(dayCount) jours d'activité")
                    .font(smallFont).foregroundColor(.white.opacity(0.4))
                Text("·").font(smallFont).foregroundColor(.white.opacity(0.2))
                Text("\(st.totalMessagesAllTime) msgs")
                    .font(smallFont).foregroundColor(.white.opacity(0.4))
            }

            workdayProjection(st.workdayCostAverages, monthly: monthly)

            if monthly {
                if !st.monthlyCosts.isEmpty {
                    MonthlyCostChart(months: st.monthlyCosts, fontSize: fontSize)
                }
            } else if st.workdayCostTrend.count > 1 {
                WorkdayCostChart(points: st.workdayCostTrend, fontSize: fontSize)
            }
        }
        .frame(width: panelWidth, alignment: .leading)
        .padding(10)
        .background(wingBackground)
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    /// « Conso moyenne » glissante, comme l'autonomie projetée d'un véhicule
    /// électrique : coût par jour ouvré actif et projection sur un ETP (200 j/an).
    @ViewBuilder
    /// En mode mois : même moyenne convertie en mois d'ETP (200 j / 12 ≈ 16,7 j ouvrés).
    private func workdayProjection(_ averages: [WorkdayCostAverage], monthly: Bool) -> some View {
        if !averages.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(monthly ? "Projection — par mois d'ETP (200 j/an)" : "Projection — par jour ouvré actif")
                    .font(boldFont).foregroundColor(.white.opacity(0.6))
                    .padding(.bottom, 1)
                HStack(spacing: 0) {
                    Text("Période").frame(maxWidth: .infinity, alignment: .leading)
                    Text(monthly ? "€/mois ETP" : "€/j ouvré").frame(maxWidth: .infinity, alignment: .trailing)
                    Text("ETP/an").frame(maxWidth: .infinity, alignment: .trailing)
                    Text("Jours").frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(smallFont).foregroundColor(.white.opacity(0.35))
                ForEach(averages.indices, id: \.self) { index in
                    let avg = averages[index]
                    HStack(spacing: 0) {
                        Text(avg.label).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor(.white.opacity(0.5))
                        Text(formatEuros(monthly ? avg.perFTEYearUSD / 12 : avg.perWorkdayUSD))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundColor(.white.opacity(0.7))
                        Text(formatEuros(avg.perFTEYearUSD)).frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundColor(TerminalColors.amber.opacity(0.8))
                        Text("\(avg.workdays)").frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .font(boldFont)
                }
            }
        }
    }

    /// Bascule jour / mois du panneau all-time (mémorisée).
    private var periodToggle: some View {
        HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { isMonthly in
                let selected = allTimeMonthly == isMonthly
                Text(isMonthly ? "mois" : "jour")
                    .font(smallFont)
                    .foregroundColor(.white.opacity(selected ? 0.85 : 0.35))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(selected ? 0.15 : 0)))
                    .contentShape(Rectangle())
                    .onTapGesture { allTimeMonthly = isMonthly }
            }
        }
        .padding(1)
        .background(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.15), lineWidth: 1))
    }

    /// Largeur du panneau all-time : de quoi tenir la légende du graphe sur une
    /// ligne (3 × « ▬ Total 1.2k € » + date) à la taille de police choisie.
    private var allTimePanelWidth: CGFloat { max(360, fontSize * 38) }

    private func tokensTodayDetail(_ st: DailyStats) -> some View {
        let todayTokens = st.todayLiveTokens > 0 ? st.todayLiveTokens : st.totalTokens

        return VStack(alignment: .leading, spacing: 8) {
            Text("Tokens — Aujourd'hui")
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tokens").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text(formatTokens(todayTokens))
                        .font(boldFont).foregroundColor(.white.opacity(0.7))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Coût API").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text(formatEuros(st.todayCostUSD))
                        .font(boldFont).foregroundColor(.white.opacity(0.7))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Messages").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text("\(st.messageCount)")
                        .font(boldFont).foregroundColor(.white.opacity(0.7))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sessions").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text("\(st.sessionCount)")
                        .font(boldFont).foregroundColor(.white.opacity(0.7))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                if st.recordTokens > 0 {
                    let pct = Double(todayTokens) / Double(st.recordTokens) * 100
                    Text("\(Int(pct))% du record (\(formatTokens(st.recordTokens)))")
                        .font(smallFont).foregroundColor(.white.opacity(0.4))
                }
                if st.costRecordCostUSD > 0 {
                    let pct = st.todayCostUSD / st.costRecordCostUSD * 100
                    Text("\(Int(pct))% du record en coût (\(formatEuros(st.costRecordCostUSD)))")
                        .font(smallFont).foregroundColor(.white.opacity(0.4))
                }
            }
        }
        .padding(10)
        .background(wingBackground)
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    private func dailyDetail(_ st: DailyStats) -> some View {
        let days = st.last7Days
        let maxTokens = days.map(\.tokens).max() ?? 0
        let minTokens = days.map(\.tokens).min() ?? 0
        let recordDay = st.record(byCost: recordByCost).date
        let hasRecord = days.contains { $0.date == recordDay }

        return VStack(alignment: .leading, spacing: 0) {
            if !days.isEmpty {
                Text("7 derniers jours")
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.bottom, 4)

                // Header row
                HStack(spacing: 0) {
                    Text("Date")
                        .frame(width: 68, alignment: .leading)
                    Text("Msgs")
                        .frame(width: 54, alignment: .trailing)
                    Text("Sess")
                        .frame(width: 40, alignment: .trailing)
                    Text("Tools")
                        .frame(width: 54, alignment: .trailing)
                    Text("Tokens")
                        .frame(width: 60, alignment: .trailing)
                    Text("Coût")
                        .frame(width: 60, alignment: .trailing)
                }
                .font(smallFont)
                .foregroundColor(.white.opacity(0.35))

                // Data rows
                ForEach(Array(days.enumerated()), id: \.offset) { _, entry in
                    let isWeekendRow: Bool = {
                        let df = DateFormatter()
                        df.dateFormat = "yyyy-MM-dd"
                        guard let d = df.date(from: entry.date) else { return false }
                        let wd = Calendar.current.component(.weekday, from: d)
                        return wd == 1 || wd == 7
                    }()
                    let isRecord = entry.date == recordDay
                    let rowColor: Color = {
                        if isRecord { return TerminalColors.amber.opacity(isWeekendRow ? 0.7 : 0.9) }
                        if maxTokens != minTokens {
                            if entry.tokens == maxTokens { return TerminalColors.green.opacity(isWeekendRow ? 0.7 : 0.9) }
                            if entry.tokens == minTokens { return TerminalColors.blue.opacity(isWeekendRow ? 0.4 : 0.5) }
                        }
                        return .white.opacity(isWeekendRow ? 0.45 : 0.7)
                    }()
                    HStack(spacing: 0) {
                        Text(formatDayDate(entry.date))
                            .frame(width: 68, alignment: .leading)
                            .overlay(alignment: .leading) {
                                if isRecord {
                                    Text("🏆")
                                        .font(.system(size: fontSize - 2))
                                        .offset(x: -18)
                                }
                            }
                        Text("\(entry.messages)")
                            .frame(width: 54, alignment: .trailing)
                        Text("\(entry.sessions)")
                            .frame(width: 40, alignment: .trailing)
                        Text("\(entry.toolCalls)")
                            .frame(width: 54, alignment: .trailing)
                        Text(formatTokens(entry.tokens))
                            .frame(width: 60, alignment: .trailing)
                        Text(formatEuros(entry.costUSD))
                            .frame(width: 60, alignment: .trailing)
                    }
                    .font(smallFont)
                    .foregroundColor(rowColor)
                    .padding(.vertical, 1)
                    .padding(.horizontal, -2)
                    .background(
                        Group {
                            if isWeekendRow {
                                DiagonalHatching(spacing: 5, lineWidth: 1, color: .white.opacity(0.18))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                    )
                }
            } else {
                Text("Pas de données")
                    .font(smallFont).foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, hasRecord ? 24 : 10)
        .padding(.trailing, 10)
        .background(wingBackground)
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    private func recordDetail(_ st: DailyStats) -> some View {
        let todayTokens = st.todayLiveTokens > 0 ? st.todayLiveTokens : st.totalTokens
        let byTokens = st.record(byCost: false)
        let byCost = st.record(byCost: true)
        let rec = recordByCost ? byCost : byTokens
        let other = recordByCost ? byTokens : byCost
        let pctOfRecord: Double = recordByCost
            ? (rec.costUSD > 0 ? st.todayCostUSD / rec.costUSD * 100 : 0)
            : (rec.tokens > 0 ? Double(todayTokens) / Double(rec.tokens) * 100 : 0)
        let highlight = TerminalColors.amber.opacity(0.9)
        let dim = TerminalColors.amber.opacity(0.6)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("🏆").font(.system(size: fontSize))
                Text("Record")
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundColor(TerminalColors.amber.opacity(0.9))
                Spacer(minLength: 12)
                recordMetricToggle
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Date").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text(formatShortDate(rec.date))
                        .font(boldFont).foregroundColor(dim)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tokens").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text(formatTokens(rec.tokens))
                        .font(boldFont).foregroundColor(recordByCost ? dim : highlight)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Coût API").font(smallFont).foregroundColor(.white.opacity(0.4))
                    Text(formatEuros(rec.costUSD))
                        .font(boldFont).foregroundColor(recordByCost ? highlight : dim)
                }
            }

            // L'autre record, s'il tombe un autre jour
            if other.date != rec.date, !other.date.isEmpty {
                Text("Record \(recordByCost ? "tokens" : "coût") : \(formatShortDate(other.date)) · \(formatTokens(other.tokens)) · \(formatEuros(other.costUSD))")
                    .font(smallFont).foregroundColor(.white.opacity(0.4))
            }

            if st.isToday, rec.date == st.date {
                Text("🎉 Nouveau record !")
                    .font(boldFont).foregroundColor(highlight)
            } else if st.isToday {
                Text(recordByCost
                     ? "Aujourd'hui : \(formatEuros(st.todayCostUSD)) (\(Int(pctOfRecord))% du record)"
                     : "Aujourd'hui : \(formatTokens(todayTokens)) (\(Int(pctOfRecord))% du record)")
                    .font(smallFont).foregroundColor(.white.opacity(0.5))
            }
        }
        // Largeur au contenu : sans ça le Spacer du titre étire le panneau
        .fixedSize(horizontal: true, vertical: false)
        .padding(10)
        .background(wingBackground)
        .clipShape(RoundedRectangle(cornerRadius: wingCornerRadius))
    }

    /// Bascule tokens / coût du record (mémorisée, pilote aussi la barre).
    private var recordMetricToggle: some View {
        HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { isCost in
                let selected = recordByCost == isCost
                Text(isCost ? "€" : "tokens")
                    .font(smallFont)
                    .foregroundColor(.white.opacity(selected ? 0.85 : 0.35))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(selected ? 0.15 : 0)))
                    .contentShape(Rectangle())
                    .onTapGesture { recordByCost = isCost }
            }
        }
        .padding(1)
        .background(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.15), lineWidth: 1))
    }

    // MARK: - Rate Limit Pill

    private enum ResetUnit { case days }

    private func rateLimitPill(label: String, utilization: Double, reset: Date, forceUnit: ResetUnit?, windowSeconds: TimeInterval) -> some View {
        let timeRemaining = max(0, reset.timeIntervalSinceNow)
        let elapsed = windowSeconds - timeRemaining
        let expectedUtil = min(1.0, max(0, elapsed / windowSeconds))
        // Fenêtres hebdo : même lecture que le panel de détail
        // (attendus hors week-end puis heures ouvrées)
        let weekdayUtil = weekdayExpectedUtilization(reset: reset, windowSeconds: windowSeconds)
        let officeUtil = officeExpectedUtilization(reset: reset, windowSeconds: windowSeconds)

        return HStack(spacing: 4) {
            Text(label)
                .font(boldFont)
                .foregroundColor(.white.opacity(0.5))
                .fixedSize(horizontal: true, vertical: false) // évite « Fable » → « Fab… »

            progressBar(utilization: utilization, expectedUtilization: expectedUtil, secondaryExpected: weekdayUtil, tertiaryExpected: officeUtil)

            // Le temps de reset (« 1h », « 4j ») suffit à indiquer le compte à
            // rebours ; l'icône ↻ était redondante et a été retirée pour gagner de la place.
            (Text("\(Int(utilization * 100))%")
                .foregroundColor(paceColor(utilization, expected: expectedUtil, weekday: weekdayUtil, office: officeUtil).opacity(0.9))
            + Text(" \(formatResetTime(reset, forceUnit: forceUnit))")
                .foregroundColor(.white.opacity(0.4)))
                .font(smallFont)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func overagePill(utilization: Double) -> some View {
        HStack(spacing: 4) {
            Text("ovg")
                .font(boldFont)
                .foregroundColor(TerminalColors.red.opacity(0.7))

            Text("\(Int(utilization * 100))%")
                .font(smallFont)
                .foregroundColor(TerminalColors.red.opacity(0.9))
        }
    }

    // MARK: - Progress Bar

    /// Barre de progression. `expectedUtilization` = attendu linéaire (repère ambre).
    /// `secondaryExpected` (fenêtres hebdo) = attendu hors week-end (repère orange).
    /// `tertiaryExpected` (fenêtres hebdo) = attendu heures ouvrées (repère rouge).
    /// Le remplissage est découpé par les repères triés : vert sous le plus bas,
    /// puis jaune / orange / rouge à mesure qu'on franchit les suivants. Sans
    /// repère supplémentaire, le comportement d'origine est conservé.
    private func progressBar(utilization: Double, expectedUtilization: Double, secondaryExpected: Double? = nil, tertiaryExpected: Double? = nil, barWidth: CGFloat = 40, barHeight: CGFloat = 3) -> some View {
        // Repères (valeur, couleur du tick), dans l'ordre de restriction croissante.
        var markers: [(value: Double, color: Color)] = [
            (min(max(0, expectedUtilization), 1.0), TerminalColors.amber)
        ]
        if let secondaryExpected {
            markers.append((min(max(0, secondaryExpected), 1.0), TerminalColors.orange))
        }
        if let tertiaryExpected {
            markers.append((min(max(0, tertiaryExpected), 1.0), TerminalColors.red.opacity(0.9)))
        }
        // Les repères ne sont pas ordonnés entre eux (la nuit, l'attendu heures
        // ouvrées stagne et repasse sous l'attendu hors week-end) : on trie.
        let bounds = markers.map(\.value).sorted()
        let zones = Self.zoneColors(boundCount: bounds.count)

        // Segments de remplissage (largeur relative, couleur), du plus bas au plus haut.
        let actual = min(max(0, utilization), 1.0)
        var segments: [(width: Double, color: Color)] = []
        var previous = 0.0
        for (index, bound) in bounds.enumerated() {
            let upTo = min(actual, bound)
            if upTo > previous { segments.append((upTo - previous, zones[index])) }
            previous = max(previous, bound)
        }
        if actual > previous { segments.append((actual - previous, zones[bounds.count])) }

        return GeometryReader { geo in
            let w = geo.size.width

            ZStack(alignment: .leading) {
                // Background
                Capsule()
                    .fill(.white.opacity(0.15))
                    .frame(height: barHeight)

                // Remplissage par zones, découpé en capsule
                HStack(spacing: 0) {
                    ForEach(segments.indices, id: \.self) { index in
                        Rectangle()
                            .fill(segments[index].color)
                            .frame(width: index == 0
                                   ? max(1, w * segments[index].width)
                                   : w * segments[index].width)
                    }
                }
                .frame(height: barHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(Capsule())

                // Repères : ambre (linéaire), orange (hors week-end), rouge (heures ouvrées)
                ForEach(markers.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(markers[index].color)
                        .frame(width: 1, height: barHeight + 2)
                        .offset(x: w * markers[index].value - 0.5)
                }
            }
        }
        .frame(width: barWidth, height: barHeight + 2)
    }

    /// Couleurs des `boundCount + 1` zones de remplissage, du plus permissif au
    /// plus strict. Avec un seul repère on garde le vert/rouge d'origine.
    private static func zoneColors(boundCount: Int) -> [Color] {
        switch boundCount {
        case 0: return [TerminalColors.green]
        case 1: return [TerminalColors.green, TerminalColors.red]
        case 2: return [TerminalColors.green, TerminalColors.orange, TerminalColors.red]
        default: return [TerminalColors.green, TerminalColors.yellow, TerminalColors.orange, TerminalColors.red]
        }
    }

    // MARK: - Attendus hors week-end / heures ouvrées
    //
    // Les trois repères appliquent la même formule, seule la notion de « temps
    // utile » change (linéaire 168 h, hors WE 120 h, ouvré 55 h par semaine) :
    //
    //   attendu = temps utile écoulé depuis le début de la fenêtre
    //             ÷ temps utile total de la fenêtre
    //
    // Pourquoi le temps UTILE écoulé et non le temps écoulé tout court
    // (« minutes écoulées × 100 % / minutes utiles ») : cette variante donne
    // des droites sans croisement, mais qui ne finissent pas à 100 % au reset —
    // l'attendu ouvré atteindrait 100 % au bout de 55 h (2,3 jours) puis ~300 %
    // au reset, car elle suppose une consommation au rythme ouvré 24 h/24.
    //
    // Conséquences assumées de ce choix :
    //   • paliers : l'attendu ouvré ne monte qu'entre 8 h et 19 h, plat la nuit ;
    //     il juge donc aussi l'HEURE de consommation (beaucoup à 9 h = rouge,
    //     la même chose à 22 h passe). Si seule compte la journée, c'est
    //     l'attendu hors WE qu'il faut lire : c'est l'ouvré lissé sur 24 h
    //     (chaque jour de semaine = 1/5 dans les deux cas, d'où leur égalité
    //     chaque matin à 8 h) ;
    //   • croisements : deux courbes allant de 0 à 100 % avec des formes
    //     différentes se croisent forcément (ex. le week-end, le linéaire
    //     rattrape les deux autres quand il reste des jours ouvrés après) —
    //     d'où le tri des repères dans progressBar / paceColor / paceSummary.

    /// Bornes des heures ouvrées prises en compte par l'attendu « heures ouvrées ».
    static let officeStartHour = 8
    static let officeEndHour = 19

    /// Part du temps utile (hors samedi/dimanche, calendrier local) écoulé dans la
    /// fenêtre `[reset − windowSeconds, reset]`. Nil hors fenêtres hebdomadaires.
    private func weekdayExpectedUtilization(reset: Date, windowSeconds: TimeInterval, now: Date = Date()) -> Double? {
        expectedUtilization(reset: reset, windowSeconds: windowSeconds, now: now, useful: { Self.workingSeconds(from: $0, to: $1) })
    }

    /// Même lecture, restreinte aux heures ouvrées (8h–19h, hors week-end) :
    /// c'est l'attendu de quelqu'un qui ne travaille ni le soir ni le week-end.
    private func officeExpectedUtilization(reset: Date, windowSeconds: TimeInterval, now: Date = Date()) -> Double? {
        expectedUtilization(reset: reset, windowSeconds: windowSeconds, now: now, useful: { Self.officeSeconds(from: $0, to: $1) })
    }

    /// Fraction du temps utile écoulée, `useful` définissant ce qui compte comme utile.
    private func expectedUtilization(
        reset: Date,
        windowSeconds: TimeInterval,
        now: Date,
        useful: (Date, Date) -> TimeInterval
    ) -> Double? {
        guard windowSeconds >= 6 * 86400 else { return nil }
        let start = reset.addingTimeInterval(-windowSeconds)
        let total = useful(start, reset)
        guard total > 0 else { return nil }
        let elapsed = useful(start, min(max(now, start), reset))
        return min(1.0, max(0, elapsed / total))
    }

    /// Secondes hors week-end entre deux dates, en découpant jour par jour.
    static func workingSeconds(from start: Date, to end: Date, calendar: Calendar = .current) -> TimeInterval {
        guard end > start else { return 0 }
        var total: TimeInterval = 0
        var cursor = start
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let segmentEnd = min(nextDay, end)
            if !calendar.isDateInWeekend(cursor) {
                total += segmentEnd.timeIntervalSince(cursor)
            }
            cursor = segmentEnd
        }
        return total
    }

    /// Secondes ouvrées (8h–19h, hors week-end) entre deux dates, jour par jour.
    static func officeSeconds(from start: Date, to end: Date, calendar: Calendar = .current) -> TimeInterval {
        guard end > start else { return 0 }
        var total: TimeInterval = 0
        var cursor = calendar.startOfDay(for: start)
        while cursor < end {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            if !calendar.isDateInWeekend(cursor),
               let open = calendar.date(bySettingHour: officeStartHour, minute: 0, second: 0, of: cursor),
               let close = calendar.date(bySettingHour: officeEndHour, minute: 0, second: 0, of: cursor) {
                let from = max(open, start)
                let to = min(close, end)
                if to > from { total += to.timeIntervalSince(from) }
            }
            cursor = nextDay
        }
        return total
    }

    // MARK: - Helpers

    /// Couleur du rythme, alignée sur les zones de la barre : rouge au-delà du
    /// repère le plus haut, orange / jaune selon le nombre de repères franchis,
    /// sinon la couleur par niveau d'utilisation.
    private func paceColor(_ util: Double, expected: Double, weekday: Double?, office: Double? = nil) -> Color {
        let bounds = [expected, weekday, office].compactMap { $0 }.sorted()
        guard let highest = bounds.last else { return colorForUtilization(util) }
        if util > highest { return TerminalColors.red }
        switch bounds.filter({ util > $0 }).count {
        case 0: return colorForUtilization(util)
        case 1 where bounds.count >= 3: return TerminalColors.yellow
        default: return TerminalColors.orange
        }
    }

    private func colorForUtilization(_ util: Double, expected: Double? = nil) -> Color {
        if let exp = expected, util > exp {
            return TerminalColors.red
        }
        if util < 0.5 { return TerminalColors.green }
        if util < 0.8 { return TerminalColors.amber }
        return TerminalColors.red
    }

    private func formatResetTime(_ date: Date, forceUnit: ResetUnit? = nil) -> String {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "" }

        if forceUnit == .days {
            let days = interval / 86400
            if days >= 1 {
                return String(format: "%.0fj", days)
            }
            // Less than 1 day: fall through to h/m format
        }

        let minutes = Int(interval) / 60
        if minutes < 60 { return "\(max(1, minutes))m" }
        // Arrondi au plus proche (2h59 → « 3h ») pour rester cohérent avec le
        // panel de détail qui affiche « 2h 59m » ; la troncature donnait « 2h ».
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 24 { return "\(hours)h" }
        return String(format: "%.0fj", max(1, interval / 86400))
    }

    private func formatShortDate(_ dateStr: String) -> String {
        let parts = dateStr.split(separator: "-")
        guard parts.count == 3 else { return dateStr }
        return "\(parts[2])/\(parts[1])"
    }

    private func formatDayDate(_ dateStr: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "fr_FR")
        guard let date = df.date(from: dateStr) else { return formatShortDate(dateStr) }
        let weekday = Calendar.current.component(.weekday, from: date)
        let names = ["Di", "Lu", "Ma", "Me", "Je", "Ve", "Sa"]
        return "\(names[weekday - 1]) \(formatShortDate(dateStr))"
    }

    /// Pourcentage avec une décimale et virgule française (ex. "2,4%").
    private func formatPercent1(_ ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100).replacingOccurrences(of: ".", with: ",")
    }

    private func formatDetailedResetTime(_ date: Date) -> String {
        let interval = max(0, date.timeIntervalSinceNow)
        let totalMinutes = Int(interval) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(max(1, minutes))m"
    }

    private func formatExactResetDateTime(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "fr_FR")
        df.dateFormat = "EEE dd/MM 'à' HH:mm"
        return df.string(from: date)
    }

    private func formatElapsed(since date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return "\(hours)h"
    }

    private func parseDate(_ dateStr: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current
        return fmt.date(from: dateStr)
    }

    /// Coût équivalent API converti en euros (taux figé ModelPricing.usdToEur).
    private func formatEuros(_ usd: Double) -> String {
        let eur = usd * ModelPricing.usdToEur
        if eur >= 1_000 {
            return String(format: "%.1fk €", eur / 1_000)
        } else if eur >= 10 {
            return String(format: "%.0f €", eur)
        }
        return String(format: "%.1f €", eur)
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// MARK: - Activity Heatmap

private struct ActivityHeatmap: View {
    let entries: [HeatmapEntry]
    var cellSize: CGFloat = 3
    var cellGap: CGFloat = 1

    var body: some View {
        let grid = buildGrid()
        let maxCount = entries.map(\.tokenCount).max() ?? 1
        let p75 = percentile75()
        let step = cellSize + cellGap

        Canvas { context, size in
            for col in 0..<grid.count {
                for row in 0..<7 {
                    let x = CGFloat(col) * step
                    let y = CGFloat(row) * step
                    let rect = CGRect(x: x, y: y, width: cellSize, height: cellSize)
                    let count = grid[col][row]
                    context.fill(
                        RoundedRectangle(cornerRadius: cellSize > 4 ? 1 : 0.5).path(in: rect),
                        with: .color(colorForCount(count, max: maxCount, p75: p75))
                    )
                }
            }
        }
        .frame(
            width: CGFloat(max(1, grid.count)) * step - cellGap,
            height: 7 * step - cellGap
        )
    }

    /// Build a calendar grid: columns = weeks, rows = day of week (Mon=0 .. Sun=6)
    private func buildGrid() -> [[Int]] {
        guard let firstEntry = entries.min(by: { $0.date < $1.date }),
              let lastEntry = entries.max(by: { $0.date < $1.date }) else {
            return []
        }

        let calendar = Calendar.current

        // Build lookup: day -> tokenCount
        var lookup: [Date: Int] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            lookup[day] = entry.tokenCount
        }

        // Find the Monday on or before the first entry
        let firstDay = calendar.startOfDay(for: firstEntry.date)
        let lastDay = calendar.startOfDay(for: lastEntry.date)
        let firstWeekday = (calendar.component(.weekday, from: firstDay) + 5) % 7 // Mon=0
        let startDate = calendar.date(byAdding: .day, value: -firstWeekday, to: firstDay)!

        // Build columns from startDate to lastDay
        var grid: [[Int]] = []
        var current = startDate

        while current <= lastDay {
            var column = [Int](repeating: 0, count: 7)
            for row in 0..<7 {
                let day = calendar.date(byAdding: .day, value: row, to: current)!
                if day >= firstDay && day <= lastDay {
                    column[row] = lookup[day] ?? 0
                } else {
                    column[row] = -1 // Outside range — won't be drawn
                }
            }
            grid.append(column)
            current = calendar.date(byAdding: .day, value: 7, to: current)!
        }

        return grid
    }

    private func percentile75() -> Int {
        let nonZero = entries.map(\.tokenCount).filter { $0 > 0 }.sorted()
        guard !nonZero.isEmpty else { return 1 }
        let index = Int(Double(nonZero.count - 1) * 0.75)
        return max(nonZero[index], 1)
    }

    private func colorForCount(_ count: Int, max: Int, p75: Int) -> Color {
        if count < 0 { return .clear }
        if count == 0 { return .white.opacity(0.06) }

        let threshold = Double(p75)

        if Double(count) <= threshold {
            // Phase 1: Linear orange gradient
            let ratio = Double(count) / threshold
            let opacity = 0.06 + ratio * 0.94
            return TerminalColors.prompt.opacity(opacity)
        } else {
            // Phase 2: Heated metal — orange → amber → yellow → white
            let range = Double(max) - threshold
            guard range > 0 else { return .white }
            let normalized = min((Double(count) - threshold) / range, 1.0)
            let r = 0.85 + pow(normalized, 0.2) * 0.15
            let g = 0.47 + pow(normalized, 0.45) * 0.53
            let b = 0.34 + pow(normalized, 0.9) * 0.66
            return Color(red: min(r, 1), green: min(g, 1), blue: min(b, 1))
        }
    }
}

// MARK: - Diagonal Hatching

private struct DiagonalHatching: View {
    let spacing: CGFloat
    let lineWidth: CGFloat
    let color: Color

    var body: some View {
        Canvas { context, size in
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(path, with: .color(color), lineWidth: lineWidth)
                x += spacing
            }
        }
    }
}

// MARK: - Detail Activity Heatmap (with tooltips)

private struct DetailActivityHeatmap: View {
    let entries: [HeatmapEntry]
    let recordDate: Date?
    var cellSize: CGFloat = 6
    var cellGap: CGFloat = 1

    @State private var hoveredInfo: String = ""
    @State private var isRecord: Bool = false

    struct Cell {
        let date: Date
        let messageCount: Int
        let tokenCount: Int
        let inRange: Bool
        let isRecord: Bool
    }

    private static let tooltipDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "E dd/MM"
        f.locale = Locale(identifier: "fr_FR")
        return f
    }()

    var body: some View {
        let grid = buildGrid()
        let maxCount = entries.map(\.tokenCount).max() ?? 1
        let p75 = percentile75()
        VStack(spacing: 5) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(0..<grid.count, id: \.self) { col in
                    VStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { row in
                            let cell = grid[col][row]
                            RoundedRectangle(cornerRadius: 1)
                                .fill(colorForCell(cell, max: maxCount, p75: p75))
                                .frame(width: cellSize, height: cellSize)
                                .overlay(
                                    cell.isRecord
                                        ? RoundedRectangle(cornerRadius: 1)
                                            .strokeBorder(TerminalColors.amber, lineWidth: 1.5)
                                            .allowsHitTesting(false)
                                        : nil
                                )
                                .padding(cellGap / 2)
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    if hovering && cell.inRange {
                                        hoveredInfo = cellText(for: cell)
                                        isRecord = cell.isRecord
                                    } else if !hovering && hoveredInfo == cellText(for: cell) {
                                        hoveredInfo = ""
                                        isRecord = false
                                    }
                                }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("🏆")
                        .font(.system(size: 10))
                        .opacity(isRecord ? 1 : 0)
                    Text(hoveredDate)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(isRecord ? TerminalColors.amber : .white.opacity(0.7))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .opacity(hoveredInfo.isEmpty ? 0 : 1)
                Text(hoveredStats)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(isRecord ? TerminalColors.amber.opacity(0.7) : .white.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .opacity(hoveredInfo.isEmpty ? 0 : 1)
            }
            .frame(height: 28)
            .frame(minWidth: 180)
            .animation(.easeOut(duration: 0.15), value: hoveredInfo.isEmpty)
        }
    }

    private var hoveredDate: String {
        guard !hoveredInfo.isEmpty else { return " " }
        return String(hoveredInfo.split(separator: "\n").first ?? " ")
    }

    private var hoveredStats: String {
        guard !hoveredInfo.isEmpty else { return " " }
        return String(hoveredInfo.split(separator: "\n").last ?? " ")
    }

    private func cellText(for cell: Cell) -> String {
        let dateStr = Self.tooltipDateFormatter.string(from: cell.date)
        let tokenStr = formatTokensCompact(cell.tokenCount)
        return "\(dateStr)\n\(cell.messageCount) msgs · \(tokenStr) tokens"
    }

    private func formatTokensCompact(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private func percentile75() -> Int {
        let nonZero = entries.map(\.tokenCount).filter { $0 > 0 }.sorted()
        guard !nonZero.isEmpty else { return 1 }
        let index = Int(Double(nonZero.count - 1) * 0.75)
        return max(nonZero[index], 1)
    }

    private func colorForCell(_ cell: Cell, max: Int, p75: Int) -> Color {
        guard cell.inRange else { return .clear }
        if cell.tokenCount == 0 { return .white.opacity(0.06) }

        let threshold = Double(p75)

        if Double(cell.tokenCount) <= threshold {
            // Phase 1: Linear orange gradient
            let ratio = Double(cell.tokenCount) / threshold
            let opacity = 0.06 + ratio * 0.94
            return TerminalColors.prompt.opacity(opacity)
        } else {
            // Phase 2: Heated metal — orange → amber → yellow → white
            let range = Double(max) - threshold
            guard range > 0 else { return .white }
            let normalized = min((Double(cell.tokenCount) - threshold) / range, 1.0)
            let r = 0.85 + pow(normalized, 0.2) * 0.15
            let g = 0.47 + pow(normalized, 0.45) * 0.53
            let b = 0.34 + pow(normalized, 0.9) * 0.66
            return Color(red: min(r, 1), green: min(g, 1), blue: min(b, 1))
        }
    }

    private func buildGrid() -> [[Cell]] {
        guard let firstEntry = entries.min(by: { $0.date < $1.date }),
              let lastEntry = entries.max(by: { $0.date < $1.date }) else {
            return []
        }

        let calendar = Calendar.current
        let recordDay = recordDate.map { calendar.startOfDay(for: $0) }
        var msgLookup: [Date: Int] = [:]
        var tokLookup: [Date: Int] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            msgLookup[day] = entry.messageCount
            tokLookup[day] = entry.tokenCount
        }

        let firstDay = calendar.startOfDay(for: firstEntry.date)
        let lastDay = calendar.startOfDay(for: lastEntry.date)
        let firstWeekday = (calendar.component(.weekday, from: firstDay) + 5) % 7
        let startDate = calendar.date(byAdding: .day, value: -firstWeekday, to: firstDay)!

        var grid: [[Cell]] = []
        var current = startDate

        while current <= lastDay {
            var column: [Cell] = []
            for row in 0..<7 {
                let day = calendar.date(byAdding: .day, value: row, to: current)!
                let inRange = day >= firstDay && day <= lastDay
                column.append(Cell(
                    date: day,
                    messageCount: inRange ? (msgLookup[day] ?? 0) : 0,
                    tokenCount: inRange ? (tokLookup[day] ?? 0) : 0,
                    inRange: inRange,
                    isRecord: recordDay != nil && day == recordDay
                ))
            }
            grid.append(column)
            current = calendar.date(byAdding: .day, value: 7, to: current)!
        }

        return grid
    }
}
