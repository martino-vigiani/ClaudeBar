import Foundation

// Registry dei provider + auto-detect del default sensato.
//
// A differenza di CodexBar (registry globale con NSLock + macro di auto-registrazione), qui il
// registry è un value type immutabile costruito al boot dal composition root (AppDelegate),
// passando le istanze concrete dei provider. Più semplice, niente stato globale, testabile.
//
// L'auto-detect (BRIEF: "auto-rileva credenziali e sceglie un default sensato") interroga ogni
// provider con `detectAvailability` (no rete, no prompt) e applica la politica:
//   1. il provider PRIMARIO disponibile con priorità più alta (Claude prima di tutti);
//   2. altrimenti il primo provider disponibile in assoluto;
//   3. altrimenti Claude (così la UX di default non cambia mai per chi ha solo Claude).

public struct ProviderRegistry: Sendable {
    /// Provider registrati, in ordine di PRIORITÀ per il default automatico (Claude primo).
    public let providers: [any Provider]

    public init(providers: [any Provider]) {
        self.providers = providers
    }

    /// Provider di default (solo Claude) — preserva esattamente il comportamento attuale per chi
    /// non costruisce un registry multi-provider. Usato come fallback sicuro.
    public static func claudeOnly(service: ClaudeLimitsService = ClaudeLimitsService()) -> ProviderRegistry {
        ProviderRegistry(providers: [ClaudeProvider(service: service)])
    }

    public func provider(for id: ProviderID) -> (any Provider)? {
        self.providers.first(where: { $0.descriptor.id == id })
    }

    public var descriptors: [ProviderDescriptor] {
        self.providers.map(\.descriptor)
    }

    /// Interroga ogni provider per la disponibilità (no rete/prompt) e ritorna la mappa.
    public func detectAvailability(_ context: ProviderFetchContext) async -> [ProviderID: ProviderAvailability] {
        var result: [ProviderID: ProviderAvailability] = [:]
        for provider in self.providers {
            result[provider.descriptor.id] = await provider.detectAvailability(context)
        }
        return result
    }

    /// Sceglie il default automatico secondo la politica (vedi commento in testa). `context`
    /// deve essere no-UI (background) per non far comparire prompt al boot.
    public func autoDetectDefault(_ context: ProviderFetchContext) async -> ProviderID {
        let availability = await self.detectAvailability(context)
        // 1. Primario disponibile con priorità più alta.
        for provider in self.providers
            where provider.descriptor.isPrimaryCandidate && (availability[provider.descriptor.id]?.isAvailable ?? false) {
            return provider.descriptor.id
        }
        // 2. Primo disponibile in assoluto.
        for provider in self.providers where availability[provider.descriptor.id]?.isAvailable ?? false {
            return provider.descriptor.id
        }
        // 3. Fallback: Claude (UX storica), o il primo registrato se Claude non c'è.
        return self.provider(for: .claude)?.descriptor.id
            ?? self.providers.first?.descriptor.id
            ?? .claude
    }

    /// Applica l'auto-detect alle impostazioni RIEMPIENDO SOLO I VUOTI, senza sovrascrivere le
    /// scelte manuali dell'utente (DECISIONS addendum giu 2026: "auto-detect riempie solo i
    /// vuoti"). Regole:
    ///   - un provider disponibile e MAI configurato dall'utente viene abilitato e gli viene
    ///     impostato l'auth rilevato come `preferredAuth` (se non già scelto);
    ///   - i provider già presenti in `settings.providers` (scelta manuale) NON sono toccati;
    ///   - `defaultProvider` è ricalcolato SOLO se `autoDetectDefault` è attivo e l'utente non
    ///     ne ha scelto uno valido/disponibile.
    /// `context` deve essere no-UI (background) per non far comparire prompt.
    public func applyingAutoDetect(
        to settings: MultiProviderSettings,
        context: ProviderFetchContext) async -> MultiProviderSettings
    {
        let availability = await self.detectAvailability(context)
        var result = settings

        for provider in self.providers {
            let id = provider.descriptor.id
            guard availability[id]?.isAvailable ?? false else { continue }
            // Riempi solo i vuoti: non toccare un provider che l'utente ha già configurato.
            guard !settings.providers.contains(where: { $0.id == id }) else { continue }
            result = result.updating(ProviderConfig(
                id: id,
                enabled: true,
                preferredAuth: availability[id]?.detectedAuth))
        }

        if result.autoDetectDefault {
            let current = result.defaultProvider
            let currentIsUsable = current.map { availability[$0]?.isAvailable ?? false } ?? false
            if !currentIsUsable {
                result.defaultProvider = await self.autoDetectDefault(context)
            }
        }
        return result
    }
}
