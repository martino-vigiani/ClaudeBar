# 01 — Data & Integration Layer

> Piano del livello dati di ClaudeBar. Tutto ciò che segue è **verificato** sull'upstream
> CodexBar (`.reference/CodexBar/Sources/`) e sul sistema reale dell'utente
> (`~/.claude/projects`, Keychain). Gli endpoint NON sono inventati: sono estratti dal
> codice CodexBar che già li usa in produzione.
>
> Riferimenti chiave letti:
> - `CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift` (endpoint usage)
> - `.../ClaudeOAuth/ClaudeOAuthCredentials.swift` (keychain + refresh, 2141 righe)
> - `.../ClaudeOAuth/ClaudeOAuthCredentialModels.swift` (modello credenziali)
> - `CostUsage/CostUsageScanner+Claude.swift` (parser .jsonl incrementale)
> - `CostUsage/CostUsageJsonl.swift` (scanner byte-level a offset)
> - `CostUsage/CostUsagePricing.swift` (pricing table reale)

---

## 0. Sommario delle scoperte (fatti, non ipotesi)

| Cosa | Valore reale verificato |
|------|--------------------------|
| **Endpoint usage** | `GET https://api.anthropic.com/api/oauth/usage` |
| Header obbligatori | `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`, `Accept: application/json`, `User-Agent: claude-code/<versione>` |
| Risposta usage | JSON con chiavi `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, `seven_day_oauth_apps`, `extra_usage`. Ogni finestra: `{ "utilization": <0-100>, "resets_at": <ISO8601> }` |
| **Refresh token** | `POST https://platform.claude.com/v1/oauth/token`, body `x-www-form-urlencoded`: `grant_type=refresh_token&refresh_token=<rt>&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e` |
| Risposta refresh | `{ "access_token", "refresh_token"?, "expires_in", "token_type" }` |
| OAuth client ID | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` (pubblico, identico a Claude Code CLI) |
| **Keychain** | `kSecClassGenericPassword`, service `Claude Code-credentials`. Sul sistema dell'utente: account `martinovigiani`. JSON sotto chiave `claudeAiOauth` |
| **Transcript** | `~/.claude/projects/<encoded-cwd>/*.jsonl` — **20 progetti, 4135 file, 1.8 GB**. Re-scan completo = inaccettabile → incrementale obbligatorio |
| Modelli usati dall'utente | `claude-fable-5`, `claude-opus-4-7`, `claude-opus-4-8`, `claude-opus-4-6`, `claude-sonnet-4-6`, varianti `[1m]`, alias `fable`/`opus`/`sonnet`/`haiku`, `<synthetic>` |
| service_tier | sempre `standard` (54k campioni) — nessun priority/batch nei log |

⚠️ **Buchi trovati nella pricing table di CodexBar** che dobbiamo colmare:
1. `claude-opus-4-7` (il modello PIÙ usato dall'utente) **non è in tabella** → costo nil.
2. Il suffisso `[1m]` (`claude-opus-4-7[1m]`) **non viene normalizzato** dalla regex CodexBar.
3. Gli alias brevi `opus`/`sonnet`/`haiku` non sono mappati.
4. CodexBar usa **un solo** `cacheCreationInputCostPerToken` (prezzo 5m) e ignora la
   distinzione `ephemeral_1h` vs `ephemeral_5m` presente nei .jsonl. **Noi la useremo**
   (la cache-write 1h costa 2× la 5m): è il nostro vantaggio di precisione.

---

## 1. Struttura dei moduli (target Swift Package locale)

Il dato vive in un modulo `ClaudeBarKit` (libreria), separato dalla UI. Solo macOS 26+,
Swift 6.2, strict concurrency.

```
ClaudeBarKit/
├── Limits/                         # limiti ufficiali (sessione 5h + settimanale)
│   ├── ClaudeCredentials.swift     # modello + parse del JSON claudeAiOauth
│   ├── ClaudeKeychainReader.swift  # SecItemCopyMatching, multi-account
│   ├── ClaudeTokenRefresher.swift  # refresh OAuth quando scaduto
│   ├── ClaudeUsageEndpoint.swift   # GET /api/oauth/usage + decode
│   ├── ClaudeLimitsModels.swift    # UsageWindow, LimitsSnapshot
│   └── ClaudeLimitsService.swift   # actor orchestratore (credenziali→refresh→fetch)
├── Analytics/                      # analytics locali profonde dai .jsonl
│   ├── TranscriptLine.swift        # Codable della riga assistant
│   ├── JSONLByteScanner.swift      # scan a offset (porting di CostUsageJsonl)
│   ├── UsageEvent.swift            # evento normalizzato + dedup key
│   ├── IncrementalIndex.swift      # stato per-file (size/mtime/offset/rows) su disco
│   ├── TranscriptIndexer.swift     # actor: walk + parse incrementale + dedup
│   ├── Aggregator.swift            # rollup per modello/progetto/sessione/giorno/branch
│   └── AnalyticsModels.swift       # report aggregati
├── Pricing/
│   ├── PricingTable.swift          # tabella embedded Claude 4.x + override JSON
│   └── ModelNormalizer.swift       # normalizza model id ([1m], alias, date)
└── Watch/
    └── TranscriptWatcher.swift     # DispatchSource/FSEvents → trigger indicizzazione
```

Due servizi pubblici indipendenti:
- `ClaudeLimitsService` (rete, lento, ~ogni 60-120 s o on-demand)
- `TranscriptIndexer` + `Aggregator` (locale, veloce, reattivo ai cambi file)

---

## 2. PARTE A — Limiti ufficiali (sessione 5h + settimanale)

### 2.1 Flusso testuale

```
glance refresh / apertura pannello / timer
        │
        ▼
ClaudeLimitsService.currentLimits()                      [actor]
        │
        ├─ 1. carica credenziali (vedi 2.3)
        │       env var → cache memoria → file ~/.claude/.credentials.json → Keychain
        │
        ├─ 2. se accessToken scaduto (now >= expiresAt):
        │       owner == claudeCLI  → NON refreshare noi: il token è di Claude Code,
        │                             che ruota il refresh-token. Rileggi dal Keychain
        │                             (Claude lo avrà già rinnovato) → se ancora scaduto,
        │                             segnala "apri Claude per ri-autenticare".
        │       owner == claudeBar   → refresh diretto via /v1/oauth/token (2.4)
        │
        ├─ 3. GET /api/oauth/usage con Bearer accessToken (2.2)
        │
        └─ 4. decode → LimitsSnapshot { session5h, weekly, weeklyOpus?, extraUsage? }
```

Nota di design importante (ereditata da CodexBar, riga 1141-1152 di
`ClaudeOAuthCredentials.swift`): **se il token appartiene a Claude Code CLI, NON facciamo
il refresh noi**. Claude Code ruota i refresh-token; rinnovarli noi li invaliderebbe.
Rileggiamo il Keychain (sincronizzato da Claude) e, se serve, deleghiamo.

### 2.2 Endpoint usage — `ClaudeUsageEndpoint`

```swift
enum ClaudeUsageEndpoint {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"

    static func fetch(accessToken: String, claudeCodeVersion: String) async throws -> OAuthUsageResponse
    // GET, timeout 30s
    // Authorization: Bearer <accessToken>
    // anthropic-beta: oauth-2025-04-20
    // Accept / Content-Type: application/json
    // User-Agent: claude-code/<version>   (fallback "2.1.0" se versione non rilevabile)
}
```

Gestione status (identica a CodexBar):
- `200` → decode
- `401` → `unauthorized` (token non valido / scaduto lato server → ri-autenticare)
- `429` → `rateLimited(retryAfter:)`, leggi header `Retry-After` (secondi o data RFC1123);
  applica un **gate di backoff locale** per non martellare l'endpoint (vedi 2.6)
- `403` / altri → `serverError(code, body)`

Decode (shape reale verificata):

```swift
struct OAuthUsageResponse: Decodable {
    let fiveHour: UsageWindow?          // "five_hour"
    let sevenDay: UsageWindow?          // "seven_day"
    let sevenDayOpus: UsageWindow?      // "seven_day_opus"
    let sevenDaySonnet: UsageWindow?    // "seven_day_sonnet"
    let extraUsage: ExtraUsage?         // "extra_usage" (pay-as-you-go oltre piano)
}

struct UsageWindow: Decodable {
    let utilization: Double?            // 0–100, % USATA (non rimanente!)
    let resetsAt: String?              // ISO8601 → Date
}

struct ExtraUsage: Decodable {         // crediti extra acquistabili oltre il piano Max
    let isEnabled: Bool?
    let monthlyLimit: Double?          // in CENTESIMI → /100 per USD
    let usedCredits: Double?           // in CENTESIMI → /100
    let utilization: Double?
    let currency: String?
}
```

⚠️ Semantica: `utilization` è la **percentuale usata** (0=fresco, 100=esaurito).
Il glance colorato verde→ambra→rosso si guida con `utilization` direttamente.
`extra_usage.monthlyLimit/usedCredits` sono in **centesimi** (verificato: CodexBar divide
sempre per 100).

### 2.3 Lettura credenziali — `ClaudeKeychainReader` + `ClaudeCredentials`

Modello (dal JSON `claudeAiOauth` verificato):

```swift
struct ClaudeCredentials: Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?               // da expiresAt (ms epoch) / 1000
    let scopes: [String]
    let rateLimitTier: String?
    let subscriptionType: String?      // "max", ...
    var isExpired: Bool { expiresAt.map { Date() >= $0 } ?? true }
}

enum CredentialOwner: Sendable { case claudeCLI, claudeBar, environment }
struct CredentialRecord: Sendable { let credentials: ClaudeCredentials; let owner: CredentialOwner; let source: Source }
```

Parsing JSON (struttura reale):
```json
{ "claudeAiOauth": { "accessToken": "...", "refreshToken": "...",
  "expiresAt": 1730000000000, "scopes": ["user:inference","user:profile"],
  "subscriptionType": "max", "rateLimitTier": "..." } }
```

Catena di lettura (ordine, dal più economico al più costoso — da CodexBar `loadRecord`):
1. **Env var** `CLAUDEBAR_OAUTH_TOKEN` (debug/test) → owner `.environment`
2. **Cache in memoria** (validità ~30 min) se non scaduta
3. **File** `~/.claude/.credentials.json` (Linux / alcune installazioni) → owner `.claudeCLI`
4. **Keychain** (macOS, sorgente primaria reale dell'utente) → owner `.claudeCLI`

Keychain reader (query reale verificata, righe 1625-1658 di `ClaudeOAuthCredentials.swift`):

```swift
enum ClaudeKeychainReader {
    static let service = "Claude Code-credentials"

    // Enumerazione multi-account (kSecMatchLimitAll), ordina per data più recente.
    static func candidates() -> [Candidate]    // persistentRef, account, modifiedAt, createdAt
    // query: kSecClass=GenericPassword, kSecAttrService=service,
    //        kSecMatchLimit=All, kSecReturnAttributes=true, kSecReturnPersistentRef=true

    // Legge i byte del candidato più recente via persistentRef.
    static func readData(for candidate: Candidate) throws -> Data
    // query per persistentRef + kSecReturnData=true
}
```

**Account multipli** (`Claude Code-credentials-<hash>` citato nel brief): la query con
`kSecMatchLimitAll` + ordinamento per `kSecAttrModificationDate` desc seleziona il più
recente. MVP: usiamo il più recente; predisponiamo un selettore account in settings (vedi
domande aperte).

**Prompt Keychain** — punto delicato: leggere un item creato da un'altra app (Claude Code)
fa apparire il prompt di autorizzazione macOS. CodexBar ha un'intera macchina di gate
(`ClaudeOAuthKeychainAccessGate`, prompt cooldown, "no-UI" query con
`kSecUseAuthenticationUI=kSecUseAuthenticationUIFail`). Strategia ClaudeBar (semplificata):
- **Probe non-interattivo** (`kSecUseAuthenticationUIFail`) in background per rilevare
  cambi/fingerprint senza UI.
- **Prompt reale solo su azione utente** (apertura pannello / "Refresh" manuale).
- Dopo un diniego (`errSecUserCanceled`/`errSecAuthFailed`), **backoff** e suggerire di
  consentire l'accesso in "Accesso Portachiavi" o usare il fallback CLI.
- Cache su nostro Keychain item dedicato (`com.claudebar.oauth-cache`) per non ripromptare.

Invalidazione cache: fingerprint `(modifiedAtMs, size)` del file credenziali +
`(modifiedAt, createdAt, persistentRefHash)` del Keychain item. Se cambia → invalida.

### 2.4 Refresh token — `ClaudeTokenRefresher` (solo per credenziali owner `.claudeBar`)

```swift
enum ClaudeTokenRefresher {
    static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    static func refresh(refreshToken: String, existing: ClaudeCredentials) async throws -> ClaudeCredentials
    // POST x-www-form-urlencoded:
    //   grant_type=refresh_token&refresh_token=<rt>&client_id=<clientID>
    // 200 → TokenRefreshResponse{access_token, refresh_token?, expires_in, token_type}
    //       expiresAt = now + expires_in; preserva scopes/rateLimitTier/subscriptionType
}
```

Disposizione errori refresh (da CodexBar):
- `invalid_grant` → **terminale**: refresh-token morto, invalida cache, richiedi
  ri-login (`claude login`). Non ritentare.
- altri 4xx/5xx → **backoff transitorio**, ritenta più tardi.

Dopo refresh riuscito: salva nel nostro Keychain cache (owner `.claudeBar`) + memoria.

### 2.5 Snapshot finale esposto alla UI

```swift
struct LimitsSnapshot: Sendable {
    let session: UsageBar          // five_hour
    let weekly: UsageBar?          // seven_day
    let weeklyOpus: UsageBar?      // seven_day_opus (cap Opus separato)
    let weeklySonnet: UsageBar?    // seven_day_sonnet
    let extraCredits: SpendInfo?   // extra_usage normalizzato in USD
    let subscriptionType: String?  // "max"
    let accountLabel: String?      // account Keychain (es. "martinovigiani")
    let fetchedAt: Date
    let source: Source             // .oauth / .cliProbe / .cached
}

struct UsageBar: Sendable {
    let usedPercent: Double        // 0–100 (= utilization)
    var remainingPercent: Double { max(0, 100 - usedPercent) }
    let windowMinutes: Int?        // 300 sessione, 10080 settimana
    let resetsAt: Date?
    var status: BarStatus { ... }  // verde <70, ambra 70–90, rosso >90 (soglie in config)
}
```

`status` è ciò che pilota il **glance colorato** nella menu bar (decisione di prodotto #2).

### 2.6 Rate-limit gate locale

Per non farci bloccare da Anthropic con i 429: dopo un 429 registriamo `blockedUntil`
(da `Retry-After` o backoff esponenziale) e **non rifacciamo la GET** finché non scade;
mostriamo l'ultimo snapshot cached con badge "stale". Memoria + persistenza leggera.

### 2.7 Fallback PTY / CLI probe — **opzionale, non MVP**

CodexBar lancia `claude /usage` in una home isolata
(`~/Library/Application Support/.../ClaudeProbe/.claude/`) e fa parsing **testuale** del
pannello TUI (`session_5h`, `week_all_models`, formati come "5pm (Europe/Rome)").
È **fragile** (dipende dal layout TUI di Claude Code) e lento (subprocess + PTY).

**Decisione**: l'endpoint OAuth `/api/oauth/usage` copre sessione 5h + settimanale +
cap Opus/Sonnet + extra credits → **non serve il PTY per l'MVP**. Lo teniamo come
fallback di secondo livello (feature flag) solo se l'OAuth fallisse strutturalmente
(es. Anthropic cambia auth). La home `ClaudeProbe` esiste già sul sistema dell'utente
(creata da CodexBar) ma non la riutilizziamo.

---

## 3. PARTE B — Analytics locali dai .jsonl

### 3.1 Schema riga (verificato su file reale dell'utente)

Riga `type: "assistant"` rilevante (chiavi top-level reali):
`cwd, gitBranch, isSidechain, message, parentUuid, requestId, sessionId, timestamp,
type, uuid, version, userType, entrypoint`.

`message.usage` reale:
```json
{ "input_tokens": 6, "cache_creation_input_tokens": 42400,
  "cache_read_input_tokens": 0, "output_tokens": 1554,
  "cache_creation": { "ephemeral_1h_input_tokens": 42400, "ephemeral_5m_input_tokens": 0 },
  "server_tool_use": { "web_search_requests": 0, "web_fetch_requests": 0 },
  "service_tier": "standard" }
```

`message.model` reale: `claude-opus-4-7`, `message.id`: `msg_...`.

```swift
struct TranscriptUsage: Decodable, Sendable {
    let inputTokens: Int                 // input_tokens
    let cacheReadInputTokens: Int        // cache_read_input_tokens
    let cacheCreationInputTokens: Int    // totale cache write (legacy/somma)
    let outputTokens: Int                // output_tokens
    let cacheCreation: CacheBreakdown?   // cache_creation { ephemeral_1h / ephemeral_5m }
    let serviceTier: String?
}
struct CacheBreakdown: Decodable, Sendable {
    let ephemeral1h: Int     // ephemeral_1h_input_tokens
    let ephemeral5m: Int     // ephemeral_5m_input_tokens
}
```

### 3.2 Evento normalizzato + dedup

```swift
struct UsageEvent: Sendable {
    let timestamp: Date
    let dayKey: String          // "yyyy-MM-dd" in TZ locale (per rollup giornaliero)
    let model: String           // normalizzato (vedi 3.5)
    let rawModel: String        // originale per debug
    let projectPath: String     // da cwd
    let sessionId: String?
    let messageId: String?
    let requestId: String?
    let gitBranch: String?
    let isSidechain: Bool
    let input: Int
    let cacheRead: Int
    let cacheCreate1h: Int      // da cache_creation.ephemeral_1h (più preciso di CodexBar)
    let cacheCreate5m: Int      // da cache_creation.ephemeral_5m
    let output: Int
    var dedupKey: String?       // "\(messageId):\(requestId)" se entrambi presenti
}
```

**Dedup** (regola verificata in CodexBar, righe 189-197): i chunk di streaming
condividono `message.id`+`requestId` nello stesso file → l'ultimo chunk cumulativo vince
(overwrite su `[dedupKey] = event`). Righe senza ID → trattate come distinte (mai
scartate, per non perdere usage di log vecchi). Tra file diversi: stesso `dedupKey` →
vince il record subagent / sidechain (regola `claudeRowWins`), tie-break sul path.

⚠️ Se `cache_creation` è assente (log vecchi), usa `cache_creation_input_tokens` come
fallback assegnandolo tutto a 5m (prezzo conservativo più basso) — comportamento esplicito
nel parser.

### 3.3 Parsing incrementale — `JSONLByteScanner` + `IncrementalIndex`

Porting diretto di `CostUsageJsonl.scan` (verificato, performante):
- apre `FileHandle`, fa `seek(toOffset:)` all'offset salvato, legge a blocchi di 256 KB,
  splitta sulle newline `0x0A`, applica un cap per riga (512 KB) per non esplodere su
  tool-output enormi (righe troncate scartate dal conteggio usage), ritorna `parsedBytes`.
- **prefiltro byte-level** prima del JSON parse: la riga deve contenere
  `"type":"assistant"` e `"usage"` → evita di deserializzare le righe `user`/`system`
  (la stragrande maggioranza). Enorme risparmio CPU.

Stato per-file persistito su disco (il cuore dell'incrementale):

```swift
struct FileState: Codable, Sendable {
    let path: String
    let size: Int64            // ultima dimensione vista
    let mtimeMs: Int64         // ultima modifica vista
    let parsedBytes: Int64     // offset fino a cui abbiamo parsato (= dove riprendere)
    let events: [UsageEvent]   // righe estratte da questo file (per re-rollup/merge cross-file)
}

actor IncrementalIndex {       // persistito in Application Support, formato versionato
    func fileState(_ path: String) -> FileState?
    func upsert(_ state: FileState)
    func prune(touched: Set<String>)   // rimuove file scomparsi
    func snapshotAllEvents() -> [UsageEvent]
    func save() / load()
}
```

Logica decisionale per file (da `processClaudeFile`, righe 482-536):
```
per ogni *.jsonl trovato nell'enumerazione:
  cached = index.fileState(path)
  se cached.size == size && cached.mtimeMs == mtime  → SKIP (invariato)
  altrimenti se size > cached.size && cached.parsedBytes valido:
        → INCREMENTALE: parse da parsedBytes, merge eventi (dedup in-file), aggiorna stato
  altrimenti (file rimpicciolito / ruotato / nuovo / niente cache):
        → FULL PARSE dall'offset 0
```

### 3.4 Walk + watch — `TranscriptIndexer` + `TranscriptWatcher`

Root: `~/.claude/projects` (+ `$CLAUDE_CONFIG_DIR` se presente, + `~/.config/claude/projects`).

```swift
actor TranscriptIndexer {
    func refresh(force: Bool = false) async throws -> AnalyticsReport
    // 1. enumera ricorsivamente *.jsonl (FileManager.enumerator, skipsHiddenFiles)
    //    leggendo solo .fileSizeKey + .contentModificationDateKey (no apertura file)
    // 2. per ciascuno applica la logica 3.3
    // 3. prune file scomparsi, salva IncrementalIndex
    // 4. Aggregator.build(...) → report
}
```

**Watch** (no polling cieco su 4135 file): `DispatchSource` su FSEvents per la directory
`~/.claude/projects`. Su evento → coalescing (debounce ~1-2 s) → `indexer.refresh()`.
Il primo avvio fa un full index (1.8 GB, ma con prefiltro byte-level e parse solo
`assistant` è gestibile; mostriamo progress); i successivi sono near-instant perché
toccano solo i file con mtime/size cambiati.

Performance attesa: a regime un refresh tocca 1-3 file (la/le sessioni attive) → decine di
ms. Il primo full index gira su task in background con priorità `.utility`, cancellabile.

### 3.5 Pricing & normalizzazione modelli — `PricingTable` + `ModelNormalizer`

Prezzi **per token** (USD), verificati dalla tabella CodexBar (`per token`, non per milione):

| Modello (normalizzato) | input | output | cache-write (5m) | cache-write (1h) | cache-read |
|---|---|---|---|---|---|
| `claude-fable-5` ⚠️*flagship, no long-context tier* | 1e-5 | 5e-5 | 1.25e-5 | **2e-5** | 1e-6 |
| `claude-opus-4-8` | 5e-6 | 2.5e-5 | 6.25e-6 | **1e-5** | 5e-7 |
| `claude-opus-4-7` ⚠️*nuovo* | 5e-6 | 2.5e-5 | 6.25e-6 | **1e-5** | 5e-7 |
| `claude-opus-4-6` | 5e-6 | 2.5e-5 | 6.25e-6 | **1e-5** | 5e-7 |
| `claude-opus-4-5` | 5e-6 | 2.5e-5 | 6.25e-6 | **1e-5** | 5e-7 |
| `claude-opus-4-1` / `claude-opus-4` | 1.5e-5 | 7.5e-5 | 1.875e-5 | **3e-5** | 1.5e-6 |
| `claude-sonnet-4-6` | 3e-6 | 1.5e-5 | 3.75e-6 | **6e-6** | 3e-7 |
| `claude-sonnet-4-5` | 3e-6 | 1.5e-5 | 3.75e-6 | **6e-6** | 3e-7 |
| `claude-haiku-4-5` | 1e-6 | 5e-6 | 1.25e-6 | **2e-6** | 1e-7 |

⚠️ La colonna **cache-write 1h** non è in CodexBar (lui usa solo la 5m). La calcoliamo
noi: per le famiglie Anthropic la cache-write 1h = `input × 2` (5m = `input × 1.25`).
Questo è il moltiplicatore ufficiale Anthropic; lo teniamo come campo esplicito,
**verificabile** e override-abile. Sonnet ha anche **long-context tier** (soglia 200k
token: prezzi raddoppiati sopra soglia) — già nella tabella CodexBar, lo manteniamo.

```swift
struct ModelPricing: Sendable, Codable {
    let input: Double
    let output: Double
    let cacheWrite5m: Double
    let cacheWrite1h: Double
    let cacheRead: Double
    // long-context (Sonnet): soglia + prezzi sopra soglia, opzionali
    let thresholdTokens: Int?
    let inputAbove: Double?; let outputAbove: Double?
    let cacheWrite5mAbove: Double?; let cacheWrite1hAbove: Double?; let cacheReadAbove: Double?
}

enum PricingTable {
    static let embedded: [String: ModelPricing]      // tabella sopra
    static func pricing(for normalizedModel: String) -> ModelPricing?
    // override: legge ~/Library/Application Support/ClaudeBar/pricing-overrides.json
    //           (merge sopra embedded) → aggiornabile senza ricompilare

    static func cost(model: String, input: Int, cacheRead: Int,
                     cacheWrite5m: Int, cacheWrite1h: Int, output: Int) -> Double?
    // applica tiering long-context se thresholdTokens presente
}
```

`ModelNormalizer` (estende la regex CodexBar per coprire i casi reali dell'utente):

```swift
enum ModelNormalizer {
    static func normalize(_ raw: String) -> String
    // 1. trim; rimuovi prefisso "anthropic." / segmento bedrock "...claude-..."
    // 2. rimuovi suffisso "[1m]"  ← NUOVO, necessario per claude-opus-4-7[1m]
    // 3. rimuovi suffisso versione bedrock "-v\d+:\d+"
    // 4. rimuovi data "-YYYYMMDD" se la base è in tabella
    // 5. rimuovi data Vertex "@YYYYMMDD"
    // 6. mappa alias brevi: "opus"→famiglia opus corrente, "sonnet"→sonnet, "haiku"→haiku
    //    (gli alias non hanno versione: stimiamo con l'ultima nota, segnando il dato come "stimato")
    // 7. "<synthetic>" → escludi dal costo (token di sistema, no billing)
}
```

⚠️ Gli alias brevi e `<synthetic>` vanno trattati con cura: contribuiscono ai **token**
ma il costo per alias è una stima (modello esatto ignoto). Marchiamo l'aggregato con un
flag `costEstimated` quando entrano alias, così la UI può mostrarlo onesto.

### 3.6 Aggregazioni — `Aggregator` + `AnalyticsReport`

Da `[UsageEvent]` deduplicati produciamo rollup multi-dimensione (il vantaggio sulla
precisione promesso nel brief):

```swift
struct AnalyticsReport: Sendable {
    let totals: TokenTotals               // input/output/cacheRead/cacheWrite5m/1h/cost
    let byDay: [DayBucket]                // per Swift Charts (trend)
    let byModel: [ModelBucket]
    let byProject: [ProjectBucket]        // da cwd
    let bySession: [SessionBucket]
    let byBranch: [BranchBucket]          // da gitBranch
    let cacheEfficiency: CacheEfficiency  // cacheRead / (cacheRead+input) → % risparmio
    let costEstimated: Bool               // true se entrano alias non versionati
    let generatedAt: Date
}

struct TokenTotals: Sendable {
    let input, output, cacheRead, cacheWrite5m, cacheWrite1h, totalTokens: Int
    let costUSD: Double?
}
```

Costo = somma per-evento di `PricingTable.cost(...)` con i token reali (incluso lo split
1h/5m). Aggregare per-evento e poi sommare preserva i confini di soglia long-context
(nota verificata in CodexBar, riga 728). Cache efficiency = quanto la cache-read sta
risparmiando rispetto a rileggere tutto come input fresco.

---

## 4. Concurrency & persistenza

- Tutto il dato in **actor** (`ClaudeLimitsService`, `TranscriptIndexer`, `IncrementalIndex`).
  Modelli `Sendable`. Nessun stato condiviso mutabile fuori dagli actor.
- `IncrementalIndex` persistito in `~/Library/Application Support/ClaudeBar/index/<provider>.json`
  (o binario `propertyList`/`Data` per dimensione: con migliaia di eventi conviene un
  formato compatto, valutare splitting per-progetto).
- HTTP via un `URLSession` dedicato con timeout 30 s, no cookie, no cache disco.
- Refresh limiti: timer ~90 s + on-demand all'apertura del pannello (rispettando il gate 429).
- Refresh analytics: guidato da FSEvents (debounce) + un refresh pigro all'apertura.

---

## 5. Rischi e fallback

| Rischio | Mitigazione |
|---|---|
| Prompt Keychain ripetuti / negati | Probe no-UI in background; prompt solo su azione utente; cache su Keychain item nostro; backoff su diniego; suggerimento fallback CLI |
| Anthropic cambia `/api/oauth/usage` o beta header | Versionare endpoint+header in un solo file; fallback PTY dietro feature flag; gestione 4xx esplicita con messaggi azionabili |
| 429 rate limit | Gate locale con `Retry-After`/backoff; mostra ultimo snapshot con badge stale |
| Refresh-token rotato da Claude CLI (lo invalidiamo) | Rispettare `owner == claudeCLI` → NON refreshare, rileggere Keychain, delegare a `claude` |
| Pricing obsoleta / modello nuovo non in tabella | Override JSON locale + catalogo modelli remoto opzionale (modesto, come `models.dev` in CodexBar) + flag `costEstimated`; costo nil invece di sbagliato |
| `[1m]`, alias, `<synthetic>` | `ModelNormalizer` esteso (3.5); alias→stima con flag; synthetic escluso dal costo |
| Primo full-index su 1.8 GB lento | Prefiltro byte-level, parse solo `assistant`, task `.utility` cancellabile con progress; poi solo incrementale |
| Righe enormi (tool output) | Cap 512 KB/riga, righe troncate non conteggiate (come CodexBar) |
| Duplicati / chunk streaming | Dedup `messageId:requestId`, last-wins in-file, regola winner cross-file |
| Account multipli Keychain | `kSecMatchLimitAll` + ordina per modifica; selettore account in settings (post-MVP) |
| cache_creation assente (log vecchi) | Fallback: tutto su 5m (prezzo più basso, conservativo) |

---

## 6. Domande aperte per il team-lead

1. **cache-write 1h** — la calcolo come `input × 2` (regola Anthropic standard). Confermi
   che è accettabile come default override-abile, o vuoi che verifichi i prezzi 1h
   ufficiali per ogni famiglia via doc Anthropic prima dell'implementazione?
2. **Catalogo modelli remoto** (stile `models.dev` di CodexBar) per auto-aggiornare i
   prezzi: lo vogliamo (più resiliente ma una dipendenza di rete) o restiamo embedded +
   override JSON locale (più semplice, coerente con "uso personale")?
3. **Account multipli** — l'utente ha un solo account (`martinovigiani`). MVP a singolo
   account (il più recente) o predispongo subito il selettore?
4. **Costo: API teorico vs abbonamento** — gli analytics calcolano il costo **API teorico**
   (quanto costerebbe a listino). Con piano Max è "valore consumato", non spesa reale.
   Confermi che l'etichetta UI deve dirlo chiaramente (es. "costo API equivalente")?
5. **Persistenza indice** — con migliaia di eventi, JSON unico o split per-progetto +
   formato binario? Propendo per split per-progetto. Procedo così?
```