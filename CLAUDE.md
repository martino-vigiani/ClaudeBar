# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Cos'è

ClaudeBar — menu bar app macOS 26+ (Tahoe) per monitorare limiti e usage di provider AI
(Claude/Max è il default; anche Codex, Gemini, Cursor, Anthropic API, OpenAI API). Glance-first:
l'icona nella status bar dà a colpo d'occhio lo stato dei limiti (verde→ambra→rosso); al click si
apre un pannello Liquid Glass con dettaglio limiti + analytics locali.

Stack: Swift 6.2, SPM puro, **zero dipendenze esterne**, StrictConcurrency. AppKit (NSStatusItem,
NSPanel) + SwiftUI (pannello) + Swift Charts + Observation. Lingua del codice/commenti: italiano.

## Comandi

```bash
swift build                       # build debug della libreria + eseguibili (richiede toolchain Swift 6.2 + SDK macOS 26)
swift build -c release            # build release
swift test                        # tutti i test (framework Swift Testing)
swift test --filter <regex>       # singola suite/test, es. --filter PaceCalculatorTests
Scripts/bundle.sh                 # impacchetta in ./ClaudeBar.app nella root (release di default; gitignored: *.app)
CLBAR_CONFIG=debug Scripts/bundle.sh   # bundle debug → bundle id .debug, istanza separata
Scripts/run.sh                    # dev loop: build debug + bundle + open (uccide l'istanza precedente)

swift run ClaudeBarCLI            # dev-tool: indicizza ~/.claude/projects e stampa l'AnalyticsReport
swift run ClaudeBarCLI --json     # report in JSON
swift run ClaudeBarCLI --limits   # fetch limiti ufficiali (Keychain + OAuth)
```

Il CLI è un dev-tool interno per validare il parser/costi (vs `ccusage` / `claude /usage`);
**non** è incluso nel bundle distribuito.

## Architettura

Tre target SPM con confine netto (`Package.swift`):

- **ClaudeBarCore** — libreria pura, **NON importa AppKit/SwiftUI**. Value type `Sendable`,
  servizi limiti (OAuth/Keychain), parser incrementale `.jsonl`, pricing, Pace, provider.
- **ClaudeBarApp** — eseguibile `@main` (AppKit + SwiftUI). **Non parsa né fa IO di rete
  direttamente**: delega tutto al Core.
- **ClaudeBarCLI** — dev-tool, non distribuito.

Questi due vincoli di confine sono la regola architetturale centrale: rispettarli.

### Flusso runtime

- **Composition root** = `AppDelegate.applicationDidFinishLaunching` (App/AppDelegate.swift):
  costruisce il grafo dipendenze, crea il `ProviderRegistry`, installa lo `StatusItemController`,
  avvia `FileWatcher` + `RefreshScheduler`, fa il bootstrap dell'`AppModel`.
- **`AppModel`** (`@Observable @MainActor`, State/AppModel.swift) è l'**unica fonte di verità** per
  la UI. Coordina i servizi via protocolli di confine (`LimitsServicing`/`TranscriptIndexing`/
  `PersistenceServicing`), pubblica `status`/`glanceSpec`/`limits`/`activeSnapshot`/`analytics`.
  Non parsa né fa rete: coordina e basta.
- **Status bar**: `NSStatusItem` con icona disegnata a mano (Core Graphics, StatusItem/). Al click
  un `NSPanel` borderless ospita una `NSHostingView` SwiftUI Liquid Glass (Panel/). La view è
  generica sul protocollo presentazionale; `AppModelPanelAdapter` traduce l'`AppModel` nei VM UI.
- **Analytics**: parsing **incrementale** dei transcript `.jsonl` (mai re-scan completo). Indice +
  checkpoint persistiti su disco (`TranscriptIndexer`, `IncrementalIndex`, Persistence/). Cache
  binaria in Application Support → primo paint istantaneo anche offline.
- **`FileWatcher`** (DispatchSource vnode) su `~/.claude/projects`, debounce ~2s → ingest delta.
  **`RefreshScheduler`** (Watch/) fa il fetch limiti su timer (no-UI Keychain), intervallo
  configurabile.
- **`SettingsStore`** (`@Observable`, su UserDefaults) persiste `MultiProviderSettings` come JSON.

### Astrazione multi-provider (Sources/ClaudeBarCore/Providers/)

Pattern preso da CodexBar ma semplificato. **Le firme pubbliche in `Providers/` sono CONGELATE:
cambi solo additivi, mai rinominare** (vedi `docs/plan/mp/01-architecture.md`).

- `Provider` (protocollo) espone un `descriptor` e una pipeline di `ProviderFetchStrategy` con
  ordine + fallback su errori non terminali. `snapshot(context:)` di default esegue la pipeline.
- `ProviderSnapshot` è lo **snapshot unificato e generico**: `windows[]` (limiti, riusa
  `UsageWindow`) + `cost?` + `credits?`. La UI sceglie il layout dal **contenuto** dello snapshot,
  non dall'id del provider. Espone i derivati `mostCriticalWindow` / `glance` / `isStale`.
- `ProviderRegistry` è un **value type immutabile** costruito al boot (niente stato globale/macro).
  `ProviderID` è un enum chiuso di 6 casi. `applyingAutoDetect(to:context:)` riempie SOLO i provider
  mai configurati (non sovrascrive le scelte manuali); usare questo al boot, non `autoDetectDefault`.
- **Claude resta il default e la sua UX non regredisce**: `ClaudeProvider` **avvolge** l'attore
  `ClaudeLimitsService` esistente senza riscriverlo (regole "non rubare il refresh alla CLI",
  no-UI in background, gate 429 locale, cache in memoria — tutte intatte e testate).
- `ProviderFetchContext.userInitiated`: `true` → il Keychain può mostrare il prompt (apertura
  pannello / Refresh manuale); `false` (timer/boot) → query no-UI, nessun prompt.

### Segreti e Keychain

- Le API key inserite dall'utente vanno SEMPRE in Keychain via `ProviderSecretStore`/
  `KeychainSecretStore` (service `com.subralabs.claudebar.secret.<provider>`). Mai su disco in chiaro.
- La lettura delle credenziali OAuth **altrui** (Claude Code) è separata, in `KeychainReader`
  (service `"Claude Code-credentials"`, regola no-UI). Le due cose non si toccano.
- **Firma stabile** (`bundle.sh`): di default firma con la prima identità di codesigning valida, così
  il permesso Keychain "Always Allow" PERSISTE tra le ricompilazioni. La firma ad-hoc (`CLBAR_SIGN=1`)
  cambia a ogni build → il Keychain ri-chiede la password.

## Convenzioni e trappole

- **Concorrenza Swift 6 strict**: tipi di confine value-type `Sendable`; gli unici reference type
  sono attori (`ClaudeLimitsService`) o `@unchecked Sendable` con lock. Il callback di progress
  dell'indexer (off-main) fa hop sul MainActor via un relay Sendable.
- **Rebrand a costo zero**: i path su disco (Application Support, UserDefaults) derivano dal **bundle
  id**, non dal display name. `bundle.sh` accetta override via env (`CLBAR_DISPLAY_NAME`,
  `CLBAR_BUNDLE_ID`, `CLBAR_VERSION`, …). La build debug usa bundle id `.debug` = istanza separata.
- **Test**: Swift Testing (`@Suite`/`@Test`/`#expect`/`#require`), non XCTest. Il tag `.networking`
  marca i test che esercitano il livello rete (sempre mockato, mai live).
- **`.reference/CodexBar/`** è il repo upstream di riferimento, **READ-ONLY, gitignored, NON parte
  del progetto**. Consultalo per capire come CodexBar ottiene i dati, non modificarlo.

## Documentazione

`docs/plan/` contiene le decisioni di prodotto e architettura. Autorevoli: **`BRIEF.md`**
(contesto + decisioni prese) e **`DECISIONS.md`** (decisioni finali bloccate dall'utente — hanno
priorità in caso di conflitto con gli altri doc). `docs/plan/mp/` documenta l'astrazione
multi-provider. Non rimettere in discussione le decisioni già prese in questi file.
