# Provider Gemini + Cursor — studio CodexBar (FASE A)

> Autore: `gemini-cursor-engineer` (task #13). Riferimento READ-ONLY:
> `.reference/CodexBar/Sources/CodexBarCore/Providers/{Gemini,Cursor}/`.
> Scopo: documentare come CodexBar recupera usage per Gemini e Cursor (endpoint reali,
> auth, shape della risposta, mapping nel modello unificato) così che, una volta
> CONGELATO il protocollo `Provider` dall'architetto, l'implementazione in
> `ClaudeBarCore/Providers/` sia rapida e fedele.

---

## 0. TL;DR / scoperte chiave (da portare al team-lead)

- **Gemini in CodexBar NON usa l'API key**: usa **OAuth Google** (le credenziali della
  Gemini CLI: `~/.gemini/oauth_creds.json`) verso le **Cloud Code Private API**
  (`cloudcode-pa.googleapis.com`). La auth "API key" è ESPLICITAMENTE bloccata
  (`unsupportedAuthType("API key")`), idem Vertex AI. Quindi quanto chiede il BRIEF
  ("Gemini API key usage/costo") **non è coperto da CodexBar** e va deciso: vedi §3.
- **Cursor in CodexBar NON usa API key né OAuth ufficiale**: usa i **cookie di sessione del
  browser** (`cursor.com`) per chiamare endpoint web non documentati
  (`/api/usage-summary`, `/api/auth/me`, `/api/usage`). È esattamente il caso
  "cookie-auth = stretch/invasivo" segnalato nel BRIEF. Non esiste un'API key Cursor.
- Entrambi mappano su un modello unificato `UsageSnapshot { primary, secondary, tertiary,
  providerCost?, ... }` con `RateWindow { usedPercent, windowMinutes?, resetsAt?, ... }`.
  Nel NOSTRO core l'equivalente è `LimitsSnapshot`/`UsageWindow` (vedi §5 per il mapping).
- **Conseguenza di prodotto (serve decisione lead/utente)**:
  - Gemini: o (A) riusiamo l'OAuth della Gemini CLI come CodexBar (no API key, ma copre il
    caso "abbonamento/quota giornaliera"), oppure (B) implementiamo davvero la **API key a
    consumo** via Google Cloud Monitoring/Billing (più lavoro, vedi §3.B) — o entrambi.
  - Cursor: senza cookie-auth **non c'è modo** di leggere l'usage del piano. O accettiamo il
    cookie-import (stretch), o Cursor resta fuori dall'MVP. Vedi §4.

---

## 1. Gemini — come CodexBar lo gestisce

### 1.1 File
- `Providers/Gemini/GeminiProviderDescriptor.swift` — descriptor + strategy.
- `Providers/Gemini/GeminiStatusProbe.swift` — fetch, refresh token, parsing.
- `Providers/Gemini/GeminiStatusProbe+DataLoader.swift` — data loader URLSession + fallback `curl`.

### 1.2 Auth (OAuth della Gemini CLI, NON API key)
- Le credenziali stanno su disco in chiaro: `~/.gemini/oauth_creds.json`
  (`access_token`, `id_token`, `refresh_token`, `expiry_date` in ms). Lette, NON in Keychain.
- Il tipo di auth viene letto da `~/.gemini/settings.json` → `security.auth.selectedType`:
  - `oauth-personal` o `unknown` → procede.
  - `api-key` → **errore `unsupportedAuthType`** (bloccato).
  - `vertex-ai` → **errore** (bloccato).
- **Refresh token**: se l'access token è scaduto, fa POST a
  `https://oauth2.googleapis.com/token` con `grant_type=refresh_token`. Il problema è che
  servono `client_id`/`client_secret` dell'app OAuth della CLI: CodexBar li **estrae dal
  sorgente JavaScript della Gemini CLI installata** (cerca `OAUTH_CLIENT_ID`/
  `OAUTH_CLIENT_SECRET` in `oauth2.js` del package `@google/gemini-cli`, con localizzazione
  Homebrew/npm/bun/Nix/fnm). Dopo il refresh riscrive `oauth_creds.json`.
  → **Fragile e invasivo** (dipende dal layout del pacchetto npm). Per noi: o riusiamo solo
  l'access token finché valido (no refresh "magico"), o accettiamo questa euristica.

### 1.3 Endpoint reali (Cloud Code Private API)
- Quota: `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
  - Header: `Authorization: Bearer <accessToken>`, `Content-Type: application/json`.
  - Body: `{"project": "<projectId>"}` (o `{}` se sconosciuto).
  - 401 → not logged in; 200 → JSON con `buckets`.
- Tier/progetto: `POST .../v1internal:loadCodeAssist`
  - Body: `{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}`.
  - Risposta usata per: `cloudaicompanionProject` (project id) e `currentTier.id`
    (`free-tier`/`legacy-tier`/`standard-tier`).
- Discovery progetto (fallback): `GET https://cloudresourcemanager.googleapis.com/v1/projects`
  — cerca un progetto con prefisso `gen-lang-client` o label `generative-language`.
- Account info: estratta dai claim JWT dell'`id_token` (`email`, `hd` = hosted domain →
  distingue Workspace vs free personale).

### 1.4 Shape risposta quota (`retrieveUserQuota`)
```json
{ "buckets": [
    { "modelId": "gemini-2.5-pro", "remainingFraction": 0.83,
      "resetTime": "2026-06-02T00:00:00Z", "tokenType": "..." },
    { "modelId": "gemini-2.5-flash", "remainingFraction": 0.97, "resetTime": "..." },
    ...
] }
```
- `remainingFraction` ∈ [0,1] = **frazione RIMANENTE** (non usata!). CodexBar fa
  `percentLeft = remainingFraction * 100`, poi `usedPercent = 100 - percentLeft`.
- Per ogni model id tiene il bucket col valore **più basso** (peggiore).
- Raggruppa i modelli in 3 famiglie e li mappa su finestre da 24h (`windowMinutes: 1440`):
  - **Pro** (`*pro*`) → `primary`
  - **Flash** (`*flash*` ma non flash-lite) → `secondary`
  - **Flash Lite** (`*flash-lite*`) → `tertiary`
- Plan label: `standard-tier`→"Paid", `free-tier`+`hd`→"Workspace", `free-tier`→"Free",
  `legacy-tier`→"Legacy".

### 1.5 Data loader
- `ProviderHTTPClient.shared.data(for:)` con **fallback a `curl`** se URLSession va in timeout
  (alcune reti corporate bloccano URLSession verso le Private API Google). Per noi: probabile
  non necessario nell'MVP; usare il transport iniettabile e basta.

---

## 2. Cursor — come CodexBar lo gestisce

### 2.1 File
- `Providers/Cursor/CursorProviderDescriptor.swift` — descriptor + strategy (`kind: .web`).
- `Providers/Cursor/CursorStatusProbe.swift` — cookie importer + probe + parsing.
- `Providers/Cursor/CursorRequestUsage.swift` — modello piani legacy (request-based).

### 2.2 Auth (cookie di sessione del browser → web API non documentata)
- Nessuna API key, nessun OAuth. CodexBar **importa i cookie di sessione** da Safari/Chrome/
  Firefox (libreria `SweetCookieKit`, dipendenza esterna) per i domini `cursor.com`,
  `www.cursor.com`, `cursor.sh`, `authenticator.cursor.sh`. Nomi cookie cercati:
  `WorkosCursorSessionToken`, `__Secure-next-auth.session-token`, `wos-session`,
  `authjs.session-token`, ecc.
- Ordine browser: **Safari prima** (le sessioni attive spesso vivono solo lì).
- Fallback: cookie header manuale (impostazioni), cache su disco (`CookieHeaderCache`),
  sessione salvata dal flow "Add Account" (`CursorSessionStore` → file JSON in App Support).
- Il cookie header viene passato come `Cookie:` raw alle richieste HTTP.

### 2.3 Endpoint reali (web, non documentati — base `https://cursor.com`)
- `GET /api/usage-summary` (Accept: application/json, Cookie: …) → `CursorUsageSummary`.
  - 401/403 → not logged in.
- `GET /api/auth/me` → `CursorUserInfo` (email, name, `sub` = user id).
- `GET /api/usage?user=<sub>` → `CursorUsageResponse` (solo **piani legacy request-based**;
  best-effort, `try?`).

### 2.4 Shape risposta (`/api/usage-summary`)
Tutti i valori monetari sono **in CENTESIMI** (es. `2000` = $20.00).
```jsonc
{
  "billingCycleStart": "ISO8601", "billingCycleEnd": "ISO8601",
  "membershipType": "pro" | "enterprise" | "hobby" | "team",
  "isUnlimited": false,
  "individualUsage": {
    "plan":   { "used": 2000, "limit": 2000, "autoPercentUsed": 36.0,
                "apiPercentUsed": 12.0, "totalPercentUsed": 48.0,
                "breakdown": { "included": …, "bonus": …, "total": … } },
    "onDemand": { "enabled": true, "used": 0, "limit": null, "remaining": null },
    "overall": { "used": 7384, "limit": 10000, "remaining": 2616 }  // cap personale team/enterprise
  },
  "teamUsage": {
    "onDemand": { "used": …, "limit": … },
    "pooled":   { "used": …, "limit": … }   // pool condiviso team
  }
}
```
- **Headline "Total"** (`planPercentUsed`), precedenza CodexBar:
  1. `plan.totalPercentUsed`
  2. media `autoPercentUsed`+`apiPercentUsed`
  3. una sola delle due lane
  4. ratio `plan.used/plan.limit`
  5. ratio `overall.used/overall.limit` (cap personale team/enterprise)
  6. ratio `pooled.used/pooled.limit` (ultima risorsa)
  - Tutti i percent sono clampati 0–100. NB: i campi percent sono **già in unità %**, anche
    quando < 1.0 (0.36 significa 0.36%, non 36%).
- Mapping su `UsageSnapshot`:
  - `primary` = Total (o, per piani legacy request-based, `requestsUsed/requestsLimit`).
  - `secondary` = Auto+Composer (`autoPercentUsed`).
  - `tertiary` = API named model (`apiPercentUsed`).
  - `providerCost` = on-demand in USD (`onDemandUsed/Limit`), period "Monthly",
    `resetsAt = billingCycleEnd`.
  - `cursorRequests` = solo piani legacy.
- `resetsAt` = `billingCycleEnd` (ISO8601). `membershipType` → "Cursor Pro"/"Enterprise"/…

### 2.5 Robustezza
- Scansiona più browser e più candidati cookie finché l'API accetta (i token Chrome possono
  essere stantii). `usage-summary` e `auth/me` in parallelo (`withThrowingTaskGroup`).

---

## 3. Gemini per ClaudeBar — opzioni e raccomandazione

Il BRIEF chiede "Gemini (API key usage/costo)" + segreti in Keychain. Realtà:

- **3.A — OAuth CLI (come CodexBar)**: copre la quota giornaliera per-modello (Pro/Flash/
  Flash-Lite). NIENTE API key, niente Keychain (le creds OAuth sono già su disco gestite
  dalla CLI). È un modello "quota/limiti" (24h), NON "costo a consumo". Pro: dati ricchi,
  rispecchia la UX limiti. Contro: dipende dalla Gemini CLI installata, refresh fragile.
- **3.B — API key a consumo (vero pay-as-you-go)**: la "Gemini API key" (Google AI Studio,
  `https://generativelanguage.googleapis.com`) **NON espone un endpoint usage/cost** per la
  key stessa. L'usage/costo reale di un progetto Google Cloud si legge da
  **Cloud Monitoring** (`monitoring.googleapis.com`, metriche
  `generativelanguage.googleapis.com/...`) o **Cloud Billing**, che richiedono OAuth/service
  account e setup non banale — sproporzionato per l'MVP. La API key servirebbe solo a
  *fare* richieste, non a leggerne l'usage.
- **3.C — niente costo, solo "validazione + modelli"**: con API key in Keychain potremmo solo
  validare la key (`GET /v1beta/models?key=…`) e mostrare "API key configurata", senza usage.

**Raccomandazione (da confermare al lead/utente)**: per l'MVP fare **3.A (OAuth CLI)** se
l'utente usa la Gemini CLI — è ciò che dà valore (quota giornaliera, UX limiti coerente con
Claude). Conservare la API key in Keychain come **opzionale** per uso futuro (3.B/3.C), ma
NON promettere usage/costo via API key in v1. Se l'utente NON usa la Gemini CLI, Gemini
degrada a "configurato, nessun dato".

### 3.1 Endpoint/shape da implementare (variante 3.A)
- Creds: `~/.gemini/oauth_creds.json` (access/refresh/id token, expiry ms).
- Quota: `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
  (Bearer + `{"project": …}`), parse `buckets[].{modelId, remainingFraction, resetTime}`.
- Tier/project: `POST .../v1internal:loadCodeAssist` (body GEMINI_CLI).
- `usedPercent = 100 - remainingFraction*100`; raggruppa Pro/Flash/Flash-Lite → 3 finestre 24h.
- Mapping al NOSTRO modello: vedi §5.

---

## 4. Cursor per ClaudeBar — opzioni e raccomandazione

- **4.A — cookie-import (come CodexBar)**: unico modo per leggere l'usage del piano. Richiede
  o una libreria di lettura cookie browser (CodexBar usa `SweetCookieKit`, dipendenza esterna
  — in conflitto col vincolo "zero dipendenze esterne se possibile" del BRIEF) o un nostro
  estrattore cookie (Safari `~/Library/Cookies` binarycookies + Chromium SQLite cifrato:
  molto lavoro, invasivo, prompt Full Disk Access / Safe Storage).
- **4.B — cookie header MANUALE**: l'utente incolla il proprio cookie header dalle DevTools del
  browser nelle Impostazioni; lo salviamo in Keychain. Niente lettura cookie browser, niente
  dipendenze, niente prompt FDA. Contro: UX manuale, scade quando il cookie scade.
- **4.C — fuori MVP**: Cursor non incluso in v1.

**Raccomandazione**: per l'MVP fare **4.B (cookie header manuale in Keychain)** — rispetta
"zero dipendenze" e "segreti in Keychain", è semplice, e gli endpoint/parsing sono identici a
CodexBar. L'auto-import dei cookie (4.A) resta stretch post-MVP. Se anche 4.B è troppo, Cursor
va in 4.C.

### 4.1 Endpoint/shape da implementare (variante 4.B)
- `GET https://cursor.com/api/usage-summary` con header `Cookie: <header manuale>`,
  `Accept: application/json`. 401/403 → not logged in. Parse `CursorUsageSummary` (§2.4).
- `GET https://cursor.com/api/auth/me` → email/name/sub (best-effort).
- (opz.) `GET /api/usage?user=<sub>` per piani legacy.
- Valori in **centesimi** → /100 per USD. Headline = precedenza §2.4. `resetsAt = billingCycleEnd`.

---

## 5. Mapping al modello dominio di ClaudeBar (CONTRATTO da rispettare)

> CodexBar usa `UsageSnapshot { primary/secondary/tertiary: RateWindow, providerCost?, ... }`.
> Il NOSTRO core (oggi solo-Claude) usa `LimitsSnapshot`/`UsageWindow` (`utilization` = % USATA,
> 0–100) + `PaceProjection`. L'astrazione `Provider` che l'architetto congelerà unificherà i
> due mondi. Finché non è congelata, ecco l'intenzione di mapping (da validare):

| Concetto CodexBar (`RateWindow.usedPercent`) | ClaudeBar (`UsageWindow.utilization`) |
|---|---|
| Gemini Pro (24h)        | finestra primaria, `kind` ~ generica/"giornaliera" |
| Gemini Flash (24h)      | finestra secondaria |
| Gemini Flash-Lite (24h) | finestra terziaria |
| Cursor Total (ciclo)    | finestra primaria, `resetsAt = billingCycleEnd` |
| Cursor Auto / API       | finestre secondaria/terziaria |
| Cursor on-demand USD    | sezione costo (analogo a `extraUsage` / costo) |

Punti aperti per l'architetto (da CONGELARE prima di FASE B):
1. `PaceWindowKind` oggi è hardcodato sui valori Claude (`fiveHour`, `sevenDay`, …). Serve un
   `kind` generico per finestre non-Claude (es. `daily`, `billingCycle`) o un campo
   `windowMinutes`/`label` libero come in `RateWindow`. **Decisione architetto.**
2. Famiglia "API a consumo / costo": serve un tipo costo unificato (analogo a
   `ProviderCostSnapshot { used, limit, currencyCode, period, resetsAt }`).
3. Identità account (email/plan) nel modello unificato.
4. Forma del protocollo `Provider` (async `fetch() -> ProviderSnapshot`?), auth injection,
   transport iniettabile (`URLProtocol`/closure) per i test.

---

## 6. Cosa serve per FASE B (implementazione)

Una volta CONGELATE le interfacce dall'architetto, implementerò in
`Sources/ClaudeBarCore/Providers/`:

- **`GeminiProvider`** (variante 3.A consigliata, salvo diversa decisione lead):
  - lettura `~/.gemini/oauth_creds.json`, refresh opzionale, `retrieveUserQuota` +
    `loadCodeAssist`, parsing buckets → finestre, mapping al modello unificato;
  - API key opzionale in **Keychain** (validazione/uso futuro), senza promettere usage v1;
  - transport iniettabile per i test (no rete nei test, fixture JSON dei buckets).
- **`CursorProvider`** (variante 4.B consigliata):
  - cookie header da **Keychain** (impostazioni), `usage-summary` + `auth/me` + (legacy)
    `usage`, parsing centesimi→USD, headline con precedenza §2.4, mapping al modello unificato;
  - transport iniettabile per i test (fixture JSON `usage-summary`).
- **Test** (Swift Testing): parsing/edge case (quota mancante, 401, piani team/enterprise,
  legacy request-based, valori percent < 1, billingCycleEnd nil), senza I/O di rete.
- Compilare spesso (`swift build`), non rompere i 45 test esistenti né il path Claude.

## 6bis. Implementazione realizzata (FASE B — task #13 + rework #17)

Conforme alle interfacce CONGELATE (`docs/plan/mp/01-architecture.md`). Niente rinomine.
DECISIONE FINALE UTENTE (DECISIONS.md §Addendum): **Gemini = OAuth della Gemini CLI → LIMITI**
(non più API key/costOnly: la key Google AI Studio non espone usage). Cursor = cookie → LIMITI.
Il primo giro Gemini (costOnly/API key) è stato sostituito dal rework #17 qui sotto.

File in `Sources/ClaudeBarCore/Providers/`:
- `Gemini/GeminiProvider.swift` — `GeminiProvider: Provider` (`hasUsageLimits`, `authKinds=[.oauthManaged]`)
  + `GeminiOAuthCredential` (disponibilità no-rete: legge `~/.gemini/oauth_creds.json` + auth type da
  `settings.json`; api-key/vertex-ai → non disponibile) + `GeminiOAuthStrategy`. `homeDirectory`
  iniettabile per i test.
- `Gemini/GeminiOAuthEndpoint.swift` — auth OAuth CLI + `POST :retrieveUserQuota` (Bearer,
  `{"project":…}`) + `POST :loadCodeAssist` (project id/tier) su `cloudcode-pa.googleapis.com`,
  parsing buckets (`remainingFraction`→`percentLeft`, peggiore per modello), claim JWT email/plan,
  loader iniettabile `GeminiOAuthDataLoader`. 401/403→unauthorized, 429→rateLimited. Token scaduto →
  unauthorized azionabile ("riapri la Gemini CLI"): in v1 NIENTE refresh "magico" (no estrazione
  client_id/secret dal JS della CLI, fragile/invasivo).
- `Gemini/GeminiUsageFetcher.swift` — `makeWindows` PURA: raggruppa Pro/Flash/Flash-Lite →
  3 finestre `utilization = 100 - percentLeft`, `customDurationMinutes = 1440` (quota giornaliera)
  + `label` ("Pro"/"Flash"/"Flash Lite"). Se la CLI manca → provider non disponibile (degrada
  "configurabile, nessun dato"). Il `kind` (`.fiveHour`) è solo un contenitore per abilitare il Pace;
  la durata reale è in `customDurationMinutes` (campo additivo pubblicato dall'architetto).
- `Cursor/CursorProvider.swift` — `CursorProvider: Provider`
  (`hasUsageLimits`+`hasCredits`, `authKinds=[.browserCookie]`) + `CursorCredential`
  (Keychain `.cursor` cookie header > env `CURSOR_COOKIE`) + `CursorCookieStrategy`.
- `Cursor/CursorUsageEndpoint.swift` — `GET /api/usage-summary` + `/api/auth/me`
  (loader iniettabile `CursorDataLoader`, header `Cookie:`), modelli decodabili (sottoinsieme
  CodexBar). 401/403→unauthorized.
- `Cursor/CursorUsageFetcher.swift` — `makeSnapshot` PURA: headline con precedenza §2.4,
  3 finestre con `label` ("Total"/"Auto"/"API") + `customDurationMinutes` = ciclo mensile (30g),
  on-demand (cents→USD) → `ProviderCredits`, identità best-effort. `kind` solo contenitore.

Aggiornato `Sources/ClaudeBarApp/Settings/ProviderCatalog.swift`: `.gemini`/`.cursor` ora delegano
ai descriptor REALI (`GeminiProvider().descriptor`/`CursorProvider().descriptor`).

Test: `Tests/ClaudeBarCoreTests/GeminiCursorProviderTests.swift` (18 test, loader iniettabile/funzioni
pure, niente rete). Suite intera: 147/147 verdi.

Note di conformità: la pipeline `Provider.snapshot` lancia un errore TERMINALE quando la credenziale
manca (`noAvailableStrategy`/`noCredentials`) — i test verificano `isTerminal`. Il window-kind
generico è stato RISOLTO dall'architetto in modo additivo su `UsageWindow`: i campi
`customDurationMinutes` (durata reale: 1440 per Gemini, ~mensile per Cursor) + `label` (testo libero:
"Pro"/"Flash"/… , "Total"/"Auto"/"API"). Il `kind` resta un contenitore per abilitare il Pace;
`effectiveDuration` usa la durata custom. Niente nuovi case in `PaceWindowKind` (i 4 Claude invariati).

## 7. Rischi
- **Gemini OAuth refresh** dipende dall'estrarre `client_id/secret` dal JS della CLI: fragile;
  per l'MVP valutare di usare solo l'access token valido e segnalare "rilancia `gemini`" se scaduto.
- **Cursor cookie scaduti**: il cookie manuale scade → stato "non loggato"; messaggio chiaro.
- **Endpoint Cursor non documentati**: possono cambiare senza preavviso (stessa fragilità che
  ha CodexBar). Difese: `try?`/decoding tollerante, badge "stale".
- **Vincolo zero-dipendenze**: evitare `SweetCookieKit`; preferire input manuale (4.B).
- **`PaceWindowKind` Claude-specifico**: blocca il mapping pulito finché l'architetto non lo
  generalizza (punto 1 §5).
