# 00 — Analisi astrazione provider di CodexBar (MP-1)

> READ-ONLY su `.reference/CodexBar/Sources/CodexBarCore/`. Scopo: dare a `provider-architect`
> un modello concreto (pattern, file:riga, endpoint, header, shape risposte) per progettare
> l'astrazione multi-provider di ClaudeBar. **Non implementare.**
>
> CodexBar supporta ~47 provider (`UsageProvider`, `Providers/Providers.swift:5`). Qui mi concentro
> su Claude/Codex/OpenAI/Gemini/Cursor + API a consumo, che sono i target v1 del BRIEF.

---

## 1. Pattern di astrazione provider

### 1.1 Il `ProviderDescriptor` (il cuore)
`Providers/ProviderDescriptor.swift:13`. Ogni provider è descritto da un value type `Sendable` composto da 5 parti:

```swift
public struct ProviderDescriptor: Sendable {
    public let id: UsageProvider          // enum case (Providers.swift:5)
    public let metadata: ProviderMetadata // label, dashboardURL, defaultEnabled, isPrimaryProvider, supportsCredits…
    public let branding: ProviderBranding // iconStyle + iconResourceName + ProviderColor (RGB)
    public let tokenCost: ProviderTokenCostConfig // supportsTokenCost + noDataMessage
    public let fetchPlan: ProviderFetchPlan       // sourceModes + pipeline di strategie
    public let cli: ProviderCLIConfig             // name, aliases, versionDetector
}
```

- `fetchOutcome(context:)` / `fetch(context:)` (`ProviderDescriptor.swift:37-44`) delegano al `fetchPlan`.
- **Registry centrale**: `ProviderDescriptorRegistry` (`ProviderDescriptor.swift:47`). Mappa `descriptorsByID` statica `[UsageProvider: ProviderDescriptor]` (`:55`), bootstrap lazy con `preconditionFailure` se manca un descriptor (`:107`). Espone `all`, `metadata`, `descriptor(for:)`, `cliNameMap` (alias CLI → provider). Registrazione thread-safe con `NSLock`.
- I descriptor concreti sono enum statici (es. `ClaudeProviderDescriptor.descriptor`) generati via **macro Swift** `@ProviderDescriptorRegistration` + `@ProviderDescriptorDefinition` (vedi `Providers/Claude/ClaudeProviderDescriptor.swift:4`). La macro genera la proprietà `descriptor` da `makeDescriptor()` e l'auto-registrazione. **Per ClaudeBar non serve replicare le macro**: basta un dizionario statico o un array di descriptor — il pattern resta valido senza metaprogrammazione.

### 1.2 `ProviderMetadata` (`Providers.swift:108`)
Campi rilevanti per noi:
- `displayName`, `sessionLabel`/`weeklyLabel`/`opusLabel` (etichette delle 3 finestre per-provider),
- `supportsOpus: Bool`, `supportsCredits: Bool`, `creditsHint`,
- `defaultEnabled: Bool` (default auto-detect), `isPrimaryProvider: Bool` (Claude e Codex sono primary),
- `usesAccountFallback: Bool` (multi-account),
- `dashboardURL` / `subscriptionDashboardURL` (link "apri dashboard"), `changelogURL`, `statusPageURL`.

Nota: le etichette delle finestre sono **per-provider** (Claude: Session/Weekly/Sonnet; Codex: Session/Weekly; Cursor: Total/Auto/API; Gemini: Pro/Flash/Flash-Lite). L'astrazione mappa 3 slot generici (`primary/secondary/tertiary`) a etichette diverse.

### 1.3 `ProviderFetchPlan` + pipeline a strategie con fallback (`Providers/ProviderFetchPlan.swift`)
Questo è il meccanismo più importante da riusare:

- `ProviderSourceMode` (`:8`): `auto | web | cli | oauth | api`. `auto` = auto-detect.
- `ProviderFetchPlan` (`:224`): `sourceModes: Set<ProviderSourceMode>` (cosa il provider supporta) + `pipeline`.
- `ProviderFetchPipeline` (`:172`): closure `resolveStrategies(context) -> [any ProviderFetchStrategy]`. La lista di strategie è **risolta a runtime** in base a `context.sourceMode`/credenziali disponibili.
- `ProviderFetchStrategy` (protocollo, `:147`):
  ```swift
  var id: String; var kind: ProviderFetchKind  // cli|web|oauth|apiToken|localProbe|webDashboard
  func isAvailable(_ context) async -> Bool
  func fetch(_ context) async throws -> ProviderFetchResult
  func shouldFallback(on error: Error, context) -> Bool
  ```
- **Esecuzione fallback chain** (`ProviderFetchPipeline.fetch`, `:179`): scorre le strategie in ordine; salta quelle non `isAvailable`; alla prima `fetch` riuscita ritorna `.success`; su errore, se `shouldFallback` è true continua, altrimenti ritorna `.failure`. Raccoglie un array di `ProviderFetchAttempt` (per diagnostica). Se nessuna strategia disponibile → `ProviderFetchError.noAvailableStrategy`.

Esempio Claude (`ClaudeProviderDescriptor.swift:46`): in `auto` produce la catena ordinata `[admin-api?] → oauth → cli → web` (decisa da `ClaudeSourcePlanner`). Esempio Codex (`CodexProviderDescriptor.swift:44`): `auto` app = `[oauth, cli]`, `auto` cli = `[web, oauth, cli]`.

**Raccomandazione architetto**: adottare 1:1 questo schema (sourceMode + pipeline di strategie con `isAvailable`/`shouldFallback`). È il modo pulito per fare auto-detect e per non regredire il path Claude (che oggi in ClaudeBar è "solo OAuth/keychain" → diventa una strategia tra le altre).

### 1.4 `ProviderFetchContext` (input al fetch, `ProviderFetchPlan.swift:20`)
Value type `Sendable` passato a tutte le strategie. Campi chiave: `runtime (.app/.cli)`, `sourceMode`, `includeCredits`, `includeOptionalUsage`, `webTimeout`, `verbose`, `env: [String:String]` (**qui vengono iniettate le API key**, vedi §2.4), `settings: ProviderSettingsSnapshot?`, `fetcher`, `claudeFetcher`, `browserDetection`, `selectedTokenAccountID: UUID?` (multi-account), `tokenAccountTokenUpdater`/`providerManualTokenUpdater` (callback per scrivere token refreshati), `costUsageHistoryDays`.

`ProviderInteractionContext` / `ProviderRefreshContext` (`ProviderInteractionContext.swift`): `@TaskLocal` per distinguere `userInitiated` vs `background` e `startup` vs `regular` — usati per decidere se è lecito mostrare un prompt Keychain (vedi §2.2).

### 1.5 `ProviderFetchResult` (output, `ProviderFetchPlan.swift:78`)
```swift
usage: UsageSnapshot            // modello unificato (§3)
credits: CreditsSnapshot?       // credito residuo + eventi
dashboard: OpenAIDashboardSnapshot?  // dati ricchi dashboard web (Codex)
sourceLabel: String             // "oauth"/"web"/"codex-cli"/"admin-api"…
strategyID, strategyKind
```

---

## 2. Autenticazione: metodi supportati e selezione del token

CodexBar usa **5 famiglie di auth**, scelte per provider dalla pipeline:

### 2.1 API key (catena env-first uniforme)
- Ogni provider ha un `…SettingsReader` (es. `MoonshotSettingsReader.apiKey`, `Providers/Moonshot/MoonshotSettingsReader.swift`) che legge una **env var** (`MOONSHOT_API_KEY`, `OPENAI_ADMIN_KEY`, ecc.), trimmata e ripulita da apici.
- `ProviderTokenResolver` (`Providers/ProviderTokenResolver.swift`) centralizza: ogni `…Resolution(environment:)` ritorna `ProviderTokenResolution { token, source: .environment | .authFile }`. Per alcuni (Kilo, Codebuff, Kimi, Perplexity) fa fallback env → file auth → **cookie browser** (`:282`, `:343`, `:245`, `:356`).
- **`source` è solo `.environment` o `.authFile`** — non c'è un caso `.keychain` esplicito qui: le API key salvate in Settings vengono **proiettate come env var** (vedi §2.4).

### 2.2 Keychain no-UI (per le credenziali OAuth Claude/Codex già presenti)
- `KeychainNoUIQuery.apply(to:)` (`KeychainNoUIQuery.swift:11`): aggiunge a una query `SecItem` un `LAContext` con `interactionNotAllowed = true` + `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail` (risolto a runtime via `dlsym` per evitare l'API deprecata). Scopo: leggere il Keychain **senza far apparire il prompt Allow/Deny** di sistema.
- `KeychainAccessPreflight.checkGenericPassword(service:account:)` (`KeychainAccessPreflight.swift:126`): preflight non interattivo che ritorna `.allowed | .interactionRequired | .notFound | .failure(status)`. Usa `kSecReturnAttributes` (mai `kSecReturnData`) per non scatenare UI. **Pattern da copiare**: prima fai il preflight, e solo se serve (e se `userInitiated`) chiedi il prompt vero.
- `KeychainAccessGate` (`KeychainAccessGate.swift`): flag globale (DEBUG/UserDefaults) per **disabilitare ogni accesso Keychain** (usato nei test e in modalità privacy).
- `KeychainPromptHandler` (`KeychainAccessPreflight.swift:36`): callback per notificare alla UI che un certo accesso (es. `claudeOAuth`) richiederebbe un prompt — la UI può mostrare un bottone "Concedi accesso".
- Claude: service Keychain **`"Claude Code-credentials"`** (`ClaudeOAuth/ClaudeOAuthCredentials.swift:16`), classe `kSecClassGenericPassword`. **Questo è esattamente ciò che ClaudeBar già fa** e va preservato come strategia OAuth.

### 2.3 OAuth (access/refresh token + refresh automatico)
- **Claude**: credenziali in Keychain `Claude Code-credentials`; usage GET `https://api.anthropic.com/api/oauth/usage` con `Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<versione>` (`ClaudeOAuth/ClaudeOAuthUsageFetcher.swift:37-60`). Refresh: POST `https://platform.claude.com/v1/oauth/token`, `grant_type=refresh_token`, `client_id=<oauthClientID>` (`ClaudeOAuthCredentials.swift:1024`). Gestione 401/429/403 con rate-limit gate (`ClaudeOAuthUsageRateLimitGate`).
- **Codex**: credenziali in **file** `~/.codex/auth.json` (NON keychain), parse di `tokens.{access_token,refresh_token,id_token,account_id}` + `last_refresh` (`CodexOAuth/CodexOAuthCredentials.swift:48-167`). `needsRefresh` se > 8 giorni (`:24`). Refresh: POST `https://auth.openai.com/oauth/token`, `client_id=app_EMoamEEZ73f0CkXaXp7hrann`, `grant_type=refresh_token` (`CodexTokenRefresher.swift:6-49`); mappa errori `refresh_token_expired/reused/invalid_grant`. Usage GET `https://chatgpt.com/backend-api/wham/usage` con `Authorization: Bearer` + header **`ChatGPT-Account-Id`** (`CodexOAuthUsageFetcher.swift:233-250`).
- Pattern refresh: la strategia OAuth, dentro `fetch`, controlla `needsRefresh`, chiama il refresher, **salva** le nuove credenziali, poi fa la chiamata usage (`CodexProviderDescriptor.swift:170-177`).

### 2.4 Proiezione delle Settings come env var (collegamento auth ↔ config)
**Punto cruciale per l'architetto.** `ProviderConfigEnvironment.applyAPIKeyOverride(base:provider:config:)` (`Config/ProviderConfigEnvironment.swift:4`) prende l'`apiKey` salvata nel `ProviderConfig` e la **inietta come env var** (es. `OPENAI_ADMIN_KEY`, `ANTHROPIC_ADMIN_KEY`, `MOONSHOT_API_KEY`…) prima del fetch, così i `SettingsReader` la trovano nell'ambiente. C'è una mappa `directAPIKeyEnvironmentKey(for:)` (`:77`) provider→nome-env, più casi speciali (OpenAI/Bedrock/Azure/Deepgram/LLMProxy con region/endpoint/projectID). Precedenza: env reale del processo **vince** sulla key salvata per alcuni provider.

→ ClaudeBar può mantenere questo disaccoppiamento elegante (resolver legge da `context.env`), **ma sostituire la sorgente**: invece di leggere `apiKey` da `config.json` su disco, leggerla dal **Keychain** e iniettarla nel `context.env` solo in memoria. Vedi §6.

### 2.5 Cookie del browser (auth web, opzionale/invasivo)
- `BrowserDetection` + `BrowserCookieAccessGate` + `CookieHeaderCache`/`CookieHeaderNormalizer` + dipendenza `SweetCookieKit`. Provider che lo usano: **Cursor** (solo cookie, `CursorProviderDescriptor.swift:45`), Codex web dashboard, Claude web (fallback), Kimi, Perplexity, MiniMax.
- `ProviderCookieSource` (enum `.auto/.manual/.off` + header manuale incollato). In `ProviderSettingsSnapshot` ogni provider cookie-based ha `cookieSource` + `manualCookieHeader`.
- Ordine di import per-browser configurabile (`ProviderBrowserCookieDefaults`, `Providers.swift:185`): es. Cursor preferisce Safari, Grok solo Chrome.
- **Per il BRIEF**: cookie-auth = stretch. Va modellato come una `ProviderFetchStrategy` di `kind: .web` con `isAvailable` legato a `cookieSource != .off`, ma non blocca l'MVP. Cursor però **richiede** cookie (non ha API key): se lo vogliamo in v1, serve `SweetCookieKit` o equivalente.

### 2.6 Multi-account (`TokenAccounts.swift`)
- `ProviderTokenAccount` (`:3`): `id: UUID, label, token, addedAt, lastUsed?, externalIdentifier?` (es. GitHub login per dedup), `organizationID?` (Claude web sessionKey → org Anthropic).
- `ProviderTokenAccountData` (`:58`): `version, accounts: [ProviderTokenAccount], activeIndex` (con `clampedActiveIndex()`).
- `FileTokenAccountStore` (`:86`): persiste su `~/Library/Application Support/CodexBar/token-accounts.json` con `chmod 0600`. **NB: token su disco in chiaro** — da NON replicare così (vedi §6).
- Selezione: `context.selectedTokenAccountID: UUID?`; i descriptor (es. Claude admin-api `:202`) controllano se l'account selezionato corrisponde a un token risolvibile. Refresh dei token scritti via callback `tokenAccountTokenUpdater`/`providerManualTokenUpdater` nel context.

---

## 3. Distinzione "a limiti/quota" vs "a consumo/costo" — UN SOLO snapshot unificato

Il modello centrale è `UsageSnapshot` (`UsageFetcher.swift:82`), `Codable & Sendable`, che **rappresenta entrambe le famiglie** con campi opzionali — esattamente la "fusione" richiesta dal BRIEF.

### 3.1 Famiglia "a limiti" → `RateWindow` (`UsageFetcher.swift:3`)
```swift
public struct RateWindow {
    usedPercent: Double          // utilization 0–100
    windowMinutes: Int?          // durata finestra
    resetsAt: Date?              // quando si resetta
    resetDescription: String?    // testo reset (scrape CLI)
    nextRegenPercent: Double?    // recupero rolling (alcuni provider)
    var remainingPercent: Double // = 100 - usedPercent
}
```
- `UsageSnapshot.primary/secondary/tertiary: RateWindow?` = le 3 finestre (es. Claude: 5h / 7d / Sonnet-7d). Più `extraRateWindows: [NamedRateWindow]?` per limiti nominati (es. Codex Spark, `NamedRateWindow` = id+title+window).
- `hasRateLimitWindows` (`:286`) e `UsageLimitsAvailability.resolve` (`:425`) determinano se un provider "a limiti" ha effettivamente finestre o se sono indisponibili.
- `backfillingResetTime(s)` (`:30`, `:324`): se il fetch nuovo non ha `resetsAt` ma la cache sì, lo riempie — utile per non perdere il countdown tra refresh.

### 3.2 Famiglia "a consumo/costo" → tre rappresentazioni
1. **`ProviderCostSnapshot`** (`ProviderCostSnapshot.swift:4`) — spend vs budget di un periodo, **dentro `UsageSnapshot.providerCost`**:
   ```swift
   used: Double, limit: Double, currencyCode: String,
   period: String?, resetsAt: Date?, nextRegenAmount: Double?, updatedAt: Date
   ```
   Es. Claude "Extra usage" mensile (da `extra_usage.monthly_limit`/`used_credits` dell'OAuth usage). Cursor lo usa come fallback budget on-demand quando il piano è esaurito (`UsageFetcher.swift:255-267`).
2. **`CreditsSnapshot`** (`CreditsModels.swift:40`) — credito residuo + storico eventi:
   ```swift
   remaining: Double, events: [CreditEvent], updatedAt: Date
   // CreditEvent: { date, service, creditsUsed }
   ```
   Ritornato a parte in `ProviderFetchResult.credits` (Codex credits, OpenAI credit grants).
3. **Usage API per-provider** (token + costo $ giornaliero/per-modello) — campi tipizzati dentro `UsageSnapshot`: `openAIAPIUsage`, `claudeAdminAPIUsage`, `mistralUsage`, `deepgramUsage`, `cursorRequests`, `openRouterUsage`, `kiroUsage`, ecc. (`UsageFetcher.swift:88-97`). Vedi §4 per shape.

### 3.3 Calcolo costo **locale** (dai log `.jsonl`, non da API) — `CostUsageFetcher`
`CostUsageFetcher.swift` produce `CostUsageTokenSnapshot` SCANSIONANDO i log locali (Codex sessions, Claude `~/.claude/projects`) e applicando una pricing table (`ModelsDevPricingPipeline`, da models.dev). Supportato **solo per `.codex, .claude, .vertexai, .bedrock`** (`:105`).
```swift
CostUsageTokenSnapshot {
  sessionTokens: Int?, sessionCostUSD: Double?,
  last30DaysTokens: Int?, last30DaysCostUSD: Double?, last30DaysRequests: Int?,
  historyDays: Int, daily: [CostUsageDailyReport.Entry], updatedAt: Date
}
```
→ È **complementare** al path "limiti": un utente Claude Max vede le finestre, ma può anche vedere "quanto ha speso in token" calcolato dai log (ClaudeBar **già fa qualcosa di simile** col suo parser `.jsonl` + `PricingTable` + `TokenTotals` — quindi è riusabile per la vista "costo" di Claude/Codex).

### 3.4 Come la UI sceglie il layout
La UI non guarda un flag "tipo provider": guarda **quali campi dello snapshot sono valorizzati**. Se ci sono `RateWindow` → layout finestre/anello+%. Se c'è `providerCost`/`credits`/`*Usage` → layout costo/usage. `switcherWeeklyWindow(for:showUsed:)` (`:244`) ha logica per-provider per scegliere la finestra "principale" da mostrare nel menu bar. **Raccomandazione**: replicare questo principio (snapshot con campi opzionali + il descriptor che dichiara `supportsCredits`/`supportsTokenCost`/`isPrimaryProvider` per guidare il default UI).

---

## 4. Modelli dati usage/cost — shape ed endpoint reali

### 4.1 Claude OAuth usage (path attuale di ClaudeBar) — `GET /api/oauth/usage`
`OAuthUsageResponse` (`ClaudeOAuth/ClaudeOAuthUsageFetcher.swift:141`). Decodifica con chiavi dinamiche (resiliente a rinomine server):
- finestre: `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, `seven_day_oauth_apps`, `seven_day_routines` (+ alias `cowork`…), `iguana_necktie`. Ognuna è `OAuthUsageWindow { utilization: Double?, resets_at: String? }`.
- `extra_usage`: `OAuthExtraUsage { is_enabled, monthly_limit, used_credits, utilization, currency }` → mappato a `ProviderCostSnapshot`.
- Header obbligatori: `Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<v>`.

### 4.2 Claude **Admin API** a consumo — `cost_report` + `usage_report/messages`
`Providers/Claude/ClaudeAdminAPIUsageFetcher.swift`. Per chi ha una **Anthropic Admin API key** (org). Due endpoint:
- `GET https://api.anthropic.com/v1/organizations/cost_report?starting_at&ending_at&bucket_width=1d&limit=31&group_by[]=description` (`:27`, `:215`). Risposta `data[].results[]` con `amount` (**stringa in centesimi USD**, `/100`, `:211`), `description`, `cost_type`, `currency`.
- `GET https://api.anthropic.com/v1/organizations/usage_report/messages?...&group_by[]=model` (`:28`). Risposta `data[].results[]` con `uncached_input_tokens`, `cache_creation.{ephemeral_1h,ephemeral_5m}_input_tokens`, `cache_read_input_tokens`, `output_tokens`, `model`.
- Header: `x-api-key: <key>`, `anthropic-version: 2023-06-01`, `Accept: application/json`.
- Aggregati in `ClaudeAdminAPIUsageSnapshot { daily: [DailyBucket], updatedAt }`, con `DailyBucket` = costo + token + `costItems` + `models` per giorno.

### 4.3 OpenAI **a consumo** (Organization/Admin API) — `OpenAIAPIUsageFetcher`
`Providers/OpenAI/`. Per chi ha `OPENAI_ADMIN_KEY` (+ `projectID` opzionale).
- `GET https://api.openai.com/v1/organization/costs` (`OpenAIAPIUsageFetcher.swift:36`)
- `GET https://api.openai.com/v1/organization/usage/completions` (`:37`)
- `GET https://api.openai.com/v1/dashboard/billing/credit_grants` (credit balance, `OpenAIAPICreditBalanceFetcher.swift:118`)
- Header: `Authorization: Bearer <admin-key>`, `Accept: application/json`.
- Shape: `OpenAIAPIUsageSnapshot { daily: [DailyBucket{ day, costUSD, requests, inputTokens, cachedInputTokens, outputTokens, totalTokens, lineItems[], models[] }] }` (`OpenAIAPIUsageSnapshot.swift:3`).

### 4.4 Codex OAuth usage — `wham/usage`
`CodexUsageResponse` (`CodexOAuth/CodexOAuthUsageFetcher.swift:6`): `plan_type` (free/plus/pro/team/business/enterprise…), `rate_limit.{primary_window,secondary_window}` (→ RateWindow), `credits.{balance}` (→ CreditsSnapshot), `additional_rate_limits[]` (→ extraRateWindows, decodifica **lossy per-elemento** così un entry malformato non scarta gli altri). Riconciliato via `CodexReconciledState`.

### 4.5 Codex **dashboard web** (cookie) — dati ricchi
`CodexWebDashboardStrategy` → `OpenAIDashboardSnapshot` (`OpenAIDashboardModels.swift:3`): `signedInEmail`, `accountPlan`, `primaryLimit`/`secondaryLimit`/`codeReviewLimit` (RateWindow), `extraRateWindows`, `creditsRemaining`, `creditEvents[]`, `dailyBreakdown[]`/`usageBreakdown[]` (serie per-servizio, 30 giorni), `creditsPurchaseURL`. Ha cache su disco (`OpenAIDashboardCacheStore`). Convertibile a `UsageSnapshot` via `toUsageSnapshot()` (`:130`).

### 4.6 Copilot — quota (`CopilotUsageModels.swift`)
`CopilotUsageResponse`: `quota_snapshots.{premium_interactions, chat}` con `QuotaSnapshot { entitlement, remaining, percent_remaining, quota_id }` (→ `usedPercent = 100 - percent_remaining`). Molto difensivo: deriva la % se manca, fallback su chiavi dinamiche, gestisce `monthly_quotas`/`limited_user_quotas`. `copilot_plan`, `quota_reset_date`.

### 4.7 Cursor / Gemini
- **Cursor**: nessuna API key, solo cookie (`CursorStatusProbe` → `cursorRequests: CursorRequestUsage` + finestre + providerCost on-demand). sourceModes `[.auto, .cli]`.
- **Gemini**: `GeminiStatusProbe` (OAuth dei Google API), `kind: .apiToken`, sourceModes `[.auto, .api]`. `supportsTokenCost: false`. Etichette Pro/Flash/Flash-Lite. (Non c'è una API "usage $" pubblica diretta: si appoggia allo status probe.)

### 4.8 HTTP client comune — `ProviderHTTPClient`
`ProviderHTTPClient.swift:168`: wrapper `URLSession` `Sendable` con `ProviderHTTPTransport` protocollo (iniettabile nei test). `response(for:retryPolicy:)` con `ProviderHTTPRetryPolicy` (retry su 408/429/5xx + URLError transitori, backoff esponenziale, rispetta `Retry-After`). Timeout 30s/90s. **Da riusare**: un client HTTP unico con retry policy.

---

## 5. Config / Settings (persistenza)

- `CodexBarConfig` (`Config/CodexBarConfig.swift:3`): `{ version, providers: [ProviderConfig] }`. `makeDefault()` genera un `ProviderConfig` per ogni provider con `enabled = metadata.defaultEnabled` (auto-detect dei default). `enabledProviders()`, `orderedProviders()`, `normalized()` (aggiunge provider nuovi mantenendo l'ordine — utile per upgrade).
- `ProviderConfig` (`:75`): `id, enabled?, source? (sourceMode), extrasEnabled?, apiKey?, secretKey?, cookieHeader?, cookieSource?, region?, workspaceID?, enterpriseHost?, tokenAccounts?, codexActiveSource?, quotaWarnings?, awsProfile?, awsAuthMode?`. Getter `sanitized*` ripuliscono apici/spazi.
- `CodexBarConfigStore` (`Config/CodexBarConfigStore.swift:20`): persiste su **`config.json`** in Application Support (`:87`). `loadOrCreateDefault()`.
- `ProviderSettingsSnapshot` (`Providers/ProviderSettingsSnapshot.swift`): snapshot **immutabile/Sendable** dei settings, costruito dal config e passato nel `ProviderFetchContext`. Per-provider ha struct dedicate (`ClaudeProviderSettings { usageDataSource, webExtrasEnabled, cookieSource, manualCookieHeader, organizationID }`, `CodexProviderSettings`, `CursorProviderSettings`, …). `QuotaWarningConfig` per soglie di alert per-finestra/per-provider.

⚠️ **`apiKey`/`secretKey`/`cookieHeader` sono salvati in `config.json` in chiaro** — vedi §6 / rischi.

---

## 6. Implicazioni per ClaudeBar (note per `provider-architect`)

1. **Adottare il triangolo Descriptor → FetchPlan(pipeline di Strategy con fallback) → UsageSnapshot unificato.** È il pattern giusto, value-type, Sendable, già allineato a `@Observable @MainActor AppModel` come fonte di verità (lo snapshot è il prodotto, l'AppModel lo consuma). Niente macro: dizionario statico di descriptor.
2. **`UsageSnapshot` unificato è la chiave del BRIEF**: finestre opzionali (`primary/secondary/tertiary` + `extraRateWindows`) + cost/usage opzionali (`providerCost`, `credits`, `*Usage`). La UI sceglie il layout dai campi presenti + da `metadata` (`isPrimaryProvider`, `supportsCredits`, `supportsTokenCost`). Il default Claude-abbonamento (anello+%) cade naturalmente nel ramo "finestre".
3. **Claude diventa una strategia tra le altre**: il path attuale di ClaudeBar (Keychain `Claude Code-credentials` + `GET /api/oauth/usage`) = `ClaudeOAuthFetchStrategy`. La fallback chain `oauth → cli → web` e l'admin-api a consumo sono già mappati 1:1.
4. **Auth env-first è elegante e riusabile**, MA la sorgente delle API key va cambiata: **le key in Keychain**, lette e iniettate in `context.env` solo a runtime (non scritte in `config.json`). Mantenere `ProviderConfigEnvironment.applyAPIKeyOverride` come idea, cambiare il backing store. Stesso discorso per `tokenAccounts` (no `token-accounts.json` in chiaro → Keychain).
5. **Keychain no-UI + preflight + interaction gate** (`KeychainNoUIQuery`, `KeychainAccessPreflight`, `ProviderInteractionContext`) sono best-practice da portare: leggere senza prompt in background, prompt solo su azione utente.
6. **HTTP client unico** con retry/`Retry-After` (`ProviderHTTPClient`) + transport iniettabile per i test.
7. **Provider v1 fattibili senza dipendenze esterne**: Claude (OAuth+CLI+AdminAPI), Codex (OAuth file+CLI), OpenAI API a consumo (admin key), Claude API a consumo (admin key), calcolo costo locale Claude/Codex. **Cursor e Codex-web richiedono cookie browser** (`SweetCookieKit`) → stretch, non MVP. **Gemini** "usage" è debole (status probe, no API $) → valutare scope.

---

## 7. Domande aperte (per team-lead / prodotto)

1. **API key in Keychain**: confermare che NON replichiamo `config.json` in chiaro per le key/cookie/token. Serve un `KeychainSecretStore` nostro (un item per `provider+accountID`). Confermare se vogliamo anche il multi-account (`activeIndex`) in v1 o solo single-account.
2. **Cursor in v1?** Richiede cookie-auth (zero API key). Se sì → serve una dipendenza tipo `SweetCookieKit` (contro il vincolo "zero dipendenze"). Proposta: rimandare Cursor a v1.1.
3. **Gemini**: senza una vera "usage/cost API" pubblica, cosa mostriamo? Solo presenza/versione CLI + status? O lo togliamo dall'MVP?
4. **Vista "costo" per Claude/Codex con piano abbonamento**: vogliamo affiancare alla vista limiti anche il costo-token calcolato dai log locali (riuso del parser `.jsonl` esistente di ClaudeBar)? Il BRIEF lascia intendere di sì per i provider "a consumo", ma per gli abbonati è un extra.
5. **Display multi vs singolo provider** (menu bar): icona merged (`IconStyle.combined`) con switcher, o un `NSStatusItem` per provider? CodexBar supporta entrambi. Da confermare con l'utente dopo la fase A.
6. **`anthropic-beta: oauth-2025-04-20`** e gli endpoint sono soggetti a cambi lato Anthropic/OpenAI: confermare strategia di resilienza (decodifica a chiavi dinamiche come fa CodexBar) — consigliato adottarla.
