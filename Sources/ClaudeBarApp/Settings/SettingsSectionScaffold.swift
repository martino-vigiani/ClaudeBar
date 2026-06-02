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

/// Guscio standard di una sezione: titolo + sottotitolo opzionale, poi il contenuto scrollabile.
/// Vetro NEUTRO (DECISIONS §3): nessuna tinta. Lo sfondo della finestra è fornito dallo shell.
struct SettingsSectionScaffold<Content: View>: View {
    let section: SettingsSection
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                self.header
                self.content
            }
            .padding(DS.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(self.section.title)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(self.section.title)
                .font(.system(size: 20, weight: .semibold))
            if let subtitle = self.section.subtitle {
                Text(subtitle)
                    .font(.dsBody)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Gruppo di opzioni

/// Gruppo etichettato di controlli, reso come `GroupBox` su materiale neutro. Riga-titolo
/// opzionale + contenuto in `VStack`. Sostituisce le `Section` del vecchio `Form` mantenendo
/// la coerenza con il DesignSystem (DS.*). Usare per ogni blocco di una sezione.
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
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            if let title {
                Text(title.uppercased())
                    .font(.dsEyebrow)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.leading, DS.Spacing.xs)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    self.content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.xs)
            }
            if let footnote {
                Text(footnote)
                    .font(.dsCaption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, DS.Spacing.xs)
            }
        }
    }
}

// MARK: - Riga con etichetta + controllo a destra

/// Riga orizzontale "etichetta a sinistra, controllo a destra" con didascalia opzionale.
/// Helper presentazionale per uniformare le righe dentro un `SettingsGroup`.
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
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                    .font(.dsBody)
                if let caption {
                    Text(caption)
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Spacing.m)
            self.control
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
