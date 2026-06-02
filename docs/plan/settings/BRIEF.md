# ClaudeBar — Impostazioni "vere" — Brief condiviso

> Leggi PRIMA questo file + docs/plan/DECISIONS.md + docs/plan/mp/DECISIONS.md.
> Obiettivo: trasformare le Impostazioni minime attuali in una **pagina Impostazioni da app vera**,
> con MOLTE opzioni configurabili e ogni controllo CABLATO al comportamento reale.

## Obiettivo (richiesta utente)
"Una pagina di app vera dove seleziono molte cose, tra cui anche **ogni quanto si refresha l'app**."
→ Finestra Impostazioni completa, polished, in stile macOS, con sezioni e tante opzioni reali.
NON un placeholder: ogni toggle/picker deve fare effetto davvero (scheduler, icona, notifiche, ecc.).

## Stato attuale
- `Sources/ClaudeBarApp/Settings/`: `SettingsStore.swift` (@Observable, UserDefaults prefisso `clbar.`,
  possiede `multiProvider: MultiProviderSettings`), `PreferencesView.swift` (TabView: Generale·Provider·Icona·Notifiche — minimale), `ProvidersPreferencesView.swift`, `ProviderCatalog.swift`, `LaunchAtLoginManager.swift` (SMAppService), `Notifications.swift`.
- Comportamenti già esistenti da pilotare: `RefreshScheduler` (preset Manual/1/2/5/15/30m), `IconRenderer`/`StatusItemController` (anello+%), `Notifications` (soglie sessione + celebrazione reset), `AppModel.analyticsRange`, `TranscriptIndexer`/`IncrementalIndex` (cache aggregati su disco), `PricingTable` (+override JSON locale), `appearance`.
- L'apertura: il pulsante ⚙️ del pannello chiama `AppModel.openPreferences()`.
- Build: `swift build` / `swift test` / `CLBAR_CONFIG=release ./Scripts/bundle.sh`. macOS 26, SPM, Swift 6.2.

## Vincoli
- **Vetro neutro**, coerente col DesignSystem (`DS.*`) e con il resto dell'app. NIENTE accenti blu di sistema (l'app è monocroma + colori semantici solo per gli stati). Usa i componenti/stili esistenti dove possibile.
- **Non regredire** nulla (147 test verdi). Aggiungere test per la logica settings (es. refresh interval, persistenza).
- **Segreti SEMPRE in Keychain** (mai UserDefaults): API key, cookie. Riusa `ProviderSecretStore`/`KeychainSecretStore`.
- Ogni opzione **persistita** (UserDefaults `clbar.` per le preferenze; Keychain per i segreti) e con un **default sensato**; se l'utente non tocca nulla l'app si comporta come oggi.
- **Congelare** il modello/contratto delle impostazioni una volta definito dall'architetto: niente rinomine in parallelo (lezione delle fasi precedenti).

## Catalogo opzioni (da rifinire dall'architetto; l'utente vuole "molte cose")
**Generale**: launch-at-login; **intervallo di refresh** (Manuale/1/2/5/15/30m) — richiesta esplicita; refresh all'apertura pannello / al risveglio (toggle); aspetto (Sistema/Chiaro/Scuro); provider attivo + auto-detect.
**Menu bar / Icona**: stile icona (anello / anello+%); mostra etichetta % (on/off); cosa mostra il numero (usato/rimanente); fallback monocromo (on/off); pulsazione su critico (on/off); (la finestra guida = più critica, da DECISIONS — eventualmente esponibile).
**Provider**: (esistente) enable/disable, stato auth + config (API key / incolla cookie Cursor / OAuth-CLI), default.
**Notifiche**: abilita; soglie sessione (set editabile, default 50/75/90); celebrazione reset settimanale; suono on/off; per-provider.
**Analytics**: range di default (Oggi/7g/30g); includi subagent (on/off); mostra disclaimer costo; override pricing (avanzato: carica JSON locale).
**Avanzato**: posizione dati/transcript (info); ricostruisci/azzera cache indice (azione); esporta analytics (CSV/JSON); diagnostica (copia log); reset di tutte le impostazioni.
**Info**: nome/versione/build; crediti; (link opzionali).

## IA consigliata
Finestra Impostazioni in stile **app vera**: `NavigationSplitView` con **sidebar** di sezioni
(Generale · Menu bar · Provider · Notifiche · Analytics · Avanzato · Info) + pannello di dettaglio
con `Form`/`GroupBox` puliti (vetro neutro). Larghezza ~640–720, ridimensionabile. L'architetto
decide e costruisce lo SHELL; gli altri riempiono le sezioni. (Alternativa: TabView arricchito —
ma la sidebar dà la sensazione "app vera" richiesta.)

## Fasi
- **A**: `settings-architect` espande il MODELLO impostazioni + costruisce lo SHELL della finestra
  (navigazione + contratto di sezione) + cabla refresh-interval/appearance/launch-at-login, poi
  CONGELA il contratto e avvisa gli altri.
- **B**: gli altri 3 riempiono le sezioni e cablano ogni opzione al comportamento.

## Output
Codice in `Sources/ClaudeBarApp/Settings/`. Doc in `docs/plan/settings/`. Riportare al team-lead in italiano.
