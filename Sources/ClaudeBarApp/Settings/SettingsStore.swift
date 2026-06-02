import ClaudeBarCore
import Foundation
import Observation

/// Sorgente dei limiti ufficiali. Web (cookie) escluso dall'MVP. Nell'MVP `.auto` ≡ OAuth
/// (il fallback CLI è v1, non MVP-blocking).
enum UsageSource: String, Sendable, CaseIterable, Identifiable {
    case auto
    case oauth
    case cli

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .auto: String(localized: "Automatic")
        case .oauth: "OAuth"
        case .cli: "CLI"
        }
    }
}

/// Cosa rappresenta il NUMERO mostrato accanto all'anello (e nei testi della menu bar).
/// NB (LOCK glance): arco e colore restano SEMPRE sull'% USATO; questo cambia solo il TESTO.
enum GlanceNumberContent: String, Sendable, CaseIterable, Identifiable {
    case used
    case remaining

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .used: String(localized: "Used")
        case .remaining: String(localized: "Remaining")
        }
    }
}

/// Impostazioni MVP (02-app-architecture.md §8). Backing: `UserDefaults.standard` con prefisso
/// `clbar.`. `@Observable @MainActor`: le Preferenze ci si legano direttamente; ogni `didSet`
/// persiste e notifica i sottosistemi via `onChange`.
@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults

    /// Callback invocata dopo ogni modifica persistita, per propagare ai sottosistemi
    /// (scheduler, limits service, launch-at-login, ridisegno glance). Impostata dall'AppModel.
    @ObservationIgnored
    var onChange: (@MainActor () -> Void)?

    /// Versione dello schema delle preferenze "scalari" (clbar.*). Bump SOLO se una migrazione
    /// non additiva lo richiede; oggi i campi sono additivi con default, quindi non serve resettare.
    static let schemaVersion = 1

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Versione schema: scritta al primo avvio, usata da eventuali migrazioni future.
        if defaults.object(forKey: Self.key("schemaVersion")) == nil {
            defaults.set(Self.schemaVersion, forKey: Self.key("schemaVersion"))
        }
        // Carica i valori persistiti (o i default sensati: senza tocchi, l'app si comporta come oggi).
        // — Generale —
        self._usageSource = Self.readEnum(defaults, "usageSource") ?? .auto
        self._refreshInterval = Self.readEnum(defaults, "refreshInterval") ?? .fiveMinutes
        self._appearance = Self.readEnum(defaults, "appearance") ?? .system
        self._launchAtLogin = defaults.object(forKey: Self.key("launchAtLogin")) as? Bool ?? false
        self._refreshOnPanelOpen = defaults.object(forKey: Self.key("refreshOnPanelOpen")) as? Bool ?? true
        self._refreshOnWake = defaults.object(forKey: Self.key("refreshOnWake")) as? Bool ?? true
        // — Menu bar / icona —
        self._glanceStyle = (Self.readString(defaults, "glanceStyle") == "dualBar") ? .dualBar : .ring
        self._showPercentLabel = defaults.object(forKey: Self.key("showPercentLabel")) as? Bool ?? true
        self._numberContent = Self.readEnum(defaults, "numberContent")
            ?? ((defaults.object(forKey: Self.key("showUsedInsteadOfRemaining")) as? Bool ?? true) ? .used : .remaining)
        self._monochromeIcon = defaults.object(forKey: Self.key("monochromeIcon")) as? Bool ?? false
        self._pulseOnCritical = defaults.object(forKey: Self.key("pulseOnCritical")) as? Bool ?? true
        // — Soglie colore (sull'usato) —
        self._warnThreshold = defaults.object(forKey: Self.key("warnThreshold")) as? Double ?? 0.60
        self._criticalThreshold = defaults.object(forKey: Self.key("criticalThreshold")) as? Double ?? 0.85
        // — Notifiche —
        self._notifyOnSessionThreshold = defaults.object(forKey: Self.key("notifyOnSessionThreshold")) as? Bool ?? true
        self._notifyOnWeeklyReset = defaults.object(forKey: Self.key("notifyOnWeeklyReset")) as? Bool ?? true
        self._notificationSound = defaults.object(forKey: Self.key("notificationSound")) as? Bool ?? true
        self._sessionThresholds = Self.readThresholds(defaults) ?? Self.defaultSessionThresholds
        // — Analytics —
        self._defaultAnalyticsRange = Self.readEnum(defaults, "defaultAnalyticsRange") ?? .today
        self._includeSubagentsInAnalytics = defaults.object(forKey: Self.key("includeSubagentsInAnalytics")) as? Bool ?? true
        self._showCostDisclaimer = defaults.object(forKey: Self.key("showCostDisclaimer")) as? Bool ?? true
        self._pricingOverridePath = Self.readString(defaults, "pricingOverridePath")
        // — Multi-provider (JSON, versionato a parte) —
        self._multiProvider = Self.readMultiProvider(defaults) ?? .initial
    }

    // MARK: - Dati / sorgente

    var usageSource: UsageSource {
        didSet { self.persistEnum(self.usageSource, "usageSource") }
    }

    var refreshInterval: RefreshInterval {
        didSet { self.persistEnum(self.refreshInterval, "refreshInterval") }
    }

    /// Aspetto richiesto per le finestre dell'app (Sistema/Chiaro/Scuro). Cablato a `NSApp.appearance`.
    var appearance: AppAppearance {
        didSet { self.persistEnum(self.appearance, "appearance") }
    }

    /// Refresh on-demand dei limiti quando si apre il pannello (se i dati sono vecchi).
    var refreshOnPanelOpen: Bool {
        didSet { self.persistBool(self.refreshOnPanelOpen, "refreshOnPanelOpen") }
    }

    /// Refresh dei limiti al risveglio dal sleep / ritorno connettività.
    var refreshOnWake: Bool {
        didSet { self.persistBool(self.refreshOnWake, "refreshOnWake") }
    }

    // MARK: - Avvio / glance

    var launchAtLogin: Bool {
        didSet { self.persistBool(self.launchAtLogin, "launchAtLogin") }
    }

    /// Cosa rappresenta il NUMERO mostrato (usato/rimanente). Il colore/arco resta sull'USATO.
    var numberContent: GlanceNumberContent {
        didSet {
            self.persistEnum(self.numberContent, "numberContent")
            // Manteniamo allineata la vecchia chiave per compat con dati persistiti pre-esistenti.
            self.defaults.set(self.numberContent == .used, forKey: Self.key("showUsedInsteadOfRemaining"))
        }
    }

    /// Compat: alcuni call site storici leggono questo flag. Derivato da `numberContent`.
    var showUsedInsteadOfRemaining: Bool {
        get { self.numberContent == .used }
        set { self.numberContent = newValue ? .used : .remaining }
    }

    var glanceStyle: GlanceStyle {
        didSet { self.persistString(self.glanceStyle == .dualBar ? "dualBar" : "ring", "glanceStyle") }
    }

    /// Testo % accanto all'anello.
    var showPercentLabel: Bool {
        didSet { self.persistBool(self.showPercentLabel, "showPercentLabel") }
    }

    /// Icona template B/N (fallback contrasto / preferenza).
    var monochromeIcon: Bool {
        didSet { self.persistBool(self.monochromeIcon, "monochromeIcon") }
    }

    /// Pulsazione dell'icona quando lo stato è critico (usato ≥ soglia empty). Off → icona statica.
    var pulseOnCritical: Bool {
        didSet { self.persistBool(self.pulseOnCritical, "pulseOnCritical") }
    }

    // MARK: - Soglie / colore (sull'USATO; condivise con la classificazione in Core)

    var warnThreshold: Double {
        didSet { self.persistDouble(self.warnThreshold, "warnThreshold") }
    }

    var criticalThreshold: Double {
        didSet { self.persistDouble(self.criticalThreshold, "criticalThreshold") }
    }

    // MARK: - Notifiche

    /// Soglie di sessione di DEFAULT (% USATO), usate quando l'utente non le ha personalizzate.
    static let defaultSessionThresholds: [Int] = [50, 75, 90]

    var notifyOnSessionThreshold: Bool {
        didSet { self.persistBool(self.notifyOnSessionThreshold, "notifyOnSessionThreshold") }
    }

    var notifyOnWeeklyReset: Bool {
        didSet { self.persistBool(self.notifyOnWeeklyReset, "notifyOnWeeklyReset") }
    }

    /// Suono sulle notifiche (on/off). Off → notifiche silenziose.
    var notificationSound: Bool {
        didSet { self.persistBool(self.notificationSound, "notificationSound") }
    }

    /// Soglie sessione editabili (% USATO, 1...99). Persistite come CSV in `clbar.sessionThresholds`.
    /// L'`AppNotifications` le legge da qui (non più dalla costante statica) — vedi wiring SET-3.
    /// Il `didSet` normalizza in-place (clamp/dedup/ordina): l'assegnazione dentro `didSet` NON
    /// ri-triggera `didSet`, quindi niente ricorsione.
    var sessionThresholds: [Int] {
        didSet {
            let clean = Self.normalizeThresholds(self.sessionThresholds)
            if clean != self.sessionThresholds {
                self.sessionThresholds = clean
            }
            self.persistThresholds(clean)
        }
    }

    // MARK: - Analytics

    /// Range mostrato all'apertura del pannello (Oggi/7g/30g).
    var defaultAnalyticsRange: AnalyticsRange {
        didSet { self.persistEnum(self.defaultAnalyticsRange, "defaultAnalyticsRange") }
    }

    /// Includere le sessioni subagent negli aggregati analytics.
    var includeSubagentsInAnalytics: Bool {
        didSet { self.persistBool(self.includeSubagentsInAnalytics, "includeSubagentsInAnalytics") }
    }

    /// Mostrare il disclaimer "stima API-equivalente" sotto il costo.
    var showCostDisclaimer: Bool {
        didSet { self.persistBool(self.showCostDisclaimer, "showCostDisclaimer") }
    }

    // MARK: - Pricing

    var pricingOverridePath: String? {
        didSet { self.persistString(self.pricingOverridePath, "pricingOverridePath") }
    }

    /// La label di percentuale derivata dalle preferenze.
    var percentLabel: PercentLabel {
        guard self.showPercentLabel else { return .hidden }
        return self.numberContent == .used ? .used : .remaining
    }

    // MARK: - Multi-provider (MP-6)
    //
    // Modello Settings multi-provider (Core, value type Codable). Persistito come JSON in
    // UserDefaults sotto `clbar.multiProvider`. Default di prima esecuzione = `.initial` (SOLO
    // Claude abilitato, singleActive, auto-detect) → parità totale con l'MVP solo-Claude per chi
    // aggiorna. I SEGRETI (API key) NON sono qui: vivono in Keychain via `ProviderSecretStore`.

    /// Configurazione multi-provider completa. Scriverla persiste JSON e notifica i sottosistemi.
    var multiProvider: MultiProviderSettings {
        didSet { self.persistMultiProvider(self.multiProvider) }
    }

    /// Provider attualmente "attivo" per il pannello/icona: il default scelto dall'utente se
    /// abilitato, altrimenti il primo abilitato, altrimenti Claude (parità con l'MVP). L'auto-detect
    /// del default a runtime è del Core/AppModel; questo è il fallback presentazionale.
    var activeProviderID: ProviderID {
        if let preferred = self.multiProvider.defaultProvider,
           self.multiProvider.config(for: preferred).enabled {
            return preferred
        }
        return self.multiProvider.enabledProviders.first ?? .claude
    }

    // MARK: Helper di mutazione (usati dalla UI Impostazioni)

    /// Abilita/disabilita un provider (immutabile sul modello Core).
    func setProviderEnabled(_ enabled: Bool, for id: ProviderID) {
        var config = self.multiProvider.config(for: id)
        config.enabled = enabled
        self.multiProvider = self.multiProvider.updating(config)
    }

    /// Imposta l'auth preferita per un provider (quando ne supporta più d'una).
    func setPreferredAuth(_ kind: ProviderAuthKind?, for id: ProviderID) {
        var config = self.multiProvider.config(for: id)
        config.preferredAuth = kind
        self.multiProvider = self.multiProvider.updating(config)
    }

    /// Imposta il provider di default scelto dall'utente.
    func setDefaultProvider(_ id: ProviderID?) {
        var copy = self.multiProvider
        copy.defaultProvider = id
        self.multiProvider = copy
    }

    /// Attiva/disattiva l'auto-detect del default al boot.
    func setAutoDetectDefault(_ enabled: Bool) {
        var copy = self.multiProvider
        copy.autoDetectDefault = enabled
        self.multiProvider = copy
    }

    /// Imposta la modalità di display della barra (singleActive/perProvider/merged).
    func setBarDisplayMode(_ mode: BarDisplayMode) {
        var copy = self.multiProvider
        copy.barDisplayMode = mode
        self.multiProvider = copy
    }

    // MARK: - Reset

    /// Riporta TUTTE le preferenze (clbar.*) ai default, segreti Keychain esclusi (restano).
    /// Usata dalla sezione Avanzato. Riassegna ogni proprietà così i `didSet` persistono e
    /// l'`onChange` propaga ai sottosistemi (scheduler/icona/launch-at-login) in un colpo solo.
    func resetToDefaults() {
        self.usageSource = .auto
        self.refreshInterval = .fiveMinutes
        self.appearance = .system
        self.launchAtLogin = false
        self.refreshOnPanelOpen = true
        self.refreshOnWake = true
        self.glanceStyle = .ring
        self.showPercentLabel = true
        self.numberContent = .used
        self.monochromeIcon = false
        self.pulseOnCritical = true
        self.warnThreshold = GlanceThresholds.warn
        self.criticalThreshold = GlanceThresholds.critical
        self.notifyOnSessionThreshold = true
        self.notifyOnWeeklyReset = true
        self.notificationSound = true
        self.sessionThresholds = Self.defaultSessionThresholds
        self.defaultAnalyticsRange = .today
        self.includeSubagentsInAnalytics = true
        self.showCostDisclaimer = true
        self.pricingOverridePath = nil
        // Multi-provider torna alla configurazione iniziale (solo Claude, auto-detect).
        self.multiProvider = .initial
    }

    // MARK: - Persistenza

    private static func key(_ name: String) -> String { AppInfo.defaultsPrefix + name }

    private func persistBool(_ value: Bool, _ name: String) {
        self.defaults.set(value, forKey: Self.key(name))
        self.onChange?()
    }

    private func persistDouble(_ value: Double, _ name: String) {
        self.defaults.set(value, forKey: Self.key(name))
        self.onChange?()
    }

    private func persistString(_ value: String?, _ name: String) {
        if let value {
            self.defaults.set(value, forKey: Self.key(name))
        } else {
            self.defaults.removeObject(forKey: Self.key(name))
        }
        self.onChange?()
    }

    private func persistEnum(_ value: some RawRepresentable<String>, _ name: String) {
        self.defaults.set(value.rawValue, forKey: Self.key(name))
        self.onChange?()
    }

    /// Persiste le soglie sessione come CSV ordinato/deduplicato di interi 1...99.
    private func persistThresholds(_ values: [Int]) {
        let clean = Self.normalizeThresholds(values)
        self.defaults.set(clean.map(String.init).joined(separator: ","), forKey: Self.key("sessionThresholds"))
        self.onChange?()
    }

    /// Legge le soglie sessione dal CSV. `nil` se assente/vuoto → default 50/75/90.
    private static func readThresholds(_ defaults: UserDefaults) -> [Int]? {
        guard let raw = defaults.string(forKey: key("sessionThresholds")), !raw.isEmpty else { return nil }
        let parsed = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let clean = normalizeThresholds(parsed)
        return clean.isEmpty ? nil : clean
    }

    /// Vincola le soglie a 1...99, deduplica e ordina (contratto condiviso con la UI/notifiche).
    static func normalizeThresholds(_ values: [Int]) -> [Int] {
        Array(Set(values.map { min(99, max(1, $0)) })).sorted()
    }

    private static func readString(_ defaults: UserDefaults, _ name: String) -> String? {
        defaults.string(forKey: key(name))
    }

    private static func readEnum<T: RawRepresentable<String>>(_ defaults: UserDefaults, _ name: String) -> T? {
        guard let raw = defaults.string(forKey: key(name)) else { return nil }
        return T(rawValue: raw)
    }

    /// Persiste `MultiProviderSettings` come JSON sotto `clbar.multiProvider`.
    private func persistMultiProvider(_ value: MultiProviderSettings) {
        if let data = try? JSONEncoder().encode(value) {
            self.defaults.set(data, forKey: Self.key("multiProvider"))
        }
        self.onChange?()
    }

    /// Carica `MultiProviderSettings` da JSON. `nil` se assente o non decodificabile (→ `.initial`).
    /// Se lo schema persistito è di una versione precedente alla corrente, si ignora il dato vecchio
    /// e si riparte da `.initial` (migrazione minimale: nessuna perdita di segreti, che sono in Keychain).
    private static func readMultiProvider(_ defaults: UserDefaults) -> MultiProviderSettings? {
        guard let data = defaults.data(forKey: key("multiProvider")),
              let decoded = try? JSONDecoder().decode(MultiProviderSettings.self, from: data),
              decoded.version == MultiProviderSettings.currentVersion
        else {
            return nil
        }
        return decoded
    }
}
