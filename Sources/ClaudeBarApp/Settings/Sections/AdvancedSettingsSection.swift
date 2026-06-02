import AppKit
import ClaudeBarCore
import SwiftUI
import UniformTypeIdentifiers

/// Sezione AVANZATO delle Impostazioni (SET-4).
///
/// Raccoglie le operazioni "di servizio", tutte cablate al comportamento reale:
/// - **Posizione dati** (sola lettura): root dei transcript + cartella Application Support, con
///   "Apri in Finder";
/// - **Indice / cache**: "Ricostruisci indice" (`MaintenanceService.rebuildIndex`) e
///   "Azzera cache indice" (`clearAndRebuild`, con conferma) — l'eliminazione su disco vive nel
///   Core (niente file cancellati "a mano" dalla UI);
/// - **Esporta analytics** (CSV / JSON) dal report corrente su disco, via `NSSavePanel`;
/// - **Diagnostica**: copia negli appunti un riepilogo (ambiente + path + log recenti) via `NSPasteboard`;
/// - **Reset di tutte le impostazioni** (`settings.resetToDefaults()`, con conferma) — NON tocca i
///   segreti in Keychain.
///
/// Vetro NEUTRO: nessuna tinta, niente `.glassEffect()` sul contenuto. Azioni distruttive con
/// `confirmationDialog` attaccato al trigger (il Liquid Glass anima dalla sorgente).
struct AdvancedSettingsSection: View {
    @Bindable var settings: SettingsStore
    let secretStore: any ProviderSecretStoring

    /// Servizio di manutenzione (Core): ricostruzione/azzeramento indice + lettura report. Stateless,
    /// usa i path deterministici di `AppPaths` → opera sulla stessa cache dell'app a runtime.
    private let maintenance = MaintenanceService()

    /// Stato dell'operazione su indice/cache in corso (disabilita i bottoni + mostra spinner).
    @State private var indexTask: IndexOperation?
    @State private var indexMessage: String?
    /// Conferme delle azioni distruttive.
    @State private var confirmingClearCache = false
    @State private var confirmingReset = false
    /// Export.
    @State private var exportFormat: ExportFormat = .csv
    @State private var exportError: String?
    /// Feedback "copiato" per la diagnostica.
    @State private var diagnosticsCopied = false

    private enum IndexOperation: String { case rebuilding, clearing }

    var body: some View {
        SettingsSectionScaffold(section: .advanced) {
            self.dataLocationGroup
            self.indexGroup
            self.exportGroup
            self.diagnosticsGroup
            self.resetGroup
        }
    }

    // MARK: - Posizione dati (sola lettura)

    private var dataLocationGroup: some View {
        SettingsGroup(
            "Posizione dei dati",
            footnote: "Sola lettura. I transcript sono prodotti da Claude Code; ClaudeBar li legge soltanto. La cache vive in Application Support.")
        {
            ForEach(Self.transcriptRootPaths, id: \.self) { path in
                Self.pathRow(title: "Transcript", path: path)
            }
            Divider()
            Self.pathRow(title: "Cache app", path: AppPaths.appSupportDir().path)
            HStack {
                Spacer()
                Button("Apri in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.appSupportDir()])
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private static var transcriptRootPaths: [String] {
        AppPaths.transcriptRoots().map(\.path)
    }

    /// Riga "etichetta + path monospace selezionabile". Il path va a capo invece di troncare,
    /// così resta leggibile anche con finestra stretta.
    private static func pathRow(title: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.dsCaption)
                .foregroundStyle(.secondary)
            Text(path)
                .font(.dsMono)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Indice / cache

    private var indexGroup: some View {
        SettingsGroup(
            "Indice analytics",
            footnote: "«Ricostruisci» riparsa tutti i transcript (più lento). «Azzera» elimina prima la cache su disco e poi la rigenera da zero. I transcript originali non vengono toccati.")
        {
            HStack(spacing: DS.Spacing.s) {
                Button {
                    self.runIndexOperation(.rebuilding)
                } label: {
                    self.indexButtonLabel("Ricostruisci indice", busy: self.indexTask == .rebuilding)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(self.indexTask != nil)

                Button(role: .destructive) {
                    self.confirmingClearCache = true
                } label: {
                    self.indexButtonLabel("Azzera cache indice", busy: self.indexTask == .clearing)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(self.indexTask != nil)
                .confirmationDialog(
                    "Azzerare la cache dell'indice?",
                    isPresented: self.$confirmingClearCache,
                    titleVisibility: .visible)
                {
                    Button("Azzera e ricostruisci", role: .destructive) {
                        self.runIndexOperation(.clearing)
                    }
                    Button("Annulla", role: .cancel) {}
                } message: {
                    Text("La cache su disco verrà eliminata e ricostruita dai transcript. L'operazione non cancella i tuoi transcript.")
                }

                Spacer()
            }

            if let indexMessage {
                Text(indexMessage)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func indexButtonLabel(_ title: String, busy: Bool) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
            Text(title)
        }
    }

    // MARK: - Esporta analytics

    private var exportGroup: some View {
        SettingsGroup(
            "Esporta analytics",
            footnote: "Salva il report corrente come file. CSV per i fogli di calcolo, JSON per il dato completo.")
        {
            Picker("Formato", selection: self.$exportFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.label).tag(format)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button("Esporta…") { self.runExport() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
            }

            if let exportError {
                Text(exportError)
                    .font(.dsCaption)
                    .foregroundStyle(UsageColorScale.color(used: 95))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Diagnostica

    private var diagnosticsGroup: some View {
        SettingsGroup(
            "Diagnostica",
            footnote: "Copia negli appunti un riepilogo tecnico (versione, percorsi, conteggi e log recenti). Utile per capire un problema; nessun dato viene inviato da nessuna parte.")
        {
            HStack {
                Button {
                    self.copyDiagnostics()
                } label: {
                    Label(
                        self.diagnosticsCopied ? "Copiato" : "Copia diagnostica",
                        systemImage: self.diagnosticsCopied ? "checkmark" : "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
        }
    }

    // MARK: - Reset impostazioni

    private var resetGroup: some View {
        SettingsGroup(
            "Reset",
            footnote: "Riporta tutte le impostazioni ai valori di default. Le credenziali salvate nel portachiavi (chiavi API, cookie) NON vengono toccate.")
        {
            HStack {
                Button(role: .destructive) {
                    self.confirmingReset = true
                } label: {
                    Text("Reset di tutte le impostazioni")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .confirmationDialog(
                    "Ripristinare le impostazioni di default?",
                    isPresented: self.$confirmingReset,
                    titleVisibility: .visible)
                {
                    Button("Ripristina i default", role: .destructive) {
                        self.settings.resetToDefaults()
                    }
                    Button("Annulla", role: .cancel) {}
                } message: {
                    Text("Aspetto, soglie, notifiche, intervallo di refresh e tutte le altre preferenze tornano ai valori iniziali. I segreti nel portachiavi restano.")
                }
                Spacer()
            }
        }
    }

    // MARK: - Azioni indice

    private func runIndexOperation(_ operation: IndexOperation) {
        self.indexTask = operation
        self.indexMessage = operation == .rebuilding
            ? "Ricostruzione dell'indice in corso…"
            : "Azzeramento e ricostruzione in corso…"
        // Rispetta la preferenza Analytics → il report ricostruito è coerente col pannello.
        let includeSubagents = self.settings.includeSubagentsInAnalytics
        Task {
            do {
                let report: AnalyticsReport
                switch operation {
                case .rebuilding:
                    report = try await self.maintenance.rebuildIndex(includeSubagents: includeSubagents)
                case .clearing:
                    report = try await self.maintenance.clearAndRebuild(includeSubagents: includeSubagents)
                }
                self.indexMessage = Self.indexSummary(report)
            } catch {
                self.indexMessage = "Operazione non riuscita: \(error.localizedDescription)"
            }
            self.indexTask = nil
        }
    }

    private static func indexSummary(_ report: AnalyticsReport) -> String {
        let tokens = Self.compactNumber(report.totals.totalTokens)
        let days = report.byDay.count
        return "Indice aggiornato: \(tokens) token su \(days) giorn\(days == 1 ? "o" : "i")."
    }

    // MARK: - Export (NSSavePanel → file CSV/JSON)

    private func runExport() {
        self.exportError = nil
        let format = self.exportFormat
        Task {
            guard let report = await self.maintenance.currentReport() else {
                self.exportError = "Nessun dato da esportare: prova prima a ricostruire l'indice."
                return
            }
            let payload: String
            switch format {
            case .csv: payload = AnalyticsExport.csv(from: report)
            case .json:
                guard let json = AnalyticsExport.json(from: report) else {
                    self.exportError = "Impossibile serializzare il report in JSON."
                    return
                }
                payload = json
            }
            self.presentSavePanel(payload: payload, format: format)
        }
    }

    @MainActor
    private func presentSavePanel(payload: String, format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = format.defaultFilename
        panel.canCreateDirectories = true
        panel.title = "Esporta analytics"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try payload.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            self.exportError = "Salvataggio non riuscito: \(error.localizedDescription)"
        }
    }

    // MARK: - Diagnostica (NSPasteboard)

    private func copyDiagnostics() {
        Task {
            let report = await self.maintenance.currentReport()
            let text = DiagnosticsReport.build(report: report)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            self.diagnosticsCopied = true
            try? await Task.sleep(for: .seconds(2))
            self.diagnosticsCopied = false
        }
    }

    // MARK: - Helper

    /// Numero compatto (1.2M / 34k / 980) per i riepiloghi, coerente con i numeri del pannello.
    static func compactNumber(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.0fk", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }
}

// MARK: - Formato di export

enum ExportFormat: String, CaseIterable, Identifiable {
    case csv
    case json

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .csv: "CSV"
        case .json: "JSON"
        }
    }

    var utType: UTType {
        switch self {
        case .csv: .commaSeparatedText
        case .json: .json
        }
    }

    var defaultFilename: String {
        let stamp = Self.dateStamp()
        switch self {
        case .csv: return "claudebar-analytics-\(stamp).csv"
        case .json: return "claudebar-analytics-\(stamp).json"
        }
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

#Preview("Avanzato") {
    AdvancedSettingsSection(settings: SettingsStore(), secretStore: InMemorySecretStore())
        .frame(width: 484, height: 620)
}
