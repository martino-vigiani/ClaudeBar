import Foundation
import Testing
@testable import ClaudeBarCore

// Test delle operazioni di manutenzione esposte alla sezione "Avanzato" delle Impostazioni:
// `MaintenanceService` (rebuild / clear+rebuild / lettura report) e i `clear()` aggiunti a
// `IncrementalIndex` e `PersistenceService`. Tutto su sandbox temporanee: niente effetti sui dati
// reali dell'utente.

@Suite("Maintenance service (rebuild/clear cache)")
struct MaintenanceServiceTests {
    /// Sandbox con una root transcript, una dir indice e un file cache dedicati.
    private struct Sandbox {
        let base: URL
        let root: URL
        let indexDir: URL
        let cacheURL: URL
        let projectDir: URL

        init() {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("clbar-maint-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            root = base.appendingPathComponent("projects", isDirectory: true)
            indexDir = base.appendingPathComponent("index", isDirectory: true)
            cacheURL = base.appendingPathComponent("analytics-cache.json", isDirectory: false)
            projectDir = root.appendingPathComponent("proj-A", isDirectory: true)
            try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: base)
        }

        func index() -> IncrementalIndex {
            IncrementalIndex(dir: indexDir, pricingFingerprint: "test-fp")
        }

        func persistence() -> PersistenceService {
            PersistenceService(url: cacheURL)
        }

        func maintenance(index: IncrementalIndex, persistence: PersistenceService) -> MaintenanceService {
            MaintenanceService(roots: [root], index: index, persistence: persistence)
        }
    }

    private func assistantLine(msg: String, req: String, input: Int, output: Int) -> String {
        #"""
        {"type":"assistant","timestamp":"2026-05-30T10:00:00.000Z","cwd":"/Users/x/proj-A","requestId":"\#(req)","sessionId":"sess_1","message":{"id":"\#(msg)","model":"claude-opus-4-7","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":\#(output)}}}
        """#
    }

    private func write(_ lines: [String], to url: URL) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
    }

    @Test("rebuildIndex produce il report e salva la cache su disco")
    func rebuildIndexBuildsAndPersists() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let file = sb.projectDir.appendingPathComponent("s.jsonl")
        try write([assistantLine(msg: "m1", req: "r1", input: 100, output: 10)], to: file)

        let persistence = sb.persistence()
        let maintenance = sb.maintenance(index: sb.index(), persistence: persistence)
        let report = try await maintenance.rebuildIndex()

        #expect(report.totals.input == 100)
        #expect(report.totals.output == 10)
        // La cache su disco è stata scritta: una nuova PersistenceService la rilegge.
        let reloaded = await sb.persistence().loadReport(pricingFingerprint: PricingTable.fingerprint())
        #expect(reloaded?.totals.input == 100)
    }

    @Test("clearCache svuota indice e cache; clearAndRebuild ricostruisce da zero")
    func clearAndRebuild() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let file = sb.projectDir.appendingPathComponent("s.jsonl")
        try write([assistantLine(msg: "m1", req: "r1", input: 100, output: 10)], to: file)

        let index = sb.index()
        let persistence = sb.persistence()
        let maintenance = sb.maintenance(index: index, persistence: persistence)

        _ = try await maintenance.rebuildIndex()
        // Dopo il rebuild: shard JSON presenti e cache presente.
        #expect(try shardCount(sb.indexDir) > 0)
        #expect(FileManager.default.fileExists(atPath: sb.cacheURL.path))

        await maintenance.clearCache()
        #expect(try shardCount(sb.indexDir) == 0)
        #expect(!FileManager.default.fileExists(atPath: sb.cacheURL.path))

        // clearAndRebuild su una NUOVA istanza ricostruisce lo stesso totale dai transcript.
        let index2 = sb.index()
        let maintenance2 = sb.maintenance(index: index2, persistence: sb.persistence())
        let rebuilt = try await maintenance2.clearAndRebuild()
        #expect(rebuilt.totals.input == 100)
    }

    @Test("rebuildIndex con includeSubagents:false esclude le sessioni subagent")
    func rebuildExcludesSubagents() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        // File "main" e file dentro /subagents/ → quest'ultimo è marcato isSubagent dall'indexer.
        let main = sb.projectDir.appendingPathComponent("main.jsonl")
        let subDir = sb.projectDir.appendingPathComponent("subagents", isDirectory: true)
        try? FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let sub = subDir.appendingPathComponent("agent.jsonl")
        try write([assistantLine(msg: "m1", req: "r1", input: 100, output: 10)], to: main)
        try write([assistantLine(msg: "m2", req: "r2", input: 999, output: 99)], to: sub)

        // Con subagent inclusi: 100 + 999.
        let withSub = try await sb.maintenance(index: sb.index(), persistence: sb.persistence())
            .rebuildIndex(includeSubagents: true)
        #expect(withSub.totals.input == 1099)

        // Senza subagent: solo il main (100).
        let withoutSub = try await sb.maintenance(index: sb.index(), persistence: sb.persistence())
            .rebuildIndex(includeSubagents: false)
        #expect(withoutSub.totals.input == 100)
    }

    @Test("currentReport ritorna nil senza cache, il report dopo rebuild")
    func currentReport() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let file = sb.projectDir.appendingPathComponent("s.jsonl")
        try write([assistantLine(msg: "m1", req: "r1", input: 42, output: 7)], to: file)

        let persistence = sb.persistence()
        let maintenance = sb.maintenance(index: sb.index(), persistence: persistence)

        #expect(await maintenance.currentReport() == nil)
        _ = try await maintenance.rebuildIndex()
        #expect(await maintenance.currentReport()?.totals.input == 42)
    }

    @Test("IncrementalIndex.clear rimuove gli shard e svuota lo stato")
    func incrementalIndexClear() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let index = sb.index()
        await index.load()
        await index.upsert(FileState(
            path: sb.projectDir.appendingPathComponent("x.jsonl").path,
            size: 1, mtimeMs: 1, inode: 1, parsedBytes: 1, events: []))
        await index.save()
        #expect(try shardCount(sb.indexDir) > 0)

        await index.clear()
        #expect(try shardCount(sb.indexDir) == 0)
        #expect(await index.snapshotAllStates().isEmpty)
    }

    @Test("PersistenceService.clear rimuove il file cache (no-op se assente)")
    func persistenceClear() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let persistence = sb.persistence()
        // No-op senza file: non deve lanciare.
        await persistence.clear()
        #expect(!FileManager.default.fileExists(atPath: sb.cacheURL.path))

        await persistence.saveReport(.empty(), pricingFingerprint: "fp")
        #expect(FileManager.default.fileExists(atPath: sb.cacheURL.path))
        await persistence.clear()
        #expect(!FileManager.default.fileExists(atPath: sb.cacheURL.path))
    }

    /// Conta i file shard `.json` nella dir indice (esclude eventuali tmp).
    private func shardCount(_ dir: URL) throws -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".tmp") }.count
    }
}
