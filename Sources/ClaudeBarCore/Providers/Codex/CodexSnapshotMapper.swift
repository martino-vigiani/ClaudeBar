import Foundation

// Proiezione di `CodexUsageResponse` (endpoint wham/usage) nello snapshot unificato
// `ProviderSnapshot`, SENZA introdurre tipi provider-specifici nel modello di confine.
//
// MAPPING (come indicato da provider-architect):
//   primary_window   → finestra SESSIONE  (.fiveHour)
//   secondary_window → finestra SETTIMANA (.sevenDay)
// I window Codex riusano la STESSA semantica di Claude: `used_percent` = % USATA (0–100) →
// `utilization`; `reset_at` (epoch seconds) → `resetsAt`. Il Pace è precalcolato col
// `PaceCalculator.withPace` esistente, coerente con `ClaudeLimitsService`.
//
// NORMALIZZAZIONE: l'API può talvolta invertire primary/secondary. Si distingue il ruolo dalla
// durata della finestra (`limit_window_seconds`): ~5h (≤6h) = sessione, ~7g (≥6g) = settimana.
//
// LIMITI EXTRA (`additional_rate_limits`, es. Codex Spark): supplementari. Si proiettano sulle
// corsie per-modello settimanali ancora libere (.sevenDayOpus/.sevenDaySonnet) per non collidere
// con le finestre principali; se sono già occupate, l'entry extra viene ignorata (l'MVP privilegia
// le due finestre primarie, coerente con DECISIONS).
//
// CREDITS → `ProviderCredits` (balance pay-as-you-go), valorizzato solo se `balance` è noto.
// IDENTITY → email/plan dal JWT `id_token` (fallback su `plan_type`).

enum CodexSnapshotMapper {
    /// Costruisce un `ProviderSnapshot` dalla risposta usage Codex.
    static func makeSnapshot(
        from response: CodexUsageResponse,
        credentials: CodexOAuthCredentials,
        accountLabel: String?,
        now: Date,
        source: LimitsSource = .live) -> ProviderSnapshot
    {
        let windows = self.windows(from: response, now: now)
        let credits = self.credits(from: response.credits)
        let identity = self.identity(from: response, credentials: credentials, accountLabel: accountLabel)

        return ProviderSnapshot(
            providerID: .codex,
            windows: windows,
            cost: nil, // i limiti-piano Codex non portano costo; l'usage/costo è il provider OpenAI a consumo
            credits: credits,
            identity: identity,
            fetchedAt: now,
            source: source)
    }

    // MARK: - Finestre

    static func windows(from response: CodexUsageResponse, now: Date) -> [UsageWindow] {
        guard let rateLimit = response.rateLimit else { return [] }
        let (session, weekly) = self.normalize(
            primary: rateLimit.primaryWindow,
            secondary: rateLimit.secondaryWindow)

        var result: [UsageWindow] = []
        if let session, let window = self.usageWindow(kind: .fiveHour, from: session, now: now) {
            result.append(window)
        }
        if let weekly, let window = self.usageWindow(kind: .sevenDay, from: weekly, now: now) {
            result.append(window)
        }

        // Limiti extra per-modello (es. Spark) sulle corsie weekly per-modello ancora libere.
        let extraKinds: [PaceWindowKind] = [.sevenDayOpus, .sevenDaySonnet]
        var freeKinds = extraKinds.makeIterator()
        for extra in response.additionalRateLimits {
            guard let snapshot = extra.rateLimit?.primaryWindow ?? extra.rateLimit?.secondaryWindow else { continue }
            guard let kind = freeKinds.next() else { break }
            if let window = self.usageWindow(kind: kind, from: snapshot, now: now) {
                result.append(window)
            }
        }
        return result
    }

    /// Normalizza la coppia primary/secondary in (sessione, settimana) usando la durata finestra.
    static func normalize(
        primary: CodexUsageResponse.Window?,
        secondary: CodexUsageResponse.Window?)
        -> (session: CodexUsageResponse.Window?, weekly: CodexUsageResponse.Window?)
    {
        switch (primary, secondary) {
        case let (.some(p), .some(s)):
            switch (self.role(of: p), self.role(of: s)) {
            case (.weekly, .session), (.weekly, .unknown):
                return (s, p) // invertite → riallinea
            default:
                return (p, s)
            }
        case let (.some(p), .none):
            return self.role(of: p) == .weekly ? (nil, p) : (p, nil)
        case let (.none, .some(s)):
            return self.role(of: s) == .weekly ? (nil, s) : (s, nil)
        case (.none, .none):
            return (nil, nil)
        }
    }

    private enum WindowRole { case session, weekly, unknown }

    private static func role(of window: CodexUsageResponse.Window) -> WindowRole {
        let minutes = window.limitWindowSeconds / 60
        if minutes <= 0 { return .unknown }
        if minutes <= 6 * 60 { return .session }       // ≤ 6h → sessione (tipico 5h = 300m)
        if minutes >= 6 * 24 * 60 { return .weekly }   // ≥ 6g → settimana (tipico 7g = 10080m)
        return .unknown
    }

    private static func usageWindow(
        kind: PaceWindowKind,
        from window: CodexUsageResponse.Window,
        now: Date) -> UsageWindow?
    {
        let utilization = max(0, min(100, window.usedPercent))
        let resetsAt: Date? = window.resetAt > 0 ? Date(timeIntervalSince1970: TimeInterval(window.resetAt)) : nil
        let usage = UsageWindow(kind: kind, utilization: utilization, resetsAt: resetsAt)
        // `withPace` precalcola il Pace usando la durata effettiva della finestra (idiomatico).
        return PaceCalculator.withPace(usage, now: now)
    }

    // MARK: - Credits

    static func credits(from credits: CodexUsageResponse.Credits?) -> ProviderCredits? {
        guard let credits, let balance = credits.balance else { return nil }
        return ProviderCredits(remaining: balance, total: nil, currency: "USD")
    }

    // MARK: - Identity

    static func identity(
        from response: CodexUsageResponse,
        credentials: CodexOAuthCredentials,
        accountLabel: String?) -> ProviderAccountIdentity
    {
        let claims = credentials.idToken.flatMap(Self.decodeJWTClaims)
        let email = self.resolveEmail(claims: claims)
        let plan = self.resolvePlan(planType: response.planType, claims: claims)
        return ProviderAccountIdentity(
            label: accountLabel,
            email: email,
            organization: nil,
            plan: plan)
    }

    private static func resolveEmail(claims: [String: Any]?) -> String? {
        guard let claims else { return nil }
        if let email = claims["email"] as? String, !email.isEmpty { return email }
        if let profile = claims["https://api.openai.com/profile"] as? [String: Any],
           let email = profile["email"] as? String, !email.isEmpty
        {
            return email
        }
        return nil
    }

    private static func resolvePlan(planType: String?, claims: [String: Any]?) -> String? {
        if let planType, !planType.isEmpty { return planType }
        guard let claims else { return nil }
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
           let plan = auth["chatgpt_plan_type"] as? String, !plan.isEmpty
        {
            return plan
        }
        return (claims["chatgpt_plan_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Decodifica i claims dal payload (parte centrale) di un JWT, senza verifica della firma
    /// (serve solo a leggere email/plan, non a fidarsi del token).
    static func decodeJWTClaims(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Padding base64.
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        return json
    }
}
