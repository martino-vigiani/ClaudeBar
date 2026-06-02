import Foundation

// Bridge SENZA PERDITA: il `LimitsSnapshot` di Claude (già testato) si proietta nello snapshot
// unificato `ProviderSnapshot`. Questo permette al `ClaudeProvider` di riusare integralmente
// `ClaudeLimitsService` e di esporre i dati nel modello multi-provider, senza toccare i tipi
// dominio esistenti né i 45 test.

extension LimitsSnapshot {
    /// Proietta lo snapshot Claude nel modello unificato.
    public func asProviderSnapshot() -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: .claude,
            windows: self.allWindows,
            cost: nil, // il costo Claude vive nel report analytics, non nello snapshot limiti
            credits: nil,
            identity: ProviderAccountIdentity(
                label: self.accountLabel.isEmpty ? nil : self.accountLabel,
                plan: self.subscriptionType.isEmpty ? nil : self.subscriptionType),
            fetchedAt: self.fetchedAt,
            source: self.source)
    }
}

extension ProviderSnapshot {
    /// Reverse-bridge: ricostruisce un `LimitsSnapshot` dalle finestre dello snapshot unificato,
    /// così l'`AppModel` può riusare INTATTA tutta la pipeline glance/Pace/notifiche esistente
    /// (scritta su `LimitsSnapshot`) per QUALSIASI provider a limiti, non solo Claude.
    ///
    /// Mappa le finestre per `kind`: la prima `.fiveHour` → sessione (fallback util 0 se assente),
    /// la prima `.sevenDay` → settimana, `.sevenDayOpus`/`.sevenDaySonnet` → cap per-modello.
    /// `label`/`customDurationMinutes` delle finestre non-Claude sono preservati nelle `UsageWindow`
    /// risultanti (la UI li usa via l'adapter). Ritorna `nil` se non ci sono finestre (provider a
    /// solo costo): in quel caso l'AppModel mostra la vista usage/costo, non i limiti.
    public func asLimitsSnapshot() -> LimitsSnapshot? {
        guard hasLimits else { return nil }
        let five = window(.fiveHour)
            ?? UsageWindow(kind: .fiveHour, utilization: 0, resetsAt: nil)
        let seven = window(.sevenDay)
            ?? UsageWindow(kind: .sevenDay, utilization: 0, resetsAt: nil)
        return LimitsSnapshot(
            fiveHour: five,
            sevenDay: seven,
            sevenDayOpus: window(.sevenDayOpus),
            sevenDaySonnet: window(.sevenDaySonnet),
            extraUsage: nil,
            subscriptionType: identity.plan ?? "",
            accountLabel: identity.label ?? "",
            fetchedAt: fetchedAt,
            source: source)
    }
}
