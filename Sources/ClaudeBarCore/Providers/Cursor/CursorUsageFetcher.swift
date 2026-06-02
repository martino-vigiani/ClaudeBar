import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Aggregatore Cursor: `usage-summary` (+ identità best-effort) → `ProviderSnapshot`.
// La logica di parsing/mapping è PURA (`makeSnapshot`) e testabile senza rete.
//
// MAPPING al modello unificato (vedi docs/plan/mp/prov-gemini-cursor.md §2.4 / §5):
// - windows[0] = "Total" del piano → contenitore `.sevenDay` (NON è una settimana: è la finestra del
//   ciclo di fatturazione mensile; `PaceWindowKind` oggi ha solo i 4 case Claude, quindi riusiamo
//   il contenitore più ampio. `resetsAt = billingCycleEnd`, `pace = nil` perché il pace lineare di
//   Claude non ha senso qui). È la finestra usata per icona/glance (`mostCriticalWindow`).
// - windows[1] = "Auto + Composer" (se presente) → contenitore `.fiveHour`.
// - windows[2] = "API named model" (se presente) → contenitore `.sevenDayOpus`.
//   NB: i `kind` sono solo CONTENITORI di trasporto; la UI li riconosce per posizione/etichetta.
// - on-demand (USD, oltre il piano) → `ProviderCredits { remaining = max(0, limit-used), total =
//   limit, currency USD }` così il pannello mostra la spesa a consumo oltre il piano.
//
// HEADLINE "Total" (precedenza, identica a CodexBar):
//   1. plan.totalPercentUsed → 2. media auto+api → 3. una sola lane → 4. ratio plan.used/limit
//   → 5. ratio overall.used/limit → 6. ratio pooled.used/limit. Tutto clampato 0–100.
// I percent di Cursor sono GIA' in unità % (anche < 1.0: 0.36 = 0.36%, non 36%).

enum CursorUsageFetcher {
    /// Durata nominale del ciclo di fatturazione Cursor (~mensile, 30g) in minuti. Non conosciamo
    /// l'inizio esatto del ciclo dall'API, quindi usiamo 30g come durata custom per il Pace.
    static let billingCycleMinutes = 30 * 24 * 60

    /// Scarica usage-summary (+ identità best-effort) e costruisce lo snapshot.
    static func fetch(
        cookieHeader: String,
        loader: CursorDataLoader,
        now: Date = Date()) async throws -> ProviderSnapshot
    {
        let summary = try await CursorUsageEndpoint.fetchUsageSummary(
            cookieHeader: cookieHeader, loader: loader, now: now)
        // L'identità non deve far fallire il fetch principale.
        let userInfo = try? await CursorUsageEndpoint.fetchUserInfo(
            cookieHeader: cookieHeader, loader: loader, now: now)
        return self.makeSnapshot(summary: summary, userInfo: userInfo, now: now)
    }

    /// Costruisce il `ProviderSnapshot` dal riepilogo (PURA, per i test).
    static func makeSnapshot(
        summary: CursorUsageSummary,
        userInfo: CursorUserInfo?,
        now: Date) -> ProviderSnapshot
    {
        let billingEnd = self.parseDate(summary.billingCycleEnd)

        let plan = summary.individualUsage?.plan
        let autoPercent = self.normPercent(plan?.autoPercentUsed)
        let apiPercent = self.normPercent(plan?.apiPercentUsed)
        let totalPercent = self.headlinePercent(summary: summary, autoPercent: autoPercent, apiPercent: apiPercent)

        // Finestre del ciclo di fatturazione: `customDurationMinutes` = ciclo mensile (~30g) + `label`
        // descrittiva, così il layout LIMITI si accende (il `kind` è solo un contenitore).
        var windows: [UsageWindow] = [
            UsageWindow(
                kind: .sevenDay, utilization: totalPercent, resetsAt: billingEnd,
                customDurationMinutes: Self.billingCycleMinutes, label: "Total"),
        ]
        if let autoPercent {
            windows.append(UsageWindow(
                kind: .fiveHour, utilization: autoPercent, resetsAt: billingEnd,
                customDurationMinutes: Self.billingCycleMinutes, label: "Auto"))
        }
        if let apiPercent {
            windows.append(UsageWindow(
                kind: .sevenDayOpus, utilization: apiPercent, resetsAt: billingEnd,
                customDurationMinutes: Self.billingCycleMinutes, label: "API"))
        }

        let credits = self.makeOnDemandCredits(summary)

        let identity = ProviderAccountIdentity(
            label: userInfo?.name,
            email: userInfo?.email,
            plan: summary.membershipType.map(Self.formatMembership))

        return ProviderSnapshot(
            providerID: .cursor,
            windows: windows,
            cost: nil,
            credits: credits,
            identity: identity,
            fetchedAt: now,
            source: .live)
    }

    // MARK: - Headline

    /// Precedenza dell'headline "Total" (vedi commento in testa). Sempre clampato 0–100.
    private static func headlinePercent(
        summary: CursorUsageSummary,
        autoPercent: Double?,
        apiPercent: Double?) -> Double
    {
        let plan = summary.individualUsage?.plan
        if let total = plan?.totalPercentUsed {
            return self.clampPercent(total)
        }
        if let auto = autoPercent, let api = apiPercent {
            return self.clampPercent((auto + api) / 2)
        }
        if let api = apiPercent { return self.clampPercent(api) }
        if let auto = autoPercent { return self.clampPercent(auto) }
        if let used = plan?.used, let limit = plan?.limit, limit > 0 {
            return self.clampPercent(Double(used) / Double(limit) * 100)
        }
        if let overall = summary.individualUsage?.overall,
           let used = overall.used, let limit = overall.limit, limit > 0
        {
            return self.clampPercent(Double(used) / Double(limit) * 100)
        }
        if let pooled = summary.teamUsage?.pooled,
           let used = pooled.used, let limit = pooled.limit, limit > 0
        {
            return self.clampPercent(Double(used) / Double(limit) * 100)
        }
        return 0
    }

    // MARK: - On-demand → credits (USD)

    /// On-demand (spesa oltre il piano) come `ProviderCredits` in USD. `nil` se assente.
    /// Cursor riporta i valori in CENTESIMI → /100. Preferisce individualUsage.onDemand,
    /// poi teamUsage.onDemand.
    private static func makeOnDemandCredits(_ summary: CursorUsageSummary) -> ProviderCredits? {
        let onDemand = summary.individualUsage?.onDemand ?? summary.teamUsage?.onDemand
        guard let onDemand else { return nil }
        let usedCents = onDemand.used ?? 0
        guard let limitCents = onDemand.limit, limitCents > 0 else {
            // Limite sconosciuto/illimitato: niente budget significativo da mostrare.
            return nil
        }
        let usedUSD = Double(usedCents) / 100.0
        let limitUSD = Double(limitCents) / 100.0
        return ProviderCredits(
            remaining: max(0, limitUSD - usedUSD),
            total: limitUSD,
            currency: "USD")
    }

    // MARK: - Helpers

    /// Normalizza un percent opzionale a [0, 100]; `nil` resta `nil`.
    private static func normPercent(_ value: Double?) -> Double? {
        value.map(Self.clampPercent)
    }

    private static func clampPercent(_ value: Double) -> Double {
        max(0, min(100, value))
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func formatMembership(_ type: String) -> String {
        switch type.lowercased() {
        case "enterprise": "Cursor Enterprise"
        case "pro": "Cursor Pro"
        case "hobby": "Cursor Hobby"
        case "team": "Cursor Team"
        default: "Cursor \(type.capitalized)"
        }
    }
}
