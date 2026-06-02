import ClaudeBarCore
import SwiftUI
import UniformTypeIdentifiers

/// Sezione ANALYTICS delle Impostazioni (SET-3).
///
/// Lega:
/// - `defaultAnalyticsRange` → range mostrato all'apertura del pannello (l'AppModel inizializza
///   `analyticsRange` da qui);
/// - `includeSubagentsInAnalytics` → include/esclude le sessioni subagent dagli aggregati;
/// - `showCostDisclaimer` → mostra il disclaimer "stima API-equivalente" sotto il costo;
/// - `pricingOverridePath` → carica un JSON locale che SOVRASCRIVE i prezzi della tabella embedded
///   (avanzato). Il file viene copiato in `AppPaths.pricingOverridesURL()` e applicato subito via
///   `PricingOverrides.shared.reload()`.
///
/// Vetro NEUTRO: nessuna tinta, niente `.glassEffect()` sul contenuto.
struct AnalyticsSettingsSection: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsSectionScaffold(section: .analytics) {
            self.rangeGroup
            self.contentGroup
            self.pricingGroup
        }
    }

    // MARK: Range di default

    private var rangeGroup: some View {
        SettingsGroup(
            "Periodo di default",
            footnote: "È il periodo mostrato quando apri il pannello. Puoi sempre cambiarlo al volo dal pannello stesso.")
        {
            Picker("Periodo all'apertura", selection: self.$settings.defaultAnalyticsRange) {
                ForEach(AnalyticsRange.allCases) { range in
                    Text(Self.rangeLabel(range)).tag(range)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    /// Etichetta estesa del range per le Impostazioni (nel pannello sono più compatte: Oggi/7g/30g).
    private static func rangeLabel(_ range: AnalyticsRange) -> String {
        switch range {
        case .today: "Oggi"
        case .week: "Ultimi 7 giorni"
        case .month: "Ultimi 30 giorni"
        }
    }

    // MARK: Contenuto degli aggregati

    private var contentGroup: some View {
        SettingsGroup(
            "Contenuto",
            footnote: "Le sessioni subagent sono le esecuzioni avviate da Claude Code in sotto-agenti. Escluderle mostra solo l'uso della sessione principale.")
        {
            Toggle("Includi le sessioni subagent", isOn: self.$settings.includeSubagentsInAnalytics)
                .toggleStyle(.switch)
            Divider()
            Toggle("Mostra il disclaimer di costo", isOn: self.$settings.showCostDisclaimer)
                .toggleStyle(.switch)
            Text("Con piano Max il costo non è una spesa reale: è il valore a listino dei token consumati (stima API-equivalente).")
                .font(.dsCaption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Override pricing (avanzato)

    private var pricingGroup: some View {
        SettingsGroup(
            "Pricing personalizzato (avanzato)",
            footnote: "Carica un file JSON con i prezzi per token dei modelli. Sovrascrive la tabella interna; utile per aggiornare i listini senza aggiornare l'app.")
        {
            PricingOverrideRow(settings: self.settings)
        }
    }
}

// MARK: - Riga override pricing (file picker → copia in AppSupport → reload)

private struct PricingOverrideRow: View {
    @Bindable var settings: SettingsStore

    @State private var importing = false
    @State private var errorMessage: String?
    /// Conteggio dei modelli nel file override correntemente caricato (feedback "N modelli").
    @State private var overrideCount: Int = 0

    /// Fonte di verità: la presenza del file nel path standard (è ciò che `PricingTable` applica
    /// davvero). `pricingOverridePath` è solo l'etichetta del file originale scelto dall'utente.
    private var hasOverride: Bool {
        FileManager.default.fileExists(atPath: AppPaths.pricingOverridesURL().path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            if self.hasOverride {
                self.activeState
            } else {
                self.emptyState
            }

            HStack(spacing: DS.Spacing.s) {
                Button(self.hasOverride ? "Sostituisci file…" : "Carica file JSON…") {
                    self.importing = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if self.hasOverride {
                    Button("Rimuovi") { self.removeOverride() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
                Spacer()
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.dsCaption)
                    .foregroundStyle(UsageColorScale.color(used: 95))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { self.refreshCount() }
        .fileImporter(
            isPresented: self.$importing,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false)
        { result in
            self.handleImport(result)
        }
    }

    private var activeState: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Override attivo")
                    .font(.dsBody)
                Text(self.overrideCount > 0
                    ? "\(self.overrideCount) modell\(self.overrideCount == 1 ? "o" : "i") con prezzi personalizzati."
                    : "File caricato.")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        Text("Nessun override: l'app usa la tabella prezzi interna.")
            .font(.dsCaption)
            .foregroundStyle(.tertiary)
    }

    // MARK: Import / rimozione

    private func handleImport(_ result: Result<[URL], Error>) {
        self.errorMessage = nil
        switch result {
        case let .success(urls):
            guard let source = urls.first else { return }
            self.copyAndApply(from: source)
        case let .failure(error):
            self.errorMessage = "Impossibile aprire il file: \(error.localizedDescription)"
        }
    }

    /// Valida che il JSON sia decodificabile come `[String: ModelPricing]`, poi lo copia nel path
    /// standard e ricarica gli override. Salva il path originale in `pricingOverridePath` (display).
    private func copyAndApply(from source: URL) {
        // I file scelti via fileImporter sono security-scoped: serve l'accesso esplicito.
        let needsAccess = source.startAccessingSecurityScopedResource()
        defer { if needsAccess { source.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: source) else {
            self.errorMessage = "Impossibile leggere il file selezionato."
            return
        }
        guard let decoded = try? JSONDecoder().decode([String: ModelPricing].self, from: data),
              !decoded.isEmpty
        else {
            self.errorMessage = "Il file non è un JSON di pricing valido (atteso un oggetto «modello → prezzi»)."
            return
        }

        let destination = AppPaths.pricingOverridesURL()
        AppPaths.ensureDirectory(destination.deletingLastPathComponent())
        do {
            // Riscriviamo i dati (già validati) nel path standard, sostituendo l'eventuale precedente.
            try data.write(to: destination, options: .atomic)
        } catch {
            self.errorMessage = "Impossibile salvare l'override: \(error.localizedDescription)"
            return
        }

        // Applica subito: il PricingTable legge da `PricingOverrides.shared.table`.
        PricingOverrides.shared.reload()
        self.settings.pricingOverridePath = source.path
        self.overrideCount = decoded.count
    }

    private func removeOverride() {
        self.errorMessage = nil
        try? FileManager.default.removeItem(at: AppPaths.pricingOverridesURL())
        PricingOverrides.shared.reload()
        self.settings.pricingOverridePath = nil
        self.overrideCount = 0
    }

    private func refreshCount() {
        self.overrideCount = PricingOverrides.shared.table.count
    }
}

#Preview("Analytics") {
    AnalyticsSettingsSection(settings: SettingsStore())
        .frame(width: 484, height: 560)
}
