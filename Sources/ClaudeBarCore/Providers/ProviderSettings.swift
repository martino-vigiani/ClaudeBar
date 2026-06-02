import Foundation

// Modello SETTINGS multi-provider (value type Sendable + Codable). Vive in Core così che sia
// condiviso tra app, CLI e test. `SettingsStore` (app layer) lo persisterà su UserDefaults; la
// UI delle Impostazioni (settings-ui-engineer) lo legge/scrive.
//
// Distinzione netta dai SEGRETI: qui NON ci sono token/API key (quelli stanno in Keychain via
// `ProviderSecretStore`). Qui c'è solo la CONFIGURAZIONE: quali provider sono abilitati, quale
// auth preferire, l'account selezionato (etichetta, non il segreto), il default, e cosa
// mostrare nella barra.

/// Configurazione per-provider (no segreti).
public struct ProviderConfig: Sendable, Equatable, Codable {
    public var id: ProviderID
    /// L'utente ha abilitato questo provider (compare nel pannello/barra).
    public var enabled: Bool
    /// Auth preferita quando ne è disponibile più di una (es. apiKey vs oauthManaged).
    public var preferredAuth: ProviderAuthKind?
    /// Etichetta dell'account selezionato nel `ProviderSecretStore` (NON il segreto). Default "default".
    public var selectedAccount: String

    public init(
        id: ProviderID,
        enabled: Bool,
        preferredAuth: ProviderAuthKind? = nil,
        selectedAccount: String = "default")
    {
        self.id = id
        self.enabled = enabled
        self.preferredAuth = preferredAuth
        self.selectedAccount = selectedAccount
    }
}

/// Come comporre l'icona della menu bar quando più provider sono abilitati. Decisione di
/// prodotto APERTA (BRIEF: confermata dal lead dopo la fase A): il modello le supporta entrambe.
public enum BarDisplayMode: String, Sendable, Equatable, CaseIterable, Codable {
    /// Una sola icona = il provider di default/attivo (comportamento attuale di Claude).
    case singleActive = "single_active"
    /// Un item per ogni provider abilitato.
    case perProvider = "per_provider"
    /// Un'icona unica che fonde i provider abilitati (più critico vince).
    case merged
}

/// Settings multi-provider completi.
public struct MultiProviderSettings: Sendable, Equatable, Codable {
    /// Versione dello schema (bump su cambi incompatibili → migrazione).
    public var version: Int
    /// Configurazione per ogni provider noto.
    public var providers: [ProviderConfig]
    /// Provider di default scelto dall'utente. `nil` = usa l'auto-detect.
    public var defaultProvider: ProviderID?
    /// Se `true`, il default è ricalcolato automaticamente all'avvio (auto-detect).
    public var autoDetectDefault: Bool
    /// Come mostrare i provider nella barra.
    public var barDisplayMode: BarDisplayMode

    public init(
        version: Int = MultiProviderSettings.currentVersion,
        providers: [ProviderConfig],
        defaultProvider: ProviderID? = nil,
        autoDetectDefault: Bool = true,
        barDisplayMode: BarDisplayMode = .singleActive)
    {
        self.version = version
        self.providers = providers
        self.defaultProvider = defaultProvider
        self.autoDetectDefault = autoDetectDefault
        self.barDisplayMode = barDisplayMode
    }

    public static let currentVersion = 1

    /// Default di prima esecuzione: SOLO Claude abilitato, auto-detect attivo, icona singola.
    /// Garantisce che chi aggiorna dall'MVP solo-Claude non veda alcun cambiamento.
    public static var initial: MultiProviderSettings {
        MultiProviderSettings(
            providers: [ProviderConfig(id: .claude, enabled: true)],
            defaultProvider: .claude,
            autoDetectDefault: true,
            barDisplayMode: .singleActive)
    }

    /// Config di un provider (creandola disabilitata se assente).
    public func config(for id: ProviderID) -> ProviderConfig {
        self.providers.first(where: { $0.id == id }) ?? ProviderConfig(id: id, enabled: false)
    }

    /// Provider abilitati, nell'ordine di `providers`.
    public var enabledProviders: [ProviderID] {
        self.providers.filter(\.enabled).map(\.id)
    }

    /// Inserisce/aggiorna la config di un provider (immutabile: ritorna copia).
    public func updating(_ config: ProviderConfig) -> MultiProviderSettings {
        var copy = self
        if let index = copy.providers.firstIndex(where: { $0.id == config.id }) {
            copy.providers[index] = config
        } else {
            copy.providers.append(config)
        }
        return copy
    }
}
