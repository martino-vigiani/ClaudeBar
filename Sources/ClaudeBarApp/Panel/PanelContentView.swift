import SwiftUI

// MARK: - PanelContentView (entry point del pannello Liquid Glass)
//
// Assembla l'intero pannello sopra il view model. È generica su `PanelViewModeling`
// così funziona sia col Mock (preview/sviluppo/test) sia con l'AppModel reale tramite
// l'adapter `AppModelPanelAdapter` (wiring in AppDelegate / PanelHostController).
//
// Entry point CONCORDATO con core-engineer (vedi AppDelegate):
//   PanelContentView(model: AppModelPanelAdapter(appModel))  // dentro la factory AnyView
//
// Struttura (03-design §4.2):
//   GlassPanel (cornice glass neutra, GlassEffectContainer unico)
//     ├─ HEADER identità (account · plan · aggiornato · refresh · settings)
//     ├─ FASCIA A — limiti (anelli + reset + PaceBar) / o stato (loading/err/no-auth)
//     ├─ hairline divider
//     └─ FASCIA B — analytics (sempre visibili) in ScrollView

struct PanelContentView<Model: PanelViewModeling>: View {
    /// Il model è posseduto altrove (l'adapter trattenuto dal wiring per il reale, il
    /// wrapper per le preview); qui lo osserviamo soltanto. Essendo `@Observable`, le
    /// modifiche aggiornano la view.
    let model: Model

    @State private var showUsed = true
    @State private var appeared = false
    /// Fascia limiti collassata ai soli 2 anelli → più spazio verticale alle analytics.
    /// Controllata dalla `CollapseHandle` sotto la fascia. Vale solo col layout limiti
    /// (anelli); negli stati error/no-auth non ci sono finestre da collassare.
    @State private var topCollapsed = false
    @Namespace private var glassNS

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var statusColor: Color {
        guard let w = model.criticalWindow else { return .secondary }
        // Glance della finestra critica → curva parametrica con le soglie utente (coerente icona).
        return w.glanceColor
    }

    var body: some View {
        // Collassabile solo quando c'è davvero la fascia anelli (layout limiti).
        let collapsed = topCollapsed && !model.windows.isEmpty
        return GlassEffectContainer(spacing: DS.Spacing.l) {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                PanelHeaderView(
                    account: model.account,
                    statusColor: statusColor,
                    lastUpdated: model.lastUpdated,
                    isRefreshing: model.isRefreshing,
                    onRefresh: { model.refresh() },
                    onSettings: { model.openSettings() },
                    onQuit: { model.quit() }
                )

                // Switcher provider (solo se ≥2 provider abilitati). Con 1 solo provider
                // resta nascosto → UX mono-Claude invariata.
                if model.availableProviders.count >= 2 {
                    ProviderSwitcher(
                        providers: model.availableProviders,
                        activeID: model.activeProvider?.id,
                        onSelect: { model.setActiveProvider($0) })
                }

                providerArea

                // Separatore interattivo: con le finestre presenti diventa una maniglia che
                // collassa la fascia ai soli anelli (più aria alle analytics); altrimenti è un
                // semplice divider (niente da collassare negli stati error/no-auth).
                if !model.windows.isEmpty {
                    CollapseHandle(collapsed: $topCollapsed)
                } else {
                    Divider().overlay(Color.primary.opacity(0.06))
                }

                ScrollView {
                    AnalyticsSection(
                        analytics: model.analytics,
                        onRange: { model.setRange($0) }
                    )
                    .padding(.bottom, DS.Spacing.s)
                }
                .scrollIndicators(.automatic)
                // ALTEZZA ADATTIVA: lo ScrollView ha un cap (non più "riempi .infinity") così,
                // con l'altezza del pannello non più fissa ma `maxHeight`, il pannello si ACCORCIA
                // quando il contenuto è poco (es. loading/errore) invece di lasciare spazio vuoto.
                // Collassando la fascia limiti il cap (e il pannello) crescono → la fascia
                // analytics guadagna ~150pt invece di restare schiacciata.
                .frame(maxHeight: collapsed ? 480 : 340)
            }
            .padding(DS.Spacing.xl)
        }
        .frame(width: DS.Size.panelWidth)
        .frame(maxHeight: collapsed ? DS.Size.panelMaxHeightExpanded : DS.Size.panelMaxHeight)
        .background {
            GlassPanel { Color.clear }
        }
        // Arrotonda l'INTERA cornice in modo uniforme (niente angolo squadrato), poi ombra
        // sulla forma arrotondata. Il padding dà spazio all'ombra dentro la finestra borderless.
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .padding(DS.Spacing.l)
        // Apertura: scale 0.96→1 + slide-down + fade (Reduce Motion → solo fade).
        .scaleEffect(appeared || reduceMotion ? 1 : 0.96)
        .offset(y: appeared || reduceMotion ? 0 : -8)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            // Refresh on-demand se i dati sono vecchi (l'adapter inoltra a AppModel.panelDidOpen()).
            model.panelDidOpen()
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : DS.Motion.soft) {
                appeared = true
            }
        }
    }

    // MARK: Fascia provider — switch sullo stato, poi sul TIPO di dati (limiti vs usage+costo)

    @ViewBuilder
    private var providerArea: some View {
        switch model.state {
        case .loading:
            LimitsLoadingView()

        case .ok:
            providerContent
                .transition(.opacity)

        case .stale(let since):
            VStack(spacing: DS.Spacing.s) {
                StaleBanner(since: since)
                providerContent
                    .opacity(0.6) // valori desaturati finché non arriva il fresh
            }

        case .error(let message):
            LimitsErrorView(message: message, onRetry: { model.retry() })

        case .noAuth:
            NoAuthView(
                onReconnect: { model.reconnect() },
                onHowTo: { model.openSettings() },
                providerName: model.activeProvider?.name ?? "Claude",
                message: noAuthMessage,
                isReconnecting: model.isRefreshing)

        case .noSubscription:
            NoSubscriptionView()
        }
    }

    /// Messaggio onboarding adatto al provider attivo: per i provider a consumo invita a inserire
    /// la API key in Impostazioni; per Claude (o legacy) resta il messaggio OAuth di default (nil).
    private var noAuthMessage: String? {
        guard let name = model.activeProvider?.name, name != "Claude" else { return nil }
        return String(localized: "Enter your \(name) API key in Settings → Providers to see usage and cost.")
    }

    /// Sceglie il layout in base ai DATI presenti (non al provider):
    /// - finestre limite → vista "limiti" (anelli + Pace), IDENTICA a Claude oggi (default);
    /// - altrimenti usage+costo → vista "API a consumo";
    /// - altrimenti niente (le analytics locali sotto restano comunque visibili).
    @ViewBuilder
    private var providerContent: some View {
        if !model.windows.isEmpty {
            LimitsSection(windows: model.windows, showUsed: $showUsed, collapsed: topCollapsed)
        } else if let cost = model.usageCost {
            UsageCostSection(cost: cost, credits: model.credits)
        } else if let credits = model.credits {
            // Solo credito, niente finestre né costo per range.
            UsageCostSection(
                cost: UsageCostVM(buckets: [], byModel: [], series: [], costEstimated: false, currencyCode: credits.currency),
                credits: credits)
        }
        // Nessun blocco provider → solo analytics locali (degradazione elegante).
    }
}

// MARK: - CollapseHandle (separatore interattivo fascia limiti ↔ analytics)
//
// Hairline su entrambi i lati + chevron centrato. Tap → collassa la fascia superiore ai soli
// 2 anelli (via binding), liberando spazio per lo ScrollView analytics; ri-tap → ripristina
// reset/pace/cap. Chevron verso l'alto = "comprimi", verso il basso = "espandi di nuovo".

private struct CollapseHandle: View {
    @Binding var collapsed: Bool

    var body: some View {
        Button {
            withAnimation(DS.Motion.soft) { collapsed.toggle() }
        } label: {
            HStack(spacing: DS.Spacing.s) {
                hairline
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                hairline
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show limits detail" : "Collapse to rings — more analytics")
        .accessibilityLabel(collapsed ? Text("Show limits detail") : Text("Collapse limits to rings"))
        .accessibilityAddTraits(.isButton)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: DS.Size.hairline)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Previews (tutti gli stati)
//
// Wrapper che possiede il Mock via @State (l'@Observable dev'essere trattenuto da
// qualcuno perché l'osservazione funzioni): PanelContentView lo osserva soltanto.

private struct PreviewHost: View {
    @State private var model: MockPanelViewModel
    init(_ model: MockPanelViewModel) { _model = State(initialValue: model) }
    var body: some View {
        PanelContentView(model: model).padding(40)
    }
}

#Preview("OK") { PreviewHost(MockPanelViewModel(state: .ok)) }

#Preview("Loading") { PreviewHost(MockPanelViewModel(state: .loading)) }

#Preview("Limits error") {
    PreviewHost(MockPanelViewModel(state: .error(message: "Unable to reach Anthropic. Check your connection.")))
}

#Preview("No auth") { PreviewHost(MockPanelViewModel(state: .noAuth)) }

#Preview("No subscription") { PreviewHost(MockPanelViewModel(state: .noSubscription)) }

#Preview("Critical") {
    let crit = UsageWindowVM(
        kind: .session, utilization: 96,
        resetsAt: Date().addingTimeInterval(41 * 60),
        pace: PaceInfo(paceMarker: 0.88, status: .over, etaToEmpty: 18 * 60, emptyAt: .now))
    let weekly = UsageWindowVM(
        kind: .weekly, utilization: 52, resetsAt: Date().addingTimeInterval(3 * 86400),
        pace: PaceInfo(paceMarker: 0.6, status: .under, etaToEmpty: nil, emptyAt: nil))
    return PreviewHost(MockPanelViewModel(state: .ok, windows: [crit, weekly]))
}

// Multi-provider (MP-6): provider a consumo (usage+costo+credito) con switcher attivo.
#Preview("Usage-based API + switcher") {
    PreviewHost(MockPanelViewModel(
        state: .ok,
        account: AccountVM(name: "platform.openai", plan: "pay-as-you-go"),
        windows: [],
        availableProviders: MockPanelViewModel.sampleProviders(),
        activeProvider: MockPanelViewModel.sampleProviders()[1],
        usageCost: MockPanelViewModel.sampleUsageCost(),
        credits: CreditsVM(remaining: 65.90, total: 100, currency: "USD")))
}
