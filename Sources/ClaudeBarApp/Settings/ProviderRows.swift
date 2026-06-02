import ClaudeBarCore
import SwiftUI

// MARK: - Componenti riusabili per la configurazione dei provider (SET-3)
//
// Estratti da `ProvidersPreferencesView` (vecchio TabView) così che la nuova
// `ProvidersSettingsSection` dello shell li riusi SENZA duplicare la logica auth/Keychain
// (vincolo BRIEF: i segreti passano SOLO da `ProviderSecretStoring`). Sono `internal` (non più
// `private`) per essere condivisi tra le view di Impostazioni dello stesso target.
//
// Mapping auth (DECISIONS §Impostazioni + MP):
//   - .oauthManaged (Claude/Codex/Gemini) → stato in sola lettura "rilevato da CLI/OAuth";
//   - .browserCookie (Cursor)            → campo "incolla cookie di sessione" → Keychain;
//   - .apiKey (OpenAI/Anthropic)         → campo "Admin API key (org)" → Keychain, con avviso.

/// Riga di un provider: header (icona, nome, stato, toggle abilita) + sezione auth espandibile.
struct ProviderRow: View {
    let descriptor: ProviderDescriptor
    @Bindable var settings: SettingsStore
    let secretStore: any ProviderSecretStoring
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    private var config: ProviderConfig { self.settings.multiProvider.config(for: self.descriptor.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: self.descriptor.branding.symbolName)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(self.descriptor.displayName)
                        .font(.body.weight(.medium))
                    Text(self.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                // Espandi configurazione (solo se abilitato e ha qualcosa da configurare).
                if self.config.enabled, self.hasConfigurableAuth {
                    Button(action: self.onToggleExpand) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(self.isExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(self.isExpanded ? "Comprimi" : "Espandi")
                }

                Toggle("", isOn: self.enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if self.config.enabled, self.isExpanded {
                self.authSection
                    .padding(.leading, 30)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Stato testuale (sotto il nome)

    private var statusText: String {
        guard self.config.enabled else { return "Disabilitato" }
        // OAuth/CLI (Claude/Codex/Gemini): stato gestito da un'altra app, sola lettura.
        if self.descriptor.authKinds.contains(.oauthManaged) {
            return "Rilevato da CLI/OAuth"
        }
        // Cookie di sessione (Cursor).
        if self.descriptor.authKinds.contains(.browserCookie) {
            return self.hasSecret ? "Cookie di sessione salvato" : "Incolla il cookie di sessione"
        }
        // API key (OpenAI/Anthropic).
        if self.descriptor.authKinds.contains(.apiKey) {
            return self.hasSecret ? "API key salvata" : "Admin API key (org) non impostata"
        }
        return "Abilitato"
    }

    private var hasConfigurableAuth: Bool {
        self.descriptor.authKinds.contains(.apiKey)
            || self.descriptor.authKinds.contains(.oauthManaged)
            || self.descriptor.authKinds.contains(.browserCookie)
    }

    private var hasSecret: Bool {
        self.secretStore.hasSecret(provider: self.descriptor.id)
    }

    // MARK: Sezione auth (dipende dalle authKinds del descriptor)

    @ViewBuilder
    private var authSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if self.descriptor.authKinds.contains(.oauthManaged) {
                OAuthAuthRow(descriptor: self.descriptor)
            }
            if self.descriptor.authKinds.contains(.browserCookie) {
                SecretFieldAuthRow(
                    provider: self.descriptor.id,
                    account: self.config.selectedAccount,
                    secretStore: self.secretStore,
                    fieldLabel: "Cookie di sessione",
                    placeholder: "Incolla qui il cookie di sessione",
                    footnote: "ClaudeBar salva il cookie nel Keychain (solo questo Mac). Auto-import = post-MVP.",
                    dashboardURL: self.descriptor.branding.dashboardURL,
                    dashboardLinkLabel: "Apri \(self.descriptor.displayName)")
            } else if self.descriptor.authKinds.contains(.apiKey) {
                SecretFieldAuthRow(
                    provider: self.descriptor.id,
                    account: self.config.selectedAccount,
                    secretStore: self.secretStore,
                    fieldLabel: "Admin API key (org)",
                    placeholder: "Admin API key dell'organizzazione",
                    footnote: "Richiede una Admin key di account ORG. Senza, o con risposta 401/403, il provider resta visibile con un avviso.",
                    dashboardURL: self.descriptor.branding.dashboardURL,
                    dashboardLinkLabel: "Dove la trovo?")
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.config.enabled },
            set: { self.settings.setProviderEnabled($0, for: self.descriptor.id) })
    }
}

// MARK: - Riga auth OAuth/CLI (login gestito da un'altra app)

struct OAuthAuthRow: View {
    let descriptor: ProviderDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Autenticazione via login della CLI/app del provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if self.descriptor.id == .claude {
                Text("Effettua il login con Claude Code; ClaudeBar legge le credenziali in sola lettura.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let urlString = self.descriptor.branding.dashboardURL, let url = URL(string: urlString) {
                Link("Apri la dashboard del provider", destination: url)
                    .font(.caption)
            }
        }
    }
}

// MARK: - Riga auth a segreto (SecureField → Keychain)
//
// Generica: serve sia per la API key (OpenAI/Anthropic) sia per il cookie di sessione (Cursor).
// Label/placeholder/footer/link sono parametrici; il segreto è SEMPRE salvato in Keychain via
// `ProviderSecretStore` per la coppia (provider, account).

struct SecretFieldAuthRow: View {
    let provider: ProviderID
    let account: String
    let secretStore: any ProviderSecretStoring
    let fieldLabel: String
    let placeholder: String
    let footnote: String
    let dashboardURL: String?
    let dashboardLinkLabel: String

    @State private var draft: String = ""
    @State private var hasSavedSecret = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.fieldLabel)
                .font(.caption.weight(.semibold))
            HStack(spacing: 8) {
                SecureField(self.placeholder, text: self.$draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                Button("Salva") { self.save() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 12) {
                if self.hasSavedSecret {
                    Label("Salvato in Keychain", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Rimuovi") { self.remove() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                } else {
                    Text("Non impostato.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let urlString = self.dashboardURL, let url = URL(string: urlString) {
                    Link(self.dashboardLinkLabel, destination: url)
                        .font(.caption)
                }
            }

            Text(self.footnote)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        // Stato sincrono (presenza segreto nel Keychain): `onAppear` + `onChange` sull'account, così
        // si riallinea anche se cambia il provider/account selezionato.
        .onAppear { self.refreshState() }
        .onChange(of: self.account) { self.refreshState() }
    }

    private func refreshState() {
        self.hasSavedSecret = self.secretStore.hasSecret(provider: self.provider)
    }

    private func save() {
        let value = self.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try self.secretStore.setSecret(value, provider: self.provider, account: self.account)
            self.draft = ""
            self.errorMessage = nil
            self.refreshState()
        } catch {
            self.errorMessage = "Impossibile salvare nel Keychain."
        }
    }

    private func remove() {
        do {
            try self.secretStore.removeSecret(provider: self.provider, account: self.account)
            self.errorMessage = nil
            self.refreshState()
        } catch {
            self.errorMessage = "Impossibile rimuovere dal Keychain."
        }
    }
}
