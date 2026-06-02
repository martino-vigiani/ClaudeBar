# ClaudeBar → Multi-Provider — Brief condiviso

> Leggi PRIMA questo file, poi `docs/plan/DECISIONS.md` e i doc 01–04 esistenti.
> Obiettivo: estendere ClaudeBar (oggi solo-Claude, MVP FUNZIONANTE) per supportare
> più provider, in modo automatico e personalizzabile dalle Impostazioni.

## Obiettivo
Da app solo-Claude a **monitor multi-provider** per chi usa Claude, **Codex/OpenAI,
Gemini, Cursor** e chi usa **API "a consumo"** (pay-as-you-go, niente limiti: si mostra
USAGE + COSTO invece delle finestre limite). Tutto:
- **automatico**: auto-rileva credenziali/abbonamenti disponibili sul sistema e sceglie un default sensato;
- **personalizzabile** nelle **Impostazioni** (da CREARE): abilita/disabilita provider, configura auth, scegli il default e cosa mostrare;
- **default = la vista attuale di Claude (abbonamento → limiti)** quando l'utente ha un piano a pagamento (è la UX che l'utente ama). Per chi non ha abbonamento ma API key → vista usage/costo.

## Stato attuale (NON regredire!)
ClaudeBar è un MVP **funzionante e verde** (45 test) solo-Claude. Vedi `project_claudebar` (memoria) e:
- `Sources/ClaudeBarCore/` — `ClaudeLimitsService` (GET /api/oauth/usage, Keychain `Claude Code-credentials`), parser `.jsonl` incrementale, `PricingTable`, `PaceCalculator`, `AnalyticsReport`/`TokenTotals`.
- `Sources/ClaudeBarApp/` — `NSStatusItem` + `IconRenderer` (anello+%), `NSPanel` host, pannello SwiftUI Liquid Glass (`Panel/`), `AppModel` (@Observable @MainActor, fonte di verità), `PanelViewModeling` + `AppModelPanelAdapter`, `RefreshScheduler`, `FileWatcher`, `Notifications`, `SettingsStore`+`PreferencesView` (minime).
- Build: `swift build` / `./Scripts/run.sh` / `CLBAR_CONFIG=release ./Scripts/bundle.sh` (firma stabile auto). macOS 26, Swift 6.2, SPM puro, **vetro NEUTRO**.
- **DECISIONS.md fa fede** sulle scelte UI già prese (anello+%, finestra più critica, vetro neutro, soglie 50/75/90, Pace & Forecast). Claude resta il provider di default e la sua UX non deve peggiorare.

## Riferimento CodexBar (READ-ONLY) — dove guardare
`.reference/CodexBar/Sources/CodexBarCore/` (339 file). Aree chiave:
- **Astrazione provider**: `Providers/Providers.swift`, `Providers/ProviderDescriptor.swift`, `Providers/ProviderFetchPlan.swift`, `Providers/ProviderTokenResolver.swift`, `Providers/ProviderSettingsSnapshot.swift`, `Providers/ProviderInteractionContext.swift`; per-provider in sottocartelle (es. `Providers/Kilo/`, `Providers/MiMo/`, `Providers/Moonshot/`).
- **Fetch usage/costo**: `UsageFetcher.swift`, `CostUsageFetcher.swift`, `ProviderCostSnapshot.swift`, `CostUsageModels.swift`, `ProviderHTTPClient.swift`.
- **OpenAI/Codex**: `OpenAIDashboardModels.swift`, `CodexManagedAccounts.swift`, `ManagedCodexAccountStore.swift`, `CodexHomeScope.swift`, `CodexActiveSource.swift`, `Providers/CLIProbeSessionResetter.swift`.
- **Copilot/credits**: `CopilotUsageModels.swift`, `CreditsModels.swift`.
- **Auth**: `KeychainNoUIQuery.swift`, `KeychainAccessGate.swift`, `KeychainAccessPreflight.swift`, `TokenAccounts.swift`/`TokenAccountSupport*.swift` (API key catalog), `BrowserCookie*` + `BrowserDetection.swift` + `CookieHeader*` (cookie auth), `ProviderTokenResolver.swift`.
- **Config/impostazioni**: `Config/CodexBarConfig*.swift`, `Config/ProviderConfigEnvironment.swift`.
- App/UI: `.reference/CodexBar/Sources/CodexBar/` (per ispirazione su provider switcher, settings, merged-icon vs per-provider items). README in `.reference/CodexBar/README.md`.

## Modello concettuale da progettare
Due "famiglie" di provider, da unificare in UN modello snapshot:
- **Abbonamento/limiti** (Claude Max, ChatGPT/Codex plan, Cursor plan…): finestre di utilizzo (sessione/settimana) con `utilization %` + reset + Pace. → la nostra UI attuale.
- **API a consumo** (Anthropic API key, OpenAI API key, Gemini API key…): NIENTE limiti → si mostra **usage + costo** (oggi/7g/30g, per-modello), eventualmente credito/budget residuo se l'API lo espone.
Lo snapshot unificato deve poter rappresentare entrambi (windows opzionali + cost/usage opzionali) così la UI sceglie il layout giusto per provider.

## Provider target v1 (priorità)
1. **Claude** (già fatto → diventa "il provider Claude" dietro l'astrazione, default).
2. **Codex/OpenAI** (plan limits se disponibili + Admin/usage API a consumo).
3. **Gemini** (API key usage/costo).
4. **Cursor** (plan usage).
5. **API generiche a consumo** (Anthropic API, OpenAI API) per chi non ha abbonamento.
Auth: **API key (in Keychain) + OAuth dove applicabile**. Cookie-browser = opzionale/stretch (più invasivo: valutare ma non bloccare l'MVP multi-provider).

## Vincoli
- macOS 26, Swift 6.2, SPM puro, zero dipendenze esterne se possibile, vetro NEUTRO, StrictConcurrency.
- Value types Sendable ai confini; `@Observable @MainActor AppModel` resta la fonte di verità UI.
- NON rompere il path Claude né i 45 test esistenti. Aggiungere test per i nuovi provider.
- **API key e segreti SEMPRE in Keychain**, mai su disco in chiaro.
- **Congelare le interfacce pubbliche** una volta definite dall'architetto: niente rinomine in parallelo (lezione della fase precedente).

## Fasi
- **Fase A (subito)**: `provider-research` + `provider-architect` definiscono modello/astrazione/auth/settings; gli engineer di provider studiano in parallelo come CodexBar fa il LORO provider e scrivono un mini-doc.
- **Fase B**: una volta che l'architetto pubblica le interfacce (congelate), gli engineer implementano e `settings-ui-engineer` crea Impostazioni + adatta il pannello.
Decisioni di prodotto aperte (display multi vs singolo provider, cookie-auth sì/no, default auto-detect) verranno confermate dal team-lead con l'utente DOPO la fase A.

## Output
Doc in `docs/plan/mp/`. Codice nuovo in `ClaudeBarCore/Providers/` e `ClaudeBarApp/` (Settings + adattamento pannello). Riportare al team-lead in italiano con scoperte, interfacce proposte, rischi.
