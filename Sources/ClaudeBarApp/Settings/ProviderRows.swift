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
                ProviderGlyph(
                    providerID: self.descriptor.id.rawValue,
                    fallbackSymbol: self.descriptor.branding.symbolName,
                    size: 16)
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
                    .accessibilityLabel(self.isExpanded ? "Collapse" : "Expand")
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
        guard self.config.enabled else { return String(localized: "Disabled") }
        // OAuth/CLI (Claude/Codex/Gemini): stato gestito da un'altra app, sola lettura.
        if self.descriptor.authKinds.contains(.oauthManaged) {
            return String(localized: "Detected from CLI/OAuth")
        }
        // Cookie di sessione (Cursor).
        if self.descriptor.authKinds.contains(.browserCookie) {
            return self.hasSecret ? String(localized: "Session cookie saved") : String(localized: "Paste the session cookie")
        }
        // API key (OpenAI/Anthropic).
        if self.descriptor.authKinds.contains(.apiKey) {
            return self.hasSecret ? String(localized: "API key saved") : String(localized: "Admin API key (org) not set")
        }
        return String(localized: "Enabled")
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
                    fieldLabel: String(localized: "Session cookie"),
                    placeholder: String(localized: "Paste the session cookie here"),
                    footnote: String(localized: "ClaudeBar saves the cookie in the Keychain (this Mac only). Auto-import = post-MVP."),
                    dashboardURL: self.descriptor.branding.dashboardURL,
                    dashboardLinkLabel: String(localized: "Open \(self.descriptor.displayName)"))
            } else if self.descriptor.authKinds.contains(.apiKey) {
                SecretFieldAuthRow(
                    provider: self.descriptor.id,
                    account: self.config.selectedAccount,
                    secretStore: self.secretStore,
                    fieldLabel: String(localized: "Admin API key (org)"),
                    placeholder: String(localized: "Organization Admin API key"),
                    footnote: String(localized: "Requires an ORG account Admin key. Without one, or with a 401/403 response, the provider stays visible with a warning."),
                    dashboardURL: self.descriptor.branding.dashboardURL,
                    dashboardLinkLabel: String(localized: "Where do I find it?"))
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
            Text("Authentication via the provider's CLI/app login.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if self.descriptor.id == .claude {
                Text("Sign in with Claude Code; ClaudeBar reads the credentials read-only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let urlString = self.descriptor.branding.dashboardURL, let url = URL(string: urlString) {
                Link("Open the provider dashboard", destination: url)
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
                Button("Save") { self.save() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 12) {
                if self.hasSavedSecret {
                    Label("Saved in Keychain", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Remove") { self.remove() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                } else {
                    Text("Not set.")
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
                .foregroundStyle(.secondary)
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
            self.errorMessage = String(localized: "Couldn't save to the Keychain.")
        }
    }

    private func remove() {
        do {
            try self.secretStore.removeSecret(provider: self.provider, account: self.account)
            self.errorMessage = nil
            self.refreshState()
        } catch {
            self.errorMessage = String(localized: "Couldn't remove from the Keychain.")
        }
    }
}
