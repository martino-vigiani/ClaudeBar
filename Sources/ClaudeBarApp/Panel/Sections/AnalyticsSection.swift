import SwiftUI
import Charts

// MARK: - AnalyticsSection (Fascia B — analytics locali)
//
// Header "ANALYTICS" + range picker (Oggi/7g/30g). KPI row (costo "stima
// API-equivalente" + disclaimer, token, efficienza cache). Grafico Swift Charts
// (area/line) con hover→RuleMark. Breakdown per modello/progetto espandibili
// (DisclosureGroup). "Mostra di più" con morphing glass (GlassEffectContainer +
// glassEffectID).
//
// Le analytics restano SEMPRE visibili (anche offline / no-auth): degradazione elegante.

struct AnalyticsSection: View {
    let analytics: AnalyticsVM
    let onRange: (AnalyticsRange) -> Void

    @State private var showCost = true       // grafico: costo vs token
    @State private var expanded = false       // "Mostra di più"
    @State private var selectedRange: AnalyticsRange
    @Namespace private var glassNS
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(analytics: AnalyticsVM, onRange: @escaping (AnalyticsRange) -> Void) {
        self.analytics = analytics
        self.onRange = onRange
        self._selectedRange = State(initialValue: analytics.range)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            header
            kpiRow
            tokenBreakdown
            chartCard
            breakdowns
            showMoreButton
        }
        // Tiene `selectedRange` allineato se il range cambia dall'esterno (es. settings).
        .onChange(of: analytics.range) { _, newValue in
            if selectedRange != newValue { selectedRange = newValue }
        }
        .onChange(of: selectedRange) { _, newValue in
            if analytics.range != newValue { onRange(newValue) }
        }
    }

    // MARK: Header + range picker

    private var header: some View {
        HStack {
            EyebrowTag(text: String(localized: "ANALYTICS"), symbol: "chart.line.uptrend.xyaxis")
            Spacer()
            // Selettore neutro (niente segmented blu di sistema): pillola con segmento attivo
            // in scala di grigi, coerente col vetro neutro e con lo ProviderSwitcher.
            HStack(spacing: 2) {
                ForEach(AnalyticsRange.allCases) { r in
                    let active = r == selectedRange
                    Button { selectedRange = r } label: {
                        Text(r.label)
                            .font(.dsCaption.weight(active ? .semibold : .regular))
                            .padding(.horizontal, DS.Spacing.s)
                            .padding(.vertical, 3)
                            .foregroundStyle(active ? Color.primary : Color.secondary)
                            .background {
                                if active {
                                    Capsule(style: .continuous).fill(Color.primary.opacity(0.12))
                                }
                            }
                            // Hover (solo i segmenti non attivi): fa capire che la pillola è cliccabile.
                            .dsHoverHighlight(in: Capsule(style: .continuous), hover: active ? 0 : 0.08)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(2)
            .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
            .animation(DS.Motion.soft, value: selectedRange)
            .fixedSize()
        }
    }

    // MARK: KPI row

    private var kpiRow: some View {
        HStack(spacing: DS.Spacing.m) {
            KPITile(
                title: String(localized: "Cost \(analytics.range.label.lowercased())"),
                value: analytics.cost.currencyString,
                delta: analytics.costDeltaPct,
                footnote: analytics.showCostDisclaimer ? String(localized: "API-equivalent estimate") : "",
                symbol: "dollarsign.circle"
            )
            KPITile(
                title: String(localized: "Token"),
                value: analytics.tokens.compactString,
                delta: nil,
                footnote: String(localized: "cache \(Int((analytics.cacheEfficiency * 100).rounded()))%"),
                symbol: "bolt"
            )
        }
    }

    // MARK: Token breakdown (input / cache scritti / cache letti / output)

    private var tokenBreakdown: some View {
        TokenBreakdownCard(
            input: analytics.inputTokens,
            cacheRead: analytics.cacheReadTokens,
            cacheWrite: analytics.cacheWriteTokens,
            output: analytics.outputTokens)
    }

    // MARK: Chart card

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack {
                Text(showCost ? "Spend over time" : "Tokens over time")
                    .font(.dsHeadline)
                Spacer()
                Button {
                    withAnimation(DS.Motion.smooth) { showCost.toggle() }
                } label: {
                    Text(showCost ? "$" : "tok")
                        .font(.dsCaption.weight(.semibold))
                        .frame(width: 30)
                        .padding(.vertical, 3)
                        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
                        .dsHoverHighlight(in: Capsule(style: .continuous))
                        .contentTransition(.identity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(showCost ? "Show tokens" : "Show cost")
            }
            SpendChart(series: analytics.series, showCost: showCost)
                .frame(height: 96)
            if analytics.showCostDisclaimer {
                Text("API-equivalent estimate: Max plans are flat-rate, this is not real spend.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DS.Spacing.m)
        .dsCardBezel()
    }

    // MARK: Breakdowns (espandibili)

    private var breakdowns: some View {
        VStack(spacing: DS.Spacing.s) {
            BreakdownDisclosure(title: String(localized: "By model"), items: analytics.byModel, showCost: showCost)
            BreakdownDisclosure(title: String(localized: "By project"), items: analytics.byProject, showCost: showCost)
        }
    }

    // MARK: "Mostra di più" — morphing glass

    private var showMoreButton: some View {
        GlassEffectContainer(spacing: DS.Spacing.m) {
            VStack(spacing: DS.Spacing.m) {
                if expanded {
                    ExtraStatsView(analytics: analytics)
                        .glassEffectID("extra", in: glassNS)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
                Button {
                    withAnimation(reduceMotion ? nil : DS.Motion.soft) { expanded.toggle() }
                } label: {
                    Label(expanded ? "Show less" : "Show more",
                          systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.dsHeadline)
                        // Esplicito: con `.tint(.clear)` la label glass restava bianca →
                        // illeggibile su vetro chiaro in light mode. Forziamo il colore primario.
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Spacing.s)
                }
                .buttonStyle(.glass)
                .tint(.clear)
                .glassEffectID("more-toggle", in: glassNS)
            }
        }
    }
}

// MARK: - KPI Tile

private struct KPITile: View {
    let title: String
    let value: String
    let delta: Double?
    let footnote: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(title).font(.dsCaption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.dsDisplay(20))
                    .contentTransition(.numericText())
                if let delta {
                    DeltaBadge(pct: delta)
                }
            }
            if !footnote.isEmpty {
                Text(footnote)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.m)
        .dsCardBezel()
    }
}

private struct DeltaBadge: View {
    let pct: Double
    private var up: Bool { pct >= 0 }
    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: up ? "arrow.up" : "arrow.down")
                .font(.system(size: 8, weight: .bold))
            Text("\(abs(Int(pct.rounded())))%")
                .font(.system(size: 10, weight: .semibold))
        }
        // Delta costo: l'aumento usa un ambra-rosso TENUE (76), non il rosso-critico (90) della
        // scala limiti — salire di spesa va notato, non è "quota esaurita". Calo → verde.
        .foregroundStyle(up ? UsageColorScale.color(used: 76) : UsageColorScale.color(used: 20))
        .accessibilityLabel(up ? Text("up by \(Int(pct))%") : Text("down by \(abs(Int(pct)))%"))
    }
}

// MARK: - Token Breakdown (barra impilata + legenda)
//
// Mostra come si compongono i token del periodo: input "nuovi", token scritti in cache,
// token letti dalla cache, output. Monocromo (4 tonalità del primario) per restare nel
// vetro neutro; le etichette rendono i segmenti distinguibili. La somma = token totali.

private struct TokenBreakdownCard: View {
    let input: Int
    let cacheRead: Int
    let cacheWrite: Int
    let output: Int

    private struct Seg: Identifiable {
        let label: String
        let value: Int
        let shade: Double
        var id: String { label }
    }

    private var segs: [Seg] {
        [Seg(label: String(localized: "New input"), value: input, shade: 0.85),
         Seg(label: String(localized: "Cache writes"), value: cacheWrite, shade: 0.55),
         Seg(label: String(localized: "Cache reads"), value: cacheRead, shade: 0.38),
         Seg(label: String(localized: "Output"), value: output, shade: 0.20)]
    }
    private var total: Int { max(1, input + cacheRead + cacheWrite + output) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack {
                EyebrowTag(text: String(localized: "TOKEN"), symbol: "bolt")
                Spacer()
                Text(total.compactString)
                    .font(.dsMono)
                    .foregroundStyle(.secondary)
            }

            // Barra impilata (4 tonalità del colore primario).
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(segs) { seg in
                        Color.primary.opacity(seg.shade)
                            .frame(width: max(0, geo.size.width * CGFloat(seg.value) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            .animation(DS.Motion.smooth, value: total)

            // Legenda 2×2: tonalità · etichetta · valore.
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: DS.Spacing.m),
                          GridItem(.flexible(), spacing: DS.Spacing.m)],
                alignment: .leading, spacing: 6)
            {
                ForEach(segs) { seg in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.primary.opacity(seg.shade))
                            .frame(width: 9, height: 9)
                        Text(seg.label)
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(seg.value.compactString)
                            .font(.dsMono)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .padding(DS.Spacing.m)
        .dsCardBezel()
    }
}

// MARK: - Breakdown DisclosureGroup

private struct BreakdownDisclosure: View {
    let title: String
    let items: [BreakdownItem]
    let showCost: Bool
    @State private var open = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var maxValue: Double {
        max(1, items.map { showCost ? $0.cost : Double($0.tokens) }.max() ?? 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: cliccabile su TUTTA la pill (vedi .contentShape + .onTapGesture sotto).
            HStack(spacing: DS.Spacing.s) {
                Text(title).font(.dsHeadline)
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                // Hover scoped al solo chevron: tingere il chevron non deve far rivalutare
                // l'intera card (con i suoi GeometryReader) — quindi @State hover e animazione
                // vivono qui, non sul wrapper.
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(open || hovering ? Color.primary : Color.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .onHover { hovering = $0 }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
            }

            if open {
                Group {
                    if items.isEmpty {
                        Text("No data in this period")
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, DS.Spacing.s)
                    } else {
                        VStack(spacing: DS.Spacing.s) {
                            ForEach(items) { item in
                                let value = showCost ? item.cost : Double(item.tokens)
                                HStack(spacing: DS.Spacing.s) {
                                    Image(systemName: item.symbol)
                                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                                    Text(item.label)
                                        .font(.dsBody)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(width: 120, alignment: .leading)
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.primary.opacity(0.08))
                                            Capsule()
                                                .fill(Color.primary.opacity(0.45))
                                                .frame(width: max(4, geo.size.width * (value / maxValue)))
                                        }
                                    }
                                    .frame(height: 6)
                                    Text(showCost ? item.cost.currencyString : item.tokens.compactString)
                                        .font(.dsMono).foregroundStyle(.secondary)
                                        .frame(width: 52, alignment: .trailing)
                                }
                            }
                        }
                        .padding(.top, DS.Spacing.s)
                    }
                }
                // `.move(edge: .top)` farebbe scivolare le righe SOPRA l'header durante la
                // transizione: clippiamo il contenuto espandibile ai propri bounds così
                // l'entrata/uscita resta dentro il blocco e non sovrasta il titolo.
                .clipped()
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(DS.Spacing.m)
        .contentShape(Rectangle()) // tutta la pill (anche i bordi) è area di tap
        .dsCardBezel()
        .onTapGesture { withAnimation(reduceMotion ? nil : DS.Motion.soft) { open.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(open ? Text("\(title), expanded") : Text("\(title), collapsed"))
        .animation(reduceMotion ? nil : DS.Motion.soft, value: open)
        // Reset hover quando il pannello si nasconde: senza mouse-exit (panel chiuso da
        // fuori) lo stato hover resterebbe acceso al riapri. Notification dal panel-host.
        .onReceive(NotificationCenter.default.publisher(for: .claudeBarPanelDidHide)) { _ in
            hovering = false
        }
    }
}

// MARK: - Extra stats (dietro "Mostra di più")

private struct ExtraStatsView: View {
    let analytics: AnalyticsVM
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            EyebrowTag(text: String(localized: "DETAILS"))
            HStack {
                Text("Cache efficiency").font(.dsBody)
                Spacer()
                Text("\(Int((analytics.cacheEfficiency * 100).rounded()))%")
                    .font(.dsMono).foregroundStyle(.primary)
            }
            HStack {
                Text("Chart points").font(.dsBody)
                Spacer()
                Text("\(analytics.series.count)").font(.dsMono).foregroundStyle(.secondary)
            }
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCardBezel()
    }
}

// MARK: - Number formatting helpers

extension Double {
    var currencyString: String {
        "$" + String(format: self >= 100 ? "%.0f" : "%.2f", self)
    }
}
extension Int {
    var compactString: String {
        let d = Double(self)
        switch d {
        case 1_000_000...: return String(format: "%.1fM", d / 1_000_000)
        case 1_000...: return String(format: "%.0fK", d / 1_000)
        default: return "\(self)"
        }
    }
}

#Preview("AnalyticsSection") {
    ScrollView {
        AnalyticsSection(analytics: MockPanelViewModel.sampleAnalytics(range: .today),
                         onRange: { _ in })
            .padding(20)
    }
    .frame(width: 360, height: 560)
}
