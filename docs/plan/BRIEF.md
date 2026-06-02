# ClaudeBar — Brief condiviso (contesto + decisioni)

> Leggi questo file PRIMA di iniziare. Contiene fatti verificati sul sistema e le
> decisioni di prodotto già prese dall'utente. Non ridiscuterle: usale.

## Cos'è ClaudeBar
Una menu bar app macOS, nativa, **dedicata esclusivamente a Claude** (Claude Code /
abbonamento Max). Ispirata a **CodexBar** di steipete (multi-provider) ma:
- **solo Claude**, fatta meglio, più curata, più scenica;
- **più precisa** (analytics locali ad alta fedeltà);
- **performance migliori** (parsing incrementale, niente re-scan completi).

Repo di riferimento (READ-ONLY, NON modificare): `.reference/CodexBar/`
Cartella principale upstream rilevante:
- `.reference/CodexBar/Sources/CodexBarCore/` (logica usage/providers)
- `.reference/CodexBar/Sources/CodexBarClaudeWebProbe/`, `.../CodexBarClaudeWatchdog/` (come ottengono i dati Claude)
- `.reference/CodexBar/Sources/CodexBar/` (app/UI)

## Decisioni di prodotto GIÀ PRESE (non rimetterle in discussione)
1. **Design**: Liquid Glass moderno (materiali macOS 26: vibrancy, glassEffect, traslucido) per il **pannello/popover**.
2. **MA il cuore è la menu bar**: l'item nella status bar deve dare una **prima impressione a colpo d'occhio, COLORATA**, dei limiti (es. anello/barra compatta verde→ambra→rosso sulla sessione). **Al click** si apre il pannello Liquid Glass con il dettaglio (limiti + analytics + grafici). Glance-first, dettaglio-on-tap.
3. **Scope**: **Limiti ufficiali + analytics locali profonde** (vedi sotto).
4. **Target**: **macOS 26+ (Tahoe)**. Possiamo usare le API più recenti (Liquid Glass, Swift Charts recenti, Observation, Swift 6 concurrency).
5. **Distribuzione**: uso personale per ora. Niente firma/notarizzazione/Homebrew/CI adesso (si aggiungono dopo). Build locale con `xcodebuild`.
6. **Stack**: Swift 6.2+, SwiftUI (+ AppKit dove serve per NSStatusItem), Swift Charts, Observation, async/await + actors.

## L'utente
Martino — sviluppatore Swift/iOS, preferisce la semplicità e il lavoro "polished"
(rifinito) al ping-pong. Estetica monocroma B/N nei suoi altri progetti (SubraCAD,
SubraGYM), ma qui ha scelto esplicitamente Liquid Glass + glance colorato nella barra.

## FONTI DATI VERIFICATE (fatti reali sul sistema dell'utente)

### A) Limiti ufficiali (sessione 5h + settimanale)
- **Keychain**: item `Claude Code-credentials` (generic password). Contiene JSON con
  chiave `claudeAiOauth`:
  ```json
  { "accessToken": "...", "refreshToken": "...", "expiresAt": <ms>,
    "scopes": [...], "subscriptionType": "max", "rateLimitTier": "..." }
  ```
  Lettura: `security find-generic-password -s "Claude Code-credentials" -w` (o via
  Security.framework / SecItemCopyMatching). Esistono anche varianti
  `Claude Code-credentials-<hash>` (account multipli).
- Con `accessToken` (OAuth) si interroga l'endpoint usage di Anthropic per ottenere
  finestra **sessione (5h)** e **settimanale** con percentuali e reset.
  → DA REVERSE-ENGINEERARE l'endpoint esatto: studiare come fa CodexBar in
  `CodexBarCore`/`CodexBarClaudeWebProbe`. Gestire refresh del token con `refreshToken`
  quando `expiresAt` è passato.
- **Fallback "probe"**: CodexBar usa una home isolata
  `~/Library/Application Support/CodexBar/ClaudeProbe/.claude/` per lanciare la CLI
  `claude` e leggere `/usage` via PTY. Valutare se ci serve o se basta l'endpoint OAuth.

### B) Analytics locali profonde (il nostro vantaggio sulla precisione)
- Transcript in `~/.claude/projects/<encoded-cwd>/*.jsonl` (≈20 progetti, file anche grandi, es. history.jsonl 1.3MB; molti .jsonl per sessione).
- Ogni riga è un evento JSON. Le righe `type: assistant` hanno `message.usage`:
  ```json
  { "input_tokens": 6, "cache_creation_input_tokens": 42400,
    "cache_read_input_tokens": 0, "output_tokens": 1554,
    "cache_creation": { "ephemeral_1h_input_tokens": 42400, "ephemeral_5m_input_tokens": 0 },
    "service_tier": "standard" }
  ```
  Campi di riga utili: `message.model` (es. `claude-opus-4-7`), `timestamp` (ISO),
  `cwd`, `sessionId`, `gitBranch`, `version`, `requestId`, `uuid`.
- Da qui calcoliamo (stile `ccusage` ma nativo+live): **costo** (serve tabella prezzi per
  modello: input/output/cache-write-5m/cache-write-1h/cache-read), token totali,
  breakdown per **modello / progetto / sessione / giorno / branch**, **efficienza cache**,
  trend storici.
- ⚠️ Performance: NON ri-parsare tutto ogni refresh. Parsing **incrementale** (track per-file:
  size+mtime+offset, leggi solo i nuovi byte), watch via FSEvents/DispatchSource, aggregati
  cachati su disco. Dedup per `requestId`/`uuid` (i transcript possono avere righe duplicate).
- ⚠️ Prezzi: i modelli cambiano. Tenere una pricing table aggiornabile (anche locale/embedded
  con override). Attenzione a distinguere abbonamento (limiti) vs costo "teorico" API.

## Cosa rende ClaudeBar MIGLIORE di CodexBar (per Claude)
- Focus totale su Claude → UI dedicata, niente clutter multi-provider.
- Glance colorato nella barra + pannello Liquid Glass curato.
- Analytics locali precise e live (per-progetto, per-modello, cache, costo, storico).
- Parsing incrementale → CPU/RAM bassi, refresh istantanei.
- Notifiche intelligenti (avviso a soglia sessione, reset settimanale).

## Output atteso dalla fase di pianificazione
Ogni agente scrive il proprio doc in `docs/plan/` (vedi assegnazioni nei task). I doc
devono essere concreti e implementabili: file/moduli da creare, firme dei tipi
principali, diagrammi di flusso testuali, scelte tecniche motivate, rischi e fallback.
Niente codice di implementazione completo in questa fase (solo scheletri/firme dove utile).
