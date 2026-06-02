# ClaudeBar — Architettura app & strategia di performance

> Doc del task #2 (app-architect). Presuppone aver letto `BRIEF.md`.
> **`DECISIONS.md` (decisioni finali bloccate dall'utente) ha PRIORITÀ su questo doc** in caso di
> conflitto: questo file è stato riallineato a `DECISIONS.md` (icona anello+%, finestra più critica,
> vetro neutro, Pace&Forecast in MVP, notifiche 50/75/90, solo-OAuth, multi-account/widget post-MVP).
> Si allinea inoltre con `01-data-integration.md` (parser+OAuth) e `03-design.md` (UI).
> Niente codice di implementazione: solo scelte motivate, firme dei tipi, file/moduli.
> Guida per gli implementatori, in particolare `core-engineer` (Task C / #7: app shell).

---

## 0. TL;DR delle scelte

| Decisione | Scelta | Perché |
|---|---|---|
| Status bar | **NSStatusItem** con icona disegnata a mano (Core Graphics) | Controllo totale del glance colorato animabile; MenuBarExtra non permette un'icona template colorata custom con anello + animazione fluida |
| Pannello al click | **NSPanel borderless** (non-activating) che ospita una `NSHostingView` SwiftUI (Liquid Glass) | Allineato a `03-design.md`: per Liquid Glass `.regular` + Swift Charts + animazioni di morphing serve una window SwiftUI custom, non un NSMenu né l'NSPopover standard (raggio/ombra/becco non personalizzabili a sufficienza) |
| Lifecycle | **LSUIElement = true** (agent, niente Dock/menu bar app), `@NSApplicationDelegateAdaptor` | Menu bar app pura, nessuna finestra principale |
| Build system | **SPM puro** (`Package.swift`) + script `bundle.sh` che impacchetta in `.app` | Più snello del .xcodeproj, buildabile con `xcodebuild`/`swift build`, zero generatori esterni |
| Concorrenza | Swift 6 strict. **Actor** per i data store (off-main), **@Observable @MainActor** per i view-model, value types `Sendable` ai confini | Parsing/IO fuori dal main thread; UI sempre coerente sul main |
| File watching | **DispatchSource (vnode + directory) con coalescing**, fallback polling mtime | Più semplice e leggero di FSEvents per il nostro scope (una dir `~/.claude/projects`), zero dipendenze |
| Caching aggregati | Snapshot binario su disco in Application Support (Codable + checkpoint del parser) | Avvio istantaneo, niente re-scan completo al boot |
| Refresh limiti | Scheduler con intervallo selezionabile (Manual/1/2/5/15/30 min, default 5m) + on-demand all'apertura pannello | Rispetta i rate limit dell'endpoint, dati freschi quando servono |
| Settings | `UserDefaults` via `@Observable SettingsStore` | Pochi flag scalari, niente bisogno di file custom |
| Launch at login | **SMAppService.mainApp** | API moderna macOS 13+, già usata dall'upstream |

---

## 1. Moduli / target (SPM)

Tre target principali + due di supporto. Il confine è netto: **Core** non importa AppKit/SwiftUI;
**App** non parsa né fa IO di rete direttamente (delega al Core).

```
ClaudeBar (Package.swift, swift-tools-version 6.2, platforms: [.macOS(.v26)])
│
├── ClaudeBarCore            (library, NO AppKit/SwiftUI)
│   ├── Models/              value types Sendable (snapshot, rollup, window, pricing)
│   ├── Limits/              OAuth + Keychain + endpoint usage (5h/settimana)
│   ├── Analytics/           parser incrementale .jsonl + aggregazioni + pricing
│   ├── Persistence/         cache su disco (checkpoint parser + snapshot)
│   └── Util/                logging, date, path
│
├── ClaudeBarApp             (executableTarget, @main, AppKit + SwiftUI)
│   ├── App/                 lifecycle, AppDelegate, dependency wiring
│   ├── StatusItem/          NSStatusItem controller + IconRenderer (Core Graphics)
│   ├── Panel/               NSPopover + viste SwiftUI Liquid Glass
│   ├── State/               view-model @Observable @MainActor (AppModel)
│   ├── Watch/               file watcher DispatchSource + scheduler refresh
│   ├── Settings/            SettingsStore (@Observable) + finestra Preferenze
│   └── Resources/           Assets, Info.plist values
│
└── ClaudeBarCLI             (executableTarget, opzionale, dev-only)
    └── dump aggregati a terminale per debug/verifica del parser senza UI

Test:
├── ClaudeBarCoreTests       (Swift Testing — parser, dedup, pricing, OAuth parsing su fixtures)
└── ClaudeBarAppTests        (Swift Testing — icon rendering snapshot, scheduler, stato/errori)
```

### Perché SPM puro e non xcodegen/.xcodeproj

- **Snellezza**: un solo `Package.swift` versionato, niente file `.xcodeproj` rumoroso nei diff né `project.yml` da rigenerare. L'upstream CodexBar è SPM puro e si builda con `xcodebuild`/`swift build` su macOS 26: prova che il pattern regge per una menu bar app con risorse.
- **Build app bundle**: `swift build` produce un eseguibile, non un `.app`. Serve un piccolo script (`Scripts/bundle.sh`) che crea la struttura `ClaudeBar.app/Contents/{MacOS,Resources,Info.plist}`. Questo è già il pattern usato da CodexBar (vedi `Makefile`/`Scripts/`). Mantiene LSUIElement, icona, versioni.
- **xcodebuild compatibile**: `xcodebuild -scheme ClaudeBarApp` funziona su un package SPM (Xcode genera lo scheme dal manifest). Il brief chiede solo "build locale con xcodebuild" — soddisfatto.
- **Quando passare a .xcodeproj**: solo se in futuro servono entitlement firmati complessi, App Group per un widget, o notarizzazione in CI. Per uso personale ora non serve. Decisione rivedibile a costo basso (si può generare il progetto dopo).

> Dipendenze esterne: **zero** per l'MVP. Niente Sparkle (no auto-update per uso personale),
> niente KeyboardShortcuts (eventuale hotkey globale rimandata), niente swift-log (usiamo
> `os.Logger`). Tutto Foundation/AppKit/SwiftUI/Security/ServiceManagement di sistema.
> Questo riduce tempi di build e superficie di manutenzione, coerente con la preferenza
> dell'utente per la semplicità.

---

## 2. Lifecycle dell'app

```
@main ClaudeBarMain (App)
  └─ @NSApplicationDelegateAdaptor(AppDelegate)
       AppDelegate.applicationDidFinishLaunching:
         1. NSApp.setActivationPolicy(.accessory)   // ridondante con LSUIElement, esplicito
         2. costruisce il grafo dipendenze (composition root)
         3. installa lo StatusItemController (crea NSStatusItem)
         4. AppModel.bootstrap():
              - carica snapshot cache da disco  → glance immediato (anche offline)
              - avvia FileWatcher su ~/.claude/projects
              - avvia RefreshScheduler (limiti)
              - kick iniziale: ingest incrementale + fetch limiti
         5. richiede authorization notifiche (soft, non blocca)
```

- **LSUIElement = true** nell'Info.plist → nessuna icona nel Dock, nessun menu applicazione. Tutto vive nella status bar.
- Niente `WindowGroup` principale. La finestra **Preferenze** è una `Settings` scene SwiftUI aperta on-demand (`SettingsLink`/`NSApp.sendAction(showPreferencesWindow:)`), oppure un `NSWindow` dedicato gestito dall'AppDelegate. Scelgo `Settings` scene perché su macOS 26 dà la chrome nativa con tab.
  - Nota: una menu bar app con solo `Settings` scene a volte richiede una finestra keepalive nascosta per tenere vivo il runloop SwiftUI (pattern usato dall'upstream con `HiddenWindowView`). La adotto solo se in fase di implementazione la `Settings` scene non si apre; altrimenti l'AppDelegate basta a mantenere vivo il processo.
- `applicationWillTerminate`: chiude il pannello, ferma watcher e scheduler, fa flush dell'ultimo checkpoint del parser su disco.
- `applicationShouldTerminateAfterLastWindowClosed` → `false` (è un agent).

### 2.1 Naming & bundle identity (parametrici)

Direzione di prodotto (`04-product-roadmap.md`, product-lead): nome in-codice/target **"ClaudeBar"**,
ma **display name parametrico** per evitare attriti col marchio "Claude" (candidati: "ClaudeBar",
"MaxBar", "AnthroBar"). Tengo tutto override-abile:

| Chiave | Valore | Dove |
|---|---|---|
| Bundle id (release) | `com.subralabs.claudebar` | Info.plist `CFBundleIdentifier`, parametrizzato in `bundle.sh` |
| Bundle id (debug) | `com.subralabs.claudebar.debug` | build di debug → istanza separata, no conflitto con la release installata |
| Display name | `CFBundleDisplayName` (default "ClaudeBar") | Info.plist, modificabile senza toccare il codice |
| Target/eseguibile | `ClaudeBarApp` | `Package.swift` (nome interno stabile) |

- I path su disco (Application Support, UserDefaults suite) derivano dal **bundle id**, non dal display name → cambiare il display name non sposta la cache né le impostazioni.
- `bundle.sh` accetta override via env (es. `CLBAR_BUNDLE_ID`, `CLBAR_DISPLAY_NAME`) così debug/release e un eventuale rebrand non richiedono modifiche al sorgente.

---

## 3. Status bar: NSStatusItem + glance colorato

### Perché NSStatusItem e non MenuBarExtra

Il cuore del prodotto (decisione #2 del brief) è un **glance colorato disegnato**: anello/barra
verde→ambra→rosso sulla sessione, eventualmente animato (pulse vicino al limite).

- `MenuBarExtra(content:label:)` con `.menuBarExtraStyle(.window)` permetterebbe una label SwiftUI, ma:
  - il rendering di una `Canvas`/`Shape` colorata come label è meno prevedibile in termini di dimensione/baseline nella status bar, e l'animazione continua a 12fps di una view SwiftUI nella menu bar è inefficiente e fragile;
  - non dà accesso diretto al `NSStatusItem.button` per il tracking del click sinistro/destro né al posizionamento del pannello ancorato.
- `NSStatusItem` con `button.image = renderGlance(...)` ci dà:
  - una **NSImage disegnata a mano** con Core Graphics → colori pieni (`isTemplate = false`), anello + **percentuale numerica** (sempre, default), controllo pixel-perfect alla scala del display (Retina);
  - controllo del click (sinistro → pannello, destro/⌘ → menu contestuale rapido);
  - animazione via display link solo quando serve (cambia frame dell'immagine).

Quindi: **NSStatusItem**. MenuBarExtra è scartato. (Confermato dal design-lead: il sistema ricolora le immagini *template* di MenuBarExtra → niente controllo sul disegno colorato, che per noi è il punto.)

### IconRenderer (Core Graphics)

Firma del renderer dell'icona del glance. **LOCK da `DECISIONS.md` §1 e "LOCK semantica glance"
(fa fede)**: l'icona è **anello (ring gauge) + percentuale numerica accanto, sempre** (es. `◕ 71%`);
anello, % e colore rappresentano tutti il **% USATO** (`utilization`) della **finestra più critica**.
Più usato → più rosso. Mapping colore sull'usato: verde `<60`, ambra `60–85`, rosso `>85`, pulsa `≥95`.
La % di default è l'**USATO** (`71%` = 71% consumato); il rimanente è solo per testi secondari/tooltip.

```swift
struct GlanceIconSpec: Sendable, Equatable {
    var used: Double                 // 0...1, % USATO della finestra PIÙ CRITICA → arco + colore + %
    var criticalKind: PaceWindowKind // quale finestra è la più critica (per badge nel pannello)
    var weeklyUsed: Double?          // 0...1, % USATO settimanale (secondo arco/riga, solo .dualBar)
    var state: GlanceState           // 5 livelli derivati dalle soglie sull'usato
    var style: GlanceStyle           // .ring (default) | .dualBar (sessione+settimana)
    var percentLabel: PercentLabel   // .used (DEFAULT, da DECISIONS §1) | .remaining | .hidden
    var monochrome: Bool             // fallback template B/N (preferenza utente / contrasto)
    var animation: GlanceAnimation   // .none / .pulse / .refreshSpin / .loadingSpin
    var appearance: GlanceAppearance // .light / .dark (per contrasto)
    var scale: CGFloat               // backingScaleFactor del display
}

// 5 ancore con interpolazione continua del colore sull'USATO.
// Soglie sull'usato: OK <60 · WARN 60–85 · LOW/CRIT >85 · EMPTY ≥95 (pulsa).
enum GlanceState: Sendable { case ok, warn, low, critical, empty }
enum GlanceStyle: Sendable { case ring, dualBar }
enum PercentLabel: Sendable { case used, remaining, hidden }   // default .used
enum GlanceAnimation: Sendable { case none, pulse, refreshSpin, loadingSpin }

enum IconRenderer {
    /// Disegna l'icona della status bar (anello + % numerica). Pure function: stessa chiave → stessa immagine.
    /// Colore, riempimento e % sono funzione di `used` (la finestra più critica); lo `state` decide micro-glifi/pulsazione.
    static func render(_ spec: GlanceIconSpec) -> NSImage
}
```

- Le **soglie e la mappa colore** (`used → Color`, ancore OK/WARN/LOW/CRIT/EMPTY interpolate sull'usato) vivono in `ClaudeBarCore` (`GlanceState.swift`), così CLI/test le riusano; il renderer (disegno Core Graphics) è nell'App (dipende da AppKit).
- L'immagine di default **NON** è template (`isTemplate = false`) → mantiene i colori, perché *il colore è l'informazione* (CodexBar usa `isTemplate = true` → monocromo; noi no, è il punto). La modalità `monochrome` produce un'icona template B/N (fallback per "Aumenta contrasto" o preferenza utente).
- **Stale/errore → DIM**: icona desaturata/abbassata di opacità, **mai un rosso falso** (un dato vecchio non deve sembrare "critico"). Lo stato `stale` non cambia lo `state` semantico, applica solo un trattamento DIM al render.
- **Caching quantizzato** (vincolo performance, design §3.6): le `NSImage` sono cachate per chiave quantizzata `IconCacheKey(usedBucket: step 2–3%, state, style, percentLabel, monochrome, appearance, scale)`. Si ridisegna **solo quando il bucket cambia**, non a ogni tick del display link. L'animazione di pulse/spin è una sequenza di frame cachati o una `CABasicAnimation` sul layer, mai un re-render del bitmap a 60fps.
- Aggiornamento su cambio appearance (dark/light) via observer di sistema → re-render con `appearance` corretto.

### StatusItemController

```swift
@MainActor
final class StatusItemController {
    init(model: AppModel)
    func install()                       // crea NSStatusItem, configura button, target/action
    func updateGlance(_ spec: GlanceIconSpec)   // ridisegna l'icona (chiamato da AppModel)
    func startPulse() / func stopPulse()        // gestisce il DisplayLinkDriver
    func togglePanel()                   // apre/chiude il GlassPanel ancorato al button
    func showQuickMenu()                 // menu destro/⌘: Refresh, Preferenze, Quit
    func prepareForShutdown()
}
```

- Le animazioni dell'icona (confermate dal design-lead) sono tre: **pulse lento** quando usato `≥95%` (`.empty`), **micro-rotazione dell'arco durante il refresh** (`.refreshSpin`), **spinner d'arco indeterminato in loading** (`.loadingSpin`). Tutte guidate dal **DisplayLinkDriver** (CADisplayLink su macOS 15+) **a 12fps** (l'icona non anima a 60fps) e **attivo solo mentre serve**: a riposo il display link è fermo → 0% CPU.
- **Reduce Motion** (vincolo accessibilità): pulse → stato statico; refresh → niente rotazione, stato statico con eventuale checkmark a completamento; loading → indicatore statico. La preferenza è letta da `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` con observer.
- Il `togglePanel` mostra un **GlassPanel** (NSPanel borderless non-activating) ancorato sotto il `statusItem.button`, con animazione di apertura (scale 0.96→1 + slide-down) gestita lato SwiftUI come da `03-design.md` §4.1.

---

## 4. Pannello Liquid Glass (NSPanel borderless + SwiftUI)

```
GlassPanel : NSPanel(styleMask: [.borderless, .nonactivatingPanel], backing: .buffered)
  · level = .statusBar, isFloatingPanel = true, hidesOnDeactivate = false
  · si chiude su click-fuori (event monitor) o Esc; ancorato sotto l'icona
  └─ NSHostingController(rootView: PanelRootView().environment(appModel))
       PanelRootView (SwiftUI, materiali macOS 26 Liquid Glass)
         ├─ IdentityHeader     (a) account + plan ("martino · Max") · ultimo refresh · stato
         ├─ LimitsSection      (b) due Gauge grandi: Sessione 5h + Settimanale
         │                          (used%, remaining%, resetAt rel+ass, state)
         ├─ PaceSection        (c) [MVP] barra Pace & Forecast: marker ritmo + tacche 50/75/100 + ETA
         ├─ AnalyticsSection   (d) range Oggi/7g/30g: costo+delta, token, efficienza cache,
         │                          serie temporale (Swift Charts), breakdown modello/progetto
         └─ FooterBar          (e) versione · Preferenze · Quit
```

Ordine e contenuto allineati a `DECISIONS.md` e al design-lead (sezioni a–e):
- **(a) IdentityHeader**: `accountLabel` + `subscriptionType` (da `LimitsSnapshot`), `lastLimitsRefresh`, badge `status`.
- **(b) LimitsSection**: due Gauge — Sessione 5h e Settimanale; ciascuno espone `utilization`/`remaining`/`resetsAt` (relativo+assoluto)/`state`. I cap per-modello (`seven_day_opus`/`seven_day_sonnet`) e `extra_usage` compaiono qui quando presenti (non nell'icona).
- **(c) PaceSection — FEATURE MVP** (promossa da `DECISIONS.md` §"Pace & Forecast", era v1): barra di **pace** per la sessione 5h (replicabile sul settimanale) con riempimento = % usata, **marker "dove dovresti essere"** = % di tempo trascorso (ritmo lineare atteso), **tacche fisse 50/75/100**, **stima testuale ETA** ("a questo ritmo esaurisci tra ~Xh Ym" / "arrivi al reset con margine") e **stato di ritmo** (verde/ambra/rosso = in linea / sopra / sotto). Matematica in §11 (`PaceProjection`). Il calcolo vive in `ClaudeBarCore` (data-engineer), la UI in `ui-engineer`.
- **(d) AnalyticsSection**: indipendente dai limiti (vive dell'`AnalyticsReport` locale); range picker Oggi/7g/30g; costo periodo (**etichettato "stima API-equivalente"**, `DECISIONS.md`) + delta, token totali, efficienza cache, serie temporale + breakdown per modello/progetto (Swift Charts). Storico/per-giorno/per-branch in "Mostra di più".
- **(e) FooterBar**: versione, Preferenze, Quit.

Note architetturali:
- Il pannello applica i materiali Liquid Glass (vibrancy/`glassEffect` sul contenitore a tutta superficie, raggio 26pt) — i dettagli visivi sono di competenza del design-lead (`03-design.md`); qui garantisco solo che la vista riceve i dati via `environment(AppModel.self)`.
- **All'apertura del pannello** l'`AppModel.panelDidOpen()` fa un refresh "best effort" (limiti via path **con prompt** + ingest delta) se i dati sono più vecchi di N secondi → l'utente vede sempre numeri freschi al click.
- Le sezioni con calcoli pesanti (breakdown/serie) leggono **aggregati già pronti** dall'`AnalyticsReport` (calcolati dall'actor in background), mai parsano nel body della view.

---

## 5. Modello di concorrenza (Swift 6 strict)

Tre zone di isolamento nette:

> **Nomi reali allineati con `01-data-integration.md`** (data-architect): gli attori del layer
> dati sono `TranscriptIndexer` (+ `IncrementalIndex` interno) e `ClaudeLimitsService`. Nel
> resto di questo doc dove compaiono i placeholder `AnalyticsStore`/`LimitsService` si intendono
> questi. I tipi di ritorno reali sono `AnalyticsReport` e `LimitsSnapshot` (vedi §11).

```
        ┌─────────────────────────── MainActor ───────────────────────────┐
        │  @Observable AppModel  ──drives──▶ StatusItemController          │
        │       ▲   │                         (NSStatusItem, IconRenderer) │
        │       │   └──drives──▶ SwiftUI PanelRootView (GlassPanel)        │
        └───────┼──────────────────────────────────────────────────────────┘
                │ await (risultati Sendable: AnalyticsReport, LimitsSnapshot)
   ┌────────────┴───────────────┐        ┌──────────────────────────────┐
   │ actor TranscriptIndexer     │        │ actor ClaudeLimitsService    │
   │  walk + parse on-demand     │        │  Keychain + OAuth + endpoint │
   │   └ actor IncrementalIndex   │        │  refresh token, gate 429     │
   │     stato per-file + dedup  │        │  no-UI vs prompt entry       │
   └────────────┬───────────────┘        └──────────────────────────────┘
                │ usa
        ┌───────┴────────────────┐
        │ Persistence (cache disk)│  (Codable atomico, off-main)
        └─────────────────────────┘
```

- **AppModel** (`@Observable`, `@MainActor`): unica fonte di verità per la UI. Possiede i riferimenti agli attori, allo scheduler e al watcher. Espone proprietà osservabili: `glanceSpec`, `limits`, `analytics`, `status`, `lastRefresh`, `errors`. Coordina ma **non** parsa né fa rete.
- **TranscriptIndexer** (`actor`, in Core): orchestra walk + parse on-demand dei `.jsonl`; possiede internamente `IncrementalIndex` (`actor`) per lo stato per-file persistito + dedup. Tutto l'IO dei transcript avviene qui, fuori dal main. Espone `refresh(force:) -> AnalyticsReport`. **Non** fa watching (il watcher è nell'app layer, lo chiama).
- **ClaudeLimitsService** (`actor`, in Core): legge Keychain (due entry: silenziosa no-UI e con prompt), parla con l'endpoint usage, gestisce refresh token e il **gate 429**. Ritorna `LimitsSnapshot` (Sendable) con `source` (`.live`/`.cached`/`.stale`).
- **Confini**: solo value types `Sendable` immutabili attraversano gli `await`. Nessun riferimento condiviso mutabile tra main e attori → niente data race, Swift 6 felice senza `@unchecked`.
- I callback dal mondo C/Cocoa (DispatchSource, CADisplayLink, panel event monitor) sono `nonisolated` e fanno hop esplicito con `Task { @MainActor in ... }`.

> Allineamento con data-architect: gli attori `TranscriptIndexer`/`ClaudeLimitsService` sono di
> sua competenza (logica dati). Io definisco solo i **confini** (firme dei metodi async, tipi di
> ritorno Sendable) e chi li possiede/coordina (AppModel). Confermato via messaggio.

---

## 6. Performance: parsing incrementale, zero re-scan

Questo è il vantaggio competitivo del brief. Strategia su tre livelli.

### 6.1 Checkpoint del parser per file

Per ogni file `.jsonl` teniamo un record di scansione persistito:

```swift
struct FileScanState: Codable, Sendable {
    var path: String
    var size: UInt64          // bytes letti finora
    var mtime: Date           // ultima modifica vista
    var byteOffset: UInt64    // da dove riprendere la lettura (== size se tutto letto)
    var inode: UInt64         // per rilevare rotazione/sostituzione file
}
```

Algoritmo di **ingest incrementale** (off-main, nell'actor):

```
per ciascun file in ~/.claude/projects/**/*.jsonl:
  - stat() → (size, mtime, inode)
  - se inode cambiato (file ruotato/ricreato) → re-scan dall'offset 0
  - se size < byteOffset (truncate) → re-scan da 0
  - se size == byteOffset && mtime invariato → SKIP (nessun lavoro)
  - altrimenti: apri, seek(byteOffset), leggi SOLO i nuovi byte fino a EOF
      → parse riga-per-riga (streaming, no caricamento intero file)
      → per ogni evento assistant: dedup su (requestId, uuid); se nuovo, accumula nei rollup
      → aggiorna byteOffset = posizione corrente (gestendo una eventuale riga parziale finale)
  - salva FileScanState aggiornato
```

- **Lettura solo dei byte nuovi**: niente `String(contentsOf:)` sull'intero file. Si usa un `FileHandle` con `seek` + lettura a chunk e split sui `\n`. Una riga parziale a fine file (scrittura in corso) viene tenuta da rileggere al prossimo giro (non si avanza l'offset oltre l'ultimo `\n` completo).
- **Dedup**: set di `requestId`/`uuid` già visti. Persistito in forma compatta nel checkpoint (o ricostruito; vedi rischi).
- **Costo a riposo**: se nessun file cambia, l'ingest è solo N `stat()` → microsecondi, zero parsing.

### 6.2 Cache aggregati su disco

```swift
struct AnalyticsCache: Codable, Sendable {
    var version: Int                          // schema version per invalidazione
    var fileStates: [String: FileScanState]   // checkpoint per file
    var report: AnalyticsReport               // aggregati pre-calcolati
    var pricingTableHash: String              // se cambia → ricalcola costi
    var savedAt: Date
}
```

- Salvata in `~/Library/Application Support/ClaudeBar/analytics-cache.json` (scrittura **atomica**: file temporaneo + rename).
- **All'avvio**: si carica la cache → l'icona/glance e il pannello mostrano subito i dati storici (anche offline), poi parte l'ingest del solo delta. Nessun re-scan completo.
- **Invalidazione**: se `version` o `pricingTableHash` cambiano → re-scan completo una tantum.
- Scrittura della cache **debounced** (es. ogni 5s o a chiusura pannello/app), non a ogni riga.

### 6.3 File watching efficiente

**Scelta: DispatchSource** (vnode su directory + write su file caldi), non FSEvents.

- Motivo: il nostro target è una **singola radice** `~/.claude/projects` con sottocartelle. FSEvents è ottimo per alberi enormi ma porta complessità (stream, callback C, latency tuning). Per il nostro scope un `DispatchSource.makeFileSystemObjectSource` sulla directory (eventi `.write/.extend/.rename`) con **coalescing/debounce** è più semplice e altrettanto leggero. (Se in implementazione la copertura ricorsiva delle sottocartelle con vnode si rivela scomoda, si passa a `FSEventStream` sulla radice senza cambiare il confine verso l'indexer.)
- **Debounce ~1–2s** (concordato con data-architect, non 300ms): durante una sessione attiva Claude Code scrive righe a raffica; un debounce di 1–2s coalizza le scritture in un solo `refresh()` evitando di richiamare l'indexer decine di volte al secondo.
- Fallback robusto: un **timer di polling mtime** a bassa frequenza (es. 30–60s) che fa da rete di sicurezza nel caso un evento vnode sfugga (succede con alcune sync/editor). Il polling fa solo `stat()`, costo trascurabile.

```swift
@MainActor
final class FileWatcher {
    init(root: URL, debounce: Duration = .seconds(2),
         onChange: @escaping @Sendable () async -> Void)
    func start()
    func stop()
}
```

- **Confine concordato con data-architect**: `onChange` chiama `await indexer.refresh(force: false) -> AnalyticsReport` (orchestrato dall'AppModel, che poi pubblica il report sul main). Il watcher fa solo file-system events → l'indexer fa walk+parse on-demand; nessuna logica di parsing nell'app layer.
- **Domanda aperta #1 → RISOLTA**: il watcher sta nell'**app layer** e chiama l'indexer; l'indexer non fa watching. Nome unico del metodo di confine: **`refresh(force:)`** (data-architect adotta questo, non `ingestChanges`/`ingestDelta`).

### 6.4 Primo full-index pesante — non bloccare il primo paint (vincolo data-architect)

Numeri reali sul sistema dell'utente: **~1.8 GB / ~4135 file** `.jsonl`. Il **primo** indice
completo (cache assente o invalidata) è l'unico momento costoso. Regole:

- Il primo `refresh()` gira come **task `.utility` cancellabile** (priorità bassa, `Task.priority = .utility`), **off-main**, **non blocca il primo paint**. Cancellabile su quit/cambio sorgente.
- **Progress osservabile**: il `TranscriptIndexer` espone avanzamento (file processati / totali o byte); l'AppModel lo pubblica come `indexingProgress: Double?`. La UI mostra uno stato "indicizzazione in corso" nel pannello, ma il **glance** intanto vive sulla **cache su disco** (se presente) o su stato `loading` neutro.
- Sequenza di avvio: `loadCache()` (istantaneo) → primo paint dei dati cached → in parallelo `refresh()` del delta o full-index → quando completa, ripubblica `AnalyticsReport` aggiornato. Nessun freeze.
- I refresh **successivi** sono incrementali (solo delta via offset/mtime) → near-instant, priorità normale.

---

## 7. Scheduler di refresh dei limiti ufficiali

> **Due cadenze separate** (vincolo da data-architect, da NON unificare):
> - **Analytics (locale)**: guidato da FSEvents + `refresh()`, near-instant a regime. **Niente
>   timer di rete.** Il primo full-index è pesante → vedi §7.1.
> - **Limiti (rete)**: questo scheduler, timer sul preset utente (default 5m) + on-demand, soggetto al **gate 429**.

I limiti (sessione 5h + finestre settimanali) arrivano dall'endpoint OAuth → vanno **schedulati**,
non guidati dai file. Rate-limit-aware.

```swift
enum RefreshInterval: Sendable, CaseIterable {
    case manual, oneMinute, twoMinutes, fiveMinutes, fifteenMinutes, thirtyMinutes
    var duration: Duration? { /* nil per .manual */ }
}

@MainActor
final class RefreshScheduler {
    init(interval: RefreshInterval, action: @escaping @Sendable () async -> Void)
    func setInterval(_ interval: RefreshInterval)
    func refreshNow()        // refresh manuale / on-demand
    func suspend() / resume() // pausa quando offline / a sleep
}
```

- Implementato con un `Task` che fa `try await Task.sleep(for: interval)` in loop (cancellabile su `setInterval`/`suspend`), **non** `Timer` (più pulito con async, niente RunLoop retain).
- **Eventi che innescano un refresh on-demand** (oltre allo scheduler periodico):
  - apertura del pannello (se dati > soglia di freschezza) → usa l'entry Keychain **con prompt**;
  - risveglio dal sleep (`NSWorkspace.didWakeNotification`) → `refreshNow()`;
  - ritorno della connettività di rete.
- **Preset** (allineati a `04-product-roadmap.md`): Manual · 1m · 2m · 5m · 15m · 30m. Default **5 minuti** (scelta product-lead). Persistito in UserDefaults, selezionabile dalle Preferenze. (La data-architect suggeriva ~90s come cadenza tecnica: vince il preset di prodotto per la scelta utente, ma il gate 429 sotto protegge comunque a ogni intervallo, anche 1m.)

### 7.1 Gate 429 e rispetto del risultato del service (vincolo data-architect)

Il gate di rate-limit (429 su `/api/oauth/usage`) vive **dentro `ClaudeLimitsService`**, ma lo
scheduler **deve rispettarne l'esito** e non insistere:

```swift
enum LimitsSource: Sendable { case live, cached, stale }   // dentro LimitsSnapshot
```

- Quando `refreshLimitsNow()` ritorna uno snapshot con `source == .cached`/`.stale` (il service è
  in backoff/gate), l'AppModel **non** ritenta subito: mostra l'ultimo snapshot con **badge
  "stale"** nel glance/pannello e attende il prossimo tick o un'azione utente esplicita.
- Lo scheduler non implementa un proprio backoff in conflitto: il backoff è del service; lo
  scheduler si limita a non forzare GET ravvicinate quando il risultato è già `.cached`.

### 7.2 Keychain: no-UI per il timer, prompt per l'azione utente (vincolo data-architect)

Leggere `Claude Code-credentials` a freddo fa comparire il **prompt di sistema** del Keychain.
`ClaudeLimitsService` espone **due entry**:

- **silenziosa (no-UI)** — usata dallo **scheduler in background**: se il sistema chiederebbe il
  prompt, fallisce in modo pulito (stato `keychainDenied`/`tokenExpired`) senza interrompere
  l'utente;
- **con prompt** — usata solo su **azione utente**: apertura pannello o **Refresh manuale**.

Regola architetturale: il `RefreshScheduler` periodico passa sempre il path no-UI; gli eventi
on-demand originati da un gesto dell'utente passano il path con prompt.

---

## 8. Persistenza impostazioni

Set di impostazioni MVP allineato a `04-product-roadmap.md` (product-lead). **Niente provider
toggles** (è solo-Claude) e **niente Web cookies** nell'MVP.

```swift
@MainActor @Observable
final class SettingsStore {
    // --- Dati / sorgente ---
    // CLI PTY probe TAGLIATO dall'MVP (DECISIONS.md): l'endpoint OAuth basta. In MVP la sorgente
    // è solo OAuth; nessun selettore in UI. (Il flag torna in v1 se servirà il fallback.)
    var refreshInterval: RefreshInterval         // .fiveMinutes default

    // --- Avvio / glance ---
    var launchAtLogin: Bool
    var percentLabel: PercentLabel                // .used (DEFAULT, DECISIONS §1) | .remaining | .hidden
    var glanceStyle: GlanceStyle                  // .ring (default) | .dualBar (sessione+settimana)

    // --- Soglie colore (sull'USATO; condivise con GlanceState in Core) ---
    var warnThreshold: Double                     // default 0.60 usato → WARN (verde→ambra)
    var criticalThreshold: Double                 // default 0.85 usato → CRIT (ambra→rosso); empty ≥0.95

    // --- Notifiche (DECISIONS.md §4) ---
    var sessionThresholds: Set<Int>               // default {50, 75, 90} (% USATO sessione 5h)
    var notifySessionThresholds: Bool             // on/off notifiche soglia sessione
    var celebrateWeeklyReset: Bool                // celebrazione al reset settimanale

    // --- Pricing ---
    var pricingOverridePath: String?              // override JSON locale tabella prezzi

    // backing: UserDefaults; ogni didSet persiste + notifica i sottosistemi
}
```

- **Backing**: `UserDefaults.standard`. I valori sono pochi e scalari → niente file custom. Le chiavi hanno prefisso `clbar.`.
- `SettingsStore` è `@Observable @MainActor`: la UI delle Preferenze ci si lega direttamente; i cambi rilevanti (`refreshInterval`, soglie, `launchAtLogin`) sono propagati ai sottosistemi (`RefreshScheduler.setInterval`, `LaunchAtLoginManager.setEnabled`, ridisegno glance).
- **Sorgente limiti — solo OAuth in MVP** (`DECISIONS.md`): `ClaudeLimitsService` interroga `/api/oauth/usage`; niente CLI PTY probe (tagliato), niente Web cookie. Nessuna scelta sorgente esposta all'utente nell'MVP.
- **Multi-account = POST-MVP** (`DECISIONS.md`: l'utente ha 1 account): nell'MVP si usa l'unico item Keychain `Claude Code-credentials`. Le varianti `-<hash>` e lo switcher arrivano dopo; nessun campo `activeAccountId` nell'MVP per non aggiungere superficie inutile.

---

## 9. Launch at login

```swift
enum LaunchAtLoginManager {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func setEnabled(_ enabled: Bool)   // register()/unregister(), gestisce errori
}
```

- **SMAppService.mainApp** (macOS 13+, sicuramente disponibile su 26). Niente login helper separato.
- Disabilitato automaticamente sotto test (controllo env `XCTest`/`SWIFT_TESTING`) come fa l'upstream, per non sporcare gli item di login durante i test.
- In Preferenze il toggle riflette lo `status` reale (non solo la preferenza salvata), così resta coerente se l'utente revoca da Impostazioni di Sistema.

---

## 10. Gestione stati ed errori

Stato globale che guida glance + pannello:

```swift
enum AppStatus: Sendable, Equatable {
    case loading                 // primo avvio, nessun dato cache
    case ready                   // dati validi e freschi
    case stale(since: Date)      // mostra ultimo dato, refresh fallito di recente
    case noSubscription          // Keychain senza item Claude o subscriptionType non Max
    case tokenExpired            // token scaduto e refresh fallito → serve ri-login
    case keychainDenied          // utente ha negato accesso al Keychain
    case offline                 // nessuna connettività
    case error(message: String)  // errore generico (con messaggio)
}
```

Mappatura su glance e pannello:

| Stato | Glance (icona) | Pannello |
|---|---|---|
| `loading` | anello grigio "loading" | spinner / scheletro |
| `ready` | anello + % colorati sulla finestra più critica | dati completi |
| `stale` | icona **DIM** (desaturata/opacità ridotta), **mai rosso falso** + badge "stale" sottile | banner "Aggiornato Xs fa, riprovo…" |
| `noSubscription` | icona grigia neutra (—) | CTA: "Accedi a Claude Code" / spiegazione |
| `tokenExpired` | icona ambra con "!" | CTA ri-login + spiegazione refresh |
| `keychainDenied` | icona neutra | spiegazione + bottone "Concedi accesso" |
| `offline` | ultimo colore noto, desaturato | banner offline |
| `error` | icona ambra "!" | messaggio + bottone Riprova + apertura log |

- **Importante** (`DECISIONS.md`: degradazione elegante): le **analytics locali** (parsing `.jsonl`) sono **indipendenti** dai limiti ufficiali. Se l'OAuth/endpoint fallisce (offline, token scaduto, no-subscription), il pannello mostra comunque token/costo/breakdown dai transcript. Il glance ripiega su un colore neutro ma il pannello resta utile. Punto di robustezza chiave.
- Errori dei due sottosistemi tracciati separatamente nell'AppModel (`limitsError`, `analyticsError`) e fusi in `AppStatus` con priorità (token/subscription/keychain > offline > generico).

### 10.1 Notifiche (modulo MVP, `DECISIONS.md` §4)

- **Soglie sessione 5h a 50% / 75% / 90%** dell'usato (`sessionThresholds`, configurabili). **De-dup per finestra**: una sola notifica per soglia **per ciclo di reset** — si traccia `(window, soglia, resetsAt)` già notificato e si azzera al cambio di `resetsAt`. Niente spam se l'usato oscilla attorno a una soglia.
- **Celebrazione al reset settimanale** (`celebrateWeeklyReset`): rilevato il rollover di `sevenDay.resetsAt`, notifica/celebrazione.
- Autorizzazione richiesta soft all'avvio (`UNUserNotificationCenter`), non blocca. Modulo `Notifications.swift` (core-engineer, task #7).

---

## 11. AppModel — firma del coordinatore

> Tipo dominio condiviso allineato a `DECISIONS.md` (§"Reconciliazione endpoint"): l'endpoint
> `GET /api/oauth/usage` ritorna `utilization` = **% USATA** (0–100), NON "remaining". Chiavi reali:
> `five_hour`→sessione, `seven_day`→settimana, `seven_day_opus`/`seven_day_sonnet`→cap per-modello,
> `extra_usage` se presente. `UsageWindow { kind, utilization, resetsAt, pace }` vive in `ClaudeBarCore`
> ed è la fonte sia per l'icona (core-engineer) sia per il pannello (ui-engineer).

```swift
enum PaceWindowKind: Sendable { case fiveHour, sevenDay, sevenDayOpus, sevenDaySonnet }

struct UsageWindow: Sendable, Equatable {
    var kind: PaceWindowKind
    var utilization: Double           // 0...100, % USATA (remainingPct = 100 - utilization)
    var resetsAt: Date?
    var pace: PaceProjection?         // calcolato in Core (data-engineer)
}

struct LimitsSnapshot: Sendable, Equatable {
    var fiveHour: UsageWindow         // sessione 5h
    var sevenDay: UsageWindow         // settimana
    var sevenDayOpus: UsageWindow?    // cap Opus separato (se presente)
    var sevenDaySonnet: UsageWindow?  // cap Sonnet separato (se presente)
    var extraUsage: UsageWindow?      // crediti pay-as-you-go (se presenti)
    var subscriptionType: String      // es. "max"
    var accountLabel: String          // etichetta account
    var fetchedAt: Date
    var source: LimitsSource          // .live / .cached / .stale
}

// Pace & Forecast — FEATURE MVP (DECISIONS.md). Calcolata in Core per ogni finestra.
// duration: fiveHour=5h, sevenDay/Opus/Sonnet=7g. windowStart = resetsAt - duration.
// usedFrac = utilization/100; elapsedFrac = clamp(elapsed/duration, 0...1).
struct PaceProjection: Sendable, Equatable {
    var paceMarker: Double            // = elapsedFrac (0...1): "dove dovresti essere"
    var isOverPace: Bool              // usedFrac > elapsedFrac → sopra ritmo
    var rhythm: PaceRhythm            // .onTrack / .over / .under (verde/rosso/ambra)
    var etaToEmpty: Date?             // se usedFrac>0 e exhaustion PRIMA del reset → ETA; altrimenti nil
    var reachesResetWithMargin: Bool  // true → "arrivi al reset con margine"
}
enum PaceRhythm: Sendable { case onTrack, over, under }

@MainActor @Observable
final class AppModel {
    // Stato osservato dalla UI
    private(set) var status: AppStatus
    private(set) var glanceSpec: GlanceIconSpec
    private(set) var limits: LimitsSnapshot?       // Sendable, dal Core (forma sopra)
    private(set) var analytics: AnalyticsReport?   // Sendable, dal Core
    private(set) var indexingProgress: Double?     // primo full-index in corso (§6.4), nil = idle
    private(set) var lastLimitsRefresh: Date?
    private(set) var lastAnalyticsRefresh: Date?

    // Dipendenze (composition root le inietta) — nomi reali del layer dati
    init(limits: ClaudeLimitsService,
         indexer: TranscriptIndexer,
         settings: SettingsStore,
         persistence: PersistenceService)

    // Ciclo di vita
    func bootstrap() async        // carica cache (paint immediato), avvia watcher+scheduler, primo refresh
    func shutdown()

    // Azioni
    func refreshLimitsNow(userInitiated: Bool) async  // userInitiated → Keychain con prompt (§7.2)
    func refreshAnalytics(force: Bool) async          // chiama indexer.refresh(force:)
    func panelDidOpen()           // refresh on-demand se dati vecchi (userInitiated = true)
    func applySettingsChange()    // reagisce a interval/soglie/glance/launchAtLogin

    // Interni: ricalcola glanceSpec da (limits, settings) e aggiorna StatusItemController.
    // La finestra di riferimento del glance è la PIÙ CRITICA = max(utilization).
    private func recomputeGlance()
}
```

- **Glance su finestra più critica** (`DECISIONS.md` §2): tra `fiveHour`/`sevenDay`/`sevenDayOpus`/`sevenDaySonnet`, `recomputeGlance()` sceglie come riferimento quella con **`utilization` massima** (= messa peggio); icona, % e colore la rappresentano, e `criticalKind` indica quale (badge nel pannello). Le finestre restano tutte distinte nel pannello. Lo `weeklyUsed` alimenta il secondo arco/riga solo nello stile `.dualBar`.
- `source == .cached/.stale` (gate 429) → glance con badge "stale", nessun ritento immediato (§7.1).

- L'`AppModel` è l'unico punto in cui i risultati degli attori vengono pubblicati su MainActor e tradotti in `glanceSpec`/`status`. Decide quando far partire/fermare il pulse del display link.
- Riceve i riferimenti a `StatusItemController` (per `updateGlance`) tramite weak ref o callback impostata dall'AppDelegate dopo l'install (evita ciclo di init).

**Matematica Pace & Forecast** (`PaceCalculator` in Core, da `DECISIONS.md`) — per ogni `UsageWindow`:
- `duration` = 5h (`fiveHour`) o 7g (le `sevenDay*`); `windowStart = resetsAt − duration`; `elapsed = now − windowStart`; `remainingTime = resetsAt − now`.
- `usedFrac = utilization/100`; `elapsedFrac = clamp(elapsed/duration, 0...1)` → **`paceMarker`** ("dove dovresti essere").
- **`isOverPace`** = `usedFrac > elapsedFrac`; `rhythm` = `.over`/`.onTrack`/`.under` con piccola tolleranza attorno a `elapsedFrac`.
- **ETA**: se `usedFrac > 0`, `rate = usedFrac/elapsed`, `etaToEmpty = (1−usedFrac)/rate`. Se `etaToEmpty < remainingTime` → esaurisci PRIMA del reset (`etaToEmpty` valorizzato); altrimenti `reachesResetWithMargin = true`.
- **Bonus v1** (non MVP): burn-rate recente dai transcript locali (ultimi 30–60 min) per una stima più reattiva del lineare-da-inizio.

---

## 12. Composition root & wiring

Ordine di costruzione in `AppDelegate.applicationDidFinishLaunching` (tutto su MainActor):

```
1. SettingsStore()                              // legge UserDefaults
2. PersistenceService(appSupportURL: …)         // path cache
3. TranscriptIndexer(persistence:)               // actor (Core) — possiede IncrementalIndex
4. ClaudeLimitsService(keychain:, urlSession:)   // actor (Core) — gate 429, no-UI + prompt entry
5. AppModel(limits:, indexer:, settings:, persistence:)
6. StatusItemController(model: appModel); .install()
7. appModel.attach(statusController:)            // chiude il ciclo per updateGlance
8. FileWatcher(root: ~/.claude/projects, debounce: .seconds(2),
              onChange: { await appModel.refreshAnalytics(force: false) })
9. RefreshScheduler(interval: settings.refreshInterval,
              action: { await appModel.refreshLimitsNow(userInitiated: false) })  // no-UI Keychain
10. Task { await appModel.bootstrap() }
```

- Inietto le dipendenze esplicitamente (no singleton globali se non `os.Logger`). Facilita i test: si possono passare fake di `ClaudeLimitsService`/`TranscriptIndexer`.

---

## 13. Lista file da creare (proposta)

```
Package.swift
Scripts/bundle.sh                         # impacchetta swift build → ClaudeBar.app
Scripts/run.sh                            # build + bundle + open (dev loop)

# NB: i nomi dei file in Limits/ e Analytics/ sono di competenza data-architect
# (01-data-integration.md). Qui riporto i nomi reali concordati; il confine pubblico
# verso l'app è refresh(force:) -> AnalyticsReport e LimitsSnapshot.
Sources/ClaudeBarCore/
  Models/UsageEvent.swift                 # riga .jsonl decodificata (Sendable)
  Models/AnalyticsReport.swift            # report aggregato (per modello/progetto/sessione/giorno/branch)
  Models/LimitsSnapshot.swift             # UsageWindow{kind,utilization,resetsAt,pace} + finestre five_hour/seven_day/opus/sonnet/extra
  Models/PricingTable.swift               # prezzi per modello + override JSON + cache ×1.25/×2/×0.1 + normalizza suffisso [1m]
  Models/GlanceState.swift                # soglie + mappa colore used→Color (condivise con renderer)
  Models/PaceProjection.swift             # Pace & Forecast (MVP): paceMarker, ETA, rhythm
  Limits/ClaudeOAuthCredentials.swift     # modello credenziali keychain  [data-engineer]
  Limits/KeychainReader.swift             # SecItemCopyMatching: entry no-UI + entry con prompt  [data-engineer]
  Limits/ClaudeLimitsService.swift        # actor: GET /api/oauth/usage + refresh token + gate 429  [data-engineer]
  Analytics/JSONLParser.swift             # parsing streaming riga-per-riga  [data-engineer]
  Analytics/IncrementalIndex.swift        # actor: stato per-file (offset/mtime/inode) + dedup  [data-engineer]
  Analytics/TranscriptIndexer.swift       # actor: walk + parse on-demand, refresh(force:)  [data-engineer]
  Analytics/CostCalculator.swift          # report × PricingTable → "stima API-equivalente"  [data-engineer]
  Analytics/PaceCalculator.swift          # UsageWindow → PaceProjection (matematica §11)  [data-engineer]
  Persistence/PersistenceService.swift    # load/save AnalyticsCache (atomico)
  Persistence/AnalyticsCache.swift        # Codable schema cache (fileStates + report + pricingHash)
  Util/Logging.swift                      # os.Logger wrapper + categorie
  Util/AppPaths.swift                     # ~/.claude/projects, Application Support (da bundle id)

Sources/ClaudeBarApp/
  App/ClaudeBarMain.swift                 # @main App + Settings scene
  App/AppDelegate.swift                   # lifecycle + composition root
  State/AppModel.swift                    # @Observable @MainActor coordinatore
  State/AppStatus.swift                   # enum stati/errori
  StatusItem/StatusItemController.swift    # NSStatusItem + click handling
  StatusItem/IconRenderer.swift           # disegno Core Graphics del glance + IconCacheKey
  StatusItem/GlanceIconSpec.swift         # spec immagine (anello+%, 5 stati su %USATO, ring|dualBar)  [core-engineer]
  StatusItem/DisplayLinkDriver.swift       # pulse/refreshSpin/loadingSpin 12fps on-demand  [core-engineer]
  Panel/GlassPanel.swift                  # NSPanel borderless + ancoraggio + dismissal  [core-engineer]
  Panel/PanelRootView.swift               # SwiftUI root (Liquid Glass NEUTRO)  [ui-engineer]
  Panel/IdentityHeader.swift              # (a) account + plan + refresh + stato  [ui-engineer]
  Panel/LimitsSection.swift               # (b) due Gauge: sessione 5h + settimanale  [ui-engineer]
  Panel/PaceSection.swift                 # (c) MVP — barra Pace&Forecast: marker + tacche 50/75/100 + ETA  [ui-engineer]
  Panel/AnalyticsSection.swift            # (d) range + costo/token/cache + Swift Charts + breakdown  [ui-engineer]
  Watch/FileWatcher.swift                 # DispatchSource + polling fallback  [core-engineer]
  Watch/RefreshScheduler.swift            # async loop intervallo  [core-engineer]
  Settings/SettingsStore.swift            # @Observable UserDefaults  [core-engineer]
  Settings/PreferencesView.swift          # finestra preferenze SwiftUI
  Settings/LaunchAtLoginManager.swift      # SMAppService  [core-engineer]
  App/Notifications.swift                 # soglie 50/75/90 de-dup per ciclo + celebrazione reset settimanale  [core-engineer]
  Resources/Info.plist (values)           # LSUIElement, versioni
  Resources/Assets.xcassets               # eventuale icona app

Sources/ClaudeBarCLI/                     # DEV-TOOL interno, NON nel bundle, NON distribuito
  main.swift                              # dump AnalyticsReport per validare parser+costi vs ccusage/`claude /usage`

Tests/ClaudeBarCoreTests/                 # parser incrementale, dedup, pricing, oauth parse
Tests/ClaudeBarAppTests/                  # icon render snapshot, scheduler, mapping stati
```

> I file marcati `[data-architect]` / `[coord. design-lead]` hanno il loro contenuto definito dai
> rispettivi doc; qui fisso solo posizione e confine (firme pubbliche).
>
> **Target CLI** (deciso dal product-lead, `04-product-roadmap.md` §9.1): `ClaudeBarCLI` è un
> **dev-tool interno** — serve a validare parser JSONL + calcolo costi contro `ccusage`/`claude
> /usage` (criteri di accettazione MVP), **non** è nel bundle dell'app, non è distribuito, non è
> scope di prodotto. L'**MVP di prodotto = solo l'app** (zero-extra). Una **CLI companion pubblica**
> (stile codexbar: `usage`/`cost`/`config`, export CSV/JSON) resta **v2**, fuori MVP.

---

## 14. Budget di performance (target)

- **A riposo** (nessuna sessione Claude attiva, pannello chiuso): ~0% CPU. Display link fermo, watcher idle, scheduler che dorme. Solo wakeups del timer di refresh ogni N min.
- **Durante sessione attiva** (Claude Code scrive .jsonl): ingest del solo delta, debounced ~2s → frazioni di ms per giro, lettura di pochi KB.
- **Avvio a freddo (con cache)**: glance visibile <100ms (da cache su disco), prima dei dati di rete.
- **Primo avvio (senza cache, ~1.8GB/4135 file)**: full-index una tantum come task `.utility` cancellabile, off-main, con `indexingProgress` (§6.4). Non blocca il primo paint; il glance resta neutro/loading finché il report è pronto.
- **RAM**: bassa e costante — non si tengono in memoria i file interi, solo il report aggregato e lo stato per-file (offset/mtime/inode) + dedup. Il set di dedup è il principale consumo: vedi rischio R3.

---

## 15. Rischi e fallback

- **R1 — Endpoint usage OAuth**: `GET https://api.anthropic.com/api/oauth/usage` con header `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<ver>`; risposta con `utilization` (% usata) per `five_hour`/`seven_day`/`seven_day_opus`/`seven_day_sonnet`/`extra_usage` (`DECISIONS.md`). Refresh token con la regola "non rubare il refresh alla CLI". Se l'endpoint non è disponibile → glance neutro + pannello vive di sole analytics locali (§10). **CLI PTY probe TAGLIATO dall'MVP** (`DECISIONS.md`): eventuale fallback dietro flag in v1.
- **R2 — Keychain prompt**: leggere `Claude Code-credentials` può far comparire un prompt di sistema. Strategia concordata con data-architect (§7.2): il **timer di background** usa l'entry **no-UI** (fallisce pulito → `keychainDenied`/`tokenExpired`, niente loop di prompt); il prompt reale compare **solo su azione utente** (apertura pannello / Refresh manuale). Multi-account post-MVP (`DECISIONS.md`): nell'MVP si legge l'unico item `Claude Code-credentials`.
- **R3 — Crescita del set di dedup**: con molti progetti/sessioni il set di `requestId`/`uuid` cresce. Mitigazione (coerente con `IncrementalIndex` per-file della data-architect): il dedup è tenuto **per-file** e si scarta quando il file è consolidato nel report e l'offset è a EOF stabile; gli id di quel file non restano in memoria. Confine pulito perché lo stato per-file è già la granularità dell'indice.
- **R4 — Riga JSONL parziale a fine file**: la scrittura concorrente di Claude Code può lasciare una riga incompleta. Mitigazione: non avanzare l'offset oltre l'ultimo `\n` completo; rileggere al prossimo giro.
- **R5 — File ruotati/spostati**: si rileva via `inode` nel checkpoint; cambio inode o size in calo → re-scan da 0 di quel file.
- **R6 — Pricing obsoleto**: i prezzi cambiano. Tabella embedded + override locale (`pricingOverridePath`); il costo è marcato "stimato". Cambio tabella → `pricingTableHash` invalida i costi cachati (rollup di token restano validi).
- **R7 — Settings scene + agent app**: a volte la `Settings` scene non si apre senza una finestra viva. Fallback: finestra keepalive nascosta (pattern upstream) o `NSWindow` dedicato per le preferenze.

---

## 16. Domande aperte (per team-lead / altri agenti)

1. ~~**Watcher ownership**~~ → **RISOLTO** con data-architect: watcher nell'**app layer** che chiama `await indexer.refresh(force:)`; l'indexer non fa watching. Vedi §6.3.
2. ~~**Glance: testo % o solo anello?**~~ → **RISOLTO** dal design-lead: default **anello (ring gauge)** colorato sul % *usato* (verde <60, ambra 60–85, rosso >85, pulsa ≥95), **niente testo** obbligatorio; testo `%` opzionale (usato/rimanente, default off) e variante **`.dualBar`** (sessione+settimana) selezionabile. `GlanceIconSpec`/`IconRenderer` allineati su `*Used`.
3. ~~**Endpoint limiti**~~ → **RISOLTO** (`DECISIONS.md`): `GET /api/oauth/usage`, header Bearer + `anthropic-beta: oauth-2025-04-20` + `User-Agent: claude-code/<ver>`; risposta `utilization` (% usata) per `five_hour`/`seven_day`/`seven_day_opus`/`seven_day_sonnet`/`extra_usage`. Modellato in `LimitsSnapshot`/`UsageWindow` (§11). Sorgente = solo OAuth in MVP (CLI PTY tagliato).
4. ~~**Notifiche in MVP?**~~ → **RISOLTO** (`DECISIONS.md` §4): notifiche soglia sessione **50/75/90%** con de-dup per finestra per ciclo di reset + **celebrazione reset settimanale**, in scope MVP. Modulo `Notifications.swift` (§10.1).
5. ~~**CLI target**~~ → **RISOLTO** dal product-lead (`04-product-roadmap.md` §9.1): `ClaudeBarCLI` è un **dev-tool interno** (validazione parser+costi vs ccusage/`claude /usage`), **non** nel bundle né distribuito, non scope di prodotto → resta nel package. **CLI companion pubblica = v2**. L'MVP di prodotto è solo l'app (zero-extra).
