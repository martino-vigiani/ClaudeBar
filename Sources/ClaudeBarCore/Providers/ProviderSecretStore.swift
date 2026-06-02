import Foundation

#if canImport(Security)
import Security
#endif

// Storage SICURO dei segreti per-provider. Vincolo BRIEF: API key e segreti SEMPRE in Keychain,
// MAI su disco in chiaro (a differenza di CodexBar che usa un file JSON).
//
// Modello: una entry Keychain (GenericPassword) per coppia (provider, account). Il `service`
// è namespacato per la nostra app + provider; l'`account` è l'etichetta scelta dall'utente
// (default "default"). Il valore è il segreto (es. API key) in UTF-8.
//
// NB: la lettura delle credenziali OAuth ALTRUI (Claude Code) resta competenza di
// `KeychainReader` (service "Claude Code-credentials", regola no-UI). QUESTO store gestisce i
// segreti che SCRIVE la nostra app (API key inserite in Impostazioni). Le due cose non si
// sovrappongono: una legge item di terzi, l'altra possiede i propri.

/// Astrazione dello storage segreti (testabile: i test iniettano un fake in memoria).
public protocol ProviderSecretStoring: Sendable {
    /// Salva (o aggiorna) il segreto per (provider, account).
    func setSecret(_ secret: String, provider: ProviderID, account: String) throws
    /// Legge il segreto per (provider, account). `nil` se assente.
    func secret(provider: ProviderID, account: String) throws -> String?
    /// Elenca gli account configurati per un provider (es. ["default", "work"]).
    func accounts(provider: ProviderID) throws -> [String]
    /// Rimuove il segreto per (provider, account).
    func removeSecret(provider: ProviderID, account: String) throws
}

extension ProviderSecretStoring {
    /// Account di default usato quando l'utente non ne specifica uno.
    public static var defaultAccount: String { "default" }

    /// true se esiste almeno un segreto per il provider (per l'auto-detect API key, no rete).
    public func hasSecret(provider: ProviderID) -> Bool {
        ((try? self.accounts(provider: provider)) ?? []).isEmpty == false
    }
}

/// Implementazione Keychain (GenericPassword). Service namespacato:
/// `"<bundlePrefix>.secret.<providerRaw>"`, account = etichetta utente.
public struct KeychainSecretStore: ProviderSecretStoring {
    /// Prefisso del `service` Keychain (di default il bundle id dell'app).
    private let servicePrefix: String

    public init(servicePrefix: String = "com.subralabs.claudebar") {
        self.servicePrefix = servicePrefix
    }

    private func service(for provider: ProviderID) -> String {
        "\(self.servicePrefix).secret.\(provider.rawValue)"
    }

    #if os(macOS)

    public func setSecret(_ secret: String, provider: ProviderID, account: String) throws {
        let service = self.service(for: provider)
        let data = Data(secret.utf8)
        // Upsert: prova update, altrimenti add.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // DECISIONS MP §Trasversali: niente sync iCloud, segreto legato a QUESTO dispositivo.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ProviderError.serverError(code: Int(addStatus), body: "Keychain add status \(addStatus)")
            }
            return
        }
        throw ProviderError.serverError(code: Int(updateStatus), body: "Keychain update status \(updateStatus)")
    }

    public func secret(provider: ProviderID, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service(for: provider),
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try Self.throwIfDenied(status)
        guard status == errSecSuccess else {
            throw ProviderError.serverError(code: Int(status), body: "Keychain read status \(status)")
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw ProviderError.invalidResponse
        }
        return value
    }

    public func accounts(provider: ProviderID) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service(for: provider),
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try Self.throwIfDenied(status)
        guard status == errSecSuccess else {
            throw ProviderError.serverError(code: Int(status), body: "Keychain enumerate status \(status)")
        }
        guard let rows = result as? [[String: Any]] else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public func removeSecret(provider: ProviderID, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service(for: provider),
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound || status == errSecSuccess { return }
        try Self.throwIfDenied(status)
        throw ProviderError.serverError(code: Int(status), body: "Keychain delete status \(status)")
    }

    private static func throwIfDenied(_ status: OSStatus) throws {
        switch status {
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, errSecNoAccessForItem:
            throw ProviderError.keychainDenied
        default:
            break
        }
    }

    #else

    public func setSecret(_: String, provider _: ProviderID, account _: String) throws {
        throw ProviderError.noCredentials
    }
    public func secret(provider _: ProviderID, account _: String) throws -> String? { nil }
    public func accounts(provider _: ProviderID) throws -> [String] { [] }
    public func removeSecret(provider _: ProviderID, account _: String) throws {}

    #endif
}

/// Store in memoria per i test (niente Keychain). `@unchecked Sendable` via lock.
public final class InMemorySecretStore: ProviderSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProviderID: [String: String]] = [:]

    public init() {}

    public func setSecret(_ secret: String, provider: ProviderID, account: String) throws {
        self.lock.lock(); defer { self.lock.unlock() }
        self.storage[provider, default: [:]][account] = secret
    }

    public func secret(provider: ProviderID, account: String) throws -> String? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.storage[provider]?[account]
    }

    public func accounts(provider: ProviderID) throws -> [String] {
        self.lock.lock(); defer { self.lock.unlock() }
        return Array(self.storage[provider]?.keys ?? [:].keys)
    }

    public func removeSecret(provider: ProviderID, account: String) throws {
        self.lock.lock(); defer { self.lock.unlock() }
        self.storage[provider]?[account] = nil
    }
}
