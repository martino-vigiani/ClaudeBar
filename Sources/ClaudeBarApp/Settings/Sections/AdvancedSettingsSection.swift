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
            "Data location",
            footnote: "Read-only. Transcripts are produced by Claude Code; ClaudeBar only reads them. The cache lives in Application Support.")
        {
            ForEach(Self.transcriptRootPaths, id: \.self) { path in
                Self.pathRow(title: String(localized: "Transcript"), path: path)
            }
            Divider()
            Self.pathRow(title: String(localized: "App cache"), path: AppPaths.appSupportDir().path)
            HStack {
                Spacer()
                Button("Open in Finder") {
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
            "Analytics index",
            footnote: "“Rebuild” reparses all transcripts (slower). “Clear” first deletes the on-disk cache, then regenerates it from scratch. The original transcripts are not touched.")
        {
            HStack(spacing: DS.Spacing.s) {
                Button {
                    self.runIndexOperation(.rebuilding)
                } label: {
                    self.indexButtonLabel(String(localized: "Rebuild index"), busy: self.indexTask == .rebuilding)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(self.indexTask != nil)

                Button(role: .destructive) {
                    self.confirmingClearCache = true
                } label: {
                    self.indexButtonLabel(String(localized: "Clear index cache"), busy: self.indexTask == .clearing)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(self.indexTask != nil)
                .confirmationDialog(
                    "Clear the index cache?",
                    isPresented: self.$confirmingClearCache,
                    titleVisibility: .visible)
                {
                    Button("Clear and rebuild", role: .destructive) {
                        self.runIndexOperation(.clearing)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The on-disk cache will be deleted and rebuilt from the transcripts. This operation doesn't delete your transcripts.")
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
                    .controlSize(.mini)
            }
            Text(title)
        }
    }

    // MARK: - Esporta analytics

    private var exportGroup: some View {
        SettingsGroup(
            "Export analytics",
            footnote: "Save the current report as a file. CSV for spreadsheets, JSON for the complete data.")
        {
            Picker("Format", selection: self.$exportFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.label).tag(format)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button("Export…") { self.runExport() }
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
            "Diagnostics",
            footnote: "Copies a technical summary to the clipboard (version, paths, counts and recent logs). Useful for understanding a problem; no data is sent anywhere.")
        {
            HStack {
                Button {
                    self.copyDiagnostics()
                } label: {
                    Label(
                        self.diagnosticsCopied ? "Copied" : "Copy diagnostics",
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
            footnote: "Returns all settings to their default values. The credentials saved in the keychain (API keys, cookies) are NOT touched.")
        {
            HStack {
                Button(role: .destructive) {
                    self.confirmingReset = true
                } label: {
                    Text("Reset all settings")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .confirmationDialog(
                    "Restore the default settings?",
                    isPresented: self.$confirmingReset,
                    titleVisibility: .visible)
                {
                    Button("Restore defaults", role: .destructive) {
                        self.settings.resetToDefaults()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Appearance, thresholds, notifications, refresh interval and all other preferences return to their initial values. The secrets in the keychain remain.")
                }
                Spacer()
            }
        }
    }

    // MARK: - Azioni indice

    private func runIndexOperation(_ operation: IndexOperation) {
        self.indexTask = operation
        self.indexMessage = operation == .rebuilding
            ? String(localized: "Rebuilding the index…")
            : String(localized: "Clearing and rebuilding…")
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
                self.indexMessage = String(localized: "Operation failed: \(error.localizedDescription)")
            }
            self.indexTask = nil
        }
    }

    private static func indexSummary(_ report: AnalyticsReport) -> String {
        let tokens = Self.compactNumber(report.totals.totalTokens)
        let days = report.byDay.count
        return String(localized: "Index updated: \(tokens) tokens across \(days) day(s).")
    }

    // MARK: - Export (NSSavePanel → file CSV/JSON)

    private func runExport() {
        self.exportError = nil
        let format = self.exportFormat
        Task {
            guard let report = await self.maintenance.currentReport() else {
                self.exportError = String(localized: "No data to export: try rebuilding the index first.")
                return
            }
            let payload: String
            switch format {
            case .csv: payload = AnalyticsExport.csv(from: report)
            case .json:
                guard let json = AnalyticsExport.json(from: report) else {
                    self.exportError = String(localized: "Couldn't serialize the report to JSON.")
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
        panel.title = NSLocalizedString("Export analytics", comment: "Save panel title for analytics export")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try payload.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            self.exportError = String(localized: "Save failed: \(error.localizedDescription)")
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
