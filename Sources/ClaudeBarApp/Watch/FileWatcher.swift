import Foundation
import os

/// Osserva la radice `~/.claude/projects` per scritture/rotazioni di file `.jsonl` e notifica
/// l'indexer (02-app-architecture.md §6.3). Sta nell'APP LAYER e chiama l'indexer; l'indexer
/// non fa watching.
///
/// Strategia: `DispatchSource` (vnode) sulla directory radice + le sottocartelle di primo
/// livello, con DEBOUNCE (~2s) per coalizzare le scritture a raffica di una sessione attiva.
/// Fallback robusto: timer di polling mtime a bassa frequenza, rete di sicurezza per eventi
/// vnode persi (succede con alcune sync/editor). Il polling fa solo `stat()` → costo trascurabile.
@MainActor
final class FileWatcher {
    private let root: URL
    private let debounce: Duration
    private let onChange: @Sendable () async -> Void
    private let logger = Logger(subsystem: AppInfo.bundleIdentifier, category: "watch")

    private var sources: [DispatchSourceFileSystemObject] = []
    private var watchedFDs: [Int32] = []
    private var debounceTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastSeenSignature: String = ""

    init(
        root: URL,
        debounce: Duration = .seconds(2),
        onChange: @escaping @Sendable () async -> Void)
    {
        self.root = root
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        self.installVnodeSources()
        self.startPolling()
    }

    func stop() {
        self.debounceTask?.cancel()
        self.debounceTask = nil
        self.pollTask?.cancel()
        self.pollTask = nil
        for source in self.sources { source.cancel() }
        self.sources.removeAll()
        // I file descriptor sono chiusi nell'handler di cancellazione di ciascuna source.
        self.watchedFDs.removeAll()
    }

    // MARK: - vnode sources

    private func installVnodeSources() {
        let fm = FileManager.default
        // Radice + sottocartelle di primo livello (un progetto = una cartella).
        var dirs: [URL] = [self.root]
        if let entries = try? fm.contentsOfDirectory(
            at: self.root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        {
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { dirs.append(entry) }
            }
        }

        for dir in dirs {
            self.addVnodeSource(for: dir)
        }
    }

    private func addVnodeSource(for url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            self.logger.debug("vnode open fallita per \(url.path, privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .link],
            queue: .main)
        source.setEventHandler { [weak self] in
            self?.scheduleDebouncedChange()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.sources.append(source)
        self.watchedFDs.append(fd)
    }

    private func scheduleDebouncedChange() {
        self.debounceTask?.cancel()
        let debounce = self.debounce
        let onChange = self.onChange
        self.debounceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return // un nuovo evento ha annullato questo
            }
            if Task.isCancelled { return }
            await onChange()
        }
    }

    // MARK: - Polling fallback (mtime)

    private func startPolling() {
        self.pollTask?.cancel()
        self.lastSeenSignature = self.directorySignature()
        self.pollTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(45))
                } catch {
                    return
                }
                if Task.isCancelled { return }
                let signature = self.directorySignature()
                if signature != self.lastSeenSignature {
                    self.lastSeenSignature = signature
                    self.logger.debug("polling ha rilevato un cambiamento sfuggito al vnode")
                    self.scheduleDebouncedChange()
                }
            }
        }
    }

    /// Firma leggera: conteggio file + mtime più recente nella radice e sottocartelle (solo stat).
    private func directorySignature() -> String {
        let fm = FileManager.default
        var count = 0
        var newest: TimeInterval = 0
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]

        guard let enumerator = fm.enumerator(
            at: self.root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])
        else {
            return ""
        }
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            count += 1
            if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970
            {
                newest = max(newest, mtime)
            }
        }
        return "\(count):\(Int(newest))"
    }
}
