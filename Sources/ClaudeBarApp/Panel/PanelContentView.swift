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
    @Namespace private var glassNS

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var statusColor: Color {
        guard let w = model.criticalWindow else { return .secondary }
        // Glance della finestra critica → curva parametrica con le soglie utente (coerente icona).
        return w.glanceColor
    }

    var body: some View {
        GlassEffectContainer(spacing: DS.Spacing.l) {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                PanelHeaderView(
                    account: model.account,
                    statusColor: statusColor,
                    lastUpdated: model.lastUpdated,
                    isRefreshing: model.isRefreshing,
                    onRefresh: { model.refresh() },
                    onSettings: { model.openSettings() }
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

                Divider().overlay(Color.primary.opacity(0.06))

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
                // Sotto il cap del pannello, lo ScrollView si comprime e scrolla → nessun taglio.
                // (Per tornare ad altezza fissa: ripristina `height: DS.Size.panelMaxHeight` sotto.)
                .frame(maxHeight: 340)
            }
            .padding(DS.Spacing.xl)
        }
        .frame(width: DS.Size.panelWidth)
        .frame(maxHeight: DS.Size.panelMaxHeight)
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
                message: noAuthMessage)

        case .noSubscription:
            NoSubscriptionView()
        }
    }

    /// Messaggio onboarding adatto al provider attivo: per i provider a consumo invita a inserire
    /// la API key in Impostazioni; per Claude (o legacy) resta il messaggio OAuth di default (nil).
    private var noAuthMessage: String? {
        guard let name = model.activeProvider?.name, name != "Claude" else { return nil }
        return "Inserisci la API key di \(name) nelle Impostazioni → Provider per vedere usage e costo."
    }

    /// Sceglie il layout in base ai DATI presenti (non al provider):
    /// - finestre limite → vista "limiti" (anelli + Pace), IDENTICA a Claude oggi (default);
    /// - altrimenti usage+costo → vista "API a consumo";
    /// - altrimenti niente (le analytics locali sotto restano comunque visibili).
    @ViewBuilder
    private var providerContent: some View {
        if !model.windows.isEmpty {
            LimitsSection(windows: model.windows, showUsed: $showUsed)
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

#Preview("Errore limiti") {
    PreviewHost(MockPanelViewModel(state: .error(message: "Impossibile contattare Anthropic. Controlla la connessione.")))
}

#Preview("No auth") { PreviewHost(MockPanelViewModel(state: .noAuth)) }

#Preview("No subscription") { PreviewHost(MockPanelViewModel(state: .noSubscription)) }

#Preview("Critico") {
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
#Preview("API a consumo + switcher") {
    PreviewHost(MockPanelViewModel(
        state: .ok,
        account: AccountVM(name: "platform.openai", plan: "pay-as-you-go"),
        windows: [],
        availableProviders: MockPanelViewModel.sampleProviders(),
        activeProvider: MockPanelViewModel.sampleProviders()[1],
        usageCost: MockPanelViewModel.sampleUsageCost(),
        credits: CreditsVM(remaining: 65.90, total: 100, currency: "USD")))
}
