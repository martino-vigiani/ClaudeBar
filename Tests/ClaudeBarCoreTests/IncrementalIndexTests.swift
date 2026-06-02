import Foundation
import Testing
@testable import ClaudeBarCore

// Test end-to-end del parser INCREMENTALE (IMPL-E): il vantaggio competitivo del prodotto.
// Esercita TranscriptIndexer.refresh + IncrementalIndex + JSONLParser.scan(offset:) su file
// reali in una temp dir. Modella lo scenario REALE di Claude Code: i `.jsonl` crescono in
// APPEND-ONLY (nuove righe in coda), non vengono riscritti in-place. Verifica: ripresa da
// byteOffset, merge del delta senza doppio conteggio, dedup in-file last-wins, full re-parse
// su troncamento/rotazione, force, prune.

@Suite("Incremental index (offset/dedup end-to-end)")
struct IncrementalIndexTests {
    /// Sandbox temporanea con una root transcript e una dir indice separata.
    private struct Sandbox {
        let root: URL
        let indexDir: URL
        let projectDir: URL

        init() {
            // `resolvingSymlinksInPath` perché su macOS la temp dir è /var → /private/var:
            // l'enumeratore di FileManager restituisce il path risolto, e l'indice memorizza
            // gli stati per quel path. Allinearsi evita lookup falliti nei test.
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("clbar-test-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            root = base.appendingPathComponent("projects", isDirectory: true)
            indexDir = base.appendingPathComponent("index", isDirectory: true)
            projectDir = root.appendingPathComponent("proj-A", isDirectory: true)
            try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }

        func indexer() -> TranscriptIndexer {
            TranscriptIndexer(
                roots: [root],
                index: IncrementalIndex(dir: indexDir, pricingFingerprint: "test-fp"))
        }
    }

    /// Riga assistant valida con messageId/requestId distinti e token noti.
    private func assistantLine(msg: String, req: String, input: Int, output: Int) -> String {
        #"""
        {"type":"assistant","timestamp":"2026-05-30T10:00:00.000Z","cwd":"/Users/x/proj-A","requestId":"\#(req)","sessionId":"sess_1","message":{"id":"\#(msg)","model":"claude-opus-4-7","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":\#(output)}}}
        """#
    }

    /// Scrive righe terminate da newline (come fa Claude Code: ogni riga completa finisce con \n).
    private func write(_ lines: [String], to url: URL) throws {
        let text = lines.map { $0 + "\n" }.joined()
        try Data(text.utf8).write(to: url)
    }

    /// Append in coda di righe complete (scenario reale: il file cresce mentre la sessione gira).
    private func append(_ lines: [String], to url: URL) throws {
        let text = lines.map { $0 + "\n" }.joined()
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test("Primo refresh parsa tutto; secondo refresh riprende dall'offset e fonde il delta")
    func incrementalAppend() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let file = sb.projectDir.appendingPathComponent("session.jsonl")
        try write([
            assistantLine(msg: "msg_1", req: "req_1", input: 100, output: 10),
            assistantLine(msg: "msg_2", req: "req_2", input: 200, output: 20),
        ], to: file)

        let indexer = sb.indexer()
        let first = try await indexer.refresh()
        #expect(first.totals.input == 300)
        #expect(first.totals.output == 30)

        // Lo stato per-file è persistito col path risolto dall'enumeratore di FileManager
        // (la persistenza save/load roundtrippa: verificato separatamente). Qui ci interessa
        // il comportamento OSSERVABILE: che l'offset salvato faccia ripartire l'incrementale.
        let states = await indexer.debugFileStates()
        let state = states.first { $0.path.hasSuffix("session.jsonl") }
        let size = Int64((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1)
        #expect(state?.parsedBytes == size)   // offset == EOF: tutto il file è stato consumato.
        #expect(state?.events.count == 2)

        // Append di una terza riga in coda → il secondo refresh legge SOLO il delta e lo fonde.
        try append([assistantLine(msg: "msg_3", req: "req_3", input: 5, output: 1)], to: file)
        let second = try await indexer.refresh()
        #expect(second.totals.input == 305)   // 300 + 5: delta fuso, non duplicato.
        #expect(second.totals.output == 31)
    }

    @Test("Dedup in-file: stesso messageId:requestId → last-wins (chunk cumulativo)")
    func inFileDedupLastWins() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let file = sb.projectDir.appendingPathComponent("stream.jsonl")
        // Due chunk dello stesso messaggio (streaming): l'ultimo è cumulativo e vince.
        try write([
            assistantLine(msg: "msg_1", req: "req_1", input: 50, output: 5),
            assistantLine(msg: "msg_1", req: "req_1", input: 100, output: 30),
        ], to: file)

        let report = try await sb.indexer().refresh()
        #expect(report.totals.input == 100)   // non 150: stesso dedupKey, vince l'ultimo.
        #expect(report.totals.output == 30)
    }

    @Test("Dedup last-wins resiste anche se i chunk arrivano in refresh separati (append)")
    func dedupAcrossIncrementalRefreshes() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let file = sb.projectDir.appendingPathComponent("stream2.jsonl")
        try write([assistantLine(msg: "msg_1", req: "req_1", input: 50, output: 5)], to: file)
        let indexer = sb.indexer()
        let first = try await indexer.refresh()
        #expect(first.totals.input == 50)

        // Chunk cumulativo successivo (stesso messaggio) appeso in coda.
        try append([assistantLine(msg: "msg_1", req: "req_1", input: 100, output: 30)], to: file)
        let second = try await indexer.refresh()
        #expect(second.totals.input == 100)   // merge in-file: l'ultimo vince, non 150.
        #expect(second.totals.output == 30)
    }

    @Test("Troncamento del file (size in calo) → full re-parse da 0, niente doppio conteggio")
    func truncationTriggersFullReparse() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let file = sb.projectDir.appendingPathComponent("rotated.jsonl")
        try write([
            assistantLine(msg: "msg_1", req: "req_1", input: 100, output: 10),
            assistantLine(msg: "msg_2", req: "req_2", input: 200, output: 20),
        ], to: file)
        let indexer = sb.indexer()
        _ = try await indexer.refresh()

        // Il file viene sostituito con un contenuto PIÙ PICCOLO (size < parsedBytes) → re-parse da 0.
        try write([assistantLine(msg: "msg_9", req: "req_9", input: 7, output: 1)], to: file)
        let after = try await indexer.refresh()
        #expect(after.totals.input == 7)     // solo il nuovo contenuto, non 307.
        #expect(after.totals.output == 1)
    }

    @Test("force: true ignora la cache e riparsa da 0 con lo stesso risultato")
    func forceReparse() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let file = sb.projectDir.appendingPathComponent("s.jsonl")
        try write([assistantLine(msg: "msg_1", req: "req_1", input: 100, output: 10)], to: file)
        let indexer = sb.indexer()
        let a = try await indexer.refresh()
        let b = try await indexer.refresh(force: true)
        #expect(a.totals.input == b.totals.input)
        #expect(b.totals.input == 100)
    }

    @Test("Prune: un file sparito esce dal report al refresh successivo")
    func pruneRemovedFile() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let f1 = sb.projectDir.appendingPathComponent("one.jsonl")
        let f2 = sb.projectDir.appendingPathComponent("two.jsonl")
        try write([assistantLine(msg: "m1", req: "r1", input: 100, output: 1)], to: f1)
        try write([assistantLine(msg: "m2", req: "r2", input: 200, output: 2)], to: f2)
        let indexer = sb.indexer()
        let both = try await indexer.refresh()
        #expect(both.totals.input == 300)

        try FileManager.default.removeItem(at: f2)
        let pruned = try await indexer.refresh()
        #expect(pruned.totals.input == 100)
    }
}
