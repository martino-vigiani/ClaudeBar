import Foundation

// Interning di stringhe ad alta duplicazione nell'indice in memoria.
// Gli UsageEvent residenti ripetono gli stessi valori migliaia di volte (model id,
// projectPath, sessionId, …): senza interning ogni occorrenza tiene un buffer heap
// proprio, e con decine di migliaia di eventi è la voce dominante della RSS.
// Restituendo sempre l'istanza canonica, tutte le copie condividono un solo buffer.

/// Pool di interning: `intern(_:)` restituisce l'istanza canonica di una stringa,
/// così i duplicati condividono lo stesso buffer heap (le String Swift sono CoW).
/// Value type senza lock: va tenuto dentro l'isolamento di un actor.
struct StringInterner {
    private var pool: [String: String] = [:]

    /// Numero di stringhe canoniche nel pool (per test/diagnostica).
    var count: Int { pool.count }

    mutating func intern(_ string: String) -> String {
        if let canonical = pool[string] { return canonical }
        pool[string] = string
        return string
    }

    mutating func intern(_ string: String?) -> String? {
        guard let string else { return nil }
        return intern(string)
    }

    /// Svuota il pool (quando l'indice viene azzerato, per non pinnare stringhe stantie).
    mutating func removeAll() {
        pool.removeAll()
    }
}
