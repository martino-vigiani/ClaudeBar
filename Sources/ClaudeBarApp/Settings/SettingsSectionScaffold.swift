import SwiftUI

// MARK: - Contratto di sezione (CONGELATO)
//
// Ogni sezione delle Impostazioni è una `View` indipendente che riceve il `SettingsStore`
// via `@Bindable` e, dove serve, lo `ProviderSecretStoring` (Keychain). Per dare a TUTTE le
// sezioni lo stesso ritmo visivo (header + form a gruppi su vetro neutro), le si avvolge in
// `SettingsSectionScaffold`. Gli implementatori NON ricreano l'header: usano lo scaffold e
// riempiono solo `content` con `SettingsGroup`/`Form`.
//
// Esempio (firma da rispettare):
//
//     struct NotificationsSettingsSection: View {
//         @Bindable var settings: SettingsStore
//         var body: some View {
//             SettingsSectionScaffold(section: .notifications) {
//                 SettingsGroup("Sessione 5h") {
//                     Toggle("Notifica alle soglie", isOn: $settings.notifyOnSessionThreshold)
//                 }
//             }
//         }
//     }

/// Guscio standard di una sezione: `Form` in stile grouped (look nativo macOS 26), titolo nella
/// titlebar via `navigationTitle`. Vetro NEUTRO (DECISIONS §3): nessuna tinta; lo stile grouped
/// fornisce inset, materiali e divisori di sistema. Niente header manuale → il titolo NON è più
/// duplicato (prima compariva sia in titlebar sia come testo grande nel contenuto).
struct SettingsSectionScaffold<Content: View>: View {
    let section: SettingsSection
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            self.content
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(self.section.title)
    }
}

// MARK: - Gruppo di opzioni

/// Gruppo etichettato di controlli, reso come `Section` di un `Form` grouped: titolo → header
/// nativo, footnote → footer nativo. Il contenuto resta in un `VStack` (una riga del Form) così
/// i layout interni delle sezioni (divisori, chip, righe custom) restano invariati: cambia solo
/// la cornice, che ora è quella di sistema. Usare per ogni blocco di una sezione.
struct SettingsGroup<Content: View>: View {
    let title: String?
    let footnote: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                self.content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            if let title {
                Text(title)
            }
        } footer: {
            if let footnote {
                Text(footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Riga con etichetta + controllo a destra

/// Riga "etichetta a sinistra, controllo a destra" con didascalia opzionale, resa con
/// `LabeledContent` (allineamento nativo macOS). La didascalia diventa la label secondaria.
struct SettingsRow<Control: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder var control: Control

    init(_ title: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        LabeledContent {
            self.control
        } label: {
            Text(self.title)
            if let caption {
                Text(caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Placeholder per sezioni non ancora implementate

/// Riempitivo coerente mostrato dallo shell finché un implementatore non sostituisce la sezione
/// con la sua view reale. Vive nello scaffold così che la finestra sia completa e navigabile
/// fin da subito (lo shell compila e gira anche prima della Fase B).
struct SettingsSectionPlaceholder: View {
    let section: SettingsSection

    var body: some View {
        SettingsSectionScaffold(section: self.section) {
            SettingsGroup {
                Label("Sezione in arrivo", systemImage: "hammer")
                    .font(.dsBody)
                    .foregroundStyle(.secondary)
                Text("I controlli di «\(self.section.title)» vengono agganciati in questa sezione.")
                    .font(.dsCaption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
