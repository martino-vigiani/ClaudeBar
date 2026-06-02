import ClaudeBarCore
import SwiftUI

/// Sezione PROVIDER delle Impostazioni (SET-3).
///
/// Avvolge la lista provider ESISTENTE riusando `ProviderRow`/`SecretFieldAuthRow`
/// (vedi `ProviderRows.swift`): enable/disable, stato auth + configurazione (API key
/// OpenAI/Anthropic e cookie Cursor → Keychain via `ProviderSecretStore`; OAuth-CLI
/// Claude/Codex/Gemini in sola lettura), scelta del provider di default + auto-detect.
///
/// I SEGRETI passano SOLO da `ProviderSecretStoring` (Keychain), mai in UserDefaults.
/// Default = parità con l'MVP solo-Claude: alla prima esecuzione `multiProvider == .initial`.
/// Vetro NEUTRO: nessuna tinta, niente `.glassEffect()` sul contenuto.
struct ProvidersSettingsSection: View {
    @Bindable var settings: SettingsStore
    let secretStore: any ProviderSecretStoring

    @State private var expandedProvider: ProviderID?

    var body: some View {
        SettingsSectionScaffold(section: .providers) {
            self.defaultGroup
            self.providersGroup
        }
    }

    // MARK: Provider di default + auto-detect

    private var defaultGroup: some View {
        SettingsGroup(
            "Provider attivo",
            footnote: "Il provider attivo determina l'anello nella menu bar. Con l'auto-rilevamento attivo, all'avvio l'app riempie solo i provider non configurati a mano: le scelte manuali non vengono sovrascritte.")
        {
            Picker("Provider di default", selection: self.defaultBinding) {
                ForEach(self.settings.multiProvider.enabledProviders, id: \.self) { id in
                    Text(ProviderCatalog.descriptor(for: id).displayName).tag(id)
                }
                if self.settings.multiProvider.enabledProviders.isEmpty {
                    Text("Claude").tag(ProviderID.claude)
                }
            }
            Divider()
            Toggle("Rileva automaticamente i provider", isOn: self.autoDetectBinding)
                .toggleStyle(.switch)
        }
    }

    // MARK: Lista provider (catalogo completo)

    private var providersGroup: some View {
        SettingsGroup(
            "Provider",
            footnote: "Abilita i provider che vuoi monitorare e configura le credenziali. Lo switcher nel pannello compare solo con due o più provider abilitati.")
        {
            ForEach(Array(ProviderCatalog.all.enumerated()), id: \.element.id) { index, descriptor in
                if index > 0 { Divider() }
                ProviderRow(
                    descriptor: descriptor,
                    settings: self.settings,
                    secretStore: self.secretStore,
                    isExpanded: self.expandedProvider == descriptor.id,
                    onToggleExpand: {
                        withAnimation(.snappy) {
                            self.expandedProvider = self.expandedProvider == descriptor.id ? nil : descriptor.id
                        }
                    })
            }
        }
    }

    // MARK: Bindings derivati sul modello multi-provider

    private var defaultBinding: Binding<ProviderID> {
        Binding(
            get: { self.settings.activeProviderID },
            set: { self.settings.setDefaultProvider($0) })
    }

    private var autoDetectBinding: Binding<Bool> {
        Binding(
            get: { self.settings.multiProvider.autoDetectDefault },
            set: { self.settings.setAutoDetectDefault($0) })
    }
}

#Preview("Provider") {
    ProvidersSettingsSection(settings: SettingsStore(), secretStore: InMemorySecretStore())
        .frame(width: 484, height: 560)
}
