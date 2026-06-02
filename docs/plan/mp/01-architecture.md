# MP — Architettura astrazione multi-provider (INTERFACCE CONGELATE)

> Autore: `provider-architect` (task #11). Stato: **interfacce pubbliche CONGELATE e compilano**
> (`swift build` verde, 45 test verdi, zero regressioni).
> Leggere PRIMA: `BRIEF.md` → `DECISIONS.md`. Questo doc descrive l'astrazione che gli engineer
> di provider (#12 Codex/OpenAI, #13 Gemini/Cursor, #14 API a consumo) e settings-ui (#15)
> implementano in Fase B.

## Principio guida

CodexBar è iper-generico (47 provider, macro `@ProviderDescriptorRegistration`, registry globale
con `NSLock`, un mega-`UsageSnapshot` con ~15 campi provider-specifici, storage token su FILE in
chiaro). **Noi adottiamo il pattern vincente** — `ProviderFetchStrategy` con pipeline e fallback —
ma **semplifichiamo drasticamente**:

- snapshot **UNIFICATO e generico** (`windows[]` + `cost?` + `credits?`), nessun campo
  provider-specifico nel tipo di confine;
- **segreti SEMPRE in Keychain** (`ProviderSecretStore`), mai su disco in chiaro;
- registry come **value type immutabile** costruito al boot (niente stato globale/macro);
- 6 `ProviderID` chiusi (Claude, Codex, Gemini, Cursor, anthropicAPI, openaiAPI), non 47.

Claude resta il **default** e la sua UX **non regredisce**: `ClaudeProvider` **avvolge** l'attore
esistente `ClaudeLimitsService` senza riscriverne la logica (regola "non rubare il refresh alla
CLI", no-UI in background, gate 429 restano intatti e testati).

## Dove vive il codice

```
Sources/ClaudeBarCore/Providers/
  ProviderID.swift               # enum chiuso dei provider
  ProviderDescriptor.swift       # descrizione statica: capabilities, authKinds, branding
  ProviderSnapshot.swift         # SNAPSHOT UNIFICATO (windows + cost + credits)
  ProviderError.swift            # errori unificati + bridge da ClaudeLimitsError
  Provider.swift                 # protocollo Provider + ProviderFetchContext + strategie + pipeline
  ProviderSecretStore.swift      # storage segreti in Keychain (+ InMemory per i test)
  ProviderRegistry.swift         # registry + auto-detect del default
  ProviderSettings.swift         # modello Settings multi-provider (Codable)
  LimitsSnapshot+Provider.swift  # bridge LimitsSnapshot → ProviderSnapshot (senza perdita)
  Claude/ClaudeProvider.swift    # provider Claude = wrapper di ClaudeLimitsService
```

I tipi dominio esistenti `UsageWindow` / `PaceWindowKind` / `PaceProjection` / `PaceRhythm` /
`GlanceState` / `LimitsSource` sono **riusati** (resi `Codable` in modo additivo: nessun cambio
di comportamento). Il nuovo codice NON tocca i file testati di Claude.

---

## Firme pubbliche CONGELATE

> Queste firme NON cambieranno in parallelo. Se serve un'aggiunta, chiedete a
> `provider-architect`: si aggiunge (additivo), non si rinomina.

### 1. `ProviderID`

```swift
public enum ProviderID: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case claude
    case codex
    case gemini
    case cursor
    case anthropicAPI = "anthropic_api"
    case openaiAPI     = "openai_api"
    public var defaultDisplayName: String { get }
}
```

### 2. `ProviderDescriptor` (descrizione statica)

```swift
public struct ProviderCapabilities: Sendable, Equatable, Hashable, Codable {
    public var hasUsageLimits: Bool   // → vista "limiti" (utilization/reset/pace)
    public var hasCostUsage: Bool     // → vista "usage/costo"
    public var hasCredits: Bool
    public var hasPerModelWeekly: Bool
    public init(hasUsageLimits: Bool, hasCostUsage: Bool, hasCredits: Bool = false, hasPerModelWeekly: Bool = false)
    public static let limitsOnly: ProviderCapabilities
    public static let costOnly: ProviderCapabilities
}

public enum ProviderAuthKind: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case oauthManaged = "oauth_managed"   // token di una CLI/altra app, letti dal Keychain di sistema
    case apiKey       = "api_key"         // API key inserita dall'utente → Keychain NOSTRO
    case browserCookie = "browser_cookie" // OPZIONALE/stretch, non blocca l'MVP
}

public struct ProviderBranding: Sendable, Equatable, Hashable, Codable {
    public var symbolName: String        // SF Symbol di fallback (UI può sostituire)
    public var dashboardURL: String?
    public init(symbolName: String, dashboardURL: String? = nil)
}

public struct ProviderDescriptor: Sendable, Equatable, Hashable, Codable {
    public var id: ProviderID
    public var displayName: String
    public var capabilities: ProviderCapabilities
    public var authKinds: [ProviderAuthKind]      // ordine di preferenza per l'auto-detect
    public var branding: ProviderBranding
    public var isPrimaryCandidate: Bool           // candidabile a default automatico (Claude/Codex)
    public init(id:displayName:capabilities:authKinds:branding:isPrimaryCandidate:)
}
```

### 3. `ProviderSnapshot` (SNAPSHOT UNIFICATO — il cuore)

```swift
public struct ProviderAccountIdentity: Sendable, Equatable, Codable {
    public var label: String?; public var email: String?
    public var organization: String?; public var plan: String?
    public static let empty: ProviderAccountIdentity
}

public struct ProviderCostBucket: Sendable, Equatable, Codable, Identifiable {
    public var rangeDays: Int          // 1 = Oggi, 7, 30
    public var inputTokens: Int; public var outputTokens: Int; public var totalTokens: Int
    public var costUSD: Double?        // nil se il provider non espone un costo
    public var costEstimated: Bool
}

public struct ProviderModelCost: Sendable, Equatable, Codable, Identifiable {
    public var model: String; public var totalTokens: Int
    public var costUSD: Double?; public var costEstimated: Bool
}

public struct ProviderCostUsage: Sendable, Equatable, Codable {
    public var buckets: [ProviderCostBucket]   // ordinati per rangeDays asc
    public var byModel: [ProviderModelCost]
    public var spendLimit: ProviderSpendLimit?  // tetto on-demand/budget periodo (vedi Addendum)
    public var costEstimated: Bool
}

public struct ProviderCredits: Sendable, Equatable, Codable {
    public var remaining: Double; public var total: Double?; public var currency: String
    public var usedFraction: Double? { get }   // (total - remaining)/total se total noto
}

public struct ProviderSnapshot: Sendable, Equatable, Codable {
    public var providerID: ProviderID
    public var windows: [UsageWindow]          // limiti (RIUSA UsageWindow esistente). Vuoto = provider a consumo
    public var cost: ProviderCostUsage?        // usage+costo. nil = provider solo-limiti
    public var credits: ProviderCredits?
    public var identity: ProviderAccountIdentity
    public var fetchedAt: Date
    public var source: LimitsSource            // .live / .cached / .stale (RIUSA esistente)
    public init(providerID:windows:cost:credits:identity:fetchedAt:source:)

    // Derivati per la UI:
    public var hasLimits: Bool { get }                 // !windows.isEmpty
    public var mostCriticalWindow: UsageWindow? { get } // max(utilization) → icona menu bar
    public var glance: GlanceState { get }              // dal più critico, o da credits, o .ok
    public func window(_ kind: PaceWindowKind) -> UsageWindow?
    public var isStale: Bool { get }
    public func markedStale() -> ProviderSnapshot
}
```

**Regola di layout per la UI** (settings-ui-engineer, pannello):
- `hasLimits == true` (windows non vuoto) → **vista limiti** (anello + % + Pace), come Claude oggi.
- `cost != nil` → **vista usage/costo** (bucket oggi/7g/30g + per-modello + disclaimer "stima").
- `credits != nil` → blocco credito/budget residuo.
- Un provider può avere PIÙ blocchi insieme (es. Codex con limiti-piano + API a consumo).

### 4. `ProviderError`

```swift
public enum ProviderError: Error, Sendable, Equatable {
    case noCredentials
    case unauthorized(String?)
    case refreshDelegatedToOwner
    case keychainDenied
    case rateLimited(retryAfter: Date?)
    case serverError(code: Int, body: String?)
    case network(String)
    case invalidResponse
    case noAvailableStrategy(ProviderID)
    public var isTerminal: Bool { get }
}
// Bridge: ClaudeLimitsError.asProviderError → ProviderError (1:1, senza perdita)
```

### 5. `Provider` + contesto + strategie (il pattern auth/auto-detect)

```swift
public struct ProviderFetchContext: Sendable {
    public var userInitiated: Bool      // true → Keychain CON prompt; false → no-UI (background)
    public var costHistoryDays: Int     // default 30
    public var environment: [String: String]
    public var now: @Sendable () -> Date
    public init(userInitiated:costHistoryDays:environment:now:)
}

public enum ProviderFetchKind: String, Sendable, Equatable, Codable {
    case oauthManaged = "oauth_managed"; case apiKey = "api_key"
    case browserCookie = "browser_cookie"; case local
}

public protocol ProviderFetchStrategy: Sendable {
    var id: String { get }                 // es. "claude.oauth", "openai.api"
    var kind: ProviderFetchKind { get }
    func isAvailable(_ context: ProviderFetchContext) async -> Bool         // niente rete pesante
    func fetch(_ context: ProviderFetchContext) async throws -> ProviderSnapshot
    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool
}
// default shouldFallback: true solo su errori NON terminali (rete/rate-limit/server).

public protocol Provider: Sendable {
    var descriptor: ProviderDescriptor { get }
    func strategies(for context: ProviderFetchContext) async -> [any ProviderFetchStrategy]
    func snapshot(context: ProviderFetchContext) async throws -> ProviderSnapshot  // default: esegue la pipeline
    func cachedSnapshot() async -> ProviderSnapshot?                                // default: nil
    func detectAvailability(_ context: ProviderFetchContext) async -> ProviderAvailability
}

public struct ProviderAvailability: Sendable, Equatable {
    public var isAvailable: Bool
    public var detectedAuth: ProviderAuthKind?
    public var accountLabel: String?
    public static let unavailable: ProviderAvailability
}
```

**Come implementa un nuovo provider (es. OpenAI a consumo):**
1. Una `struct OpenAIAPIProvider: Provider` che ritorna il suo `descriptor`
   (`capabilities = .costOnly`, `authKinds = [.apiKey]`).
2. Una o più `ProviderFetchStrategy`: `isAvailable` controlla che ci sia la API key (via
   `ProviderSecretStore.hasSecret(provider:)`), `fetch` chiama l'endpoint e **costruisce un
   `ProviderSnapshot`** con `cost: ProviderCostUsage(...)`.
3. `detectAvailability` = `isAvailable` della strategia, **senza rete** (solo presenza segreto).
La pipeline di default (`snapshot(context:)`) gestisce ordine/fallback: di norma non va sovrascritta.

### 6. Storage segreti (SEMPRE Keychain)

```swift
public protocol ProviderSecretStoring: Sendable {
    func setSecret(_ secret: String, provider: ProviderID, account: String) throws
    func secret(provider: ProviderID, account: String) throws -> String?
    func accounts(provider: ProviderID) throws -> [String]
    func removeSecret(provider: ProviderID, account: String) throws
}
// extension: static var defaultAccount = "default"; func hasSecret(provider:) -> Bool

public struct KeychainSecretStore: ProviderSecretStoring {   // service = "<prefix>.secret.<providerRaw>"
    public init(servicePrefix: String = "com.subralabs.claudebar")
}
public final class InMemorySecretStore: ProviderSecretStoring, @unchecked Sendable { public init() }
```

> NB per apikeys-engineer (#14): le API key inserite in Impostazioni vanno SCRITTE con
> `KeychainSecretStore`. La lettura delle credenziali OAuth ALTRUI (Claude Code) resta separata in
> `KeychainReader` (service `"Claude Code-credentials"`, regola no-UI). Le due cose non si toccano.

### 7. Registry + auto-detect

```swift
public struct ProviderRegistry: Sendable {
    public let providers: [any Provider]        // ordine = priorità per il default automatico
    public init(providers: [any Provider])
    public static func claudeOnly(service: ClaudeLimitsService = .init()) -> ProviderRegistry
    public func provider(for id: ProviderID) -> (any Provider)?
    public var descriptors: [ProviderDescriptor] { get }
    public func detectAvailability(_ context: ProviderFetchContext) async -> [ProviderID: ProviderAvailability]
    public func autoDetectDefault(_ context: ProviderFetchContext) async -> ProviderID
}
```

Politica `autoDetectDefault`: (1) primo `isPrimaryCandidate` disponibile (Claude prima), (2) primo
disponibile in assoluto, (3) fallback Claude. Il `context` per il boot deve essere **no-UI**
(`userInitiated: false`) per non far comparire prompt all'avvio.

### 8. Modello Settings (Codable, in Core)

```swift
public struct ProviderConfig: Sendable, Equatable, Codable {
    public var id: ProviderID; public var enabled: Bool
    public var preferredAuth: ProviderAuthKind?; public var selectedAccount: String  // etichetta, NON il segreto
}

public enum BarDisplayMode: String, Sendable, Equatable, CaseIterable, Codable {
    case singleActive = "single_active"   // 1 icona = provider attivo (comportamento attuale)
    case perProvider  = "per_provider"
    case merged
}

public struct MultiProviderSettings: Sendable, Equatable, Codable {
    public var version: Int
    public var providers: [ProviderConfig]
    public var defaultProvider: ProviderID?   // nil = usa auto-detect
    public var autoDetectDefault: Bool
    public var barDisplayMode: BarDisplayMode
    public static let currentVersion = 1
    public static var initial: MultiProviderSettings { get }   // SOLO Claude abilitato, singleActive
    public func config(for id: ProviderID) -> ProviderConfig
    public var enabledProviders: [ProviderID] { get }
    public func updating(_ config: ProviderConfig) -> MultiProviderSettings
}
```

> NB per settings-ui-engineer (#15): i SEGRETI non sono qui. `selectedAccount` è solo l'etichetta
> da passare a `ProviderSecretStore`. Lo `SettingsStore` dell'app (UserDefaults) persisterà
> `MultiProviderSettings` come JSON. Default di prima esecuzione = `.initial` (parità con l'MVP
> solo-Claude: nessun cambiamento per chi aggiorna).

---

## Integrazione `AppModel` (Fase B — core/settings)

L'astrazione **coesiste** con l'attuale `AppModel` (che oggi parla con `LimitsServicing`/Claude):
nessun cambiamento forzato in questa fase, così i 45 test restano verdi. In Fase B:
- l'`AppDelegate` costruisce un `ProviderRegistry` con i provider abilitati;
- `AppModel` consuma il **provider attivo** via `snapshot(context:)` e mappa `ProviderSnapshot →
  glanceSpec/status` (oggi lo fa da `LimitsSnapshot`; `ProviderSnapshot` espone gli STESSI derivati:
  `mostCriticalWindow`, `glance`, `isStale`, `window(_:)`);
- per Claude, `ProviderSnapshot.windows` contiene esattamente le stesse `UsageWindow` di oggi →
  l'icona e il Pace non cambiano.

Mapping errori: `AppModel.mapLimitsError` oggi usa `ClaudeLimitsError`. La versione multi-provider
userà `ProviderError` (stessi case → stessi `AppStatus`); il bridge `asProviderError` garantisce la
parità per Claude.

## Vincoli rispettati
- macOS 26, Swift 6.2, SPM puro, **zero dipendenze esterne**, StrictConcurrency: ok.
- Value type `Sendable` ai confini; gli unici reference type sono attori (`ClaudeLimitsService`) o
  `@unchecked Sendable` con lock (`InMemorySecretStore`).
- Segreti SEMPRE in Keychain.
- Claude default, UX invariata, 45 test verdi.

---

## Addendum 1 — aggiunte ADDITIVE post-congelamento (giu 2026)

> Richieste da gemini-cursor-engineer (finestre non-Claude) e dagli arbitrati `DECISIONS.md`
> §"Addendum giu 2026" (window kind generico, tipo costo unificato, auto-detect-solo-vuoti).
> Sono **aggiunte retro-compatibili**: nessuna firma esistente è cambiata o rinominata. Tutto
> compila, 93 test verdi.

### A1. Finestre non-Claude: durata custom + label su `UsageWindow`
Invece di moltiplicare i casi di `PaceWindowKind` (avrebbe rotto gli switch esaustivi in
`IconRenderer`/`AppModelPanelAdapter`/`WindowKind` di proprietà di core/ui), disaccoppiamo la
durata dal `kind`. `UsageWindow` ha due campi opzionali nuovi (default `nil` → Claude invariato):

```swift
public struct UsageWindow: Sendable, Equatable, Codable {
    public var kind: PaceWindowKind
    public var utilization: Double
    public var resetsAt: Date?
    public var pace: PaceProjection?
    public var customDurationMinutes: Int?  // NEW: durata reale se ≠ kind.duration (Gemini 1440, Cursor billing cycle)
    public var label: String?               // NEW: etichetta libera ("Pro"/"Flash"/"Total"); nil → nome dal kind
    public var effectiveDuration: TimeInterval { get }  // customDurationMinutes*60, altrimenti kind.duration
}
```

`PaceCalculator.project(...)` ha un nuovo parametro opzionale `duration:` (default `nil` →
`kind.duration`, Claude invariato). `PaceCalculator.withPace(_:now:)` usa `effectiveDuration`.

**Per gemini-cursor-engineer**: mappa le finestre non-Claude sui `kind` esistenti come SLOT
(primary→`.fiveHour`, secondary→`.sevenDay`, tertiary→`.sevenDayOpus`) e passa la durata reale
via `customDurationMinutes` + il nome via `label`. Gemini: 3 finestre 24h (`customDurationMinutes:
1440`, label "Pro"/"Flash"/"Flash-Lite"). Cursor: `customDurationMinutes` = (billingCycleEnd −
billingCycleStart) in minuti, label "Total"/"Auto"/"API", `resetsAt = billingCycleEnd`.
**Per ui-engineer**: se `window.label != nil`, mostralo al posto dell'eyebrow derivato dal kind.

### A2. Tipo costo unificato: `ProviderSpendLimit` (on-demand/budget)
Per l'on-demand di Cursor (USD nel ciclo) e i budget delle API a consumo, dentro
`ProviderCostUsage`:

```swift
public struct ProviderSpendLimit: Sendable, Equatable, Codable {
    public var used: Double
    public var limit: Double?       // nil = illimitato/non noto
    public var currency: String     // "USD"
    public var period: String?      // "Monthly" / "Billing cycle"
    public var resetsAt: Date?      // es. billingCycleEnd
    public var usedFraction: Double? { get }  // used/limit se limit noto e > 0
}
// ProviderCostUsage ora ha: var spendLimit: ProviderSpendLimit?  (default nil)
```

**Per gemini-cursor-engineer/apikeys-engineer**: l'on-demand Cursor (centesimi→USD) va in
`cost.spendLimit` con `resetsAt = billingCycleEnd`. I `buckets` restano per l'usage storico.

### A3. Auto-detect riempie SOLO i vuoti (non sovrascrive scelte manuali)
`ProviderRegistry` ha un nuovo metodo (DECISIONS §"auto-detect riempie solo i vuoti"):

```swift
public func applyingAutoDetect(
    to settings: MultiProviderSettings,
    context: ProviderFetchContext) async -> MultiProviderSettings
```

Abilita i provider disponibili MAI configurati dall'utente (settando `preferredAuth` =
auth rilevato), NON tocca i provider già presenti in `settings.providers` (scelta manuale), e
ricalcola `defaultProvider` solo se `autoDetectDefault` è attivo e il default corrente non è
usabile. **Per settings-ui-engineer**: usa QUESTO al boot/refresh, non `autoDetectDefault` da
solo, così rispetti le scelte manuali.

### A4. Correzioni descriptor Gemini/Cursor (DECISIONS addendum)
La realtà degli endpoint (da `prov-gemini-cursor.md`) corregge il brief:
- **Gemini = LIMITI** (non costOnly): `ProviderCapabilities(hasUsageLimits: true, hasCostUsage:
  false)`, `authKinds = [.oauthManaged]` (OAuth della Gemini CLI, `~/.gemini/oauth_creds.json`).
  Popola `windows[]` (quote per-modello 24h). Se la CLI manca → degrada ("configurato, nessun dato").
- **Cursor = LIMITI**: `ProviderCapabilities(hasUsageLimits: true, hasCostUsage: true)` (limiti del
  ciclo + on-demand USD via `spendLimit`), `authKinds = [.browserCookie]` (cookie header MANUALE
  in Keychain via `KeychainSecretStore`, account es. "cookie"). `windows[]` + `cost.spendLimit`.
Questi descriptor li definiscono i rispettivi `Provider` (gemini-cursor-engineer), non l'architetto.

### A5. Checkpoint utente CHIUSO (giu 2026): provider ATTIVO + switcher
Conferma delle decisioni finali sul modello Settings, già supportate dall'astrazione:
- **Display = UN solo provider attivo nella barra (default Claude) + switcher**, NON più item
  nella barra. Il "provider attivo" è `MultiProviderSettings.defaultProvider` (l'utente lo
  cambia dallo switcher via `setActiveProvider`/`setDefaultProvider`). `SettingsStore.activeProviderID`
  lo risolve: `defaultProvider` se abilitato, altrimenti il primo abilitato, altrimenti `.claude`.
  L'icona della barra e il pannello seguono il provider attivo (DECISIONS §Display).
- **`BarDisplayMode`**: l'utente ha scelto SOLO `singleActive`. I casi `perProvider`/`merged`
  restano nell'enum per compat-Codable ma sono DEPRECATI per l'MVP: nessun Picker deve offrirli
  (single+switcher è l'unica modalità). settings-ui-engineer: rimuovi l'opzione dal Picker.
- **Provider v1 = TUTTI** (Claude/Codex/Gemini/Cursor/OpenAI API/Anthropic API). Lo snapshot
  unificato copre entrambi i layout: `windows[]` (limiti) opzionali + `cost?`/`credits?` (a
  consumo) opzionali. La UI sceglie dal CONTENUTO dello snapshot, non dall'id del provider.
- **`AppModel` espone il provider attivo**: in Fase B costruisce il `ProviderRegistry`, risolve
  l'attivo da `activeProviderID`, chiama `provider.snapshot(context:)` e mappa il `ProviderSnapshot`
  su glance/pannello (gli stessi derivati di oggi). Per Claude resta identico (zero regressione).

**Stato finale**: build completa verde, 142 test verdi (Core+App+tutti i provider). Interfacce
multi-provider CONGELATE e adottate da tutti gli engineer (#12/#14/#15 completati; #13 in corso).
