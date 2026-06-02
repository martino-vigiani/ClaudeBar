import Foundation

// Parsing incrementale dei transcript `.jsonl` a offset di byte.
// Porting fedele di `CostUsageJsonl.scan` (verificato performante sull'upstream):
//   - FileHandle + seek(toOffset:) all'offset salvato;
//   - lettura a blocchi di 256 KB, split sulle newline 0x0A;
//   - cap per riga (512 KB) per non esplodere su tool-output enormi (righe troncate scartate);
//   - prefiltro byte-level prima del JSON parse: la riga deve contenere `"type":"assistant"`
//     e `"usage"` → evita di deserializzare le righe user/system (la maggioranza).

enum JSONLParser {
    /// Cap massimo per riga (oltre → riga troncata, scartata dal conteggio usage).
    static let maxLineBytes = 512 * 1024
    /// Dimensione del blocco di lettura.
    static let chunkSize = 256 * 1024

    struct Line {
        let bytes: Data
        let truncated: Bool
    }

    /// Scansiona il file dall'offset indicato, invocando `onLine` per ogni riga completa.
    /// - Returns: il nuovo offset (byte parsati) da cui riprendere la prossima volta.
    @discardableResult
    static func scan(
        fileURL: URL,
        offset: Int64,
        onLine: (Line) -> Void) throws -> Int64
    {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let startOffset = max(0, offset)
        if startOffset > 0 {
            try handle.seek(toOffset: UInt64(startOffset))
        }

        var current = Data()
        current.reserveCapacity(4 * 1024)
        var lineBytes = 0
        var truncated = false
        var bytesRead: Int64 = 0

        func appendSegment(_ base: UnsafePointer<UInt8>, count: Int) {
            guard count > 0 else { return }
            lineBytes += count
            // Manteniamo l'intera riga (fino al cap) così l'usage in coda non si perde.
            if current.count < maxLineBytes {
                let appendCount = min(maxLineBytes - current.count, count)
                if appendCount > 0 { current.append(base, count: appendCount) }
            }
            if lineBytes > maxLineBytes { truncated = true }
        }

        func flush() {
            guard lineBytes > 0 else { return }
            onLine(Line(bytes: current, truncated: truncated))
            current.removeAll(keepingCapacity: true)
            lineBytes = 0
            truncated = false
        }

        while true {
            let reachedEOF = try autoreleasepool { () -> Bool in
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty {
                    flush()
                    return true
                }
                bytesRead += Int64(chunk.count)
                chunk.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                    var segStart = 0
                    var i = 0
                    while i < raw.count {
                        if base[i] == 0x0A {
                            appendSegment(base.advanced(by: segStart), count: i - segStart)
                            flush()
                            segStart = i + 1
                        }
                        i += 1
                    }
                    if segStart < raw.count {
                        appendSegment(base.advanced(by: segStart), count: raw.count - segStart)
                    }
                }
                return false
            }
            if reachedEOF { break }
        }
        return startOffset + bytesRead
    }
}

extension Data {
    /// Cerca una sottostringa ASCII nei byte (prefiltro veloce senza decodifica UTF-8).
    func containsASCII(_ needle: String) -> Bool {
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty, count >= pattern.count else { return false }
        return withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            let n = raw.count
            let m = pattern.count
            var i = 0
            let first = pattern[0]
            while i <= n - m {
                if base[i] == first {
                    var j = 1
                    while j < m, base[i + j] == pattern[j] { j += 1 }
                    if j == m { return true }
                }
                i += 1
            }
            return false
        }
    }
}
