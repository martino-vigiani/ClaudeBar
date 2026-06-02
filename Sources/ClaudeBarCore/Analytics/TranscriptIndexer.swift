import Foundation

// Walk + parse incrementale dei transcript + dedup → AnalyticsReport.
// Logica per-file verificata sull'upstream CodexBar (`processClaudeFile`):
//   - cached.size == size && cached.mtime == mtime  → SKIP
//   - size > cached.size && offset valido            → INCREMENTALE (parse da offset)
//   - altrimenti (nuovo/rimpicciolito/ruotato)       → FULL PARSE da 0
// Dedup: in-file per `messageId:requestId` (last-wins); cross-file vince subagent/sidechain.

public actor TranscriptIndexer {
    private let roots: [URL]
    private let index: IncrementalIndex
    /// Callback di avanzamento del primo full-index (0...1), su attore esterno se serve.
    private let progress: (@Sendable (Double) -> Void)?

    public init(
        roots: [URL] = AppPaths.transcriptRoots(),
        index: IncrementalIndex = IncrementalIndex(),
        progress: (@Sendable (Double) -> Void)? = nil)
    {
        self.roots = roots
        self.index = index
        self.progress = progress
    }

    /// Indicizza (incrementale) e produce il report aggregato.
    /// - Parameters:
    ///   - force: se `true`, ignora la cache per-file e riparsa tutto.
    ///   - includeSubagents: se `false`, esclude le sessioni subagent dagli aggregati
    ///     (preferenza Impostazioni → Analytics). Default `true` = comportamento storico.
    ///     NB: la cache per-file resta invariata (gli eventi sono sempre indicizzati con il loro
    ///     `isSubagent`); il filtro è applicato solo in aggregazione, così cambiare la preferenza
    ///     non richiede un re-parse, solo un nuovo `refresh`.
    public func refresh(force: Bool = false, includeSubagents: Bool = true) async throws -> AnalyticsReport {
        await index.load()

        // 1. Enumera i file leggendo solo size + mtime (no apertura file).
        let files = enumerateFiles()
        var touched = Set<String>()

        let total = max(files.count, 1)
        var processed = 0
        let reportProgressEvery = max(total / 100, 1)

        for file in files {
            try Task.checkCancellation()
            touched.insert(file.path)
            try await processFile(file, force: force)

            processed += 1
            if let progress, processed % reportProgressEvery == 0 {
                progress(Double(processed) / Double(total))
            }
        }

        // 2. Prune dei file spariti + salva indice.
        await index.prune(touched: touched)
        await index.save()
        progress?(1.0)

        // 3. Dedup cross-file + aggregazione.
        let allStates = await index.snapshotAllStates()
        let deduped = Self.dedupCrossFile(states: allStates)
        return CostCalculator.build(events: deduped, includeSubagents: includeSubagents)
    }

    /// Azzera la cache dell'indice incrementale: svuota lo stato per-file in memoria e cancella
    /// i file dell'indice su disco (`indexDir()`). Dopo il clear, il prossimo `refresh(force:)`
    /// ricostruisce tutto da zero. Usata da "Azzera cache indice" (sezione Avanzato).
    public func clearCache() async {
        await index.clear()
    }

    /// Stati per-file correnti dell'indice (per test/diagnostica). `internal` → solo `@testable`.
    func debugFileStates() async -> [FileState] {
        await index.snapshotAllStates()
    }

    // MARK: - Per-file

    private struct FileInfo {
        let url: URL
        let path: String
        let size: Int64
        let mtimeMs: Int64
        let inode: UInt64
    }

    private func enumerateFiles() -> [FileInfo] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
        ]
        var result: [FileInfo] = []
        for root in roots {
            guard let en = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }

            for case let url as URL in en {
                guard url.pathExtension.lowercased() == "jsonl" else { continue }
                guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
                let size = Int64(v.fileSize ?? 0)
                guard size > 0 else { continue }
                let mtimeMs = Int64((v.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
                let inode = inodeOf(url)
                result.append(FileInfo(url: url, path: url.path, size: size, mtimeMs: mtimeMs, inode: inode))
            }
        }
        return result
    }

    private func inodeOf(_ url: URL) -> UInt64 {
        var st = stat()
        if stat(url.path, &st) == 0 { return UInt64(st.st_ino) }
        return 0
    }

    private func processFile(_ file: FileInfo, force: Bool) async throws {
        let cached = await index.fileState(file.path)
        let isSubagent = file.path.contains("/subagents/")

        // SKIP: invariato (e non forzato).
        if !force, let cached,
           cached.size == file.size, cached.mtimeMs == file.mtimeMs, cached.inode == file.inode
        {
            return
        }

        // INCREMENTALE: cresciuto, stesso inode, offset valido.
        if !force, let cached,
           cached.inode == file.inode,
           file.size > cached.size,
           cached.parsedBytes > 0, cached.parsedBytes <= file.size
        {
            let (newEvents, newOffset) = try parse(file.url, from: cached.parsedBytes, isSubagent: isSubagent)
            let merged = Self.mergeInFile(existing: cached.events, delta: newEvents)
            await index.upsert(FileState(
                path: file.path, size: file.size, mtimeMs: file.mtimeMs, inode: file.inode,
                parsedBytes: newOffset, events: merged))
            return
        }

        // FULL PARSE da 0.
        let (events, offset) = try parse(file.url, from: 0, isSubagent: isSubagent)
        await index.upsert(FileState(
            path: file.path, size: file.size, mtimeMs: file.mtimeMs, inode: file.inode,
            parsedBytes: offset, events: events))
    }

    /// Parsa il file dall'offset, applicando prefiltro byte-level + dedup in-file.
    private func parse(_ url: URL, from offset: Int64, isSubagent: Bool) throws -> ([UsageEvent], Int64) {
        var keyed: [String: UsageEvent] = [:]
        var unkeyed: [UsageEvent] = []

        let newOffset = try JSONLParser.scan(fileURL: url, offset: offset) { line in
            guard !line.truncated, !line.bytes.isEmpty else { return }
            // Prefiltro: deve essere assistant con usage.
            guard line.bytes.containsASCII(#""type":"assistant""#),
                  line.bytes.containsASCII(#""usage""#)
            else { return }
            guard var event = TranscriptLine.decode(line.bytes) else { return }
            event.isSubagent = isSubagent

            if let key = event.dedupKey {
                // Chunk di streaming: l'ultimo (cumulativo) vince.
                keyed[key] = event
            } else {
                unkeyed.append(event)
            }
        }

        let events = keyed.keys.sorted().compactMap { keyed[$0] } + unkeyed
        return (events, newOffset)
    }

    // MARK: - Dedup

    /// Merge in-file di eventi esistenti + delta (incrementale): dedup `messageId:requestId`.
    static func mergeInFile(existing: [UsageEvent], delta: [UsageEvent]) -> [UsageEvent] {
        var keyed: [String: UsageEvent] = [:]
        var unkeyed: [UsageEvent] = []
        for e in existing + delta {
            if let key = e.dedupKey { keyed[key] = e } else { unkeyed.append(e) }
        }
        return keyed.keys.sorted().compactMap { keyed[$0] } + unkeyed
    }

    /// Dedup cross-file: per stesso `dedupKey`, vince il record subagent/sidechain
    /// (tie-break sul path). Gli eventi senza chiave sono tutti distinti.
    static func dedupCrossFile(states: [FileState]) -> [UsageEvent] {
        var winners: [String: (path: String, event: UsageEvent)] = [:]
        var unkeyed: [UsageEvent] = []

        for state in states.sorted(by: { $0.path < $1.path }) {
            for e in state.events {
                guard let key = e.dedupKey else { unkeyed.append(e); continue }
                if let current = winners[key] {
                    if rowWins(candidate: (state.path, e), over: current) {
                        winners[key] = (state.path, e)
                    }
                } else {
                    winners[key] = (state.path, e)
                }
            }
        }
        return winners.values.map(\.event) + unkeyed
    }

    /// Regola del vincitore cross-file (da CodexBar `claudeRowWins`).
    private static func rowWins(
        candidate: (path: String, event: UsageEvent),
        over existing: (path: String, event: UsageEvent)) -> Bool
    {
        if candidate.event.isSidechain != existing.event.isSidechain {
            return candidate.event.isSidechain
        }
        if candidate.event.isSubagent != existing.event.isSubagent {
            return candidate.event.isSubagent
        }
        return candidate.path < existing.path
    }
}
