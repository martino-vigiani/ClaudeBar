# Provider "API a consumo" (Anthropic API / OpenAI API) — studio CodexBar + piano ClaudeBar

> Doc di **Fase A** del task MP-5 (apikeys-engineer). Riferimento READ-ONLY: `.reference/CodexBar/`.
> Obiettivo: capire come CodexBar gestisce API key generiche e usage/cost a consumo, mappare gli
> endpoint reali Anthropic/OpenAI, e proporre come ClaudeBar implementerà i provider "usage+costo,
> niente limiti" con **storage chiavi in Keychain** (non su disco come CodexBar).

---

## 1. Le due famiglie e il modello snapshot unificato di CodexBar

CodexBar unifica TUTTO in un solo `UsageSnapshot` (`UsageFetcher.swift`):

```
UsageSnapshot {
  primary:   RateWindow?      // finestra limite (abbonamento). API a consumo → nil
  secondary: RateWindow?      // idem
  tertiary:  RateWindow?
  providerCost: ProviderCostSnapshot?   // used/limit/currency/period/resetsAt
  openAIAPIUsage:     OpenAIAPIUsageSnapshot?     // payload ricco per layout dedicato
  claudeAdminAPIUsage: ClaudeAdminAPIUsageSnapshot?
  ...altri payload per-provider...
  updatedAt: Date
  identity:  ProviderIdentitySnapshot?  // providerID, email, org, loginMethod
}
```

- **`RateWindow`** = finestra di utilizzo: `usedPercent`, `windowMinutes`, `resetsAt`, `resetDescription`,
  `nextRegenPercent`. È IL modello dei "limiti" (la vista che l'utente ama → corrisponde al nostro
  `LimitsSnapshot` attuale).
- **`ProviderCostSnapshot`** (`ProviderCostSnapshot.swift`) = spesa/budget: `used`, `limit`, `currencyCode`,
  `period` (es. "Last 30 days", "API credits"), `resetsAt`, `nextRegenAmount`, `updatedAt`.
- **`CostUsageTokenSnapshot`** (`CostUsageModels.swift`) = usage a consumo: `sessionTokens/CostUSD/Requests`,
  `last30DaysTokens/CostUSD/Requests`, `currencyCode`, `historyDays`, `daily: [Entry]` (per-giorno con
  breakdown per modello). È il modello "usage+costo" tabellare.

**Regola d'oro per le API a consumo**: `primary/secondary = nil` (niente limiti) + `providerCost`
valorizzato + payload dettagliato (`openAIAPIUsage` / `claudeAdminAPIUsage`) per il layout per-modello.

`CreditsSnapshot` (`CreditsModels.swift`) = `remaining` + `events: [CreditEvent]` + `updatedAt`, usato dove
l'API espone credito residuo (Copilot ecc.). Per OpenAI il credito arriva via `OpenAIAPICreditBalanceSnapshot`.

---

## 2. Endpoint REALI — Anthropic Admin Usage & Cost API

File: `Providers/Claude/ClaudeAdminAPIUsageFetcher.swift` (+ `...Snapshot.swift`, `...SettingsReader.swift`).
**Verificato sulla doc ufficiale (giugno 2026, `platform.claude.com/docs/en/api/usage-cost-api`): endpoint e header del codice CodexBar sono ATTUALI e corretti.**

### Auth
- Header `x-api-key: <ADMIN_KEY>` — chiave **Admin** che inizia con `sk-ant-admin...`
  (NON la normale API key; provisionabile solo da admin org in Console → Admin keys).
- Header `anthropic-version: 2023-06-01`.
- Header `Accept: application/json`, `User-Agent: ClaudeBar/<ver>`.
- IMPORTANTE: l'Admin API **non è disponibile per account individuali** (serve un'organizzazione). Va
  gestito come "feature opzionale": se 401/403 → messaggio chiaro, niente crash, fallback assente.

### Endpoint usage (token)
`GET https://api.anthropic.com/v1/organizations/usage_report/messages`
Query: `starting_at` + `ending_at` (RFC3339 UTC), `bucket_width=1d`, `group_by[]=model`, `limit` (≤31 per `1d`).
Risposta: `{ data: [ { starting_at, ending_at, results: [ { model, uncached_input_tokens,
cache_creation{ephemeral_1h_input_tokens, ephemeral_5m_input_tokens}, cache_read_input_tokens,
output_tokens } ] } ], has_more, next_page }`.

### Endpoint costo (USD)
`GET https://api.anthropic.com/v1/organizations/cost_report`
Query: `starting_at`, `ending_at`, `bucket_width=1d`, `group_by[]=description`.
Risposta: `{ data: [ { starting_at, ending_at, results: [ { currency, amount, description, cost_type } ] } ] }`.
**`amount` = stringa decimale in UNITÀ MINIME (centesimi)** → USD = `Double(amount)/100`. (Confermato in doc.)

### Note operative
- Window: ultimi 31 giorni (`maxDailyBuckets=31`), calendario UTC.
- Freschezza dati: ~5 min di ritardo lato Anthropic; polling consigliato max 1/min.
- Paginazione `has_more`/`next_page` esiste; CodexBar NON pagina (31 bucket bastano per 1d). Per ClaudeBar v1 idem.

---

## 3. Endpoint REALI — OpenAI Organization Usage & Costs API

File: `Providers/OpenAI/OpenAIAPIUsageFetcher.swift`, `OpenAIAPICreditBalanceFetcher.swift`,
`OpenAIAPIUsageSnapshot.swift`, `OpenAIAPISettingsReader.swift`, `OpenAIAPIProviderDescriptor.swift`.

### Auth
- Header `Authorization: Bearer <ADMIN_KEY>` — chiave **Admin** (`sk-admin-...`), diversa dalla
  normale `sk-...`. L'Admin key serve per gli endpoint `/v1/organization/...`.
- Header `Accept: application/json`.
- Reader env: `OPENAI_ADMIN_KEY` (preferito), poi `OPENAI_API_KEY` (fallback); `OPENAI_PROJECT_ID` opzionale.

### Endpoint costo (USD)
`GET https://api.openai.com/v1/organization/costs`
Query: `start_time` + `end_time` (**epoch seconds, Int**), `bucket_width=1d`, `group_by=line_item`,
`limit` (≤31), opz. `project_ids`.
Risposta: `{ data: [ { start_time, end_time, results: [ { amount{value}, line_item } ] } ] }`.
`amount.value` = USD (Double).

### Endpoint usage (token)
`GET https://api.openai.com/v1/organization/usage/completions`
Query: `start_time`, `end_time`, `bucket_width=1d`, `group_by=model`, `limit`, opz. `project_ids`.
Risposta: `{ data: [ { start_time, end_time, results: [ { model, input_tokens, input_cached_tokens,
output_tokens, input_audio_tokens, output_audio_tokens, num_model_requests } ] } ] }`.

### Credito residuo (LEGACY / fallback)
`GET https://api.openai.com/v1/dashboard/billing/credit_grants`
Header `Authorization: Bearer <key>` (legacy/user key con accesso billing — le project key spesso danno **403**).
Risposta: `{ total_granted, total_used, total_available, grants:{ data:[{grant_amount, used_amount, expires_at}] } }`.
→ `OpenAIAPICreditBalanceSnapshot` → mappato a `providerCost(period:"API credits")` + `RateWindow` con `usedPercent = used/granted`.
**Stato 2026**: endpoint legacy ancora raggiungibile ma fragile (403 su project key). In ClaudeBar v1 lo
trattiamo come **fallback opzionale**, non obbligatorio: il path principale è usage+costs con Admin key.

### Strategia di fetch (da `OpenAIAPIProviderDescriptor`)
1. Se presente Admin key → prova `costs`+`completions` (path primario).
2. Su errore, se `allowsLegacyBalanceFallback` (no projectID o key non-admin) → prova `credit_grants`.
3. Errori 401/403 = credenziale rifiutata → messaggio chiaro, niente retry aggressivi.
- `maxDailyBucketLimit=31` per chunk; per `historyDays>31` CodexBar fa più chiamate a finestre.
- `retryPolicy = .transientIdempotent` (1 retry su GET per 429/5xx, rispetta `Retry-After`).

---

## 4. Auth / storage chiavi: CodexBar vs ClaudeBar (DIFFERENZA CHIAVE)

### Come fa CodexBar
- **NON usa il Keychain per le API key generiche.** Le legge da **variabili d'ambiente**
  (`ClaudeAdminAPISettingsReader`, `OpenAIAPISettingsReader`) e/o le persiste in un file JSON su disco:
  `FileTokenAccountStore` → `~/Library/Application Support/CodexBar/token-accounts.json` (chmod 0600),
  iniettandole poi come env override al fetch (`TokenAccountSupportCatalog.envOverride`).
- `KeychainNoUIQuery`/`KeychainAccessGate` in CodexBar servono al path **OAuth/cookie di Claude**, non
  alle API key a consumo.
- `TokenAccountSupport` descrive solo COME iniettare il token (`.environment(key:)` vs `.cookieHeader`),
  il placeholder UI e le env da "scrubbare".

### Cosa deve fare ClaudeBar (vincolo del BRIEF)
- **API key e segreti SEMPRE in Keychain, MAI su disco in chiaro.** Quindi NON portiamo
  `FileTokenAccountStore`. Creiamo un nostro **`APIKeyStore`** sopra `SecItem*` con item dedicati ClaudeBar:
  - `kSecClass = kSecClassGenericPassword`
  - `kSecAttrService = "ClaudeBar.apikey.anthropic"` / `"ClaudeBar.apikey.openai"` (uno per provider)
  - `kSecAttrAccount` = etichetta/identità account (multi-account opzionale; v1 single)
  - `kSecValueData` = la chiave (UTF-8)
  - `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (no iCloud sync, no export)
  - Item **creati da noi** → niente prompt macOS per leggerli (a differenza dell'item Claude di terze parti).
  - Operazioni: `set(key, for: provider, account:)` (SecItemAdd + update se esiste),
    `read(provider, account:)`, `delete(provider, account:)`, `list(provider)`.
- Stile/conformità: riuso del pattern di `Sources/ClaudeBarCore/Limits/KeychainReader.swift`
  (query `[String: Any]`, `SecItemCopyMatching`, mapping OSStatus → errore tipizzato). Aggiungo
  `SecItemAdd`/`SecItemUpdate`/`SecItemDelete` (KeychainReader oggi è solo lettura dell'item Claude).
- Override env per i fetcher: i fetcher Anthropic/OpenAI di CodexBar prendono `apiKey: String` come
  parametro diretto → noi passiamo la chiave letta dal Keychain. Nessun bisogno di env var, ma possiamo
  ANCHE leggere env (`ANTHROPIC_ADMIN_KEY`/`OPENAI_ADMIN_KEY`) come comodità di sviluppo (priorità:
  Keychain > env), mai scrivendo env su disco.

---

## 5. Interfacce/porting verso `ClaudeBarCore/Providers/` (proposta — da congelare con l'architetto)

Value types Sendable, StrictConcurrency. Porto (riscritti nello stile ClaudeBar, commenti in italiano):

| Concetto CodexBar | Destinazione ClaudeBar | Note |
|---|---|---|
| `ProviderCostSnapshot` | `Models/CostSnapshot.swift` (o riuso nome) | spesa/budget unificata |
| `CostUsageTokenSnapshot` + `CostUsageDailyReport.Entry/ModelBreakdown` | `Models/TokenUsageSnapshot.swift` | usage+costo per-giorno/per-modello |
| `ClaudeAdminAPIUsageSnapshot` / `OpenAIAPIUsageSnapshot` | payload per-provider (snella, solo i campi che la UI mostra) | breakdown per modello + line item |
| `ClaudeAdminAPIUsageFetcher` / `OpenAIAPIUsageFetcher` + `OpenAIAPICreditBalanceFetcher` | `Providers/AnthropicAPI/…Fetcher.swift`, `Providers/OpenAIAPI/…Fetcher.swift` | logica HTTP+parse invariata, endpoint/shape confermati |
| `ProviderHTTPClient`/`ProviderHTTPTransport`/`ProviderHTTPRetryPolicy` | `Networking/HTTPClient.swift` (snello) | serve transport iniettabile per i test (URLProtocol stub) |
| `TokenAccountSupport` (solo concetto inject) | sostituito da `APIKeyStore` (Keychain) | NON portiamo file-store né cookie |

**Conformità al protocollo `Provider`** (CONGELATO dall'architetto, NON rinominare): ogni provider
"API a consumo" implementa il fetch ritornando uno snapshot unificato con `windows = nil` e
`cost/usage` valorizzati, così l'`AppModel`/pannello sceglie il layout "usage+costo" invece di "limiti".
La modalità display "niente limiti" è un caso naturale: se non ci sono finestre, la UI mostra la
tabella usage/costo (oggi/7g/30g + per-modello) e l'eventuale credito residuo.

### Mapping verso il modello unificato (qualunque sia il nome finale del protocollo)
- Anthropic API: `windows=nil`, `cost = {used: somma 30g, period:"Last 30 days", currency:USD}`,
  `tokenUsage` = breakdown per-giorno/per-modello, `identity.loginMethod="Admin API"`.
- OpenAI API: come sopra + `requests` per giorno/modello; se solo `credit_grants` disponibile →
  `cost = {used: total_used, limit: total_granted, period:"API credits", resetsAt: prossima scadenza grant}`
  e una `RateWindow` con `usedPercent` (unico caso in cui un provider a consumo mostra una %).

---

## 6. Test previsti (Fase B)

- **`APIKeyStore`**: round-trip set/read/delete su Keychain (guardato `#if os(macOS)`); item separati per
  provider; sovrascrittura idempotente; delete pulito; nessuna scrittura su disco.
- **Parser Anthropic**: `_parseSnapshotForTesting(costs:messages:)` con fixture JSON reali → verifica
  `amount/100`, somma token, top-model, 30g.
- **Parser OpenAI**: `_parseSnapshotForTesting(costs:completions:)` + credit balance → verifica USD, requests,
  cached tokens, fallback 403→balance.
- **HTTP transport stub** (URLProtocol / handler iniettabile) per simulare 200/401/403/429 senza rete.
- **Mapping → snapshot unificato**: `windows == nil` e `cost/usage` popolati per entrambi i provider.

## 6-bis. IMPLEMENTAZIONE (Fase B) — completata sopra le interfacce CONGELATE

A interfacce congelate dall'architetto (task #11), implementati senza rinominare nulla:

File nuovi in `Sources/ClaudeBarCore/Providers/`:
- `AnthropicAPI/AnthropicAPIUsageEndpoint.swift` — GET cost_report + usage_report/messages
  (header `x-api-key` + `anthropic-version`), decode shape reale, mapping HTTP→`ProviderError`.
- `AnthropicAPI/AnthropicAPIUsageFetcher.swift` — aggrega in `ProviderCostUsage` (bucket 1/7/30g +
  per-modello); `amount` centesimi → USD/100; hook `_aggregateForTesting`.
- `AnthropicAPI/AnthropicAPIProvider.swift` — `Provider` (.anthropicAPI, `.costOnly`), strategia
  `.apiKey`, snapshot con `windows=[]` + `cost`.
- `OpenAIAPI/OpenAIAPIUsageEndpoint.swift` — GET /organization/costs + /usage/completions
  (Bearer Admin key, epoch seconds) + /dashboard/billing/credit_grants (fallback legacy).
- `OpenAIAPI/OpenAIAPIUsageFetcher.swift` — aggrega in `ProviderCostUsage`; fallback su credito
  (`ProviderCredits`) se le Admin usage falliscono e non c'è projectID; hook di test.
- `OpenAIAPI/OpenAIAPIProvider.swift` — `Provider` (.openaiAPI, cost+credits), strategia `.apiKey`.

Test: `Tests/ClaudeBarCoreTests/APIKeyProvidersTests.swift` (17 test): aggregazione/centesimi/
breakdown per entrambi, fallback credito, risoluzione credenziali Keychain>env, end-to-end via
`URLSession` stub (`StubURLProtocol`, suite `.serialized`), errori 401/403 terminali. Suite totale
verde: **82 test in 25 suite**.

DECISIONI di implementazione (rispetto al doc Fase A):
- **Keychain**: NON ho creato un `APIKeyStore` nuovo — uso `KeychainSecretStore`/`ProviderSecretStoring`
  GIA' forniti dall'architetto (service `com.subralabs.claudebar.secret.<providerRaw>`,
  `AfterFirstUnlock`). Requisito "chiavi in Keychain" soddisfatto senza duplicare codice.
- **Modello unificato**: i tipi sono `ProviderCostUsage` (buckets+byModel) e `ProviderCredits`
  dell'architetto, non i nomi provvisori del doc Fase A.
- **HTTP**: `URLSession` iniettabile (come `ClaudeUsageEndpoint`), niente HTTP client custom.
- **Credenziali**: risoluzione Keychain (account `default`) > env (`ANTHROPIC_ADMIN_KEY`,
  `OPENAI_ADMIN_KEY`/`OPENAI_API_KEY`, `OPENAI_PROJECT_ID`). L'env è solo comodità dev.

## 7. Rischi / questioni aperte (per il team-lead)

1. **Admin API non per account individuali** (Anthropic) e Admin key OpenAI distinta: molti utenti
   "a consumo" potrebbero NON avere accesso org. Serve UX chiara in Impostazioni ("richiede Admin key
   org") + degradazione pulita su 401/403. Domanda prodotto: mostriamo comunque il provider se la key
   non ha permessi, o lo nascondiamo?
2. **`credit_grants` OpenAI legacy**: fragile (403 su project key, possibile rimozione futura). Lo teniamo
   come fallback best-effort, non come feature garantita.
3. **Naming interfacce**: RISOLTO — implementato sulle interfacce congelate dell'architetto
   (protocollo `Provider`, `ProviderSnapshot`, `ProviderCostUsage`, `ProviderCredits`,
   `ProviderSecretStoring`), senza rinomine.
4. **Multi-account**: implementato single-account (`account = "default"`) per provider. Il
   `KeychainSecretStore` supporta già più account per service → multi-account è un'estensione UI
   futura senza cambi al data layer.
5. **UI a consumo (per settings-ui-engineer/pannello)**: lo snapshot a consumo ha `windows=[]`,
   `cost.buckets` (rangeDays 1/7/30) e `cost.byModel`; OpenAI può avere `credits`. La UI deve
   mostrare la tabella usage+costo (niente anello-limite) e il credito se presente. `glance` resta
   `.ok` per i provider a consumo senza credito (niente falso rosso).
