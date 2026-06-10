import Foundation

// Stato per-file dell'indice incrementale (il cuore del re-scan O(delta)).
// Persistito su disco in `<AppSupport>/index/`. Schema versionato per invalidazione.

/// Stato di un singolo file `.jsonl` nell'indice.
public struct FileState: Codable, Sendable, Equatable {
    public var path: String
    /// Ultima dimensione vista (byte).
    public var size: Int64
    /// Ultima data di modifica vista (ms epoch).
    public var mtimeMs: Int64
    /// Inode del file (rileva rotazione/ricreazione anche a parità di path).
    public var inode: UInt64
    /// Offset (byte) fino a cui abbiamo parsato — da qui riprende l'incrementale.
    public var parsedBytes: Int64
    /// Eventi estratti da questo file (per re-rollup e dedup cross-file).
    public var events: [UsageEvent]

    public init(path: String, size: Int64, mtimeMs: Int64, inode: UInt64, parsedBytes: Int64, events: [UsageEvent]) {
        self.path = path
        self.size = size
        self.mtimeMs = mtimeMs
        self.inode = inode
        self.parsedBytes = parsedBytes
        self.events = events
    }
}

/// Indice incrementale (actor): stato per-file + persistenza atomica.
/// Per contenere la dimensione con migliaia di eventi, persiste **split per-progetto**
/// (un file JSON per directory di primo livello sotto la root dei transcript).
public actor IncrementalIndex {
    /// Versione dello schema su disco; bump → invalida (full re-index).
    static let schemaVersion = 1

    private let dir: URL
    /// pricingFingerprint con cui sono stati calcolati gli eventi: se cambia → ricalcolo costi.
    private var pricingFingerprint: String
    private var states: [String: FileState] = [:]
    private var loaded = false
    /// Pool di interning per i campi ad alta duplicazione degli eventi residenti
    /// (model, projectPath, sessionId, …). Dentro l'isolamento dell'actor: niente lock.
    private var interner = StringInterner()

    public init(dir: URL = AppPaths.indexDir(), pricingFingerprint: String = PricingTable.fingerprint()) {
        self.dir = dir
        self.pricingFingerprint = pricingFingerprint
    }

    /// Carica l'indice da disco (una volta).
    public func load() {
        guard !loaded else { return }
        loaded = true
        AppPaths.ensureDirectory(dir)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        else { return }

        var anyPricingMismatch = false
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let shard = try? JSONDecoder().decode(IndexShard.self, from: data)
            else { continue }
            guard shard.schemaVersion == Self.schemaVersion else { continue }
            if shard.pricingFingerprint != pricingFingerprint { anyPricingMismatch = true }
            for state in shard.states {
                states[Self.canonicalKey(state.path)] = interned(state)
            }
        }
        // Se i prezzi sono cambiati, scartiamo gli eventi (verranno riparsati/ricalcolati).
        if anyPricingMismatch {
            states.removeAll()
            interner.removeAll()
        }
    }

    public func fileState(_ path: String) -> FileState? { states[Self.canonicalKey(path)] }

    public func upsert(_ state: FileState) { states[Self.canonicalKey(state.path)] = interned(state) }

    /// Rimuove dall'indice i file non più presenti sul disco.
    /// `touched` contiene i path enumerati; li canonicalizziamo per confrontarli con le chiavi.
    public func prune(touched: Set<String>) {
        let canonicalTouched = Set(touched.map { Self.canonicalKey($0) })
        for key in states.keys where !canonicalTouched.contains(key) {
            states.removeValue(forKey: key)
        }
    }

    /// Riscrive i campi ad alta duplicazione degli eventi attraverso il pool di interning,
    /// così tutte le occorrenze dello stesso valore condividono un solo buffer heap.
    /// `messageId`/`requestId` sono quasi-unici per evento: internarli gonfierebbe il pool
    /// senza condivisione, quindi restano fuori. Solo deduplicazione in memoria: l'encoding
    /// Codable delle String è identico, lo shard su disco non cambia.
    private func interned(_ state: FileState) -> FileState {
        var state = state
        for i in state.events.indices {
            state.events[i].dayKey = interner.intern(state.events[i].dayKey)
            state.events[i].model = interner.intern(state.events[i].model)
            state.events[i].rawModel = interner.intern(state.events[i].rawModel)
            state.events[i].projectPath = interner.intern(state.events[i].projectPath)
            state.events[i].sessionId = interner.intern(state.events[i].sessionId)
            state.events[i].gitBranch = interner.intern(state.events[i].gitBranch)
        }
        return state
    }

    /// Canonicalizza un path di file in una chiave stabile, indipendente dalla forma del
    /// symlink (es. `/var` vs `/private/var` su macOS): l'enumeratore di FileManager
    /// restituisce il path risolto mentre un chiamante esterno può passare quello non risolto.
    /// Senza questa normalizzazione lo stato per-file salvato non verrebbe ritrovato.
    static func canonicalKey(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Tutti gli eventi correnti (per il rollup cross-file con dedup).
    public func snapshotAllStates() -> [FileState] { Array(states.values) }

    /// Dimensione massima (eventi) di uno shard su disco. Un progetto molto attivo può
    /// superare i 100K eventi: encodare/decodare quel singolo JSON (>50MB) costa centinaia
    /// di MB di picco RSS transient. Spezzare in chunk tiene il picco piatto; `load()` legge
    /// tutti i `.json` indipendentemente dal nome, quindi il formato shard non cambia.
    static let maxEventsPerShard = 4000

    /// Salva l'indice su disco, split per-progetto (+ chunk se il progetto è grande).
    public func save() {
        AppPaths.ensureDirectory(dir)
        // Raggruppa gli stati per "shard key" (segmento progetto dal path), poi spezza
        // i gruppi grandi in chunk deterministici (ordinati per path) sotto il cap eventi.
        var grouped: [String: [FileState]] = [:]
        for state in states.values {
            grouped[Self.shardKey(for: state.path), default: []].append(state)
        }
        var shards: [String: [FileState]] = [:]
        for (key, group) in grouped {
            var chunkIndex = 0
            var chunk: [FileState] = []
            var chunkEvents = 0
            for state in group.sorted(by: { $0.path < $1.path }) {
                if !chunk.isEmpty, chunkEvents + state.events.count > Self.maxEventsPerShard {
                    shards["\(key)-\(chunkIndex)"] = chunk
                    chunkIndex += 1
                    chunk = []
                    chunkEvents = 0
                }
                chunk.append(state)
                chunkEvents += state.events.count
            }
            if !chunk.isEmpty { shards["\(key)-\(chunkIndex)"] = chunk }
        }
        // Riscrivi gli shard correnti.
        let valid = Set(shards.keys.map { "\($0).json" })
        for (key, group) in shards {
            let shard = IndexShard(
                schemaVersion: Self.schemaVersion,
                pricingFingerprint: pricingFingerprint,
                states: group)
            let url = dir.appendingPathComponent("\(key).json", isDirectory: false)
            writeAtomic(shard, to: url)
        }
        // Rimuovi gli shard JSON orfani (progetti spariti).
        if let existing = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in existing where file.pathExtension == "json" && !valid.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Azzera l'indice: svuota lo stato in memoria e rimuove i file shard JSON dal disco.
    /// Usata da "Azzera cache indice" (sezione Avanzato). Dopo il clear, un `refresh(force:)`
    /// ricostruisce tutto da zero. `loaded` resta `true`: lo stato corrente (vuoto) è autorevole.
    public func clear() {
        states.removeAll()
        interner.removeAll()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func writeAtomic(_ shard: IndexShard, to url: URL) {
        guard let data = try? JSONEncoder().encode(shard) else { return }
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// Deriva una chiave shard stabile e safe-for-filename dal path del file.
    /// Usa la directory contenitore (cartella progetto encoded) con hash **deterministico**
    /// (FNV-1a): `Swift.Hasher` usa un seed casuale per-processo e darebbe shard orfani ad
    /// ogni avvio.
    private static func shardKey(for path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let folder = (dir as NSString).lastPathComponent
        return fnv1a(folder)
    }

    /// FNV-1a 64-bit deterministico.
    private static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }

    private struct IndexShard: Codable {
        let schemaVersion: Int
        let pricingFingerprint: String
        let states: [FileState]
    }
}
