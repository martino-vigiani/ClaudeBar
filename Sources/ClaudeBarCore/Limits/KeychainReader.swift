import Foundation

#if canImport(Security)
import Security
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

// Lettura delle credenziali Claude dal Keychain di sistema.
// Query verificata sull'upstream CodexBar e sul sistema reale dell'utente:
//   kSecClass=GenericPassword, kSecAttrService="Claude Code-credentials".
// Multi-account: enumeriamo con kSecMatchLimitAll e ordiniamo per data di modifica
// (più recente = quello attivo). MVP: usiamo il più recente.
//
// PROMPT KEYCHAIN (punto delicato): leggere un item creato da un'altra app fa comparire
// il prompt macOS. Strategia (02 §7.2):
//   - probe NO-UI in background (kSecUseAuthenticationUIFail) per il timer: fallisce pulito
//     senza prompt → l'app non genera loop di richieste;
//   - prompt reale SOLO su azione utente (apertura pannello / Refresh manuale).

public enum KeychainReader {
    /// Service del Keychain di Claude Code (verificato).
    public static let service = "Claude Code-credentials"

    /// Candidato Keychain (item di credenziali) con metadati per ordinamento.
    public struct Candidate: Sendable, Equatable {
        public let persistentRef: Data
        public let account: String?
        public let modifiedAt: Date?
        public let createdAt: Date?

        /// Data di riferimento per l'ordinamento (modifica, poi creazione).
        var sortDate: Date { modifiedAt ?? createdAt ?? .distantPast }
    }

    /// Risultato della lettura: dati + account selezionato.
    public struct ReadResult: Sendable, Equatable {
        public let data: Data
        public let account: String?
    }

    #if os(macOS)

    /// Enumera i candidati (multi-account), ordinati per data più recente.
    /// - Parameter allowUI: se `false`, usa query no-UI (nessun prompt).
    public static func candidates(allowUI: Bool) throws -> [Candidate] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
        ]
        if !allowUI {
            applyNoUI(to: &query)
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return [] }
        try throwIfDenied(status)
        guard status == errSecSuccess else {
            throw ClaudeLimitsError.serverError(code: Int(status), body: "Keychain enumerate status \(status)")
        }
        guard let rows = result as? [[String: Any]] else { return [] }

        let candidates: [Candidate] = rows.compactMap { row in
            guard let ref = row[kSecValuePersistentRef as String] as? Data else { return nil }
            return Candidate(
                persistentRef: ref,
                account: row[kSecAttrAccount as String] as? String,
                modifiedAt: row[kSecAttrModificationDate as String] as? Date,
                createdAt: row[kSecAttrCreationDate as String] as? Date)
        }
        return candidates.sorted { $0.sortDate > $1.sortDate }
    }

    /// Legge i byte del candidato indicato via persistentRef.
    /// - Parameter allowUI: se `false`, query no-UI (può fallire con `errSecInteractionNotAllowed`).
    public static func readData(for candidate: Candidate, allowUI: Bool) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: candidate.persistentRef,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if !allowUI {
            applyNoUI(to: &query)
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        try throwIfDenied(status)
        guard status == errSecSuccess else {
            throw ClaudeLimitsError.serverError(code: Int(status), body: "Keychain read status \(status)")
        }
        guard let data = result as? Data else {
            throw ClaudeLimitsError.invalidResponse
        }
        return data
    }

    /// Legge il candidato più recente. Ritorna `nil` se non ci sono item.
    public static func readMostRecent(allowUI: Bool) throws -> ReadResult? {
        let all = try candidates(allowUI: allowUI)
        guard let best = all.first else { return nil }
        let data = try readData(for: best, allowUI: allowUI)
        return ReadResult(data: data, account: best.account)
    }

    /// Applica i flag per una query non interattiva (nessun prompt UI).
    /// API moderna (macOS 11+): `LAContext.interactionNotAllowed` via `kSecUseAuthenticationContext`.
    private static func applyNoUI(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
    }

    /// Mappa gli status di diniego sull'errore tipizzato `keychainDenied`.
    private static func throwIfDenied(_ status: OSStatus) throws {
        switch status {
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, errSecNoAccessForItem:
            throw ClaudeLimitsError.keychainDenied
        default:
            break
        }
    }

    #else

    public static func candidates(allowUI _: Bool) throws -> [Candidate] { [] }
    public static func readData(for _: Candidate, allowUI _: Bool) throws -> Data {
        throw ClaudeLimitsError.noCredentials
    }
    public static func readMostRecent(allowUI _: Bool) throws -> ReadResult? { nil }

    #endif
}
