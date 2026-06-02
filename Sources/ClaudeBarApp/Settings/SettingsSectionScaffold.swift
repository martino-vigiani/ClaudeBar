import SwiftUI

// MARK: - Contratto di sezione (CONGELATO)
//
// Ogni sezione delle Impostazioni è una `View` indipendente che riceve il `SettingsStore`
// via `@Bindable` e, dove serve, lo `ProviderSecretStoring` (Keychain). Per dare a TUTTE le
// sezioni lo stesso ritmo visivo (form a gruppi nativo macOS), le si avvolge in
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

/// Guscio standard di una sezione: `Form` in stile grouped, titolo nella titlebar via
/// `navigationTitle`.
///
/// DESIGN (look "System Settings"/Klack): la finestra è NATIVA (`SettingsWindowController` non usa
/// più alcun NSVisualEffectView custom) e qui usiamo il grouped NATIVO di macOS 26 (Tahoe) SENZA
/// sovrascriverlo. Su Tahoe il `Form.grouped` è già reso col design Liquid Glass di sistema: card
/// arrotondate, contrasto corretto (leggermente sollevate sullo sfondo), inset e divisori nativi.
/// Lezione delle iterazioni precedenti: bezel/sfondi custom davano un effetto "uncanny" (né nativo
/// né premium) — la resa migliore è lasciar lavorare il sistema. Vetro NEUTRO (DECISIONS §3):
/// nessuna tinta cromatica, solo i materiali neutri di sistema.
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

/// Gruppo etichettato di controlli, reso come `Section` NATIVA di un `Form` grouped: titolo →
/// header di sistema, footnote → footer di sistema, sfondo card → quello nativo di macOS (rounded,
/// ben contrastato, Liquid Glass su Tahoe). Il contenuto resta in un `VStack` (una singola riga del
/// Form) così i layout interni delle sezioni — divisori espliciti, chip, righe custom — restano
/// invariati e non si scontrano con i separatori di riga automatici del sistema.
struct SettingsGroup<Content: View>: View {
    let title: LocalizedStringKey?
    let footnote: LocalizedStringKey?
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey? = nil, footnote: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
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
/// `LabeledContent` (allineamento nativo macOS: label a sinistra, controllo flush a destra). La
/// didascalia diventa la label secondaria, in caption attenuata sotto il titolo.
struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    let caption: LocalizedStringKey?
    @ViewBuilder var control: Control

    init(_ title: LocalizedStringKey, caption: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
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
                Label("Section coming soon", systemImage: "hammer")
                    .font(.dsBody)
                    .foregroundStyle(.secondary)
                Text("The controls for “\(self.section.title)” are wired up in this section.")
                    .font(.dsCaption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
