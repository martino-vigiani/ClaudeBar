# ClaudeBar — Product scope & roadmap (Doc 04)

> Owner: product-lead. Riferimento: `docs/plan/BRIEF.md` (leggere prima).
> Questo documento definisce **cosa** costruiamo e **in che ordine**. Il **come**
> tecnico sta nei doc 01 (data), 02 (app/perf), 03 (UX/design).

---

## 0. In una frase

**ClaudeBar** è una menu bar app macOS 26+ dedicata **solo a Claude** (Claude Code /
abbonamento Max), che mostra a colpo d'occhio quanto resta della finestra di sessione e
settimanale (glance colorato nella barra) e, al click, apre un pannello Liquid Glass con
limiti ufficiali + analytics locali precise e live (costo, token, breakdown per
modello/progetto/sessione, cache, storico).

Posizionamento: **"il cruscotto Claude più curato e preciso del Mac"**. Non un
multi-provider tuttofare, ma uno strumento mono-fuoco fatto benissimo.

---

## 1. Confronto feature-by-feature con CodexBar (lato Claude)

CodexBar è multi-provider (40+). Noi prendiamo **solo la colonna Claude** e la
miglioriamo. Legenda: ✅ replichiamo · ⭐ miglioriamo · ✂️ tagliamo · 🆕 nostra novità.

| Area CodexBar | Cosa fa CodexBar | Decisione ClaudeBar |
|---|---|---|
| **Multi-provider** (40+ provider, toggles, merge icons, switcher) | Cuore dell'app | ✂️ **Tagliato.** Solo Claude. Niente provider pane, niente merge-icons, niente switcher provider. |
| **Limiti sessione 5h + settimanale** (OAuth `/api/oauth/usage`) | Mappa `five_hour`, `seven_day`, `seven_day_opus/sonnet` | ✅ **Replichiamo**, è il core. |
| **Finestre model-specific** (weekly opus / sonnet) | Mostrate come window extra | ✅ Replichiamo nel pannello (sotto la settimanale). |
| **Daily Routines / Cowork** (`seven_day_routines/cowork`) | Window extra opzionale | ⭐ Mostrata se presente, ma de-enfatizzata (non tutti la usano). |
| **Glance icona barra** | Barra/critter 18×18 template, fill = % remaining | ⭐ **Migliorata: glance COLORATO** (anello verde→ambra→rosso) — la nostra firma. CodexBar usa template monocromo; noi vogliamo l'impatto immediato. |
| **Pannello/popover** | NSMenu con righe provider | ⭐ **Migliorato: pannello Liquid Glass** (materiali macOS 26, anelli grandi, grafici). |
| **Analytics locali (cost usage)** | Scan JSONL `~/.claude/projects`, dedup `message.id+requestId`, cache su disco | ⭐ **Migliorato e centrale.** Parsing **incrementale** (offset per-file), breakdown ricco (modello/progetto/sessione/giorno/branch), efficienza cache, trend. In CodexBar è una feature secondaria; per noi è il **vantaggio di precisione**. |
| **Pace tracking** ("in deficit / in reserve", "runs out in…") | Confronto consumo vs rate atteso | ⭐ Replichiamo, ma come **v1** (vedi roadmap), nel pannello. |
| **Refresh cadence** (Manual/1m/2m/5m/15m/30m) | Preset in UserDefaults | ✅ Replichiamo identico (default 5m). |
| **Notifiche soglia sessione + confetti reset** | Opzionali | ✅⭐ Replichiamo, ma **de-dup intelligente per finestra** (vedi §3). |
| **Token auto-refresh** | OAuth auto-refresh + gate fallimenti (terminal vs transient) | ✅ Replichiamo la logica robusta (invalid_grant = block, 400/401 = backoff). È matura, la copiamo concettualmente. |
| **Keychain prompt policy + cooldown** | Never/On-action/Always + cooldown 6h dopo denial | ✅ Replichiamo (semplificata): non vogliamo subissare l'utente di prompt Keychain. |
| **Web API (cookie claude.ai)** | Import cookie Safari/Chrome/Firefox, `sessionKey` | ✂️ **Tagliato dall'MVP** (richiede Full Disk Access, decrypt cookie, attrito privacy). Riconsiderabile v2 se OAuth+CLI non bastano. |
| **CLI PTY fallback** (`claude` in PTY, parse `/usage`) | Fallback quando OAuth non disponibile | ⭐ **v1, non MVP.** Fallback utile ma fragile (parsing ANSI). MVP punta tutto su OAuth. |
| **Admin API** (`sk-ant-admin`, cost_report org) | Spend organizzazione | ✂️ **Tagliato.** È per org/team, non per il singolo utente Max. Fuori scope. |
| **Multi-account** (`tokenAccounts`, stacked/switcher) | Più account manuali | ⭐ **Ridotto:** rileviamo varianti `Claude Code-credentials-<hash>`, MVP usa l'attivo; switcher è **v1**. |
| **WidgetKit widgets** (Usage/History/Metric/Switcher) | 4 famiglie widget | ✂️ **Tagliato dall'MVP**, candidato **v2**. Bello ma non essenziale per uso personale. |
| **CLI bundled** (`codexbar usage/cost/config`) | CLI per script/CI | ✂️ **Tagliato** (uso personale, no CI ora). Eventuale v2. |
| **Provider status polling** (incident badge) | Stato incidenti provider | ✂️ **Tagliato dall'MVP.** Status di Anthropic (status.anthropic.com) è un nice-to-have **v2**. |
| **Provider storage usage scan** | Dimensioni file locali provider | ✂️ **Tagliato.** Niche, fuori fuoco. |
| **Pricing table** (models.dev, cache 24h) | Lookup prezzi per costo | ✅⭐ Replichiamo: pricing table **embedded + override locale**, refresh opzionale da fonte (no API key). Serve per il costo "teorico" delle analytics. |
| **"Show usage as used/remaining"** | Flip percentuale | ✅ Replichiamo (toggle in settings). |
| **Reset display** (countdown vs orologio assoluto) | Stile reset | ✅ Replichiamo (countdown default, opzione assoluto). |
| **Distribuzione** (Homebrew/Sparkle/notarize/AUR/Linux) | Pipeline completa | ✂️ **Tagliato per ora** (uso personale, build locale). Vedi BRIEF §5. |

### Le 5 differenze chiave (il nostro "perché")
1. **Mono-Claude:** zero clutter multi-provider → UI dedicata e leggibile.
2. **Glance COLORATO nella barra** (vs template monocromo di CodexBar) → impatto immediato.
3. **Pannello Liquid Glass** curato (macOS 26) vs NSMenu.
4. **Analytics locali come prima classe**, con **parsing incrementale** → precisione + CPU/RAM bassi.
5. **Notifiche intelligenti** con de-dup per finestra (non spam).

---

## 2. Feature set: MVP → v1 → v2 (prioritizzato)

### MVP (il taglio minimo che è già "wow" e usabile ogni giorno)
Obiettivo: **glance colorato che funziona + pannello che mostra limiti e un'analitica
locale di base, senza far impazzire l'utente con permessi.**

- **M1. Glance barra colorato** sulla sessione 5h (anello/barra verde→ambra→rosso). Click apre il pannello.
- **M2. Dati limiti via OAuth** (`/api/oauth/usage`) letti da Keychain `Claude Code-credentials`, con **auto-refresh** del token. Mostra sessione 5h + settimanale (% usata, reset).
- **M3. Pannello Liquid Glass** con: identità (account/plan inferito), anello Sessione 5h, anello Settimanale, reset countdown, "Refresh now".
- **M4. Analytics locali base:** parsing **incrementale** dei JSONL → **costo oggi**, **token oggi**, **breakdown per modello** (oggi) nel pannello. (Breakdown progetto/sessione/storico = v1.)
- **M5. Pricing table embedded** (con override locale) per calcolare il costo.
- **M6. Notifica soglia sessione** (1 soglia configurabile, default 80%, de-dup per finestra).
- **M7. Celebrazione reset settimanale** (glow/confetti nel pannello + notifica leggera).
- **M8. Settings minime** (vedi §4 MVP).
- **M9. Refresh loop** background (default 5m) + "Refresh now" manuale.
- **M10. Casi limite gestiti con grazia** (vedi §5): nessun abbonamento, token scaduto, primo avvio senza dati.
- **M11. Launch at login** (SMAppService).

**Esplicitamente FUORI dall'MVP:** Web cookie, CLI PTY, multi-account switcher, widget,
pace tracking, status polling, Admin API, CLI bundled, storico/grafici, export.

### v1 (rende l'app "completa" per power user)
- Analytics ricche: breakdown **per progetto / sessione / branch / giorno**; **efficienza cache**; **storico** (grafici Swift Charts: token/costo per giorno, ultimi 30g).
- **Pace tracking** ("in deficit X% / in riserva", "finisce tra…") sulle 2 finestre.
- Finestre **model-specific** (weekly opus/sonnet) e Daily Routines nel pannello.
- **CLI PTY fallback** quando OAuth non disponibile.
- **Multi-account**: rilevamento + switcher.
- Soglie notifica **multiple** (es. 50/80/95%) e notifica reset settimanale opzionale ON/OFF granulare.
- Reset display assoluto, "show usage as used".

### v2 (espansione / distribuzione)
- **Widget WidgetKit** (Usage / History / Metric).
- **Status polling** Anthropic (badge incidenti).
- **Notifiche costo** (soglia spesa teorica giornaliera/mensile) — opt-in.
- **Web cookie** path (solo se serve a utenti senza Claude Code / token OAuth).
- **Distribuzione**: firma + notarizzazione, Sparkle auto-update, eventuale Homebrew cask.
- Eventuale **CLI** companion / export CSV-JSON delle analytics.

---

## 3. Comportamento notifiche (dettaglio)

Tutte le notifiche usano `UNUserNotificationCenter`. Permesso richiesto **al primo
arming di una notifica**, non al primo avvio (meno attrito). Se negato: degradare a
indicatore visivo nel pannello, nessun retry aggressivo.

### 3.1 Soglia sessione (MVP)
- **Trigger:** quando la **% usata della finestra sessione 5h** supera la soglia configurata (default **80%**).
- **De-dup per finestra:** **max 1 notifica per soglia per finestra**. La finestra è identificata dal suo timestamp di reset; al reset (nuova finestra) il flag si azzera. Niente notifiche ripetute a ogni refresh sopra soglia.
- **Copy esempio:** "Sessione Claude all'82% — reset tra 1h 12m."
- **Click sulla notifica:** apre il pannello.
- v1: soglie multiple (50/80/95) ciascuna con il proprio flag de-dup per finestra.

### 3.2 Reset settimanale = celebrazione (MVP)
- **Trigger:** quando si osserva che la **finestra settimanale è ripartita** (reset rilevato: il nuovo reset > vecchio reset, oppure % crollata a ~0 dopo essere stata alta).
- **Effetto in-app:** glow/"confetti" animato nel pannello alla prossima apertura (animazione Liquid Glass), una tantum per reset.
- **Notifica:** leggera e positiva — "Settimana Claude resettata. Hai di nuovo il 100% del budget settimanale."
- De-dup: 1 per reset settimanale.
- Settimanale è la celebrazione "grande"; il reset 5h **non** genera notifica (troppo frequente), solo aggiorna il glance.

### 3.3 Regole anti-spam (trasversali)
- Mai notificare su **dati stale/errore** (un token scaduto non deve sembrare "0% usato → tutto ok").
- Coalescing: se più refresh avvengono ravvicinati, valutare la soglia una volta sola.
- Stato di "armed/fired" persistito (UserDefaults) keyed sul reset-timestamp della finestra, così sopravvive a riavvii dell'app.

---

## 4. Opzioni impostazioni

Filosofia: **poche opzioni, default giusti** (in linea con la preferenza di Martino per
la semplicità). Pannello Settings nativo SwiftUI.

### MVP (minimo indispensabile)
- **Generale**
  - Launch at login (on/off).
  - Refresh cadence: Manual / 1m / 2m / 5m (default) / 15m / 30m.
  - Mostra uso come: % rimanente (default) / % usata.
- **Notifiche**
  - Avviso soglia sessione: on/off (default on) + soglia (slider, default 80%).
  - Celebrazione reset settimanale: on/off (default on).
- **Account / dati**
  - Stato connessione (account, plan, fonte dati) — read-only, con "Riconnetti" se serve.
  - Keychain: "Consenti prompt Keychain" — Mai / Solo su azione utente (default) / Sempre.
- **Info**: versione, link repo, reset cache analytics.

### v1 (aggiunte)
- Usage source: Auto (default) / OAuth / CLI.
- Account switcher (multi-account) + label.
- Soglie notifica multiple.
- Reset display: countdown (default) / orario assoluto.
- Pace tracking on/off.
- Pricing override (apri file pricing locale).

### v2 (aggiunte)
- Widget config, status polling on/off, notifiche costo + soglie spesa, Web cookie source, auto-update (Sparkle).

---

## 5. Casi limite (comportamento atteso)

| Caso | Rilevazione | Comportamento ClaudeBar |
|---|---|---|
| **Nessun abbonamento / non loggato in Claude Code** | Keychain item assente, oppure OAuth `/usage` 401/403, oppure scope insufficiente | Glance neutro (icona "—" attenuata, nessun colore allarme). Pannello mostra stato onboarding **inline** (NON una sheet modale — vedi §9.2): "Accedi a Claude Code per vedere i tuoi limiti" + spiegazione del login `claude`, con le analytics locali comunque visibili sotto. **Le analytics locali restano disponibili** se ci sono JSONL (mostriamo costo/token storici anche senza limiti live → valore anche da disconnessi). |
| **Token scaduto** | `expiresAt` passato | Tentare **auto-refresh** con `refreshToken`. Se refresh **200** → procedi. Se **invalid_grant** → stato "Sessione scaduta, riautentica" (block fino a cambio credenziali, niente retry-storm). Se **400/401 altro** → backoff esponenziale (max 6h), glance attenuato, pannello mostra "errore temporaneo, riprovo". **Mai** mostrare 0%/verde su token rotto. |
| **Account multipli** (`Claude Code-credentials-<hash>`) | Enumerazione item Keychain | MVP: rileva, usa l'account "attivo"/principale (euristica: item base `Claude Code-credentials`, o il più recente). Mostra l'email nel pannello così l'utente sa quale. v1: switcher esplicito. |
| **Primo avvio senza dati** | Nessuna analytics in cache, nessun limite ancora fetchato | Pannello "primo avvio": skeleton/spinner mentre fa il primo fetch OAuth + primo scan JSONL. Se in <X s niente dati: messaggio guida. Glance mostra stato loading (animazione bounded, non infinita). |
| **JSONL assenti / vuoti** (`~/.claude/projects` vuoto) | Scan trova 0 eventi | Sezione analytics mostra "Nessuna attività locale ancora" anziché 0€ ambiguo. Limiti OAuth comunque mostrati. |
| **JSONL enormi / molti file** | Dimensione/conteggio | Parsing **incrementale** (offset+mtime+size per file), niente blocco UI, niente re-scan completo a ogni refresh. (Dettaglio in doc 01.) |
| **Righe duplicate nei transcript** | `requestId`/`uuid`/`message.id` ripetuti | Dedup obbligatorio prima di sommare token/costo. |
| **Modello sconosciuto nella pricing table** | Model id non in tabella | Mostra token comunque; costo marcato "n/d" per quel modello, con avviso "pricing mancante, aggiornabile". Non rompere il totale. |
| **Keychain prompt negato dall'utente** | Denial | Cooldown (es. 6h) prima di ri-promptare; nel frattempo usa cache/fonti non interattive. Pannello spiega come aggiungere ClaudeBar all'ACL del Keychain item. |
| **Rete assente** | Fetch fallisce | Mostra ultimi dati con badge "stale" + timestamp ultimo aggiornamento; analytics locali continuano a funzionare (sono offline). |
| **Cambio fuso / DST attorno al reset** | Calcolo reset | Usare i timestamp di reset forniti dall'API (assoluti); evitare assunzioni locali sul "lunedì". |

---

## 6. Naming / branding

### Rischio marchio
"Claude" è un marchio Anthropic. Usarlo nel **nome di un prodotto distribuito** (specie
su App Store / Homebrew con icona e brand) può creare attrito o richieste di
rebrand — è successo ad altri tool. **Per uso personale (scope attuale) il rischio è
nullo.** Diventa rilevante **solo se** in futuro si distribuisce pubblicamente.

Mitigazioni standard (vale anche per CodexBar che usa "Codex"): nome chiaramente
"unofficial / not affiliated with Anthropic" nel README e nell'About; niente uso del
logo Anthropic; niente claim di affiliazione.

### Raccomandazione
- **Per ora (uso personale): tenere "ClaudeBar".** È chiaro, descrittivo, coerente col
  riferimento CodexBar, e a rischio zero in ambito privato.
- **Predisporre il rebrand a costo zero:** display name (`CFBundleDisplayName`) e nome
  prodotto **parametrici**, così cambiarlo dopo è banale e non tocca il codice.

### Alternative (se/quando si distribuisce)
1. **MaxBar** — richiama l'abbonamento "Max", corto, niente marchio Claude. *(preferita)*
2. **AnthroBar** — richiama Anthropic senza dire "Claude"; rischio minore ma comunque allusivo.
3. **TokenMeter / Tokin'** — generico, zero rischio marchio, meno evocativo.
4. (fallback ironico) **"ClaudeBar (unofficial)"** come display name, bundle `claudebar`.

### Bundle id
- Proposta: **`com.subralabs.claudebar`** (release) / **`com.subralabs.claudebar.debug`** (debug).
  - Coerente con gli altri progetti dell'utente (Subra*). Indipendente dal display name → rebrand sicuro.
  - Se in futuro widget: `com.subralabs.claudebar.widget`.
- Da confermare con app-architect (già allineato via messaggio).

---

## 7. Criteri di accettazione MVP (testabili)

L'MVP è "fatto" quando **tutti** i seguenti sono verificabili sulla macchina dell'utente:

1. **Glance vivo:** l'item in menu bar mostra un indicatore colorato che riflette la % usata della sessione 5h e cambia colore alle soglie (verde <60, ambra 60–85, rosso >85). *Test: forzare valori e osservare il colore.*
2. **Click → pannello:** un click sull'item apre il pannello Liquid Glass; un secondo click/esc lo chiude. Nessuna Dock icon.
3. **Limiti reali:** il pannello mostra % usata e countdown reset corretti per **sessione 5h** e **settimanale**, letti via OAuth dal Keychain reale dell'utente. *Test: confrontare col `/usage` della CLI Claude — devono combaciare entro l'arrotondamento.*
4. **Auto-refresh token:** con `expiresAt` passato, l'app si ri-autentica via `refreshToken` senza intervento e senza prompt ripetuti. *Test: scadenza simulata.*
5. **Analytics base corrette:** il pannello mostra **costo oggi** e **token oggi** con **breakdown per modello**, calcolati dai JSONL locali, **deduplicati**. *Test: confronto con un calcolo manuale / con `ccusage` sullo stesso giorno, scarto trascurabile.*
6. **Parsing incrementale:** un secondo refresh **non** ri-parsa i file già letti (verificabile: tempo del refresh successivo ≪ primo; CPU bassa). *Test: misurare durata/CPU sul 2° refresh.*
7. **Notifica soglia:** superata la soglia sessione arriva **una** notifica; restando sopra soglia **non** arrivano duplicati nella stessa finestra; al reset il meccanismo si riarma. *Test: simulare attraversamento soglia + refresh ripetuti.*
8. **Celebrazione reset:** al reset settimanale compare l'effetto celebrativo (una tantum) + notifica leggera. *Test: simulare reset.*
9. **Refresh cadence:** cambiando il preset (es. 1m) il refresh automatico rispetta l'intervallo; "Refresh now" funziona sempre. *Test: osservare timestamp aggiornamento.*
10. **Casi limite con grazia:** (a) senza credenziali → onboarding, glance neutro, analytics locali comunque visibili se presenti; (b) token invalid_grant → "riautentica" senza retry-storm; (c) primo avvio → loading poi dati, mai schermata vuota ambigua. *Test: rinominare/rimuovere temporaneamente l'item Keychain e svuotare la cache.*
11. **Launch at login** attivabile e funzionante.
12. **Performance idle:** ad app aperta e idle (refresh 5m), CPU media ~0% tra i refresh, nessun redraw continuo della menu bar (animazione loading con ceiling). *Test: Activity Monitor / Instruments.*
13. **Privacy:** nessuna lettura di disco oltre `~/.claude/projects` + Keychain `Claude Code-credentials`; nessuna chiamata di rete oltre l'endpoint OAuth usage + (opz.) fonte pricing. *Test: review + log di rete.*
14. **Build:** `xcodebuild` produce `.app` lanciabile localmente (no firma/notarize richieste).

---

## 8. Domande aperte da decidere con l'utente

1. **Nome di distribuzione:** tenere "ClaudeBar" o pianificare "MaxBar" se mai si pubblica? (Raccomando: ClaudeBar ora, bundle/display parametrici.)
2. **Bundle id:** ok `com.subralabs.claudebar`? (allineato col pattern Subra*).
3. **Soglia notifica di default:** 80% va bene, o preferisce 90%? Vuole anche una soglia "alta" (95%) già nell'MVP?
4. **Analytics da disconnesso:** confermare che mostrare costo/token storici anche **senza** limiti live (account non loggato) è desiderato — è un piccolo extra di valore ma aggiunge un percorso UI.
5. **Costo "teorico":** chiarire nel pannello che il costo è una **stima API equivalente** (l'abbonamento Max è flat) — testo/disclaimer ok? Vuole proprio vedere il "quanto avrei speso a consumo"?
6. **CLI PTY in v1:** vale la complessità del fallback PTY, o l'OAuth è considerato sufficiente e si taglia del tutto?
7. **Widget (v2):** interessano davvero per uso personale, o si deprioritizzano a favore di analytics più profonde?

---

## 9. Decisioni di design fini (allineate con design-lead — doc 03)

Convergenza piena con il doc 03-design. Decisioni di prodotto sulle scelte fini (default
per l'MVP; le ho aperte come domande all'utente ma il design può procedere con questi):

- **Anelli vs barre:** **anelli grandi** (Gauge ring, Ø ~96pt) per Sessione 5h + Settimanale nel pannello — stesso linguaggio visivo (arco + colore) del glance dell'icona.
- **Convenzione colore:** sul **% usato**, interpolazione fluida tra ancore; soglie (verde <60, ambra 60–85, rosso >85, empty/pulsa ≥95) usate solo per stato/notifiche/pulsazione. Icona guidata dalla **Sessione 5h**; stale/errore = icona **dim**, mai rosso falso.
- **Fallback monocromo:** presente (per Increase Contrast / accessibilità e coerenza B/N), ma il **default resta colorato** (è la firma del prodotto). Non MVP-blocking.
- **Tint glass warm-clay ~6%:** ok, tocco caldo discreto; non deve ridurre il contrasto del testo (da validare a video).
- **% testuale accanto all'icona:** **opzionale, default OFF** (legata al toggle used/remaining). Il glance colorato basta da solo.
- **Range analytics default:** **Oggi** (coerente con "costo/token oggi" dell'MVP); 7g/30g sono v1.
- **Pace tracking:** riga placeholder già nel layout sotto ogni anello → v1 non tocca la struttura.

### 9.1 Target CLI: dev-tool sì, prodotto no (allineato con app-architect — doc 02)

Distinguere due cose:
- **CLI dev-tool (interno):** un piccolo target da riga di comando **opzionale, solo per
  sviluppo/debug**, è OK e anzi **utile** — serve a validare il parser JSONL e il calcolo
  costi confrontandoli con `ccusage`/`claude /usage` (vedi criteri MVP #3 e #5). **Non**
  fa parte del bundle dell'app, non è distribuito, non è una promessa di prodotto. È un
  ferro del mestiere. → **Tenerlo opzionale, dev-only.**
- **CLI companion (prodotto):** una CLI pubblica stile `codexbar usage/cost/config` per
  script/CI/export, **resta v2** (vedi §2). Niente nell'MVP.

Quindi: l'MVP del *prodotto* è zero-extra (solo l'app), ma app-architect può tenere il
target CLI di debug nel package senza che conti come scope di prodotto.

### 9.2 Onboarding no-auth: stato inline nel pannello (call di prodotto)

**Decisione:** quando manca l'autenticazione (vedi §5, "nessun abbonamento"), l'onboarding
è uno **stato inline dentro il pannello**, **non** una sheet modale dedicata.
Concordo con la preferenza di design-lead. Motivi di prodotto:
- **Glance-first / un solo luogo:** il pannello è l'unica superficie; un modale aggiunge
  un context-switch inutile per un'app che vive di apri-e-guarda.
- **Le analytics locali restano visibili sotto il messaggio:** anche senza limiti live,
  se ci sono JSONL mostriamo costo/token → l'app dà valore da subito, cosa impossibile se
  un modale copre tutto.
- **Recupero naturale:** appena l'utente fa `claude` login, al refresh successivo lo stato
  inline si trasforma negli anelli, senza chiudere nulla.
- **Semplicità implementativa** (in linea con la preferenza di Martino).

L'onboarding inline mostra: messaggio breve, come autenticarsi (`claude` login), un link/azione
"Riprova/Riconnetti", e — se presenti — le analytics locali. È MVP.
