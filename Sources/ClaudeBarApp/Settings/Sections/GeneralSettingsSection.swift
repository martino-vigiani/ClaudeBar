import ClaudeBarCore
import SwiftUI

/// Sezione GENERALE delle Impostazioni (cablata dall'architetto come riferimento del contratto).
///
/// Copre: avvio al login, **intervallo di refresh** (richiesta esplicita utente) → `RefreshScheduler`,
/// refresh all'apertura del pannello / al risveglio, aspetto (Sistema/Chiaro/Scuro) → `NSApp`.
/// Tutti i controlli si legano direttamente al `SettingsStore` (@Observable); la persistenza e la
/// propagazione ai sottosistemi avvengono nei `didSet`/`onChange` del modello.
struct GeneralSettingsSection: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsSectionScaffold(section: .general) {
            self.startupGroup
            self.refreshGroup
            self.appearanceGroup
        }
    }

    // MARK: Avvio

    private var startupGroup: some View {
        SettingsGroup("Avvio") {
            Toggle("Avvia al login", isOn: self.$settings.launchAtLogin)
                .toggleStyle(.switch)
        }
    }

    // MARK: Aggiornamento limiti

    private var refreshGroup: some View {
        SettingsGroup(
            "Aggiornamento",
            footnote: "Con «Manuale» l'app non aggiorna i limiti da sola: usa il pulsante di refresh nel pannello.")
        {
            Picker("Aggiorna i limiti ogni", selection: self.$settings.refreshInterval) {
                ForEach(RefreshInterval.allCases) { interval in
                    Text(interval.label).tag(interval)
                }
            }
            Divider()
            Toggle("Aggiorna all'apertura del pannello", isOn: self.$settings.refreshOnPanelOpen)
                .toggleStyle(.switch)
            Toggle("Aggiorna al risveglio dal sleep", isOn: self.$settings.refreshOnWake)
                .toggleStyle(.switch)
        }
    }

    // MARK: Aspetto

    private var appearanceGroup: some View {
        SettingsGroup("Aspetto") {
            Picker("Tema", selection: self.$settings.appearance) {
                ForEach(AppAppearance.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbolName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

#Preview("Generale") {
    GeneralSettingsSection(settings: SettingsStore())
        .frame(width: 484, height: 560)
}
