# ClaudeBar — DECISIONI FINALI (fa fede)

> Questo file ha PRIORITÀ sui doc di pianificazione 01–04 in caso di conflitto.
> Gli implementatori devono leggere: BRIEF.md → 01/02/03/04 → questo file.

## Scelte UI/comportamento bloccate dall'utente
1. **Icona menu bar = ANELLO + % numerica.** Anello (ring gauge) disegnato in Core
   Graphics, colore reale semantico (NON template), con la percentuale numerica accanto.
   Es. `◕ 71%`. Compatta ma con numero leggibile.
2. **L'icona segue la finestra PIÙ CRITICA** tra sessione 5h e settimanale: colore, arco
   e % rappresentano sempre la finestra messa peggio in quel momento. Nel pannello si
   vedono entrambe distinte.
3. **Vetro NEUTRO** (nessuna tinta warm). Materiali Liquid Glass di sistema puri.
4. **Notifiche soglia sessione 5h a 50% / 75% / 90%** (de-dup per finestra: una sola
   notifica per soglia per ciclo di reset). Configurabili. + celebrazione reset settimanale.

## NUOVA FEATURE MVP richiesta dall'utente — "Pace & Forecast"
Nel pannello, per la sessione 5h (e replicabile sul settimanale), mostrare un indicatore
di **ritmo + previsione di esaurimento**:
- **Barra di pace** con:
  - riempimento = % quota USATA (`utilization`);
  - **marker "dove dovresti essere"** = % di tempo trascorso nella finestra (ritmo lineare
    atteso): se hai usato più del tempo trascorso sei "sopra ritmo";
  - **tacche fisse a 50% / 75% / 100%**.
- **Stima testuale**: "A questo ritmo esaurisci tra ~Xh Ym" (ETA all'esaurimento al ritmo
  corrente). Se l'ETA cade dopo il reset → stato positivo tipo "Arrivi al reset con margine".
- **Stato di ritmo** (verde/ambra/rosso): in linea / sopra ritmo / sotto ritmo.

### Matematica del pace (spec per data-engineer)
Per ogni finestra (5h o 7g) con `utilization` (0–100, % USATA) e `resets_at`:
- `duration` = 5h (five_hour) oppure 7g (seven_day).
- `windowStart = resets_at - duration`; `elapsed = now - windowStart`;
  `remainingTime = resets_at - now`.
- `usedFrac = utilization/100`; `elapsedFrac = clamp(elapsed/duration, 0...1)`.
- **Pace marker** = `elapsedFrac` (dove "dovresti essere").
- **Stato ritmo**: `over = usedFrac > elapsedFrac` (sopra ritmo).
- **ETA esaurimento (ritmo lineare dall'inizio finestra)**:
  se `usedFrac > 0`: `rate = usedFrac/elapsed`; `etaToEmpty = (1-usedFrac)/rate`.
  Se `etaToEmpty < remainingTime` → esaurisci PRIMA del reset (mostra ETA);
  altrimenti → arrivi al reset con margine.
- **Bonus (se fattibile, sennò v1)**: calcolare anche un **burn rate recente** dai
  transcript locali (es. ultimi 30–60 min) per una stima più reattiva del lineare-da-inizio.
  L'MVP può usare il lineare; il recente è un miglioramento.

## Decisioni tecniche/prodotto già fissate (dal lead)
- **Nome**: `ClaudeBar` (display name + product name PARAMETRICI per rebrand a costo zero).
- **Bundle id**: `com.subralabs.claudebar` (`.debug` per debug).
- **Analytics visibili anche offline / senza limiti ufficiali** (degradazione elegante).
- **Costo** etichettato **"stima API-equivalente"** (piano Max è flat, non è spesa reale) +
  disclaimer breve.
- **CLI PTY probe**: TAGLIATO dall'MVP (l'endpoint OAuth basta). Eventuale fallback dietro
  flag in v1.
- **Multi-account** e **widget**: post-MVP (l'utente ha 1 account).
- **Pricing**: tabella embedded + override JSON locale. Moltiplicatori cache ufficiali:
  cache-write 5m ×1.25, cache-write 1h ×2, cache-read ×0.1 sul prezzo input del modello.
  Includere TUTTI i modelli usati (incl. `claude-opus-4-7`, normalizzare suffisso `[1m]`).

## Reconciliazione endpoint limiti (per data-engineer + core-engineer)
La risposta di `GET https://api.anthropic.com/api/oauth/usage` usa **`utilization` = % USATA**
(0–100), NON "remaining". Quindi:
- `remainingPct = 100 - utilization` (per colore/anello).
- Mappare le chiavi reali: `five_hour` → sessione; `seven_day` → settimana;
  `seven_day_opus` / `seven_day_sonnet` → cap per-modello (mostrare nel pannello, non
  necessariamente nell'icona). `extra_usage` se presente.
- Header: `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`,
  `User-Agent: claude-code/<ver>`. Refresh: regola "non rubare il refresh alla CLI".
- Il tipo dominio condiviso `UsageWindow { kind, utilization, resetsAt, pace... }` vive in
  ClaudeBarCore ed è la fonte sia per l'icona (core-engineer) sia per il pannello (ui-engineer).

### LOCK semantica glance (anti-bug — vale per icona, %, colore, barre)
Anello, percentuale numerica e colore rappresentano tutti il **% USATO** (`utilization`)
della finestra più critica. Più usato → più rosso. Mapping colore sull'USATO:
verde `<60`, ambra `60–85`, rosso `>85`, pulsa quando `≥95`. La % mostrata di default è
l'USATO (es. `◕ 71%` = 71% consumato). Niente "remaining" come canale primario (evita la
confusione già emersa in pianificazione). `remainingPct = 100 - utilization` resta utile
solo per testi secondari/tooltip.

## Struttura team fase 2 (4 implementatori)
- `build-qa-engineer` (Task A): scaffold SPM + moduli + build verde skeleton; poi (Task E)
  integrazione finale + test + .app buildabile.
- `data-engineer` (Task B): ClaudeBarCore — Keychain, LimitsService (endpoint+refresh),
  parser .jsonl incrementale + AnalyticsStore, PricingTable, calcolo Pace/Forecast, modelli.
- `core-engineer` (Task C): app shell — AppModel @Observable @MainActor, NSStatusItem +
  IconRenderer (anello+%, interpolazione colore, selezione finestra più critica), NSPanel
  host, FileWatcher, scheduler refresh, settings, launch-at-login (SMAppService), notifiche.
- `ui-engineer` (Task D): SwiftUI Liquid Glass panel — design system, hero glance, card
  limiti, **barra Pace & Forecast** (marker + tacche 50/75/100 + ETA), analytics + Swift Charts.
