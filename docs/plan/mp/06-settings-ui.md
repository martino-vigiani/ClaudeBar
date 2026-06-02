# MP-6 — Impostazioni multi-provider + adattamento del pannello

> STATO: Fase A (proposta) + Fase B (IMPLEMENTATA) + recepimento DECISIONI finali. Vedi §9 in coda.

> Autore: settings-ui-engineer · Fase A (studio + proposta, NON implementazione).
> Prerequisiti letti: `mp/BRIEF.md`, `DECISIONS.md`, `03-design.md`.
> Riferimento studiato (read-only): `.reference/CodexBar/Sources/CodexBar/` (Preferences*, ProviderRegistry/ToggleStore, ProviderSwitcher*, MenuCardView) e `.../CodexBarCore/Providers/ProviderDescriptor.swift`.
> Stato attuale studiato: `Sources/ClaudeBarApp/Settings/{PreferencesView,SettingsStore}.swift`, `Panel/{PanelContentView,PanelViewModel,Model/AppModelPanelAdapter}.swift`, `Panel/Sections/{LimitsSection,AnalyticsSection,PanelStateViews}.swift`, `Panel/DesignSystem/DesignSystem.swift`, `State/{AppModel,AppStatus}.swift`.

Questo documento propone (a) le **Impostazioni** multi-provider da creare, (b) come adattare il **pannello Liquid Glass** a renderizzare un `ProviderSnapshot` generico (limiti vs usage+costo), (c) il **provider switcher** e la scelta **1 vs N provider attivi**. Le decisioni di prodotto aperte sono marcate **[DECIDE TEAM-LEAD]**.

⚠️ **Dipendenza Fase B**: le interfacce dominio (`ProviderSnapshot`, `ProviderDescriptor`, modello auth, contratto Settings) sono di `provider-architect` e vanno **CONGELATE** prima di implementare. Qui propongo solo come la UI le consuma; coordinamento sul modello Settings da concordare con lui.

---

## 0. Sintesi (TL;DR per il team-lead)

1. **Impostazioni nuove**: aggiungere un tab **"Provider"** al `PreferencesView` esistente (resta `TabView`: Generale · **Provider** · Icona · Notifiche). Il tab Provider = **lista provider** (master-detail leggero) con: enable/disable, stato auth, configurazione credenziali (API key in SecureField → **Keychain**; "Connetti/Login" per OAuth/CLI), e — in cima — la scelta del **provider di default** + toggle **auto-rileva**.
2. **Pannello adattabile**: generalizzare il protocollo `PanelViewModeling` da "tipi Claude" a un **`ProviderSnapshot` neutro** che porta DUE famiglie opzionali di dati: `windows: [UsageWindowVM]` (limiti → layout attuale anelli+pace) **e** `usageCost: UsageCostVM?` (API a consumo → layout usage+costo). Il pannello sceglie il layout in base a cosa è presente. **Default Claude abbonamento = identico a oggi (zero regressioni).**
3. **Provider switcher**: un selettore compatto nell'**header del pannello** (segmented/menu glass) per cambiare provider visualizzato, mostrato **solo se ≥2 provider abilitati**. La barra menu segue il provider attivo (vedi §4).
4. **1 vs N provider attivi** **[DECIDE TEAM-LEAD]**: raccomando il modello **"un provider attivo nell'icona + switcher nel pannello"** per l'MVP multi-provider (semplice, non regressivo, vicino alla UX attuale). Alternative più ricche (icona unita / item per-provider) descritte in §4.3.

---

## 1. Stato attuale (cosa esiste e va riusato/non rotto)

### 1.1 Impostazioni attuali (`Settings/`)
- **`PreferencesView`** = `TabView` con 3 tab (`Generale`, `Icona`, `Notifiche`), `Form` `.grouped`, larghezza fissa 420. Si lega a `@Bindable settings`.
- **`SettingsStore`** = `@MainActor @Observable`, backing `UserDefaults` con prefisso `clbar.` (`AppInfo.defaultsPrefix`), ogni `didSet` persiste e chiama `onChange?()` per propagare ai sottosistemi (scheduler, glance, launch-at-login). Chiavi attuali: `usageSource`, `refreshInterval`, `launchAtLogin`, `showUsedInsteadOfRemaining`, `glanceStyle`, `showPercentLabel`, `monochromeIcon`, `warnThreshold`, `criticalThreshold`, `notifyOnSessionThreshold`, `notifyOnWeeklyReset`, `pricingOverridePath`.
- Nessun concetto di provider, auth/Keychain UI, default, o catalogo. **Tutto da aggiungere.**

### 1.2 Pannello attuale (`Panel/`)
- **`PanelContentView<Model: PanelViewModeling>`**: `GlassEffectContainer` → `PanelHeaderView` → `limitsArea` (switch su `PanelState`) → divider → `ScrollView { AnalyticsSection }`. Cornice `GlassPanel` neutra, ombra, animazione apertura. Larghezza/altezza fisse (`DS.Size.panelWidth/panelMaxHeight`).
- **`PanelViewModeling`** (protocollo che la view consuma): `state`, `account`, `lastUpdated`, `isRefreshing`, `criticalWindow`, `windows: [UsageWindowVM]`, `analytics`, azioni (`refresh/retry/openSettings/reconnect/setRange/panelDidOpen`). Implementato da `AppModelPanelAdapter` (traduce tipi Core → VM) e dal `MockPanelViewModel`.
- Tipi VM presentazionali (in `PanelViewModel.swift`): `UsageWindowVM` (utilization%, resetsAt, pace), `PaceInfo`, `AnalyticsVM`, `AccountVM`, `PanelState`.
- Componenti riusabili: `LimitsSection` (anelli grandi + cap rows), `UsageRing`, `PaceBar`, `AnalyticsSection`, `MiniUsageBar`, `EyebrowTag`, `ResetCountdown`, `KPITile`, `TokenBreakdownCard`, `BreakdownDisclosure`, `SpendChart`, banner di stato (`PanelStateViews`).
- **`DesignSystem` (DS)**: spacing/radius/size/motion + `UsageColorScale` (delega a `IconRenderer.color` → coerenza glance↔glass) + `dsCardBezel()`. Vetro NEUTRO, niente tinta clay (commento esplicito).

### 1.3 Come è cablato (punti d'aggancio per Fase B)
- `AppModel` (`@Observable @MainActor`) è l'unica fonte di verità; possiede `settings`, `limits: LimitsSnapshot?`, `analytics`, `status`, `glanceSpec`. `recomputeGlance()` legge `settings.glanceStyle/percentLabel/monochromeIcon` e i `limits`. `applySettingsChange()` (chiamato da `settings.onChange`) ripropaga a launch-at-login e glance.
- L'adapter `AppModelPanelAdapter` è il **punto naturale** dove leggere il provider attivo e tradurre il suo snapshot in VM. Quando l'architettura introdurrà un `activeProvider`/`providerSnapshots`, l'adapter li mappa esattamente come fa oggi con `limits`/`analytics`.

---

## 2. Come CodexBar fa provider settings/switcher (lezioni utili)

CodexBar gestisce ~45 provider; noi ne vogliamo ~5. Estraggo i pattern utili, NON la scala.

### 2.1 Catalogo + toggle + ordine
- `ProviderDescriptor` (Core) per ogni provider: `id`, `metadata` (displayName, cliName, `defaultEnabled`), `branding` (icona), `tokenCost` (supporta costo token?), `fetchPlan`, `cli`. Registro statico `ProviderDescriptorRegistry`.
- **`ProviderToggleStore`**: enable/disable per provider in un singolo dict `[cliName: Bool]` in `UserDefaults` (default = `metadata.defaultEnabled`). Semplice e robusto → **lo adottiamo** (con prefisso `clbar.`).
- Sidebar provider (`ProviderSidebarListView`): ricerca, **drag-to-reorder**, brand icon, status dot, toggle checkbox, subtitle dinamico. Per noi (5 provider) la ricerca/reorder sono **over-engineering** → li ometto nell'MVP (eventualmente reorder in v1).

### 2.2 Detail pane dichiarativo (la parte d'oro per l'auth)
- `ProviderDetailView` rende sezioni costruite da **descrittori dichiarativi**: `ProviderSettingsPickerDescriptor`, `…ToggleDescriptor`, `…FieldDescriptor` (`.plain`/`.secure` → API key!), `…ActionsDescriptor` (bottoni: "Login", "Apri file token"…), `…TokenAccountsDescriptor` (multi-account/API key con label+SecureField+attiva/rimuovi), `…OrganizationsDescriptor`.
- Le righe (`PreferencesProviderSettingsRows.swift`) sono **view generiche** che renderizzano qualsiasi descrittore. **Questo è il pattern che riuso**: ogni provider espone "quali campi auth/opzioni servono", la UI li disegna senza if-per-provider. Per l'MVP basta un set ridotto: `apiKeyField (secure)`, `loginAction (OAuth/CLI)`, `accountInfo`.
- Auth: API key → SecureField → Keychain (mai su disco in chiaro, da BRIEF/DECISIONS). OAuth/CLI → bottone "Connetti/Login" che lancia il flow del provider (es. `claude` login già esistente per Claude).

### 2.3 Switcher (AppKit, NON riusabile 1:1)
- CodexBar usa **NSMenu** classico con `ProviderSwitcherView` + bottoni segment (`PaddedToggleButton`/`StackedToggleButton`) e shortcut da tastiera. È legato all'architettura NSMenu, che **noi non usiamo** (abbiamo NSPanel + SwiftUI Liquid Glass).
- **Lezione concettuale, non codice**: serve un selettore di "provider visualizzato"; in SwiftUI lo realizziamo nativo (segmented/menu glass nell'header) — vedi §4.

### 2.4 Modello a "due famiglie" già presente in CodexBar (validazione del BRIEF)
Il `UsageMenuCardView.Model` di CodexBar unifica già abbonamento e consumo in UN modello:
- `metrics: [Metric]` → finestre/quote (percent + `pacePercent` + `resetText` + `warningMarkerPercents`) = **famiglia "limiti"**.
- `providerCost: ProviderCostSection?` (`percentUsed`, `spendLine`, `percentLine`), `creditsText`/`creditsRemaining`, `tokenUsage: TokenUsageSection?` (sessionLine/monthLine) = **famiglia "usage+costo / credito"**.
- Un campo `progressColor` e `planText`. → Conferma che lo **snapshot unificato con campi opzionali** è la strada giusta.

---

## 3. (a) Le IMPOSTAZIONI da creare

### 3.1 Struttura: un nuovo tab "Provider" nel `PreferencesView` esistente
Mantengo il `TabView` attuale (coerenza, zero attrito). Nuovo ordine:

```
TabView:  Generale · [Provider]  · Icona · Notifiche
```

Il tab **Provider** è un master-detail leggero (no sidebar pesante CodexBar): una **lista verticale** di righe-provider; tap su una riga espande inline (DisclosureGroup) la configurazione di quel provider. Per 5 provider è sufficiente e più "Apple-esque" di una sidebar con ricerca.

```
┌ Provider ─────────────────────────────────┐
│ Default                                    │
│   ◉ Claude (abbonamento)            ▾      │  Picker "Provider di default"
│   ☑︎ Rileva automaticamente i provider      │  Toggle auto-detect
│ ──────────────────────────────────────────│
│ ● Claude            Max · connesso     [⏻] │  riga: brand · stato · enable toggle
│    ▸ (espanso) Auth: Claude Code (OAuth)   │
│       [Riconnetti]   account: martino      │
│ ● Codex / OpenAI    non connesso       [⏻] │
│    ▸ API key  [••••••••••]  [Salva]        │  SecureField → Keychain
│       oppure [Login OpenAI]                 │
│ ○ Gemini            disabilitato       [⏻] │
│ ○ Cursor            disabilitato       [⏻] │
│ ● API a consumo (Anthropic/OpenAI)     [⏻] │
│    ▸ API key  [••••••••••]  [Salva]        │
└────────────────────────────────────────────┘
```

### 3.2 Contenuto per ogni riga-provider
- **Brand/icona** (SF Symbol neutro o asset), **displayName**, **stato auth** ("connesso · Max", "non connesso", "API key salvata", "disabilitato"), **toggle enable/disable** (lega a un `ProviderToggleStore`-equivalente).
- **Espanso (DisclosureGroup)**: la sezione auth costruita da **descrittori** (vedi §3.4), ovvero a seconda del provider:
  - **OAuth/CLI** (Claude oggi, Codex/OpenAI plan): info account + bottone **"Riconnetti/Login"** (lancia il flow del provider; per Claude = guida a `claude` login, già coperto da NoAuthView).
  - **API key** (API a consumo, Gemini, eventualmente OpenAI Admin): **SecureField** + bottone **"Salva"** (scrive in **Keychain**), stato "salvata/assente", bottone "Rimuovi". Multi-key opzionale (post-MVP) sul modello `TokenAccounts` di CodexBar.

### 3.3 Sezione "Default + auto-detect" (in cima al tab)
- **Picker "Provider di default"**: provider mostrato all'avvio / che guida l'icona. Default = **Claude** (DECISIONS: la UX Claude non deve regredire).
- **Toggle "Rileva automaticamente i provider"** (default ON): all'avvio l'app rileva credenziali/abbonamenti disponibili (Keychain Claude, config Codex, ecc.) e abilita+sceglie un default sensato. Se OFF, l'utente gestisce tutto a mano. **La logica di detection è di `provider-architect`/engineer**; la UI espone solo il toggle + mostra l'esito (es. badge "rilevato").
- **[DECIDE TEAM-LEAD]**: se l'auto-detect debba poter **sovrascrivere** una scelta manuale dell'utente (proposta: no — la scelta manuale vince; auto-detect riempie solo i vuoti).

### 3.4 Modello dati Settings (coordinare con provider-architect)
Propongo di estendere `SettingsStore` (stesso pattern `clbar.` + `onChange`) con:
- `enabledProviders: [ProviderID: Bool]` (backing dict in UserDefaults, default da `descriptor.defaultEnabled`) — equivalente di `ProviderToggleStore`.
- `defaultProviderID: ProviderID` (default `.claude`).
- `autoDetectProviders: Bool` (default true).
- (per-provider) preferenze leggere non-segrete (es. sorgente/opzioni) come oggi.
- **Segreti (API key) NON nello SettingsStore/UserDefaults**: vivono in **Keychain**, accedute via un servizio Core (`provider-architect`/`data-engineer`). La UI passa per un'astrazione tipo `secretStore.set(key, for: provider)` — **interfaccia da CONGELARE**.

> Nota concorrenza: il modello provider (`ProviderID`, descriptor) deve essere `Sendable` ai confini (vincolo BRIEF). La UI usa solo value types nel main actor.

### 3.5 Cosa mostra la barra (icona)
Nuova sezione nel tab **Icona** (o sotto Provider): **"L'icona segue"** → Picker:
- **Provider di default** (raccomandato, MVP).
- **Provider attivo** (segue lo switcher del pannello).
- **[v1]** Più provider (icona unita) — vedi §4.3, **[DECIDE TEAM-LEAD]**.
Le opzioni glance esistenti (anello/dualBar, %, monocromo, soglie) restano invariate e valgono per il provider mostrato nell'icona.

---

## 4. (c) Provider switcher + "1 vs N provider attivi"

### 4.1 Raccomandazione MVP (semplice, non regressivo)
**Un provider "attivo" guida l'icona (default = Claude); il pannello ha uno switcher per cambiare il provider visualizzato.** Vantaggi: vicinissimo alla UX attuale; con 1 solo provider abilitato lo switcher sparisce e tutto è identico a oggi (zero regressioni); coerente col glance "una finestra critica".

### 4.2 Switcher nel pannello (SwiftUI, vetro neutro)
- Posizione: **header del pannello**, accanto/sotto l'identità account. Mostrato **solo se ≥2 provider abilitati**.
- Forma: **segmented control** se 2–4 provider (brand icon + nome corto), oppure **menu pull-down glass** (`.buttonStyle(.glass).tint(.clear)`) se di più. Vive nello **stesso `GlassEffectContainer`** del contenitore (regola liquid-glass: glass solo sul layer contenitore).
- Selezione → `model.setActiveProvider(id)` (nuova azione del protocollo). Cambio animato (`.contentTransition`/morphing) del corpo del pannello.
- Accessibilità: ogni segmento ha label "Provider X, N% usato/stato".

### 4.3 Alternative (per il team-lead, se vuole più ricchezza)
- **B — Item per-provider nella barra**: un `NSStatusItem` per provider abilitato (più icone in barra). Massima visibilità a colpo d'occhio ma occupa spazio; CodexBar lo supporta. Post-MVP.
- **C — Icona unita ("merged")**: una sola icona che riassume il provider più critico tra tutti gli abilitati (come CodexBar `shouldMergeIcons`). Elegante ma richiede regole di aggregazione + il glance perde la chiarezza "una finestra". Da valutare in v1.
- **D — Solo default, niente switcher**: l'utente cambia provider solo dalle Impostazioni. Più minimale; perde l'immediatezza.

> **[DECIDE TEAM-LEAD con l'utente]**: A (raccomandato) vs B/C. Propendo per **A** nell'MVP, con la porta aperta a C in v1. Martino preferisce semplicità/minimalismo (memoria utente) → A si sposa meglio.

---

## 5. (b) Adattare il PANNELLO a un `ProviderSnapshot` generico

### 5.1 Principio
Il pannello oggi assume "Claude abbonamento". Lo generalizziamo introducendo nel protocollo presentazionale un **layout-kind derivato dai dati presenti**, NON da un `if provider == .claude`:
- Se lo snapshot ha **finestre limite** (`windows` non vuoto) → **layout "Limiti"** = ESATTAMENTE quello attuale (anelli grandi + PaceBar + cap rows). Default Claude.
- Se lo snapshot ha **usage+costo** (`usageCost != nil`) e NESSUNA finestra → **layout "Usage+Costo"** (nuovo, per API a consumo).
- Se ha **entrambi** (raro: es. Codex plan + costo) → layout "Limiti" in alto + una card "Costo" in più (riuso `KPITile`/breakdown). 

Le **analytics locali** (`AnalyticsSection`) restano sotto in entrambi i casi (degradazione elegante invariata).

### 5.2 Estensione del protocollo `PanelViewModeling` (proposta UI — coordinare nomi con architect)
Aggiungere (senza rompere i campi attuali, che restano per il path Claude):
```swift
// Identità provider corrente (per header/switcher)
var activeProviderID: ProviderID { get }
var availableProviders: [ProviderChip] { get }   // chip = id, nome, brand, stato/colore
func setActiveProvider(_ id: ProviderID)

// Famiglia "usage + costo" (nil per gli abbonamenti come Claude)
var usageCost: UsageCostVM? { get }
```
Dove i nuovi VM (presentazionali, `Sendable`):
```swift
struct ProviderChip: Sendable, Identifiable { let id: ProviderID; let name: String; let symbol: String; let stateColor: Color? }

struct UsageCostVM: Sendable {
    // Costo speso nei periodi (questo provider, dati ufficiali del provider, non la stima locale).
    let costToday: Double?
    let costMonth: Double?
    let costDeltaPct: Double?          // delta vs periodo prec.
    // Credito/budget residuo se l'API lo espone (es. OpenRouter/Anthropic credit).
    let creditRemaining: Double?
    let creditTotal: Double?
    // Usage in token/richieste se disponibile (per-modello opzionale).
    let usageSeries: [SpendPoint]      // riuso SpendPoint esistente
    let byModel: [BreakdownItem]       // riuso BreakdownItem esistente
    let currencyCode: String           // default "USD"
    let note: String?                  // es. "dati pay-as-you-go ufficiali"
}
```
> Questi nomi sono **proposte UI**. Se l'architect definisce un `ProviderSnapshot` Core con altri nomi, l'`AppModelPanelAdapter` traduce → VM (come fa già oggi). NON rinominare le interfacce congelate; eventualmente la UI si adatta nell'adapter.

### 5.3 Nuovo componente: `UsageCostSection` (layout "usage+costo")
Riusa il linguaggio visivo esistente (vetro neutro, `dsCardBezel`, KPITile, SpendChart, BreakdownDisclosure):
```
┌──────────────────────────────────────┐
│  ◐ OpenAI · API a consumo    8s ⟳ ⚙︎ │  header (switcher se ≥2 provider)
│                                        │
│  USO A CONSUMO                         │  eyebrow (sostituisce gli anelli)
│  ┌──────────────┐ ┌──────────────┐    │
│  │ Costo oggi   │ │ Questo mese  │    │  due KPITile (riuso)
│  │ $1.20  ↑8%   │ │ $34.10       │    │
│  └──────────────┘ └──────────────┘    │
│  Credito residuo  $65.90 / $100  ▓▓░  │  barra credito (riuso MiniUsageBar)
│  ▁▂▃▅▇▆  (spesa nel tempo)            │  SpendChart (riuso)
│  Per modello ▸                         │  BreakdownDisclosure (riuso)
│ ──────────────────────────────────────│
│  ANALYTICS (locali, come oggi)         │  AnalyticsSection invariata
└──────────────────────────────────────┘
```
- Niente anelli/pace (non ci sono finestre limite). Se manca il costo ufficiale → mostra solo le analytics locali (degradazione elegante, come per i limiti).
- Credito residuo opzionale: barra orizzontale (riuso `MiniUsageBar` con used = speso/totale) + testo.

### 5.4 Punto di switch nel `PanelContentView`
`limitsArea` diventa `providerArea` con un ulteriore switch DOPO lo `state`:
```swift
switch model.state {
case .ok, .stale:
    if !model.windows.isEmpty {
        LimitsSection(...)        // layout attuale (Claude e altri abbonamenti)
    } else if let cost = model.usageCost {
        UsageCostSection(cost: cost)   // layout API a consumo
    } else {
        // né limiti né costo → solo analytics (sotto)
    }
case .loading/.error/.noAuth/.noSubscription:
    // banner esistenti (riusati); .noAuth diventa generico per-provider
}
```
- Gli stati `.noAuth`/`.error` esistenti vanno **generalizzati per provider** (testo "Accedi a {provider}" invece di "Claude" hardcoded). Il messaggio viene dal VM/snapshot, non hardcoded nella view.
- **Default Claude**: `windows` non vuoto → `LimitsSection` come oggi. **Nessuna regressione**: il path attuale è invariato finché `usageCost == nil` e `windows` popolato.

### 5.5 Header generalizzato
`PanelHeaderView` oggi mostra `account`+`plan`. Generalizzare a: brand+nome provider, stato (account/"API a consumo"), e — se ≥2 provider — lo **switcher** (§4.2). Il `statusColor` resta dal provider critico/attivo. Cambi minimi, riuso del componente.

---

## 6. Vincoli rispettati / rischi

- **Zero regressioni Claude**: il layout "Limiti" è il path di default e non cambia; lo switcher è nascosto con 1 provider. I 45 test e la UX attuale restano. Default = vista Claude abbonamento.
- **Vetro NEUTRO** mantenuto: switcher e nuove card usano gli stessi token DS (`dsCardBezel`, `GlassEffectContainer`, `.glass`+`.tint(.clear)`), nessuna tinta.
- **Segreti in Keychain**: API key SEMPRE via SecureField → servizio Keychain (mai UserDefaults/disco). Interfaccia da congelare con architect/data-engineer.
- **Sendable/concorrenza**: VM presentazionali value-type su MainActor; `ProviderID`/snapshot Sendable ai confini.
- **Riuso massimo**: `LimitsSection`, `UsageRing`, `PaceBar`, `AnalyticsSection`, `KPITile`, `SpendChart`, `BreakdownDisclosure`, `MiniUsageBar`, `dsCardBezel`. Nuovi: `UsageCostSection`, `ProviderSwitcher` (header), tab `Provider` in `PreferencesView`, righe auth dichiarative.
- **Rischio principale**: i NOMI delle interfacce (snapshot, ProviderID, secretStore, contratto Settings) dipendono da `provider-architect`. **Non implemento finché non sono congelati**; appena pubblicati, traduco nell'adapter e adatto i VM senza rinominare.
- **Rischio minore**: i descrittori auth dichiarativi vanno tarati sull'astrazione reale dei provider (Claude OAuth vs API key vs CLI). Tengo un set minimo (apiKeyField/loginAction/accountInfo) estendibile.

---

## 7. Punti che chiedo al team-lead di decidere

1. **1 vs N provider attivi** (§4): raccomando **A** (1 attivo + switcher nel pannello, icona = default). Confermare o scegliere B/C/D.
2. **Cosa segue l'icona** (§3.5): "provider di default" (raccomandato) vs "provider attivo".
3. **Auto-detect può sovrascrivere scelte manuali?** (§3.3): proposta = no, riempie solo i vuoti.
4. **Cookie-auth** (BRIEF stretch): confermo di **escluderlo** dall'MVP UI (più invasivo). Le righe auth restano API key + OAuth/CLI.
5. **Multi-key/multi-account per provider**: post-MVP (modello `TokenAccounts` pronto in CodexBar se servirà).

## 8. Piano Fase B (quando le interfacce sono congelate)

1. Coordinare con `provider-architect` su: `ProviderID`, `ProviderSnapshot` (campi limiti vs usage/costo), servizio Keychain segreti, contratto Settings (`enabledProviders`/`defaultProviderID`/`autoDetectProviders`).
2. Estendere `SettingsStore` (provider toggles/default/auto-detect) + servizio segreti Keychain.
3. Implementare tab **Provider** nel `PreferencesView` (lista + righe auth dichiarative). Compilare.
4. Estendere `PanelViewModeling` + `AppModelPanelAdapter` (activeProvider, availableProviders, usageCost, setActiveProvider). Compilare.
5. Implementare `UsageCostSection` + `ProviderSwitcher` (header) + generalizzare banner stato per-provider. Compilare spesso.
6. Verificare zero regressioni sul path Claude (preview + app reale). Aggiungere test dove sensato.

---

## 9. STATO FINALE — implementato + recepimento DECISIONI (giu 2026)

Le interfacce Core sono state CONGELATE da `provider-architect` (`docs/plan/mp/01-architecture.md`) e il
checkpoint utente è chiuso (`docs/plan/mp/DECISIONS.md`). Tutto implementato, build verde, 142 test verdi,
app si avvia senza crash. Default Claude = UX invariata (switcher nascosto con 1 provider; layout limiti
immutato finché `windows` è popolato).

### 9.1 File toccati/creati (app)
- `Settings/SettingsStore.swift`: possiede `MultiProviderSettings` (JSON in `clbar.multiProvider`, fallback `.initial`), helper immutabili, `activeProviderID`. Segreti NON qui.
- `Settings/ProviderCatalog.swift` (nuovo): descriptor di catalogo per ogni `ProviderID` = descriptor REALE del provider concreto (Claude/Codex/Gemini/Cursor/OpenAIAPI/AnthropicAPI) → sempre allineato alle correzioni additive Core (es. Gemini, Cursor).
- `Settings/ProvidersPreferencesView.swift` (nuovo): tab "Provider" (lista, enable/disable, default, auto-detect, bar mode + sezione auth per tipo).
- `Settings/PreferencesView.swift`: aggiunto il tab Provider (Generale · Provider · Icona · Notifiche).
- `Panel/Model/PanelViewModel.swift`: VM nuovi (`ProviderChipVM`, `UsageCostVM`, `CostBucketVM`, `CreditsVM`) + protocollo esteso con default in extension (zero rotture).
- `Panel/Model/AppModelPanelAdapter.swift` + `MockPanelViewModel.swift`: cablaggio switcher/provider attivo da `multiProvider`.
- `Panel/Sections/UsageCostSection.swift` (nuovo): layout usage+costo+credito (riuso `SpendChart`/`MiniUsageBar`/`dsCardBezel`).
- `Panel/Components/ProviderSwitcher.swift` (nuovo): switcher header, vetro neutro, ≥2 provider.
- `Panel/PanelContentView.swift`: `providerArea` sceglie il layout dai dati; `NoAuthView` generalizzata.
- `Panel/Sections/PanelStateViews.swift`: `NoAuthView` parametrica per provider/messaggio.

### 9.2 Recepimento DECISIONS (cosa è cambiato rispetto alla proposta Fase A)
- **Display = single + switcher** (opzione A, come raccomandato): confermato. `barDisplayMode` è FISSO `singleActive` (DECISIONS #1): **nessun Picker in UI** (rimosso). L'enum `BarDisplayMode` e `setBarDisplayMode` restano nel modello deprecati per compat-Codable dei dati persistiti, ma non sono più una scelta utente — c'è un solo modo (1 provider attivo nella barra + switcher nel pannello).
- **L'icona segue il PROVIDER ATTIVO** (non un "default" separato): `activeProviderID` deriva il default scelto; `setActiveProvider` lo aggiorna → glance ricalcolato via `onChange`.
- **Config auth per tipo** (DECISIONS §Impostazioni + Addendum):
  - Claude/Codex/Gemini = `.oauthManaged` → riga "Rilevato da CLI/OAuth" (sola lettura) + link dashboard.
  - **Cursor = `.browserCookie`** → campo "Incolla il cookie di sessione" → Keychain (riga `SecretFieldAuthRow`). Cookie-auth INCLUSO solo per Cursor.
  - **OpenAI/Anthropic API = `.apiKey`** → campo "Admin API key (org)" → Keychain, con footnote-avviso "richiede Admin key org; senza/401-403 il provider resta visibile con avviso".
- **Layout pannello**: Claude/Codex/Gemini/Cursor → limiti (anelli+Pace); OpenAI/Anthropic API → usage+costo. Scelto DAI DATI (`windows` vs `cost`/`credits`), non da `if provider`.
- **Auto-detect riempie solo i vuoti** (non sovrascrive scelte manuali): è politica del Core (`ProviderRegistry.autoDetectDefault`); la UI espone il solo toggle.
- **Multi-account/multi-key = post-MVP**: single-account per provider (`selectedAccount = "default"`).

### 9.3 Dipendenza residua (handoff a MP-7 / core-engineer)
Per accendere i dati reali usage+costo/limiti dei provider NON-Claude nel pannello manca solo l'integrazione
`AppModel` (task #16 MP-7): consumare lo `ProviderSnapshot` del **provider attivo** e mapparlo in VM, come
l'adapter già fa con `LimitsSnapshot`. Il lato UI è pronto: `usageCost`/`credits`/`windows` dell'adapter
vanno valorizzati dallo snapshot del provider attivo, e tutto si accende senza ulteriori modifiche alla UI.
