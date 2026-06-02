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
            "Default period",
            footnote: "This is the period shown when you open the panel. You can always change it on the fly from the panel itself.")
        {
            Picker("Period on open", selection: self.$settings.defaultAnalyticsRange) {
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
        case .today: String(localized: "Today")
        case .week: String(localized: "Last 7 days")
        case .month: String(localized: "Last 30 days")
        }
    }

    // MARK: Contenuto degli aggregati

    private var contentGroup: some View {
        SettingsGroup(
            "Content",
            footnote: "Subagent sessions are the runs started by Claude Code in sub-agents. Excluding them shows only the main session's usage.")
        {
            Toggle("Include subagent sessions", isOn: self.$settings.includeSubagentsInAnalytics)
                .toggleStyle(.switch)
            Divider()
            Toggle("Show the cost disclaimer", isOn: self.$settings.showCostDisclaimer)
                .toggleStyle(.switch)
            Text("On the Max plan the cost isn't a real expense: it's the list value of the consumed tokens (API-equivalent estimate).")
                .font(.dsCaption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Override pricing (avanzato)

    private var pricingGroup: some View {
        SettingsGroup(
            "Custom pricing (advanced)",
            footnote: "Load a JSON file with per-token model prices. It overrides the built-in table; handy for updating price lists without updating the app.")
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
                Button(self.hasOverride ? "Replace file…" : "Load JSON file…") {
                    self.importing = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if self.hasOverride {
                    Button("Remove") { self.removeOverride() }
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
                Text("Override active")
                    .font(.dsBody)
                Text(self.overrideCount > 0
                    ? "\(self.overrideCount) model(s) with custom prices."
                    : "File loaded.")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        Text("No override: the app uses the built-in price table.")
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
            self.errorMessage = String(localized: "Couldn't open the file: \(error.localizedDescription)")
        }
    }

    /// Valida che il JSON sia decodificabile come `[String: ModelPricing]`, poi lo copia nel path
    /// standard e ricarica gli override. Salva il path originale in `pricingOverridePath` (display).
    private func copyAndApply(from source: URL) {
        // I file scelti via fileImporter sono security-scoped: serve l'accesso esplicito.
        let needsAccess = source.startAccessingSecurityScopedResource()
        defer { if needsAccess { source.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: source) else {
            self.errorMessage = String(localized: "Couldn't read the selected file.")
            return
        }
        guard let decoded = try? JSONDecoder().decode([String: ModelPricing].self, from: data),
              !decoded.isEmpty
        else {
            self.errorMessage = String(localized: "The file isn't a valid pricing JSON (expected a “model → prices” object).")
            return
        }

        let destination = AppPaths.pricingOverridesURL()
        AppPaths.ensureDirectory(destination.deletingLastPathComponent())
        do {
            // Riscriviamo i dati (già validati) nel path standard, sostituendo l'eventuale precedente.
            try data.write(to: destination, options: .atomic)
        } catch {
            self.errorMessage = String(localized: "Couldn't save the override: \(error.localizedDescription)")
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
