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
            "Active provider",
            footnote: "The active provider determines the ring in the menu bar. With auto-detection on, at launch the app only fills in providers not configured by hand: manual choices are not overwritten.")
        {
            Picker("Default provider", selection: self.defaultBinding) {
                ForEach(self.settings.multiProvider.enabledProviders, id: \.self) { id in
                    Text(ProviderCatalog.descriptor(for: id).displayName).tag(id)
                }
                if self.settings.multiProvider.enabledProviders.isEmpty {
                    Text("Claude").tag(ProviderID.claude)
                }
            }
            Divider()
            Toggle("Detect providers automatically", isOn: self.autoDetectBinding)
                .toggleStyle(.switch)
        }
    }

    // MARK: Lista provider (catalogo completo)

    private var providersGroup: some View {
        SettingsGroup(
            "Providers",
            footnote: "Enable the providers you want to monitor and configure their credentials. The switcher in the panel appears only with two or more enabled providers.")
        {
            ForEach(Array(ProviderCatalog.all.enumerated()), id: \.element.id) { index, descriptor in
                if index > 0 { Divider() }
                ProviderRow(
                    descriptor: descriptor,
                    settings: self.settings,
                    secretStore: self.secretStore,
                    isExpanded: self.expandedProvider == descriptor.id,
                    onToggleExpand: {
                        withAnimation(DS.Motion.soft) {
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
