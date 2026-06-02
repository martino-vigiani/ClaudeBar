# ClaudeBar — Design Spec (03)

> Autore: design-lead · Fase: pianificazione (NON implementazione)
> Prerequisito: aver letto `docs/plan/BRIEF.md`.
> Skill consultate: `liquid-glass`, `high-end-visual-design`, HIG `components-status`, `components-menus`.
> Riferimento studiato (read-only): `.reference/CodexBar/Sources/CodexBar/IconRenderer.swift`.

Questo documento definisce la **direzione visiva**, il **design system**, l'**icona menu
bar colorata**, il **pannello Liquid Glass**, le **animazioni**, gli **stati** e i **mockup
ASCII**. Tutto è pensato per macOS 26 (Tahoe), SwiftUI + AppKit (NSStatusItem) + Swift Charts.

---

## 0. Principio guida — "Glance → Glass"

Due livelli, due esperienze, una sola identità.

1. **GLANCE (menu bar)** — un microgesto visivo. In <100ms l'occhio legge *quanto ti resta*
   nella sessione 5h tramite **colore semantico** (verde → ambra → rosso) su un **anello/arco
   compatto**. Niente testo obbligatorio. È la differenza n.1 rispetto a CodexBar, che usa
   icone **template monocrome** (il sistema le ricolora di nero/bianco): noi usiamo
   un'immagine **NON-template colorata**, perché il colore *è* l'informazione.

2. **GLASS (pannello)** — al click si materializza un pannello **Liquid Glass** che galleggia
   sotto la barra. Gerarchia chiara: in cima i **due limiti ufficiali** (sessione + settimana)
   con countdown reset; sotto, le **analytics locali** (costo, token, per-progetto/modello,
   cache, storico) con Swift Charts. Glance-first, dettaglio-on-tap.

Tono: **scenico ma calmo**. Premium "Apple-esque / Linear-tier", non appariscente. Il glass è
solo nel layer di navigazione/contenitore; il contenuto resta leggibile e sobrio.

---

## 1. Direzione visiva

| Asse | Scelta | Perché |
|---|---|---|
| Materiale dominante | Liquid Glass (`.regular`) sul contenitore del pannello | È la decisione di prodotto; dà profondità senza pesare. |
| Texture vibe | "Ethereal Glass" calmo — profondità da vibrancy, **non** da gradient mesh accesi | Il colore deve restare *semantico* (stati), non decorativo. |
| Accent | **Nessun accent brand fisso**: l'unico colore vivo è quello semantico degli stati | Coerente con il glance; evita il clutter. Il "warm clay" Claude resta come tinta ultra-soffusa opzionale del glass (`.tint`), non come riempimento. |
| Contenuto | Tipografia SF, righe ariose, separatori a hairline, niente bordi grigi 1px generici | Anti-pattern da `high-end-visual-design` §2. |
| Profondità | Concentric radii (double-bezel tradotto in SwiftUI), inset highlight 1px bianco soffuso | Le card sembrano "incastonate" nel glass, come hardware. |

### 1.1 Identità del colore semantico (cuore dell'app)

> **Convenzione di riferimento (allineata con product-lead, 04-product-roadmap)**: le soglie
> colore sono definite sul **% USATO** della finestra (più intuitivo per le notifiche
> "hai consumato l'80%"). La barra/anello mostra comunque il **riempimento = % usato** che
> cresce verso il rosso. Internamente useremo `used = 100 - remaining`; i due valori sono
> intercambiabili, qui fissiamo la convenzione di prodotto per non avere ambiguità.

Soglie ufficiali (sul **% usato**), come da product-lead:

```
% USATO       0 ──────────── 60 ──────────── 85 ──────── 95 ──── 100
stato         OK      OK   →  WARN     →     CRIT    →   EMPTY
colore        ●verde         ●ambra          ●rosso      ●rosso glow/pulsa
SwiftUI       .green         .orange         .red        .red + glow
soglia        <60% usato     60–85% usato    >85% usato  ≥95% usato
```

Non sono gradini netti: il colore **interpola** in modo fluido nello spazio percettivo
(OKLCH-like; in pratica `Color` mix con easing) tra le ancore, così non "scatta". Le soglie
servono solo a decidere icona-stato / notifiche / pulsazione, non a far saltare il colore.

Token semantici (nomi, valori definitivi calibrati dall'implementatore in asset catalog):

- `usageOK`     ≈ system green, leggermente desaturato per non gridare (≈ `#34C759` calmato)
- `usageWarn`   ≈ system orange (`#FF9F0A` dark / `#FF9500` light) — zona 60–85% usato
- `usageCrit`   ≈ system red (`#FF453A` dark / `#FF3B30` light) — >85% usato
- `usageEmpty`  = `usageCrit` + alone (glow) e pulsazione — ≥95% usato / limite raggiunto
- `usageStale`  = colore corrente **desaturato/dim** (NON rosso): vedi §3.5, mai falso allarme

Accessibilità: il colore **non è mai l'unico canale**. L'arco varia anche per *quantità di
riempimento* (lunghezza) e, oltre l'85% usato, compare un micro-glifo (puntino/avviso) — così
funziona anche con daltonismo e con "Aumenta contrasto" / "Riduci trasparenza" attivi.

Accessibilità: il colore **non è mai l'unico canale**. L'arco varia anche per *quantità di
riempimento* (lunghezza) e, sotto LOW, compare un micro-glifo (es. un puntino/avviso) — così
funziona anche con daltonismo e con "Aumenta contrasto" / "Riduci trasparenza" attivi.

---

## 2. Design system

### 2.1 Tipografia (SF)

Solo font di sistema (SF Pro / SF Pro Rounded / SF Mono). Niente font esterni (su menu bar i
banned-fonts della skill non si applicano: SF *è* la scelta premium su macOS).

| Ruolo | Font | Size / Weight | Uso |
|---|---|---|---|
| Display % | SF Pro Rounded | 28pt / Semibold, **monospaced digits** | Numero grande "left this session" in cima al pannello |
| Title | SF Pro | 15pt / Semibold | Titoli sezione ("Limiti", "Analytics") |
| Headline row | SF Pro | 13pt / Medium | Etichette di riga (Sessione, Settimana, modello) |
| Body / value | SF Pro | 13pt / Regular | Valori, descrizioni |
| Numeric / token | **SF Mono** o SF Pro con `.monospacedDigit()` | 12–13pt | Token, costi, countdown — evita "jitter" di larghezza |
| Caption | SF Pro | 11pt / Regular, `.secondary` | Sottotitoli, reset, note |
| Eyebrow tag | SF Pro | 10pt / Semibold, `tracking +0.06em`, UPPERCASE | Micro-badge sezione ("SESSIONE 5H", "QUESTA SETTIMANA") |

Regole:
- Tutti i numeri che cambiano live → `.monospacedDigit()` per non far "ballare" il layout.
- Dynamic Type: il pannello rispetta `.dynamicTypeSize` fino a `.accessibility1` (oltre, scroll).
- Allineamento numerico a destra nelle righe valore.

### 2.2 Spacing & griglia

Scala a base 4 (SwiftUI-friendly): `2, 4, 8, 12, 16, 20, 24, 32`.

- Padding esterno pannello: **20pt** (contenuto) entro la cornice glass.
- Gap tra card/sezioni: **16pt**.
- Padding interno card: **14–16pt**.
- Riga limiti: altezza ~44pt (tap-target HIG ≥ 28pt su mac, ma teniamo aria).
- Larghezza pannello: **360pt** (compatto, da menu bar). Espanso/"More": stessa larghezza,
  scroll verticale; **max height ~560pt** poi `ScrollView`.

### 2.3 Materiali Liquid Glass

Regola d'oro (skill liquid-glass): **glass solo sul layer contenitore/navigazione, mai sul
contenuto** (liste, grafici, testo). Quindi:

| Elemento | Materiale | Note |
|---|---|---|
| Sfondo del pannello (cornice) | `.glassEffect(.regular, in: .rect(cornerRadius: 26))` | Il "vassoio" che galleggia sotto la barra. |
| Wrapping multiplo | **`GlassEffectContainer(spacing:)`** unico attorno agli elementi glass | Obbligatorio: il glass non campiona altro glass; evita texture inconsistenti e tripli `CABackdropLayer`. |
| Pulsanti header (refresh, settings) | `.buttonStyle(.glass)` **+ `.tint(.clear)`** (richiesto su macOS) | Pitfall noto macOS. |
| Card limiti / card analytics | **NON** glass: superficie sobria `Color(nsColor:.controlBackgroundColor)`/`windowBackground` con hairline + inset highlight | Contenuto = leggibile, non traslucido. |
| Grafici Swift Charts | sfondo neutro, nessun materiale | Il glass dietro i numeri uccide la leggibilità (pitfall "text illegibility"). |
| Tint del glass | opzionale `.regular.tint(Color.clay.opacity(0.06))` | Calore appena percettibile; mai colore pieno. |

`.interactive()` è **iOS-only** → su macOS non si usa; l'highlight è dato da hover/press
nativi e dal glass stesso.

### 2.4 Double-bezel tradotto in SwiftUI

Tecnica "Doppelrand" della skill high-end (card incastonata come hardware):

```swift
// Outer shell (vassoio) → Inner core (contenuto), raggi concentrici
RoundedRectangle(cornerRadius: 18, style: .continuous)        // outer
  .fill(.background.opacity(0.04))
  .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
    .strokeBorder(.white.opacity(0.08), lineWidth: 1))         // hairline esterna
  .overlay(alignment: .top) { /* inner core */ }
  // inner: cornerRadius = 18 - inset(es. 4) = 14, con inset highlight:
  //   .shadow(.inset, color: .white.opacity(0.12), radius: 0, y: 1) concettuale
```

Niente ombre dure (`shadow-md`, nero pieno): solo ombre **diffuse e morbide** a bassissima
opacità per lo stacco dal desktop, e **inset highlight** 1px bianco per il bordo "vivo".

### 2.5 Iconografia

SF Symbols a **peso leggero** (`.light`/`.regular`, mai bold thick): coerente con l'anti-pattern
"banned icons" (no tratti grossi). Set:
`clock` (sessione), `calendar` (settimana), `bolt` o `gauge` (uso), `cube` (modello),
`folder` (progetto), `dollarsign.circle` (costo), `arrow.clockwise` (refresh),
`gearshape` (settings), `chart.line.uptrend.xyaxis` (storico).
Transizioni di simbolo con `.symbolEffect(.drawOn)` / `.replace` per i cambi di stato.

### 2.6 Dark / Light

- Tutti i colori da asset catalog con varianti automatiche; mai hardcoded fuori dal token.
- Glass adatta da solo vibrancy/luminanza; verificare contrasto testo su entrambi.
- **Light**: hairline `black.opacity(0.06)`, inset highlight `white.opacity(0.5)`.
- **Dark**: hairline `white.opacity(0.08)`, inset highlight `white.opacity(0.12)`.
- Stati semantici hanno varianti light/dark (vedi §1.1) per mantenere contrasto AA.

---

## 3. L'ICONA MENU BAR COLORATA (il cuore)

### 3.1 Vincolo tecnico chiave (da risolvere, vs CodexBar)

CodexBar imposta `image.isTemplate = true` → il sistema **scarta il colore** e ricolora
monocromo. Per avere il glance **colorato** dobbiamo:

- Renderizzare un `NSImage` con `isTemplate = **false**` e colori reali (i token semantici).
- Disegnare a **2×** (canvas 36×36 px per 18×18 pt) come fa CodexBar, con snapping a griglia
  pixel per nitidezza.
- Gestire **noi** la leggibilità su barra chiara/scura: i colori semantici scelti hanno
  contrasto sufficiente su entrambe; in più una sottilissima **traccia** (anello di sfondo) a
  `labelColor.opacity(0.22)` ancora la forma anche quando il fill è corto.
- Rispettare "Aumenta contrasto" e una preferenza utente **"Icona monocroma"** (fallback
  template) per chi non vuole colore — ma il default è colorato.

### 3.2 Forma: anello/arco (preferito) + varianti

Default raccomandato: **anello (ring gauge)** — leggibile a colpo d'occhio, "Apple-esque"
(richiama le activity ring, ma con un solo arco e senza appropriarsi della metafora Move/
Exercise/Stand, come da HIG). La lunghezza dell'arco codifica il **% USATO** (cresce con il
consumo); il colore codifica lo stato. **La finestra che guida l'icona è la SESSIONE 5H**
(quella che brucia più in fretta), come deciso dal product-lead.

```
   ICONA MENU BAR — ANELLO (18×18pt). L'arco parte da ore 12, senso orario.
   Lunghezza arco = % USATO (riempie con il consumo). Colore = stato (interpolato).
   Guida = SESSIONE 5H.

   12% usato        48% usato       72% usato       90% usato       98% usato
    ·                ╭──             ╭───╮           ╭─────╮         ╭─────╮
   │·               │●               │●    ╮        │● ● ● ●│       │● ● ● ●│
   │·               │●               │●    │        │●     ●│       │●     ●│  (pulsa
   ╰                ╰─               ╰─  ╯           │● ● ╯         │● ● ● ●│   lento)
    verde            verde            ambra           rosso          rosso+glow
   (arco corto)    (≈mezzo)        (>60% usato)     (>85% usato)    (limite/≥95%)
```

- **Traccia** (cerchio di fondo): sempre presente, `labelColor.opacity(0.18–0.22)`, 2px —
  ancora la forma anche quando il consumo è basso (arco corto).
- **Arco di consumo**: 2.5px, `lineCap .round`, colore semantico interpolato sul % usato.
- **Centro**: vuoto (più pulito) di default. Opzione: micro-glifo Claude (un asterisco/spark
  sottile) o "C" al centro a `opacity 0.0` di default per non sporcare.

### 3.3 Variante "barra compatta" (alternativa selezionabile)

Per chi preferisce una lettura lineare o per due finestre insieme (sessione + settimana):

```
   BARRA DOPPIA COMPATTA (come CodexBar ma COLORATA)
   ┌──────────────┐   riga alta = SESSIONE 5h (più spessa), colore stato
   │▓▓▓▓▓▓▓▓░░░░░░│   riga bassa = SETTIMANA (più sottile), colore stato proprio
   └──────────────┘
     65% verde
     ──────
     ▓▓▓▓░░░░░░░░░░  → settimana 30%, ambra
```

- Riga sessione: 5pt alta. Riga settimana: 3pt. Gap 2pt. Width ~16pt.
- Fill colorato semantico per riga; traccia di fondo `opacity 0.2`.

### 3.4 Modalità testo opzionale (accanto all'icona)

Preferenza utente (default OFF per compattezza): mostra `%` accanto all'icona, SF Mono 11pt,
colore = `labelColor` (NON semantico, per non gridare) oppure semantico se l'utente lo abilita.
Es. `◷ 62%`. Larghezza riservata fissa per evitare jitter.

### 3.5 Stati dell'icona (matrice)

| Stato | Aspetto icona |
|---|---|
| Normale | Anello colorato sul % **usato** della sessione 5h. |
| Loading / primo avvio | Anello con **traccia** sola + spinner d'arco breve che ruota (indeterminato), grigio. |
| Stale (dati vecchi >X min) | Colore corrente **desaturato/dim** (`opacity 0.55` sull'arco). **MAI rosso "falso"**: lo stale non deve simulare un allarme (decisione product-lead). |
| Critico (>85% usato) | Rosso pieno. |
| Empty (≥95% usato o limite raggiunto) | Rosso + **pulsazione** lenta (scale/opacity, rispetta Reduce Motion → solo cambio statico). |
| Errore (no auth / no rete) | Anello dim/tratteggiato grigio + micro-badge `!` in basso a destra (overlay status). Mai rosso falso. |
| No subscription / non-Max | Anello "vuoto" neutro + glifo lucchetto piccolo; click apre stato dedicato. |
| Refresh in corso | Micro-rotazione dell'arco di 1 giro (non distrae). |

### 3.6 Performance del rendering icona (vincolo BRIEF)

- **Cache** dell'`NSImage` per chiave quantizzata (`%` a step di 2–3, stato, modalità,
  appearance light/dark) — esattamente lo schema di `IconRenderer` di CodexBar (`IconCacheKey`).
- Ridisegno solo quando il bucket cambia, non a ogni tick.
- Animazioni (pulsazione/spinner) gestite come sequenza di frame cachati o `CABasicAnimation`
  sul layer, non re-render del bitmap a 60fps.
- Aggiornare l'icona su cambio appearance (dark/light) via observer.

---

## 4. IL PANNELLO LIQUID GLASS

### 4.1 Contenitore & presentazione

- Si apre al **click** sull'item (left-click). È un **pannello custom** (NSPanel/NSWindow
  borderless con `NSStatusItem`), **non** un NSMenu (CodexBar usa NSMenu; noi vogliamo Liquid
  Glass + Swift Charts → serve una window SwiftUI).
- Ancorato sotto l'icona, con freccia/becco opzionale (o senza, stile pillola flottante).
- Sfondo = **Liquid Glass `.regular`**, raggio 26pt continuous, leggerissima ombra diffusa.
- Apertura: **scale 0.96 → 1.0 + opacity + slide-down 8pt**, molla morbida
  `interpolatingSpring(stiffness, damping)` ~ `cubic-bezier(0.32,0.72,0,1)` (skill high-end).
- Chiusura: reverse, leggermente più rapida. Click fuori / Esc → chiude.

### 4.2 Gerarchia (glance → dettaglio → on-tap-more)

> Struttura allineata con product-lead (04-product-roadmap): **header identità (account/plan)**
> → **due anelli GRANDI** (Sessione 5h + Settimana) → **analytics locali**. Gli anelli grandi
> sostituiscono l'idea precedente di "hero singolo + due card a barre": sono più scenici e
> coerenti col glance dell'icona (Gauge/`Gauge` SwiftUI con stile `accessoryCircular`-like custom).

Tre fasce verticali. Header + anelli sempre visibili; analytics scrolla/espande.

```
┌────────────────────────────────────────────┐  ← cornice Liquid Glass (r=26)
│  ◐  martino · Max          aggiornato 8s ⟳ ⚙︎│  HEADER IDENTITÀ (account · plan)
│                                              │
│   SESSIONE 5H            QUESTA SETTIMANA     │  FASCIA A — DUE ANELLI GRANDI
│      ╭───────╮              ╭───────╮         │  Gauge custom (ring), Ø ~96pt
│     │  62%   │             │  41%   │         │  numero al centro SF Rounded
│     │ usato  │             │ usato  │         │  colore = stato semantico
│      ╰───────╯              ╰───────╯         │  arco = % usato
│     reset 2h 14m           reset Lun 09:00    │  countdown sotto (SF Mono)
│     ↘ finisce ~17:05*      riserva ok*        │  *PACE TRACKING (v1, vedi §4.5.1)
│   ────────────────────────────────────────  │  hairline divider
│                                              │
│   ANALYTICS                          Oggi ▾  │  FASCIA B — ANALYTICS (header + range)
│   ┌──────────────────────────────────────┐  │
│   │ Costo oggi    $3.42   ↑ 12% vs ieri   │  │  KPI row
│   │ Token         1.2M    cache 78% ⚡     │  │
│   └──────────────────────────────────────┘  │
│   ┌──────────────────────────────────────┐  │  Swift Chart (spesa/token nel tempo)
│   │  ▁▂▃▅▇▆▃▂  area/line chart            │  │
│   └──────────────────────────────────────┘  │
│   Per modello   ▸  Per progetto  ▸           │  righe espandibili
│                                              │
│   [ Mostra di più ]                  v       │  bottone espansione (glass)
└────────────────────────────────────────────┘
```

### 4.3 Header identità

- Sinistra: pallino di stato (colore semantico della sessione) + **account** (es. `martino`)
  + **plan** (`Max`) come badge eyebrow. Niente nome app: l'identità utile qui è *di chi/quale
  piano* sono i numeri (decisione product-lead). Multi-account: l'account è tappabile per lo
  switch (CodexBar gestisce le varianti `Claude Code-credentials-<hash>`).
- Destra: `aggiornato 8s fa` (caption), pulsante **refresh** (`arrow.clockwise`,
  `.buttonStyle(.glass).tint(.clear)`, ruota durante il fetch), pulsante **settings**
  (`gearshape`).
- I due pulsanti glass vivono nello **stesso `GlassEffectContainer`** del contenitore.

### 4.4 Fascia A — I due anelli grandi (i limiti ufficiali)

Due **anelli grandi** (Ø ~96pt) affiancati, in card "double-bezel" (vedi §2.4) o liberi su
sfondo neutro. Ciascuno:
- Eyebrow tag sopra (SESSIONE 5H / QUESTA SETTIMANA).
- **Anello**: traccia di fondo + arco = **% usato**, colore semantico interpolato (stessa scala
  dell'icona §1.1). Stesso linguaggio visivo del glance → coerenza barra↔pannello.
- **Centro**: `%` grande SF Pro Rounded Semibold monospaced + micro-label ("usato"). Tap →
  switch usato↔rimanente (come `showUsed` di CodexBar).
- Sotto l'anello: countdown reset (relativo + assoluto): "reset 2h 14m" / "reset Lun 09:00"
  (SF Mono).
- Oltre 85% usato: l'anello prende un **alone semantico soffuso** (glow al bordo, non
  riempimento extra); ≥95% → pulsazione lenta (Reduce Motion → statico).

#### 4.5.1 Pace tracking (feature v1, non MVP — riservare spazio nel layout)

Sotto ogni anello, una riga **pace** (placeholder nel layout, attivabile in v1):
- "↘ finisce ~17:05" / "in deficit: -18% sul ritmo" (consumo più veloce del reset) **oppure**
  "riserva ok · resterai sotto soglia" (consumo sostenibile).
- Visivamente: micro-freccia + caption colorata (stato), niente nuovo widget pesante.
- Nell'MVP la riga può essere assente; il layout la prevede già (no rifacimenti dopo).

### 4.6 Fascia B — Analytics (Swift Charts)

- Header sezione "ANALYTICS" + **range picker** segmentato glassless: `Oggi · 7g · 30g`.
- **KPI row** (card): Costo (periodo) con delta vs periodo prec.; Token totali; **efficienza
  cache** (`cache_read / (input+cache)`), badge `⚡ 78%`.
- **Grafico principale** (Swift Charts): area/line di spesa o token nel tempo (bin = ora/giorno
  secondo range). Interazione: hover → `RuleMark` + annotation con valore (HIG charts: tooltip
  on hover su mac). Animazione `.animation` sull'ingresso dati.
- **Breakdown espandibili** (DisclosureGroup, progressive disclosure HIG):
  - *Per modello*: barre orizzontali per `claude-opus-4-x`, `sonnet`, ecc. (token o costo).
  - *Per progetto*: top N progetti (dal `cwd` decodificato) con barra + costo.
  - (più giù, in "Mostra di più") *Per giorno*, *Per branch*, *storico*.
- **"Mostra di più"**: bottone glass che espande la fascia con `GlassEffectContainer`
  morphing (`@Namespace` + `glassEffectID`) → animazione fluida di crescita del pannello.

### 4.7 Footer / overflow

- Riga discreta: "Aggiornato 12s fa · v0.1" + accesso a Preferenze / Quit (pull-down `…`).
- Quit/Preferenze NON nel solo glance: sono nel menu/settings, come da HIG (mai comando solo
  in posto nascosto).

---

## 5. Animazioni & micro-interazioni

Tutto con **molle morbide**, mai `linear`/`easeInOut` piatti (skill high-end §5).

| Evento | Animazione |
|---|---|
| Apertura pannello | scale 0.96→1 + slide-down 8pt + fade, `interpolatingSpring` morbido (~0.45s). |
| Cambio % live | barra/numero si animano con `withAnimation(.smooth)`; numero `.contentTransition(.numericText())`. |
| Cambio colore stato | interpolazione cromatica animata (no scatto), ~0.6s. |
| Cross-fade verde→ambra→rosso | accompagnato da micro `symbolEffect` se compare il glifo avviso. |
| Refresh | pulsante ruota (`rotationEffect` continuo durante fetch), si ferma a fine. |
| "Mostra di più" | morphing glass (`GlassEffectContainer` + `glassEffectID`) → il pannello cresce fluido. |
| Hover card / pulsante | leggerissima sopraelevazione (ombra +; scale 1.0→1.01) + highlight inset. |
| Entrata sezioni | fade-up 12pt + leggero blur→0 (whileInView equivalente: `.transition` su apparizione), staggered 40–60ms. |
| Critico/Empty | pulsazione lenta dell'anello (scale 1.0↔1.03, ~1.4s) — **disattivata** con Reduce Motion. |
| **Reset settimanale** | **celebrazione**: glow/confetti soffuso nel pannello quando la finestra settimanale si resetta (gli anelli "si svuotano" tornando verdi con una passata di luce). Notifica di sistema **leggera** (non intrusiva). Reduce Motion → solo flash di colore breve, niente confetti animati. |
| Grafici | barre/aree crescono dall'asse all'ingresso. |

**Reduce Motion**: tutte le molle → fade brevi; niente pulsazione; niente rotazioni continue
(refresh diventa stato statico + checkmark a fine); niente confetti (solo flash colore).

---

## 6. Stati globali del pannello

| Stato | Pannello |
|---|---|
| **Loading** (primo fetch) | Hero con skeleton shimmer (rettangoli a `redacted(reason:.placeholder)`), spinner indeterminato; icona barra = spinner d'arco. |
| **OK** | Layout pieno §4.2. |
| **Stale** | Banner sottile in alto "Dati di N min fa — aggiorno…" + valori desaturati finché non arriva il fresh. |
| **Errore rete/endpoint** | Card stato: icona `wifi.slash`/`exclamationmark`, messaggio chiaro, pulsante "Riprova". Le analytics locali (da JSONL) **restano visibili** anche se i limiti ufficiali falliscono → degradazione elegante. |
| **No auth / keychain mancante** | Onboarding **INLINE** nel pannello (NON sheet modale, decisione product-lead doc 04 §9.2): messaggio breve + come autenticarsi + azione "Riprova/Riconnetti". Le **analytics locali restano visibili SOTTO** il messaggio (un modale le coprirebbe). Recupero naturale: dopo `claude` login, al refresh successivo lo stato inline diventa anelli senza chiudere nulla. Niente numeri inventati per i limiti. È MVP. |
| **No subscription / non-Max** | Mostra solo analytics locali (costo/token teorici) + nota "Limiti sessione non disponibili senza piano Max". |
| **Critico** | Anello sessione rosso, eventuale suggerimento "reset tra Xh"; notifica di sistema già a soglia (gestita da layer notifiche). |
| **Reset settimanale appena avvenuto** | Glow/confetti soffuso + anelli che tornano verdi (vedi §5); badge "Settimana resettata". |

Principio HIG status: un solo indicatore aggregato, non stack di spinner; progress determinato
(anelli/barre) preferito all'indeterminato dove possibile.

### 6.1 Notifiche (allineate con product-lead, MVP)

- **MVP**: **1 sola soglia sessione**, configurabile, **default 80% usato**. De-dup per
  finestra: **max 1 notifica per soglia per finestra 5h** (non rinotifica allo stesso superamento).
- **Reset settimanale**: notifica **leggera** + celebrazione nel pannello (§5).
- **NIENTE notifiche di costo** nell'MVP.
- Stato stale/errore non genera notifiche allarmistiche (coerente con icona dim, mai rosso falso).

---

## 7. Mockup ASCII — riepilogo stati pannello

### 7.1 OK (default)
```
┌────────────────────────────────────┐
│ ◐ martino · Max     aggiornato 8s ⟳ ⚙︎│   header identità (account · plan)
│  SESSIONE 5H        QUESTA SETTIMANA │
│    ╭─────╮             ╭─────╮       │   due anelli grandi (Gauge)
│   │ 62% │             │ 41% │        │   % usato al centro, colore = stato
│    ╰─────╯             ╰─────╯       │
│   reset 2h14m         reset Lun 09:00│   countdown (SF Mono)
│   ↘ finisce ~17:05    riserva ok     │   pace tracking (v1)
│ ──────────────────────────────────  │
│  ANALYTICS                   Oggi ▾  │
│  Costo $3.42 ↑12%   Token 1.2M ⚡78% │
│  ▁▂▃▅▇▆▃▂  (line chart)              │
│  Per modello ▸   Per progetto ▸      │
│  [ Mostra di più ]               v   │
└────────────────────────────────────┘
```

### 7.2 Critico
```
┌────────────────────────────────────┐
│ ● ClaudeBar              ⚠ critico  │
│ ┌────────────────────────────────┐ │
│ │ 6%    rimanenti · sessione 5h  │ │   ← rosso, hero pulsa (no Reduce Motion)
│ │ ▓░░░░░░░░░░░░░░░░░  (rosso)      │ │
│ │ reset tra 41m · 18:30          │ │
│ └────────────────────────────────┘ │
│  Suggerimento: la sessione si       │
│  resetta tra 41 minuti.             │
│  ──────────────────────────────     │
│  ANALYTICS ... (invariate)          │
└────────────────────────────────────┘
```

### 7.3 Errore limiti (analytics ok)
```
┌────────────────────────────────────┐
│ ● ClaudeBar         errore ⟳        │
│ ┌────────────────────────────────┐ │
│ │ ⚠ Limiti non disponibili       │ │
│ │ Impossibile contattare Anthropic│ │
│ │            [ Riprova ]          │ │
│ └────────────────────────────────┘ │
│ ──────────────────────────────────  │
│  ANALYTICS (locali, sempre vive)    │
│  Costo $3.42  Token 1.2M  ⚡78%     │
│  ▁▂▃▅▇▆▃▂                            │
└────────────────────────────────────┘
```

### 7.4 No auth / onboarding (INLINE — le analytics locali restano sotto)
```
┌────────────────────────────────────┐
│ ● ClaudeBar                     ⚙︎   │
│ ┌────────────────────────────────┐ │
│ │ 🔒 Accesso non rilevato        │ │  ← stato inline, non modale
│ │ Effettua il login con Claude    │ │
│ │ Code per vedere i tuoi limiti.  │ │
│ │   [ Come fare ]  [ Riconnetti ] │ │
│ └────────────────────────────────┘ │
│ ──────────────────────────────────  │
│  ANALYTICS (locali, sempre vive)    │  ← restano visibili anche da disconnessi
│  Costo oggi $3.42  Token 1.2M ⚡78% │
│  ▁▂▃▅▇▆▃▂                            │
└────────────────────────────────────┘
```

---

## 8. Componenti SwiftUI da creare (per i task implementativi)

> Solo firme/scheletri — l'implementazione è in altri task.

> Convenzione: il valore "primario" è il **% usato** (`used = 100 - remaining`); colore e
> soglie seguono §1.1. L'icona è guidata dalla **sessione 5h** (deciso da product-lead).

```swift
// --- Icona menu bar ---
enum MenuBarIconStyle { case ring, dualBar }           // preferenza utente (default .ring)
enum UsageState { case ok, warn, crit, empty }         // soglie su % usato (§1.1)
struct UsageColorScale {                                // token → Color interpolato
    static func color(used: Double) -> Color            // 0...100 (usato) → verde→ambra→rosso
    static func state(used: Double) -> UsageState       // <60 ok · 60–85 warn · >85 crit · ≥95 empty
}
enum MenuBarIconRenderer {                               // analogo a CodexBar IconRenderer
    static func image(sessionUsed: Double?, weeklyUsed: Double?,
                      style: MenuBarIconStyle, render: IconRenderState,
                      appearance: NSAppearance) -> NSImage  // isTemplate = false (colore!)
    // render: .normal/.loading/.stale(dim)/.error/.locked/.refreshing  (mai rosso falso)
    // cache per chiave quantizzata (vedi §3.6)
}

// --- Pannello ---
struct GlassPanel<Content: View>: View { /* cornice .glassEffect + GlassEffectContainer */ }
struct PanelHeaderView: View { let account: Account; let plan: Plan }     // §4.3 identità
struct UsageRing: View { let window: RateWindow; var showUsed = true }    // anello grande §4.4
struct PaceRow: View { let window: RateWindow }                            // §4.5.1 (v1)
struct AnalyticsSection: View { let range: AnalyticsRange }                // §4.6
struct UsageBar: View { let used: Double }                                 // barra colorata riusata
struct SpendChart: View { let series: [SpendPoint] }                       // Swift Charts
struct ModelBreakdownView/ProjectBreakdownView: View { ... }

// --- Design tokens ---
enum DS {
    enum Spacing { static let xs=4.0, s=8.0, m=12.0, l=16.0, xl=20.0, xxl=32.0 }
    enum Radius  { static let panel=26.0, card=18.0, inner=14.0, pill=999.0 }
    enum Size    { static let ring=96.0 }   // diametro anelli grandi pannello
    enum Color   { /* usageOK/Warn/Crit/Empty, usageStale, hairline, insetHighlight */ }
    enum Font    { /* display, title, headline, body, mono, caption, eyebrow */ }
}
```

---

## 9. Differenze deliberate vs CodexBar (perché è "più bello")

| Aspetto | CodexBar | ClaudeBar |
|---|---|---|
| Icona barra | template **monocroma**, due barre, "critter" personalizzato | **anello/barra COLORATA** semantica (verde→ambra→rosso), glance immediato |
| Pannello | **NSMenu** classico (righe menu) | **NSPanel Liquid Glass** SwiftUI, hero + card + Swift Charts |
| Materiali | standard menu | Liquid Glass `.regular`, double-bezel, vibrancy |
| Analytics | presenti, in righe menu | **prominenti, grafiche** (line/area, breakdown, cache, delta) |
| Focus | multi-provider (clutter) | **solo Claude**, layout dedicato e pulito |
| Motion | morphing icona, confetti | molle morbide ovunque, morphing glass, numeric transitions |

---

## 10. Decisioni & domande aperte

### Decise (allineate con product-lead, 04-product-roadmap)
- ✅ **Finestra guida icona**: **sessione 5h fissa** (brucia più in fretta).
- ✅ **Soglie colore**: sul **% usato** — verde <60 · ambra 60–85 · rosso >85 · empty ≥95.
- ✅ **Stale/errore**: icona **dim**, mai rosso falso.
- ✅ **Pannello**: header identità (account/plan) → **due anelli grandi** (Sessione + Settimana)
  → analytics. (Anelli > barre, allineato con la preferenza del product-lead.)
- ✅ **Notifiche MVP**: 1 soglia sessione (default 80% usato), de-dup per finestra; reset
  settimanale = celebrazione + notifica leggera; niente notifiche di costo.
- ✅ **Pace tracking**: feature v1 (non MVP), spazio già riservato nel layout (§4.5.1).
- ✅ **Fallback icona monocromo**: disponibile per "Aumenta contrasto"/preferenza (gusti B/N di
  Martino), ma il **default resta COLORATO** — è la firma dell'app. Non MVP-blocking.
- ✅ **Forma icona**: default **anello**; doppia-barra colorata offerta come opzione selezionabile.
- ✅ **Tint glass warm-clay ~6%**: adottato come tocco caldo discreto, **purché non comprometta
  contrasto/leggibilità testo** (da validare a video).
- ✅ **% testuale accanto all'icona**: **toggle in settings, default OFF**; legato al toggle
  "mostra utilizzo come usato/rimanente".
- ✅ **Range analytics default**: **OGGI** (coerente con "costo/token oggi" MVP); 7g/30g sono v1.
- ✅ **Onboarding no-auth**: **stato INLINE nel pannello** (non sheet modale), con analytics locali
  visibili sotto e recupero naturale al refresh. È MVP. (product-lead, doc 04 §9.2; vedi §6/§7.4)
- ✅ **Pannello = NSPanel** custom borderless con SwiftUI Liquid Glass (non NSMenu/NSPopover):
  confermato lato app-architect (serve per Liquid Glass + interattività + Swift Charts).

### Ancora aperte
Nessuna. Allineamento di design chiuso (product-lead + app-architect). Le scelte fini residue
sono di calibrazione visiva a video (valori esatti token colore, tint glass) — si rifiniscono
in implementazione senza impatto sulla struttura.
```
