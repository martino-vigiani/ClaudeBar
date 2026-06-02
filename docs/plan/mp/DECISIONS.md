# Multi-Provider — DECISIONI FINALI (fa fede)

> Priorità su BRIEF.md e sui doc di analisi. Decise dall'utente al checkpoint (giu 2026).

## Display
- **UN solo provider attivo nella menu bar** (un anello colorato, default Claude) **+ SWITCHER**
  nel pannello e/o Impostazioni per cambiare provider attivo. **NON** più icone/più item nella barra.
- Auto-detect dei provider disponibili; **default = Claude (vista abbonamento/limiti)**, la UX attuale, che NON deve regredire.
- Il pannello sceglie il layout in base allo snapshot del provider attivo:
  - provider "a limiti" (Claude, Codex, Gemini, Cursor) → layout anelli + Pace (come oggi);
  - provider "a consumo" (OpenAI API, Anthropic API) → layout usage + costo (niente anelli limite).

## Provider v1 — TUTTI inclusi
1. **Claude** (esistente, default) — OAuth Keychain.
2. **Codex** (piano ChatGPT) — OAuth da `~/.codex/auth.json`, `wham/usage` (primary/secondary, used_percent+reset) → mappa sul layout limiti. Refresh **delegato alla CLI** (non rubare il refresh rotante), come Claude.
3. **Gemini** — OAuth della **Gemini CLI** (`~/.gemini/oauth_creds.json`), quote giornaliere per-modello (layout limiti). Se la CLI non c'è → provider "configurabile, nessun dato" (degrada con grazia). API key NON usata in v1.
4. **Cursor** — **cookie di sessione incollato manualmente** dall'utente, salvato in **Keychain** (zero dipendenze, niente SweetCookieKit). Endpoint web come CodexBar (`/api/usage-summary`). Auto-import cookie = post-MVP.
5. **API a consumo (OpenAI + Anthropic)** — usage+costo via **Admin key di account ORG**, inserita nelle Impostazioni e salvata in **Keychain**. Se l'utente non ha Admin key org / risposta 401-403 → mostrare il provider con **avviso chiaro** ("richiede Admin key org"), NON nascondere silenziosamente, NON crashare. Single-account per provider in v1 (multi = post-MVP).

## Trasversali
- **Segreti SEMPRE in Keychain**, item dedicati nostri (es. `ClaudeBar.apikey.<provider>`, `ClaudeBar.cookie.cursor`), `AccessibleAfterFirstUnlockThisDeviceOnly`, no iCloud. Item creati da noi → niente prompt macOS in lettura.
- **Vetro NEUTRO**, design coerente col DesignSystem esistente. macOS 26, SPM, zero dipendenze esterne, StrictConcurrency.
- **NON regredire** il path Claude né i 45 test. Aggiungere test per i nuovi provider.
- Interfacce pubbliche dell'astrazione: **congelate dall'architetto**, niente rinomine in parallelo.
- Window kind GENERICO (non solo Claude): es. session/weekly/daily/billingCycle/perModelCap. Tipo costo unificato condiviso.

## Impostazioni (da creare, settings-ui-engineer)
- Elenco provider con enable/disable, stato auth (connesso / serve config), e azione di config:
  Claude/Codex/Gemini = "rilevato dalla CLI/OAuth"; Cursor = campo "incolla cookie"; OpenAI/Anthropic = campo "Admin API key".
- Scelta del **provider attivo** (default Claude) e auto-detect.
- Resta tutto opzionale: se l'utente non tocca nulla, vede Claude come oggi.

## Addendum — arbitrati dopo il congelamento interfacce (giu 2026)
Realtà degli endpoint (da ricerca) > assunzioni del brief. Correzioni ADDITIVE ai descriptor (niente rinomine):
- **Gemini = auth OAuth della Gemini CLI → snapshot a LIMITI** (windows[]: quote per-modello, finestre giornaliere). NON "API key costOnly" (la API key Google AI Studio non espone usage/costo). Se la CLI manca → degrada ("configurato, nessun dato"). Il descriptor Gemini va corretto: `hasUsageLimits`, auth CLI/OAuth (additivo).
- **Cursor = auth cookie di sessione (Keychain) → snapshot a LIMITI** (windows[]). Aggiungere `authKind` per il cookie (es. `.browserCookie`, additivo) al descriptor Cursor.
- **L'icona della barra segue il PROVIDER ATTIVO** (default = Claude), non un "default" separato. Cambi provider → cambia l'anello.
- **Auto-detect riempie solo i vuoti**, NON sovrascrive le scelte manuali dell'utente.
- **Il campo "incolla cookie" (Cursor) È nell'MVP UI** (cookie-auth incluso, ma SOLO per Cursor). Per gli altri: API key (OpenAI/Anthropic) o OAuth/CLI (Claude/Codex/Gemini).
- **Multi-account/multi-key = post-MVP.** Switcher mostrato solo se ≥2 provider abilitati (con 1 solo → identico a oggi).
- **Vista "costo locale dai log" anche per Codex/altri** (riuso del parser .jsonl/log locali) = post-MVP nice-to-have, NON ora.
