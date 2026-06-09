import SwiftUI

// MARK: - UsageCostSection (Fascia A alternativa — provider "API a consumo")
//
// Sostituisce gli anelli "limiti" per i provider pay-as-you-go (Gemini/OpenAI API/Anthropic API):
// niente finestre limite → si mostra USAGE + COSTO (oggi/mese), credito/budget residuo se noto,
// spesa nel tempo e breakdown per modello. Riusa il linguaggio visivo esistente (vetro neutro,
// `dsCardBezel`, `SpendChart`, `MiniUsageBar`, `EyebrowTag`) per coerenza col pannello limiti.
//
// Le ANALYTICS LOCALI restano sotto (gestite da `PanelContentView`), come per il layout limiti.

struct UsageCostSection: View {
    let cost: UsageCostVM
    let credits: CreditsVM?

    @State private var showCost = true   // grafico: costo vs token

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            EyebrowTag(text: String(localized: "USAGE-BASED"), symbol: "gauge.with.dots.needle.bottom.50percent")

            // KPI: costo oggi + costo mese.
            HStack(spacing: DS.Spacing.m) {
                CostTile(
                    title: String(localized: "Cost today"),
                    value: Self.currencyText(self.cost.today?.costUSD, code: self.cost.currencyCode),
                    footnote: (self.cost.costEstimated && self.cost.showCostDisclaimer) ? String(localized: "API-equivalent estimate") : String(localized: "provider data"),
                    symbol: "dollarsign.circle")
                CostTile(
                    title: String(localized: "This month"),
                    value: Self.currencyText(self.cost.month?.costUSD, code: self.cost.currencyCode),
                    footnote: String(localized: "30 days"),
                    symbol: "calendar")
            }

            // Tetto di spesa on-demand / budget del periodo (opzionale).
            if let spendLimit = self.cost.spendLimit {
                SpendLimitCard(spendLimit: spendLimit)
            }

            // Credito/budget residuo prepagato (opzionale).
            if let credits {
                CreditsCard(credits: credits)
            }

            // Spesa/token nel tempo (riusa SpendChart).
            if !self.cost.series.isEmpty {
                chartCard
            }

            // Per modello (riusa una disclosure leggera).
            if !self.cost.byModel.isEmpty {
                CostBreakdownDisclosure(title: String(localized: "By model"), items: self.cost.byModel, showCost: self.showCost)
            }
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack {
                Text(self.showCost ? "Spend over time" : "Tokens over time")
                    .font(.dsHeadline)
                Spacer()
                Button {
                    withAnimation(DS.Motion.smooth) { self.showCost.toggle() }
                } label: {
                    Text(self.showCost ? "$" : "tok")
                        .font(.dsCaption.weight(.semibold))
                        .frame(width: 30)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            SpendChart(series: self.cost.series, showCost: self.showCost)
                .frame(height: 96)
            if self.cost.costEstimated, self.cost.showCostDisclaimer {
                Text("API-equivalent estimate: some costs are estimated from the local price table.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DS.Spacing.m)
        .dsCardBezel()
    }

    /// Formatta un costo nella valuta del provider; "—" se assente.
    private static func currencyText(_ value: Double?, code: String) -> String {
        guard let value else { return "—" }
        let symbol = code == "USD" ? "$" : (code + " ")
        return symbol + String(format: value >= 100 ? "%.0f" : "%.2f", value)
    }
}

// MARK: - Tile costo (allineata visivamente a KPITile di AnalyticsSection)

private struct CostTile: View {
    let title: String
    let value: String
    let footnote: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: self.symbol).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(self.title).font(.dsCaption).foregroundStyle(.secondary)
            }
            Text(self.value)
                .font(.dsDisplay(20))
                .contentTransition(.numericText())
            Text(self.footnote)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.m)
        .dsCardBezel()
    }
}

// MARK: - Card credito/budget residuo

private struct CreditsCard: View {
    let credits: CreditsVM

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack {
                EyebrowTag(text: String(localized: "CREDIT REMAINING"), symbol: "creditcard")
                Spacer()
                Text(self.balanceText)
                    .font(.dsMono)
                    .foregroundStyle(.primary)
            }
            if let used = self.credits.usedFraction {
                // Barra del CONSUMATO (coerente con la semantica % usato del resto dell'app).
                MiniUsageBar(used: used * 100)
            }
        }
        .padding(DS.Spacing.m)
        .dsCardBezel()
    }

    private var balanceText: String {
        let symbol = self.credits.currency == "USD" ? "$" : (self.credits.currency + " ")
        let remaining = symbol + String(format: "%.2f", self.credits.remaining)
        if let total = self.credits.total {
            return remaining + " / " + symbol + String(format: "%.0f", total)
        }
        return remaining
    }
}

// MARK: - Card tetto di spesa on-demand / budget del periodo

private struct SpendLimitCard: View {
    let spendLimit: SpendLimitVM

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack {
                EyebrowTag(text: self.eyebrow, symbol: "gauge.with.needle")
                Spacer()
                Text(self.spendText)
                    .font(.dsMono)
                    .foregroundStyle(.primary)
            }
            if let used = self.spendLimit.usedFraction {
                // Barra del CONSUMATO sul budget (semantica % usato coerente col resto).
                MiniUsageBar(used: used * 100)
            }
            if let resetsAt = self.spendLimit.resetsAt {
                Text("reset \(resetsAt.formatted(.relative(presentation: .named)))")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
            // NB: il fallback "Budget" sotto è uguale in EN/IT.
        }
        .padding(DS.Spacing.m)
        .dsCardBezel()
    }

    private var eyebrow: String {
        (self.spendLimit.period ?? "Budget").uppercased()
    }

    private var spendText: String {
        let symbol = self.spendLimit.currency == "USD" ? "$" : (self.spendLimit.currency + " ")
        let used = symbol + String(format: "%.2f", self.spendLimit.used)
        if let limit = self.spendLimit.limit {
            return used + " / " + symbol + String(format: "%.0f", limit)
        }
        return used
    }
}

// MARK: - Breakdown per modello (disclosure leggera, vetro neutro)

private struct CostBreakdownDisclosure: View {
    let title: String
    let items: [BreakdownItem]
    let showCost: Bool
    @State private var open = false

    private var maxValue: Double {
        max(1, self.items.map { self.showCost ? $0.cost : Double($0.tokens) }.max() ?? 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.s) {
                Text(self.title).font(.dsHeadline)
                Spacer()
                if !self.items.isEmpty {
                    Text("\(self.items.count)")
                        .font(.dsCaption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(self.open ? 90 : 0))
            }

            if self.open {
                if self.items.isEmpty {
                    Text("No data in this period")
                        .font(.dsCaption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, DS.Spacing.s)
                } else {
                    VStack(spacing: DS.Spacing.s) {
                        ForEach(self.items) { item in
                            let value = self.showCost ? item.cost : Double(item.tokens)
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
                                            .frame(width: max(4, geo.size.width * (value / self.maxValue)))
                                    }
                                }
                                .frame(height: 6)
                                Text(self.showCost ? item.cost.currencyString : item.tokens.compactString)
                                    .font(.dsMono).foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.top, DS.Spacing.s)
                }
            }
        }
        .padding(DS.Spacing.m)
        .contentShape(Rectangle())
        .dsCardBezel()
        .onTapGesture { withAnimation(DS.Motion.soft) { self.open.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(self.open ? Text("\(self.title), expanded") : Text("\(self.title), collapsed"))
        .animation(DS.Motion.soft, value: self.open)
    }
}

#Preview("UsageCostSection") {
    let buckets = [
        CostBucketVM(rangeDays: 1, costUSD: 1.20, totalTokens: 120_000),
        CostBucketVM(rangeDays: 7, costUSD: 9.80, totalTokens: 980_000),
        CostBucketVM(rangeDays: 30, costUSD: 34.10, totalTokens: 3_400_000),
    ]
    let series = (0..<7).map { i in
        SpendPoint(date: Date().addingTimeInterval(Double(-i) * 86400), cost: Double(i) * 1.3, tokens: i * 100_000)
    }
    let byModel = [
        BreakdownItem(label: "gpt-4o", cost: 22.0, tokens: 2_000_000, symbol: "cube"),
        BreakdownItem(label: "gpt-4o-mini", cost: 12.1, tokens: 1_400_000, symbol: "cube"),
    ]
    let spendLimit = SpendLimitVM(
        used: 18.40, limit: 50, currency: "USD", period: "Billing cycle",
        resetsAt: Date().addingTimeInterval(12 * 86400))
    return UsageCostSection(
        cost: UsageCostVM(
            buckets: buckets, byModel: byModel, series: series,
            spendLimit: spendLimit, costEstimated: true, currencyCode: "USD"),
        credits: CreditsVM(remaining: 65.90, total: 100, currency: "USD"))
        .padding(20)
        .frame(width: 360)
}
