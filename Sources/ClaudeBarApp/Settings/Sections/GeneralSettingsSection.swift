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
        SettingsGroup("Startup") {
            Toggle("Launch at login", isOn: self.$settings.launchAtLogin)
                .toggleStyle(.switch)
        }
    }

    // MARK: Aggiornamento limiti

    private var refreshGroup: some View {
        SettingsGroup(
            "Updates",
            footnote: "With “Manual” the app doesn't refresh the limits on its own: use the refresh button in the panel.")
        {
            Picker("Refresh the limits every", selection: self.$settings.refreshInterval) {
                ForEach(RefreshInterval.allCases) { interval in
                    Text(interval.label).tag(interval)
                }
            }
            Divider()
            Toggle("Refresh when the panel opens", isOn: self.$settings.refreshOnPanelOpen)
                .toggleStyle(.switch)
            Toggle("Refresh on wake from sleep", isOn: self.$settings.refreshOnWake)
                .toggleStyle(.switch)
        }
    }

    // MARK: Aspetto

    private var appearanceGroup: some View {
        SettingsGroup("Appearance") {
            Picker("Theme", selection: self.$settings.appearance) {
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
