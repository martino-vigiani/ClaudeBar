import SwiftUI

/// Sezione INFO delle Impostazioni (SET-4).
///
/// Mostra identità dell'app (nome/versione/build da `AppInfo`, derivati dal Bundle), una riga di
/// crediti sobria e qualche link utile. Nessuna dipendenza dal `SettingsStore` (contratto congelato:
/// `AboutSettingsSection()` senza argomenti). Vetro NEUTRO, niente accenti blu: i link usano lo
/// stile testuale standard e le righe seguono il DesignSystem.
struct AboutSettingsSection: View {
    var body: some View {
        SettingsSectionScaffold(section: .about) {
            self.identityGroup
            self.creditsGroup
            self.linksGroup
        }
    }

    // MARK: Identità

    private var identityGroup: some View {
        SettingsGroup {
            HStack(alignment: .center, spacing: DS.Spacing.l) {
                Self.appIcon
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(AppInfo.displayName)
                        .font(.system(size: 22, weight: .semibold))
                    Text("Versione \(AppInfo.shortVersion) (\(AppInfo.buildNumber))")
                        .font(.dsBody)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(AppInfo.bundleIdentifier)
                        .font(.dsMono)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Icona dell'app a runtime (iniettata nel bundle), con fallback su SF Symbol per
    /// preview/`swift run` dove l'icona del bundle non è disponibile.
    private static var appIcon: Image {
        if let icon = NSApp?.applicationIconImage {
            return Image(nsImage: icon)
        }
        return Image(systemName: "gauge.with.dots.needle.67percent")
    }

    // MARK: Crediti

    private var creditsGroup: some View {
        SettingsGroup("Crediti") {
            Text("ClaudeBar è un'utility per la barra dei menu che tiene d'occhio i limiti d'uso e i consumi locali di Claude Code, con analytics calcolate sui transcript del tuo Mac.")
                .font(.dsBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            SettingsRow(
                "Costruita da",
                caption: "Progetto personale, design monocromo.")
            {
                Text("SubraLabs")
                    .font(.dsBody)
            }
            SettingsRow(
                "Ispirazione tecnica",
                caption: "Il calcolo dei costi e il parsing dei transcript prendono spunto da CodexBar.")
            {
                Text("CodexBar")
                    .font(.dsBody)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Link

    private var linksGroup: some View {
        SettingsGroup("Risorse") {
            Link(destination: URL(string: "https://docs.claude.com/claude-code")!) {
                Self.linkRow("Documentazione Claude Code", systemImage: "book")
            }
            Divider()
            Link(destination: URL(string: "https://www.anthropic.com/legal/usage-policy")!) {
                Self.linkRow("Politiche d'uso Anthropic", systemImage: "doc.text")
            }
        }
    }

    /// Riga link uniforme: icona + titolo a sinistra, freccia "esterno" a destra. Niente colore
    /// accento: i link restano nel tono testo/secondario per coerenza monocroma.
    private static func linkRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.dsBody)
            Spacer(minLength: DS.Spacing.m)
            Image(systemName: "arrow.up.right")
                .font(.dsCaption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

#Preview("Info") {
    AboutSettingsSection()
        .frame(width: 484, height: 560)
}
