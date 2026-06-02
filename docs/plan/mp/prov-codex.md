# Provider Codex / OpenAI — Studio Fase A

> Doc di ricerca (Fase A) per il task MP-3. Fonte: `.reference/CodexBar/Sources/CodexBarCore/`
> (read-only). Obiettivo: documentare endpoint reali, auth, shape risposte e la distinzione
> **plan-limits (abbonamento ChatGPT/Codex)** vs **API a consumo (OpenAI Admin/usage API)**,
> così che, una volta congelate le interfacce dall'architetto (`provider-architect`), si possa
> implementare un provider conforme al protocollo `Provider` in `ClaudeBarCore/Providers/`.
>
> Riferimento incrociato: il pattern Claude già in produzione (`ClaudeLimitsService`,
> `ClaudeUsageEndpoint`, `ClaudeOAuthCredentials`, `KeychainReader`) è strutturalmente
> identico al path Codex-OAuth e va riusato come stampo.

---

## 0. TL;DR

CodexBar tratta **due "provider" distinti** dietro lo stesso vendor OpenAI:

| Aspetto | **Codex** (abbonamento) | **OpenAI** (API a consumo) |
|---|---|---|
| `providerID` | `.codex` | `.openai` |
| Famiglia | Plan-limits (finestre %) | Usage + costo (no limiti) |
| Auth | OAuth ChatGPT (token in `~/.codex/auth.json`) | API key (Admin key preferita) |
| Endpoint primario | `GET https://chatgpt.com/backend-api/wham/usage` | `GET https://api.openai.com/v1/organization/costs` + `.../usage/completions` |
| Output | `primary_window` / `secondary_window` (used %, reset) | costo USD/giorno + token per modello |
| Default abilitato | sì (`defaultEnabled: true`, primario) | no (`defaultEnabled: false`) |
| Fallback | CLI (`codex app-server` RPC) + web dashboard | balance legacy (`credit_grants`) |

Per ClaudeBar v1 proponiamo **due provider separati** (come CodexBar), che è la stessa
dualità "abbonamento → finestre" / "API → usage+costo" già prevista nel BRIEF. Il path
plan-limits è 1:1 con la UX Claude attuale; il path API riusa lo snapshot cost/usage.

---

## 1. CODEX (abbonamento ChatGPT / Codex plan)

### 1.1 Endpoint usage (OAuth)

File: `Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift`

- **Base URL default**: `https://chatgpt.com/backend-api/`
- **Path**:
  - se la base contiene `/backend-api` → `…/wham/usage`  → URL completa
    **`https://chatgpt.com/backend-api/wham/usage`**
  - altrimenti (base custom Codex self-host) → `…/api/codex/usage`
- **Override**: la base può essere ridefinita da `chatgpt_base_url` in `~/.codex/config.toml`
  (oppure `CODEX_HOME/config.toml`). `chatgpt.com`/`chat.openai.com` senza `/backend-api`
  vengono normalizzate aggiungendolo.
- **Metodo**: `GET`, timeout 30s.
- **Header**:
  - `Authorization: Bearer <accessToken>`
  - `User-Agent: CodexBar` (noi → `ClaudeBar`)
  - `Accept: application/json`
  - `ChatGPT-Account-Id: <accountId>` (solo se `accountId` presente — multi-account workspace)
- **Status handling**: 200–299 decode; 401/403 → `unauthorized` ("token scaduto, rilancia
  `codex` per ri-autenticare"); altri → `serverError(code, body)`.

### 1.2 Shape risposta usage (`CodexUsageResponse`)

File: `Providers/Codex/CodexOAuth/CodexOAuthCredentials.swift` (il modello vive lì).

```jsonc
{
  "plan_type": "pro",                 // guest|free|go|plus|pro|team|business|enterprise|edu|...
  "rate_limit": {
    "primary_window":   { "used_percent": 42, "reset_at": 1717250000, "limit_window_seconds": 18000 },
    "secondary_window": { "used_percent": 71, "reset_at": 1717700000, "limit_window_seconds": 604800 }
  },
  "credits": { "has_credits": true, "unlimited": false, "balance": 12.50 },
  "additional_rate_limits": [          // limiti per-modello opzionali (es. Codex Spark)
    { "limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "...",
      "rate_limit": { "primary_window": {…}, "secondary_window": {…} } }
  ]
}
```

Punti chiave del mapping (`CodexReconciledState.swift`, `CodexRateWindowNormalizer.swift`):

- `primary_window` → **sessione** (analogo della finestra 5h di Claude); `limit_window_seconds`
  tipicamente 18000 (5h).
- `secondary_window` → **settimanale** (`limit_window_seconds` ~604800 = 7g).
- `used_percent` è **% USATA** intera (0–100) — **stessa semantica di Claude** (più alto = più
  rosso). Si mappa direttamente su `utilization`.
- `reset_at` è **epoch seconds** (non ISO8601 come Claude) → `Date(timeIntervalSince1970:)`.
- `additional_rate_limits[]` → finestre extra nominate (`NamedRateWindow`), supplementari: non
  "resuscitano" mai uno snapshot da sole (se primary+secondary sono entrambi nil, lo snapshot è
  nil). Decodifica **lossy per-elemento**: una entry malformata non scarta le sorelle valide.
- `credits` → `CreditsSnapshot` (balance pay-as-you-go). Mostrato solo se `balance != nil`.
- Tutta la decodifica è **difensiva**: `try?` su ogni campo; un `rate_limit` rotto non fa fallire
  l'intera risposta (si tiene traccia di `primaryWindowDecodeFailed`).
- **Plan / email** vengono risolti da `plan_type` o, in fallback, dal **JWT id_token**
  (`https://api.openai.com/auth.chatgpt_plan_type`, `…/profile.email`). Vedi
  `CodexReconciledState.resolvePlan/resolveAccountEmail`.

### 1.3 Auth: credenziali OAuth

File: `Providers/Codex/CodexOAuth/CodexOAuthCredentials.swift` + `CodexHomeScope.swift`

- **Sorgente**: file **`~/.codex/auth.json`** (oppure `$CODEX_HOME/auth.json`).
  > NB: CodexBar legge Codex da **file**, non dal Keychain (a differenza di Claude su macOS,
  > che usa il Keychain `Claude Code-credentials`). Codex CLI salva i token in chiaro in
  > `auth.json`. Per ClaudeBar **non** dobbiamo scriverci segreti nostri; se rinnoviamo un
  > token noi, va in Keychain (vincolo BRIEF), non sul file della CLI.
- **Shape `auth.json`**:
  ```jsonc
  {
    "OPENAI_API_KEY": "sk-…",          // caso "API key mode": se presente, usato come accessToken
    "tokens": {
      "access_token":  "…",
      "refresh_token": "…",
      "id_token":      "…",            // JWT con email + plan
      "account_id":    "…"             // → header ChatGPT-Account-Id
    },
    "last_refresh": "2026-05-01T10:00:00.000Z"   // ISO8601 (con o senza frazioni)
  }
  ```
- `needsRefresh`: vero se `last_refresh` manca o è più vecchio di **8 giorni**.
- Decodifica robusta: accetta sia snake_case (`access_token`) che camelCase (`accessToken`).

### 1.4 Refresh token

File: `Providers/Codex/CodexOAuth/CodexTokenRefresher.swift`

- **Endpoint**: `POST https://auth.openai.com/oauth/token`
- **client_id**: `app_EMoamEEZ73f0CkXaXp7hrann` (costante hardcoded del client Codex CLI)
- **Body JSON**: `{ client_id, grant_type: "refresh_token", refresh_token, scope: "openid profile email" }`
- **Risposta**: `access_token`, `refresh_token` (rotante), `id_token`. Se un campo manca si
  tiene il precedente. Aggiorna `last_refresh = now`.
- **Errori mappati** dal body: `refresh_token_expired`→expired, `refresh_token_reused`→reused,
  `invalid_grant`/`refresh_token_invalidated`→revoked; HTTP 401→expired.
- **Regola "non rubare il refresh alla CLI"** (analoga a Claude): CodexBar **scrive** il token
  rinnovato in `auth.json` (`CodexOAuthCredentialsStore.save`). Per ClaudeBar valuteremo se
  rinnovare noi (rischiando di invalidare il refresh-token rotante della CLI) o se ri-leggere
  `auth.json` sperando che la CLI abbia già rinnovato — **stessa scelta già fatta per Claude**
  (`resolveFreshCredentials`: owner `.claudeCLI` → re-read, niente refresh nostro). Consiglio:
  replicare la policy Claude (default = delega alla CLI; refresh nostro solo se owner siamo noi).

### 1.5 Fallback CLI e web (out of scope per MVP)

Il descriptor Codex (`CodexProviderDescriptor.swift`) prevede 3 strategie in `auto`:
`[web, oauth, cli]` (CLI runtime) o `[oauth, cli]` (app). Per il **nostro MVP** proponiamo
**solo OAuth** (`auth.json` → usage API), che copre il caso reale e non richiede di lanciare
`codex app-server` (RPC PTY) né scraping web dashboard. CLI/web restano possibili estensioni
future ma sono invasive (spawn di processi) → fuori MVP, coerente col BRIEF (cookie/CLI = stretch).

---

## 2. OPENAI (API a consumo — Admin/usage API)

### 2.1 Endpoint usage + costo

File: `Providers/OpenAI/OpenAIAPIUsageFetcher.swift`

Due endpoint Organization (richiedono **Admin API key**, `sk-admin-…`):

1. **Costi**: `GET https://api.openai.com/v1/organization/costs`
   - query: `start_time`, `end_time` (epoch s), `bucket_width=1d`, `limit`, `group_by=line_item`
2. **Usage completions** (token): `GET https://api.openai.com/v1/organization/usage/completions`
   - query: come sopra + `group_by=model`

Comune:
- Header: `Authorization: Bearer <apiKey>`, `Accept: application/json`, timeout 20s.
- `project_ids=<projectID>` opzionale (filtro per progetto).
- **Paginazione per chunk**: l'API limita i daily-bucket a **31** per chiamata
  (`maxDailyBucketLimit`). Per `historyDays=30` basta una chiamata; per range più lunghi
  si spezza in finestre da ≤31 giorni. Calendario **UTC** (`en_US_POSIX`, GMT+0).
- Retry: `ProviderHTTPRetryPolicy.transientIdempotent` (le GET sono idempotenti).

### 2.2 Shape risposte API

File: `Providers/OpenAI/OpenAIAPIUsageResponses.swift`

**Costs** (`/organization/costs`):
```jsonc
{ "data": [
  { "start_time": 1717200000, "end_time": 1717286400,
    "results": [ { "amount": { "value": 1.2345, "currency": "usd" }, "line_item": "gpt-4o" } ] }
]}
```
- `amount.value` è **flessibile**: numero o stringa numerica (`decodeFlexibleDoubleIfPresent`).
- `line_item` = voce di costo (modello/feature); usato per breakdown costo.

**Usage completions** (`/organization/usage/completions`):
```jsonc
{ "data": [
  { "start_time": 1717200000, "end_time": 1717286400,
    "results": [ {
      "input_tokens": 1000, "input_cached_tokens": 200, "input_audio_tokens": 0,
      "output_tokens": 500, "output_audio_tokens": 0,
      "num_model_requests": 12, "model": "gpt-4o" } ] }
]}
```

### 2.3 Aggregazione → snapshot

File: `OpenAIAPIUsageFetcher.makeSnapshot` + `OpenAIAPIUsageSnapshot.swift`

- I bucket costi e completions sono **uniti per `start_time`** (stesso giorno) in un
  `DailyBucket` (`day` YYYY-MM-DD, costUSD, requests, input/cached/output/total tokens,
  `lineItems[]`, `models[]`).
- `totalTokens = input + output + audioInput + audioOutput` (cached non sommato al totale,
  tracciato a parte).
- Lo snapshot espone derivati comodi: `last7Days`, `last30Days`, `latestDay` (Summary),
  `topModels`, `topLineItems`, `historyWindowLabel`.
- `toUsageSnapshot()` → finestre **nil** (niente plan-limits), `providerCost` valorizzato
  (used = costo periodo, limit = 0 = nessun cap), più il payload ricco `openAIAPIUsage`.
- `identity.loginMethod = "Admin API"` (o `"Admin API: <projectID>"`).

### 2.4 Credito / balance residuo (legacy fallback)

File: `Providers/OpenAI/OpenAIAPICreditBalanceFetcher.swift`

- **Endpoint**: `GET https://api.openai.com/v1/dashboard/billing/credit_grants`
- Risposta: `total_granted`, `total_used`, `total_available`, `grants.data[].{grant_amount,used_amount,expires_at}`.
- `expires_at` epoch seconds (`dateDecodingStrategy = .secondsSince1970`); `nextGrantExpiry` =
  prossima scadenza futura.
- `toUsageSnapshot()` → `primary` window con `usedPercent = used/granted*100` + `providerCost`
  (used/limit = used/granted, period "API credits"). Utile per **key personali/legacy**.
- **403** → questo endpoint **non** funziona con project key (solo legacy/user key con accesso
  billing). CodexBar lo usa solo come **fallback** quando le organization API falliscono o quando
  la key non è Admin (`allowsLegacyBalanceFallback = projectID == nil || !usesAdminKey`).

### 2.5 Auth: API key + project ID

File: `Providers/OpenAI/OpenAIAPISettingsReader.swift` + descriptor

- **Variabili d'ambiente** (priorità): `OPENAI_ADMIN_KEY` > `OPENAI_API_KEY`; `OPENAI_PROJECT_ID`.
- `cleaned()` rimuove virgolette e spazi.
- **Selezione credenziale** (`OpenAIAPIUsageCredential`):
  - Admin key presente → la usa, `usesAdminKey = true` → organization usage API (full).
  - solo API key normale → `usesAdminKey = false` → solo balance legacy disponibile.
  - nessuna → `nil` (provider non disponibile / `missingToken`).
- **Per ClaudeBar (vincolo BRIEF)**: la key **deve stare in Keychain**, non solo in env.
  → l'env è solo override debug/test; la fonte di verità è il Keychain (vedi §4).

---

## 3. Distinzione plan-limits vs API-cost (modello unificato)

CodexBar unifica tutto in `UsageSnapshot` con campi **opzionali**:
- `primary` / `secondary` / `extraRateWindows` → **finestre** (plan-limits, famiglia abbonamento).
- `providerCost: ProviderCostSnapshot?` → **costo** (used/limit/currency/period/resetsAt).
- `openAIAPIUsage: OpenAIAPIUsageSnapshot?` → payload ricco per il pannello "API".
- `credits: CreditsSnapshot?` → balance pay-as-you-go.
- `identity: ProviderIdentitySnapshot?` → email/plan/loginMethod per l'header.

Questo è **esattamente** il "modello snapshot unificato" del BRIEF (§Modello concettuale).
La UI sceglie il layout: se ci sono `primary/secondary` → vista finestre+pace (UX Claude);
se c'è solo `providerCost`/`openAIAPIUsage` → vista usage+costo.

**Allineamento con ClaudeBar attuale**: oggi `LimitsSnapshot` ha `fiveHour`/`sevenDay`
(+opus/sonnet/extra) con `utilization` (% usata) e pace. La mappatura Codex è diretta:
`primary_window → fiveHour`, `secondary_window → sevenDay`, `used_percent → utilization`,
`reset_at(epoch) → resetsAt`. Quindi **Codex plan-limits riusa il PaceCalculator e l'anello
esistenti senza modifiche concettuali**. L'unica novità è la famiglia "API a consumo", che
richiede un secondo tipo di snapshot/vista (cost/usage) — da progettare con l'architetto.

---

## 4. Auth & Keychain — proposta per ClaudeBar

| Provider | Sorgente reale (CodexBar) | Proposta ClaudeBar |
|---|---|---|
| Codex (OAuth) | `~/.codex/auth.json` (file in chiaro) | Leggere `auth.json` (come CodexBar). Token rinnovati da **noi** → Keychain. Default: **delega refresh alla CLI** (policy Claude). |
| OpenAI (API) | env `OPENAI_ADMIN_KEY`/`OPENAI_API_KEY` | **API key in Keychain** (item dedicato, es. service `ClaudeBar OpenAI API key`), env solo override debug. |

Riuso del codice ClaudeBar esistente:
- `KeychainReader` (pattern no-UI per timer / prompt su azione utente) è generalizzabile al
  salvataggio/lettura della API key OpenAI: serve un piccolo store read/write (oggi `KeychainReader`
  è read-only su un service fisso Claude). L'architetto definirà l'astrazione segreti
  (probabilmente un `SecretStore` con get/set per `providerID`).
- `ClaudeUsageEndpoint` / `ClaudeTokenRefresher` sono lo **stampo** per
  `CodexUsageEndpoint` / `CodexTokenRefresher` (struttura identica, cambiano URL/header/shape).

---

## 5. Cosa implementeremo in Fase B (proposta, in attesa interfacce congelate)

In `Sources/ClaudeBarCore/Providers/` (nomi indicativi, si adatteranno al protocollo `Provider`
che congelerà `provider-architect` — **NON** rinominerò le interfacce sue):

**Codex (abbonamento):**
1. `CodexOAuthCredentials` + store: legge `~/.codex/auth.json` (`$CODEX_HOME`), parse robusto,
   `needsRefresh` (8 giorni).
2. `CodexTokenRefresher`: `POST auth.openai.com/oauth/token`, client_id Codex, mapping errori.
3. `CodexUsageEndpoint`: `GET chatgpt.com/backend-api/wham/usage`, header Bearer +
   `ChatGPT-Account-Id`, decode `CodexUsageResponse` difensivo.
4. `CodexProvider` (conforme a `Provider`): orchestrazione load creds → (refresh/delega CLI) →
   GET usage → map `primary/secondary (+extra)` su snapshot finestre + `credits`. Riusa Pace.

**OpenAI (API a consumo):**
5. `OpenAIAPIUsageEndpoint`: GET `organization/costs` + `organization/usage/completions`,
   chunking ≤31 giorni, calendario UTC, aggregazione daily (cost + token per modello).
6. `OpenAIAPICreditBalance` (opzionale, fallback `credit_grants`).
7. `OpenAIAPIProvider` (conforme a `Provider`): API key da Keychain (+ projectID opzionale) →
   snapshot cost/usage (no finestre). Fallback balance per key legacy.

**Test (Swift Testing, niente rete reale):**
- Decode `CodexUsageResponse` (fixture JSON: primary+secondary, solo primary, additional limits
  lossy, credits, plan_type unknown, campi mancanti/malformati).
- Risoluzione URL usage (base default vs `chatgpt_base_url` da config.toml; normalizzazione).
- Parse `auth.json` (tokens snake/camel, OPENAI_API_KEY mode, last_refresh ISO con/senza frazioni,
  `needsRefresh`).
- Mapping `reset_at` epoch → `resetsAt`, `used_percent` → `utilization`.
- Refresh: mapping errori (expired/reused/revoked/401).
- OpenAI: aggregazione bucket (cost+completions stesso start_time), `last7/30Days`, top models,
  `amount.value` numero vs stringa, chunking ranges (>31 giorni), 403 balance.

**Rischi / note:**
- Endpoint `wham/usage` e `dashboard/billing/credit_grants` sono **non documentati ufficialmente**
  (reverse-engineering CodexBar): possono cambiare → decodifica difensiva obbligatoria, niente crash.
- Refresh-token Codex è **rotante**: rinnovarlo noi può invalidare la sessione della CLI → meglio
  delegare (come Claude). Da confermare col team-lead.
- Admin API key (`sk-admin-…`) è potente: serve UX chiara in Settings ("solo lettura usage").
  La 403 sulle organization API richiede una Admin key, non una project/user key.
- Decisione di prodotto aperta (per team-lead/utente): **un provider unico "OpenAI" con due
  modalità** o **due provider separati Codex + OpenAI** (come CodexBar). Raccomando i due
  separati: rispecchiano la dualità abbonamento/API del BRIEF e tengono i descriptor semplici.
