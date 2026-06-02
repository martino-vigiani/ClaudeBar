import Foundation

// Aggregatore Gemini OAuth: quote per-modello → `ProviderSnapshot` a LIMITI (windows[]).
// La logica di mapping è PURA (`makeSnapshot`/`makeWindows`) e testabile senza rete.
//
// Le quote arrivano per-modello (es. gemini-2.5-pro, gemini-2.5-flash, gemini-2.5-flash-lite),
// ognuna con % RIMANENTE e un reset giornaliero. Le raggruppiamo in 3 famiglie e produciamo una
// finestra per famiglia con `utilization = 100 - percentLeft` (% USATA, semantica LOCK del progetto).
//
// WINDOW KIND (provvisorio): `PaceWindowKind` ha solo i 4 case Claude. Finché l'architetto non
// pubblica il kind generico (daily/perModelCap — richiesto, DECISIONS §25/§35), usiamo i case
// esistenti come CONTENITORI: Pro→.fiveHour (primaria/critica), Flash→.sevenDay, Flash-Lite→
// .sevenDayOpus. Sono solo trasporto: la UI li distingue per posizione. `pace = nil` (le quote
// giornaliere Gemini non hanno il pace lineare di Claude).

enum GeminiUsageFetcher {
    /// Scarica le quote via OAuth e costruisce lo snapshot a limiti.
    static func fetch(
        homeDirectory: String,
        loader: GeminiOAuthDataLoader,
        now: Date = Date()) async throws -> ProviderSnapshot
    {
        let result = try await GeminiOAuthEndpoint.fetchQuotas(
            homeDirectory: homeDirectory, loader: loader, now: now)
        return self.makeSnapshot(result: result, now: now)
    }

    /// Costruisce il `ProviderSnapshot` dalle quote (PURA, per i test).
    static func makeSnapshot(result: GeminiOAuthResult, now: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: .gemini,
            windows: self.makeWindows(quotas: result.quotas),
            cost: nil,
            credits: nil,
            identity: ProviderAccountIdentity(
                email: result.accountEmail,
                plan: result.accountPlan),
            fetchedAt: now,
            source: .live)
    }

    /// Durata delle quote Gemini: finestra GIORNALIERA (24h = 1440 min).
    static let dailyWindowMinutes = 1440

    /// Raggruppa le quote in finestre Pro/Flash/Flash-Lite. Ogni finestra usa
    /// `customDurationMinutes = 1440` (quota giornaliera) + `label` descrittiva, così il layout
    /// LIMITI si accende correttamente (anelli + Pace su finestra 24h, non sui 5h/7g di Claude).
    /// Il `kind` resta un contenitore: `.fiveHour` per avere il Pace, ma `effectiveDuration` usa i 1440.
    static func makeWindows(quotas: [GeminiModelQuota]) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        if let pro = self.worst(quotas, where: Self.isPro) {
            windows.append(self.window(quota: pro, label: "Pro"))
        }
        if let flash = self.worst(quotas, where: Self.isFlash) {
            windows.append(self.window(quota: flash, label: "Flash"))
        }
        if let lite = self.worst(quotas, where: Self.isFlashLite) {
            windows.append(self.window(quota: lite, label: "Flash Lite"))
        }
        return windows
    }

    // MARK: - Helpers

    private static func window(quota: GeminiModelQuota, label: String) -> UsageWindow {
        UsageWindow(
            kind: .fiveHour,
            utilization: max(0, min(100, 100 - quota.percentLeft)),
            resetsAt: quota.resetTime,
            customDurationMinutes: self.dailyWindowMinutes,
            label: label)
    }

    /// Quota peggiore (minor % rimanente) tra quelle che soddisfano il predicato.
    private static func worst(
        _ quotas: [GeminiModelQuota],
        where predicate: (String) -> Bool) -> GeminiModelQuota?
    {
        quotas
            .filter { predicate($0.modelId.lowercased()) }
            .min(by: { $0.percentLeft < $1.percentLeft })
    }

    private static func isFlashLite(_ id: String) -> Bool { id.contains("flash-lite") }
    private static func isFlash(_ id: String) -> Bool { id.contains("flash") && !self.isFlashLite(id) }
    private static func isPro(_ id: String) -> Bool { id.contains("pro") }
}
