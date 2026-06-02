# ClaudeBar — Impostazioni "vere" — Architettura & contratto (SET-1)

> Autore: `settings-architect`. Questo documento CONGELA il modello e il contratto di sezione.
> Leggere prima: `BRIEF.md` + `../DECISIONS.md`. In caso di conflitto, `DECISIONS.md` fa fede.
>
> REGOLA D'ORO (lezione fasi precedenti): una volta congelato, **niente rinomine in parallelo**.
> Per aggiungere un'opzione si aggiunge una proprietà al `SettingsStore` (default + persistenza)
> e la si lega nella propria view di sezione. NON si toccano: lo `SettingsRootView` (shell),
> l'enum `SettingsSection`, le firme pubbliche del `SettingsStore`, lo scaffold.

## 1. Modello: `SettingsStore` (unificato)

`Sources/ClaudeBarApp/Settings/SettingsStore.swift` — `@MainActor @Observable`.
Backing: `UserDefaults` con prefisso `clbar.`. Ogni `didSet` persiste e invoca `onChange`
(impostato dall'`AppDelegate`) per propagare ai sottosistemi (scheduler, icona, launch-at-login,
aspetto). I **segreti NON sono nel modello**: vivono in Keychain via `ProviderSecretStore`.

### Proprietà (tutte con default sensato → senza tocchi l'app si comporta come oggi)

| Sezione | Proprietà | Tipo | Default | Cablata da |
|---|---|---|---|---|
| Generale | `refreshInterval` | `RefreshInterval` | `.fiveMinutes` | SET-1 → `RefreshScheduler` |
| Generale | `appearance` | `AppAppearance` | `.system` | SET-1 → `NSApp.appearance` |
| Generale | `launchAtLogin` | `Bool` | `false` | SET-1 → `SMAppService` |
| Generale | `refreshOnPanelOpen` | `Bool` | `true` | SET-1 → `AppModel.panelDidOpen()` |
| Generale | `refreshOnWake` | `Bool` | `true` | SET-1 → `AppModel.handleWake()` |
| Generale | `usageSource` | `UsageSource` | `.auto` | (esistente) |
| Menu bar | `glanceStyle` | `GlanceStyle` | `.ring` | esistente → glance |
| Menu bar | `showPercentLabel` | `Bool` | `true` | esistente → glance |
| Menu bar | `numberContent` | `GlanceNumberContent` | `.used` | esistente (via `percentLabel`) |
| Menu bar | `monochromeIcon` | `Bool` | `false` | esistente → glance |
| Menu bar | `pulseOnCritical` | `Bool` | `true` | SET-1 → `AppModel.recomputeGlance()` |
| Menu bar | `warnThreshold` | `Double` | `0.60` | esistente → soglie colore |
| Menu bar | `criticalThreshold` | `Double` | `0.85` | esistente → soglie colore |
| Notifiche | `notifyOnSessionThreshold` | `Bool` | `true` | esistente |
| Notifiche | `notifyOnWeeklyReset` | `Bool` | `true` | esistente |
| Notifiche | `notificationSound` | `Bool` | `true` | SET-1 → `AppNotifications` |
| Notifiche | `sessionThresholds` | `[Int]` (1...99) | `[50,75,90]` | SET-1 → `AppNotifications` |
| Analytics | `defaultAnalyticsRange` | `AnalyticsRange` | `.today` | SET-1 → `AppModel.analyticsRange` |
| Analytics | `includeSubagentsInAnalytics` | `Bool` | `true` | SET-3 (vedi §4) |
| Analytics | `showCostDisclaimer` | `Bool` | `true` | SET-3 (vedi §4) |
| Analytics | `pricingOverridePath` | `String?` | `nil` | esistente |
| Provider | `multiProvider` | `MultiProviderSettings` | `.initial` | esistente (helper di mutazione) |

### Note di modello
- `numberContent` (`.used`/`.remaining`) sostituisce concettualmente il vecchio
  `showUsedInsteadOfRemaining`, che resta come **compat get/set** derivato (e tiene allineata la
  vecchia chiave UserDefaults). `percentLabel` deriva da `showPercentLabel` + `numberContent`.
  **LOCK glance**: arco e colore restano SEMPRE sull'% USATO; `numberContent` cambia solo il TESTO.
- `sessionThresholds`: normalizzate in-place dal `didSet` (clamp 1...99, dedup, ordina) via
  `SettingsStore.normalizeThresholds(_:)`. Persistite come CSV in `clbar.sessionThresholds`.
- `schemaVersion` (`static let = 1`) scritta al primo avvio. I campi sono additivi-con-default,
  quindi nessuna migrazione distruttiva oggi.
- `resetToDefaults()`: riporta TUTTE le preferenze ai default (segreti Keychain esclusi). Usata
  dalla sezione Avanzato (SET-4).

## 2. Shell della finestra

`Sources/ClaudeBarApp/Settings/SettingsRootView.swift` — `NavigationSplitView` (sidebar di
sezioni + dettaglio). Ridimensionabile: `minWidth 640 / ideal 700`, sidebar 184–220.
Vetro NEUTRO: la chrome/sidebar adottano il vetro di sistema (macOS 26) automaticamente; il
CONTENUTO usa `GroupBox` (materiale di sistema), **mai** `.glassEffect()` (regola Liquid Glass:
glass solo sul navigation layer). Nessuna tinta (`DECISIONS §3`).

La scene `Settings` in `ClaudeBarMain.swift` ospita `SettingsRootView`; `openPreferences()`
nell'`AppModel` è **invariato**. `windowResizability(.contentMinSize)` per lasciar ridimensionare.

## 3. Contratto di sezione (CONGELATO)

`Sources/ClaudeBarApp/Settings/SettingsSection.swift` — enum delle 7 sezioni.
`Sources/ClaudeBarApp/Settings/SettingsSectionScaffold.swift` — i 3 componenti del contratto:

- `SettingsSectionScaffold(section:) { content }` — header (titolo+sottotitolo) + ScrollView.
- `SettingsGroup("Titolo", footnote:) { ... }` — gruppo etichettato (`GroupBox`), come una `Section`.
- `SettingsRow("Etichetta", caption:) { control }` — riga etichetta↔controllo (opzionale, helper).
- `SettingsSectionPlaceholder(section:)` — riempitivo per le sezioni non ancora pronte.

Lo shell risolve la view di dettaglio in `SettingsRootView.detail(for:)`. Ogni implementatore
**sostituisce il proprio `SettingsSectionPlaceholder` con la propria view** (firme in §4) e
aggiorna SOLO la riga `case` corrispondente in `detail(for:)`.

Riferimento cablato completo: `Sections/GeneralSettingsSection.swift` (sezione Generale, SET-1).

## 4. Firme per gli implementatori (Fase B)

Ogni view di sezione è un `struct: View` con `@Bindable var settings: SettingsStore`
(+ `secretStore` dove serve). Vivono in `Sources/ClaudeBarApp/Settings/Sections/`.

### SET-2 (settings-general-engineer) — Menu bar/Icona
```swift
struct MenuBarSettingsSection: View {
    @Bindable var settings: SettingsStore
    // Lega: glanceStyle, showPercentLabel, numberContent, monochromeIcon, pulseOnCritical,
    //       warnThreshold, criticalThreshold. (Generale è GIÀ fatta da SET-1.)
}
```
Aggancio shell: `case .menuBar: MenuBarSettingsSection(settings: self.settings)`.

### SET-3 (settings-providers-engineer) — Provider, Notifiche, Analytics
```swift
struct ProvidersSettingsSection: View {            // avvolge la lista provider esistente
    @Bindable var settings: SettingsStore
    let secretStore: any ProviderSecretStoring     // riusa ProviderRow/SecretFieldAuthRow
}
struct NotificationsSettingsSection: View {
    @Bindable var settings: SettingsStore
    // Lega: notifyOnSessionThreshold, sessionThresholds (editor [Int]), notifyOnWeeklyReset,
    //       notificationSound. (Soglie GIÀ cablate alle notifiche da SET-1, vedi §5.)
}
struct AnalyticsSettingsSection: View {
    @Bindable var settings: SettingsStore
    // Lega: defaultAnalyticsRange, includeSubagentsInAnalytics, showCostDisclaimer,
    //       pricingOverridePath. NB: includeSubagents/showCostDisclaimer sono persistite ma il
    //       loro EFFETTO sull'indexer/UI costo è da agganciare (coordinare con data/ui-engineer).
}
```
Aggancio shell: i tre `case` `.providers`/`.notifications`/`.analytics` in `detail(for:)`.
`ProvidersSettingsSection` riceve `secretStore` (lo shell ha già `self.secretStore`).

### SET-4 (settings-advanced-engineer) — Avanzato, Info
```swift
struct AdvancedSettingsSection: View {
    @Bindable var settings: SettingsStore
    let secretStore: any ProviderSecretStoring
    // Azioni e API congelate (NON ricreare la logica filesystem nella UI):
    //  - Posizione dati (sola lettura): ClaudeBarCore.AppPaths.transcriptRoots()/appSupportDir()/indexDir().
    //  - Reset di tutte le impostazioni: settings.resetToDefaults() — GIÀ pronto (segreti Keychain esclusi).
    //  - Azzera/ricostruisci cache indice: model.clearIndexCacheAndRebuild() async — GIÀ pronto
    //    (vedi §7). NB: serve un riferimento all'AppModel nella view (vedi nota sotto).
    //  - Esporta analytics (CSV/JSON): da AnalyticsReport via NSSavePanel.
    //  - Diagnostica (copia log): NSPasteboard.
    //  - Usare confirmationDialog ATTACCATO al trigger sui distruttivi.
}
struct AboutSettingsSection: View {
    // Nome/versione/build via AppInfo (displayName/shortVersion/buildNumber), crediti, link.
}
```
NOTA AppModel per SET-4: `clearIndexCacheAndRebuild()` vive sull'AppModel, non sul SettingsStore.
La view di sezione riceve `settings` (e `secretStore`); per l'azione "azzera cache" servirà anche
un handle al model — opzioni concordate: o si passa una closure `onClearCache: () async -> Void`
alla `AdvancedSettingsSection` agganciata nello shell, o si espone l'AppModel via Environment.
Decidi tu l'iniezione (NON cambiare la firma di clearIndexCacheAndRebuild) e segnalami il punto
di aggancio in `SettingsRootView.detail(for:)` così aggiorno lo shell di conseguenza.

## 5. Wiring già fatto da SET-1 (NON ri-cablare)

- `refreshInterval` → `RefreshScheduler.setInterval` (via `SettingsStore.onChange` →
  `AppDelegate.handleSettingsChange`). Invariato.
- `appearance` → `AppModel.applyAppearance()` (`NSApp.appearance`), all'avvio e su ogni cambio.
- `launchAtLogin` → `LaunchAtLoginManager.setEnabled` (via `applySettingsChange`). Invariato.
- `refreshOnPanelOpen` / `refreshOnWake` → letti in `AppModel.panelDidOpen()` / `handleWake()`.
- `pulseOnCritical` → letto in `AppModel.recomputeGlance()`.
- `sessionThresholds` + `notificationSound` → passati a
  `AppNotifications.evaluateSessionThresholds(..., thresholds:sound:)` e `evaluateWeeklyReset(..., sound:)`.
  Le firme delle notifiche hanno default backward-compatible (50/75/90, suono on).
- `defaultAnalyticsRange` → inizializza `AppModel.analyticsRange`.
- `warnThreshold` / `criticalThreshold` → pilotano SOLO lo STATO del glance ("Option B", scelta
  DEFINITIVA del team-lead — chiusa, niente più cambi di rotta):
  - STATO semantico (warn/critical/empty → ambra/rosso/pulsa + flag critico nel pannello +
    etichetta OK/AMBRA/CRITICO/ESAURITO live nell'anteprima) via `GlanceClassifier.state`
    (`AppModel.classifyGlance`).
  - Il COLORE-gradiente continuo NON è parametrico: resta la curva FISSA di `IconRenderer.color(forUsed:)`,
    SORGENTE UNICA condivisa icona↔pannello (`UsageColorScale.color(used:)`). Così l'icona menu bar e
    l'anello/pace del pannello hanno SEMPRE lo stesso colore a parità di % usato (LOCK di coerenza).
    `UsageWindowVM.glanceColor` delega alla curva canonica.
  Classificatore `GlanceClassifier` (StatusItem/) condiviso icona↔anteprima Menu bar → stato + colore
  canonico coincidono. Test: `GlanceClassifierTests`.

## 6b. API azioni per la sezione Avanzato (SET-4)

Congelate da SET-1 (build verde, 157 test). NON ricreare logica filesystem nella UI:
- `SettingsStore.resetToDefaults()` — riporta TUTTE le preferenze `clbar.*` ai default (segreti
  Keychain esclusi). Sincrono, riassegna le proprietà → i `didSet` persistono e `onChange` propaga.
- `AppModel.clearIndexCacheAndRebuild() async` — azzera indice incrementale (in-memory + disco) +
  `analytics-cache.json`, poi `refresh(force: true)`. Si appoggia ai metodi di confine
  `TranscriptIndexing.clearCache()` / `PersistenceServicing.clearCache()` (DataServices.swift).
- Path sola lettura: `ClaudeBarCore.AppPaths.transcriptRoots()/appSupportDir()/indexDir()`.

## 6c. Effetto "includi subagent" — CABLATO (catena completa)

Toggle Impostazioni → Analytics (`settings.includeSubagentsInAnalytics`, default `true`) ora ha
effetto reale sugli aggregati. Catena:
`AppModel.refreshAnalytics` → `TranscriptIndexing.refresh(force:includeSubagents:)` → adapter →
`TranscriptIndexer.refresh(force:includeSubagents:)` → `CostCalculator.build(events:includeSubagents:)`
(filtra `allEvents { !$0.isSubagent }` a inizio aggregazione). Default `true` = nessuna regressione.
Il filtro è in AGGREGAZIONE, non nell'indice persistito: cambiare la preferenza e ri-fare un refresh
basta, senza re-parse né clear cache. NB (guardiano): il parametro vive su `CostCalculator.build`
(non in un filtro interno all'indexer) — forma ACCETTATA: testabile in isolamento, uniforme su
byDay/byModel/byProject, additiva con default. Test: `AnalyticsWiringTests` + test subagent di SET-3.

## 6d. Modifiche Core additive per le Impostazioni — FATTE

Entrambe completate (il data-engineer è stato congedato; le ha assorbite il team Impostazioni):
- `TranscriptIndexer.refresh(force:includeSubagents:)` + `CostCalculator.build(includeSubagents:)`
  — filtro subagent (vedi §6c).
- `TranscriptIndexer.clearCache() async` — wrapper su `IncrementalIndex.clear()` (in-memory +
  file in `indexDir()`). `TranscriptIndexerAdapter.clearCache()` ora delega all'attore (niente più
  cancellazione filesystem dall'adapter).

## 6. Stato dei file legacy

- `PreferencesView.swift` (TabView) NON è più referenziato dalla scene `Settings`. Resta
  compilabile come archivio dei componenti riusabili. **SET-3** che riusa `ProviderRow`/
  `SecretFieldAuthRow` da `ProvidersPreferencesView.swift` decide se rimuovere `PreferencesView`
  una volta migrata la sezione Provider. Non rimuoverlo finché i suoi componenti non sono spostati.
