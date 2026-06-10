import Foundation
import Testing
@testable import ClaudeBarCore

// Test dell'interning di stringhe nell'indice in memoria: il pool deve restituire
// valori canonici UGUALI (mai alterati) e l'indice deve restare comportamentalmente
// identico con o senza interning — stessi eventi, stesso roundtrip su disco.

@Suite("String interning (indice in memoria)")
struct StringInternerTests {
    @Test("intern restituisce valori uguali e non duplica il pool")
    func internCanonicalValues() {
        var interner = StringInterner()
        let a = interner.intern("claude-opus-4-8[1m]")
        let b = interner.intern("claude-opus-4-8[1m]")
        #expect(a == b)
        #expect(a == "claude-opus-4-8[1m]")
        #expect(interner.count == 1)

        _ = interner.intern("claude-sonnet-4-6")
        #expect(interner.count == 2)

        // Variante Optional: nil passa attraverso, i valori vengono internati.
        #expect(interner.intern(nil as String?) == nil)
        let c: String? = interner.intern("feature/branch" as String?)
        #expect(c == "feature/branch")
        #expect(interner.count == 3)
    }

    @Test("removeAll svuota il pool")
    func removeAllEmptiesPool() {
        var interner = StringInterner()
        _ = interner.intern("x")
        _ = interner.intern("y")
        #expect(interner.count == 2)
        interner.removeAll()
        #expect(interner.count == 0)
    }

    /// Evento con i campi ad alta duplicazione valorizzati (stringhe COSTRUITE a runtime,
    /// non literal: ogni chiamata produce buffer heap distinti, come il decode JSON reale).
    private func event(msg: String, input: Int) -> UsageEvent {
        UsageEvent(
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            dayKey: ["2026", "06", "10"].joined(separator: "-"),
            model: ["claude", "opus", "4-8"].joined(separator: "-"),
            rawModel: ["claude", "opus", "4-8"].joined(separator: "-") + "-20260115",
            projectPath: "/Users/x/" + "proj-A",
            sessionId: "sess_" + "condivisa",
            messageId: msg,
            requestId: "req_" + msg,
            gitBranch: "feature/" + "stessa",
            isSidechain: false,
            isSubagent: false,
            input: input,
            cacheRead: 0,
            cacheCreate1h: 0,
            cacheCreate5m: 0,
            output: 1)
    }

    @Test("Upsert con campi duplicati: gli eventi restano identici dopo l'interning")
    func upsertPreservesEvents() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clbar-intern-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let index = IncrementalIndex(dir: dir, pricingFingerprint: "test-fp")
        await index.load()

        let events = [event(msg: "m1", input: 100), event(msg: "m2", input: 200)]
        let state = FileState(
            path: "/tmp/proj-A/session.jsonl", size: 10, mtimeMs: 1, inode: 1,
            parsedBytes: 10, events: events)
        await index.upsert(state)

        let stored = await index.fileState("/tmp/proj-A/session.jsonl")
        // Uguaglianza comportamentale completa: l'interning non altera alcun campo.
        #expect(stored?.events == events)
    }

    @Test("Roundtrip save/load con interning: eventi e aggregati invariati")
    func saveLoadRoundtripWithInterning() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clbar-intern-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let index = IncrementalIndex(dir: dir, pricingFingerprint: "test-fp")
        await index.load()
        let e1 = [event(msg: "m1", input: 100)]
        let e2 = [event(msg: "m2", input: 200)]
        await index.upsert(FileState(
            path: "/tmp/proj-A/one.jsonl", size: 5, mtimeMs: 1, inode: 1,
            parsedBytes: 5, events: e1))
        await index.upsert(FileState(
            path: "/tmp/proj-A/two.jsonl", size: 5, mtimeMs: 1, inode: 2,
            parsedBytes: 5, events: e2))
        await index.save()

        // Nuova istanza: gli stati passano dall'entry point di load() (decode shard + intern).
        let reloaded = IncrementalIndex(dir: dir, pricingFingerprint: "test-fp")
        await reloaded.load()
        let states = await reloaded.snapshotAllStates()
        #expect(states.count == 2)
        let allEvents = states.flatMap(\.events).sorted { ($0.messageId ?? "") < ($1.messageId ?? "") }
        #expect(allEvents == e1 + e2)
        #expect(allEvents.reduce(0) { $0 + $1.input } == 300)
    }
}
