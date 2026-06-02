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
            List(SettingsSection.allCases, selection: self.$selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 184, ideal: 196, max: 220)
            .listStyle(.sidebar)
        } detail: {
            self.detail(for: self.selection)
                .frame(minWidth: 420, idealWidth: 484)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 460, idealHeight: 560)
    }

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

#Preview("Impostazioni") {
    SettingsRootView(settings: SettingsStore(), secretStore: InMemorySecretStore())
}
