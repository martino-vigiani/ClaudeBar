import AppKit
import ClaudeBarCore
import SwiftUI

/// Finestra Impostazioni in stile "app vera" (BRIEF §IA): `NavigationSplitView` con sidebar di
/// sezioni a sinistra e pannello di dettaglio a destra. Vetro NEUTRO di sistema (DECISIONS §3),
/// ridimensionabile (~640–720 di larghezza). Sostituisce il vecchio `PreferencesView` (TabView)
/// mantenendo `openPreferences()` invariato (la scene `Settings` ospita questa view).
///
/// Lo SHELL è di proprietà dell'architetto e NON va modificato dagli implementatori: per riempire
/// una sezione si edita la rispettiva `*SettingsSection` view (vedi `detail(for:)`).
struct SettingsRootView: View {
    @Bindable var settings: SettingsStore
    /// Store dei segreti (Keychain). Iniettabile per i preview/test.
    let secretStore: any ProviderSecretStoring

    @State private var selection: SettingsSection = .general

    init(settings: SettingsStore, secretStore: any ProviderSecretStoring = KeychainSecretStore()) {
        self.settings = settings
        self.secretStore = secretStore
    }

    var body: some View {
        NavigationSplitView {
            // Sidebar con righe CUSTOM e selezione NEUTRA (DECISIONS §3 — niente system-blue).
            //
            // Nota tecnica (il PERCHÉ delle righe custom): una `List(selection:)` con stile
            // `.sidebar` su macOS disegna l'highlight della riga selezionata con il BLU di sistema
            // e NON risponde a `.tint(...)` né a `.listRowBackground(.clear)` (l'highlight è
            // dipinto dalla List, non dallo sfondo riga). Per il look Klack (grigio translucido)
            // NON usiamo affatto la selezione di sistema: ogni riga è un bottone `.plain` che
            // imposta la selezione, e disegna da sé lo sfondo neutro quando attiva. Così l'highlight
            // blu non compare mai.
            //
            // Manteniamo `.listStyle(.sidebar)` e NON nascondiamo lo sfondo della List
            // (`.scrollContentBackground` resta di default): emerge il materiale `.sidebar`
            // translucido NATIVO che fonde con la titlebar — esattamente il vetro neutro voluto.
            // Sidebar raggruppata (look "System Settings"/Klack): tre gruppi con header nativi così
            // le 7 voci respirano invece di essere un elenco piatto. `.listStyle(.sidebar)` con lo
            // sfondo di default → emerge il materiale `.sidebar` translucido NATIVO (vetro neutro che
            // fonde con la titlebar). Le righe restano custom per la selezione NEUTRA (vedi sotto).
            List {
                Section {
                    self.sidebarRows([.general, .menuBar])
                }
                Section("Monitoring") {
                    self.sidebarRows([.providers, .notifications, .analytics])
                }
                Section("System") {
                    self.sidebarRows([.advanced, .about])
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 212, max: 240)
            .listStyle(.sidebar)
        } detail: {
            self.detail(for: self.selection)
                .frame(minWidth: 420, idealWidth: 484)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 460, idealHeight: 560)
        // ACCENT NEUTRO (DECISIONS §3 — niente system-blue): tinta graphite tenue applicata alla
        // radice così toggle e segmented picker delle sezioni la seguono. Resta sobria, monocroma,
        // coerente col pannello; i colori semantici (verde/ambra/rosso) restano locali.
        .tint(Self.neutralAccent)
    }

    /// Costruisce le righe di un gruppo della sidebar: ogni voce è un bottone `.plain` che imposta
    /// la selezione e disegna da sé lo sfondo NEUTRO quando attiva (no highlight blu di sistema).
    @ViewBuilder
    private func sidebarRows(_ sections: [SettingsSection]) -> some View {
        ForEach(sections) { section in
            Button {
                self.selection = section
            } label: {
                SidebarSectionRow(section: section, isSelected: self.selection == section)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
            // Sfondo riga trasparente: nessun highlight di sistema, lo sfondo di selezione lo
            // disegna la riga (capsule grigia neutra).
            .listRowBackground(Color.clear)
        }
    }

    /// Tinta neutra "graphite" dell'app per i controlli delle Impostazioni: derivata dal colore di
    /// label di sistema (adatta automaticamente a light/dark), leggermente desaturata. NON è il
    /// blu di sistema. È usata solo come accento dei controlli, mai come superficie.
    private static let neutralAccent = Color(
        nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            // Grigio caldo-neutro: chiaro su dark, profondo su light → contrasto sufficiente
            // per selezione/segmented senza "gridare" come il blu.
            return isDark
                ? NSColor(calibratedWhite: 0.80, alpha: 1.0)
                : NSColor(calibratedWhite: 0.32, alpha: 1.0)
        }
    )

    /// Risolve la view di dettaglio per la sezione selezionata. CONTRATTO: ogni sezione è una view
    /// indipendente che riceve `settings` (e `secretStore` per Provider/Avanzato). Finché un
    /// implementatore non l'ha riempita, si mostra il `SettingsSectionPlaceholder`.
    @ViewBuilder
    private func detail(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsSection(settings: self.settings)
        case .menuBar:
            MenuBarSettingsSection(settings: self.settings)
        case .providers:
            ProvidersSettingsSection(settings: self.settings, secretStore: self.secretStore)
        case .notifications:
            NotificationsSettingsSection(settings: self.settings)
        case .analytics:
            AnalyticsSettingsSection(settings: self.settings)
        case .advanced:
            AdvancedSettingsSection(settings: self.settings, secretStore: self.secretStore)
        case .about:
            AboutSettingsSection()
        }
    }
}

/// Riga della sidebar Impostazioni con selezione NEUTRA (no blu di sistema, DECISIONS §3).
///
/// Il default di `List(.sidebar)` evidenzia la riga selezionata con il blu di sistema e non
/// risponde a `.tint(...)`: per il look Klack (grigio translucido) disegniamo qui lo sfondo di
/// selezione — una capsule `Color.primary.opacity(~0.10)` — e lasciamo lo sfondo riga della List
/// trasparente. Icona SF Symbol MONOCROMA (niente tile colorate) + titolo, coerenti col resto.
private struct SidebarSectionRow: View {
    let section: SettingsSection
    let isSelected: Bool

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            // Icona monocroma a larghezza fissa così i titoli restano allineati.
            Image(systemName: self.section.symbol)
                .font(.body)
                .frame(width: 20, alignment: .center)
                .foregroundStyle(.primary)

            Text(self.section.title)
                .font(.body)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            // Sfondo di selezione NEUTRO: grigio translucido che adatta a light/dark via
            // `Color.primary` (label di sistema). Niente accento blu.
            if self.isSelected {
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
            }
        }
    }
}

#Preview("Impostazioni") {
    SettingsRootView(settings: SettingsStore(), secretStore: InMemorySecretStore())
}
