import Foundation

public struct RunSummary {
    public let run: RunRecord
    public var deleted: [DeletedItem] = []
    public var modified: [(path: String, before: VersionRecord)] = []
    public var created: [String] = []
    public var isClean: Bool { deleted.isEmpty && modified.isEmpty }
}

/// "Run anything, then undo what it did": the agent-era safety net.
/// `begin` takes a forced snapshot of everything, `end` reports what changed, `undo` puts it back.
extension Engine {
    public func beginRun(label: String, command: String) -> RunRecord {
        scan(force: true)
        return store.startRun(label: label, command: command, at: now())
    }

    public func endRun(_ run: RunRecord, status: Int) -> RunSummary {
        scan(force: true)
        store.finishRun(id: run.id, at: now(), status: status)
        return summary(for: store.run(id: run.id) ?? run)
    }

    public func summary(for run: RunRecord) -> RunSummary {
        var s = RunSummary(run: run)
        let t0 = run.startedAt.timeIntervalSince1970
        s.deleted = store.deleted(limit: 100_000, since: run.startedAt, minLifetime: 0)
            .filter { $0.file.firstSeen <= run.startedAt }
        let ids = (try? store.db.query("""
            SELECT f.id FROM files f
            WHERE f.deleted_at IS NULL AND f.first_seen<=?
              AND EXISTS (SELECT 1 FROM versions v WHERE v.file_id=f.id AND v.taken_at>?)
              AND EXISTS (SELECT 1 FROM versions v WHERE v.file_id=f.id AND v.taken_at<=?)
            """, [.real(t0), .real(t0), .real(t0)]) { $0.int(0) }) ?? []
        for id in ids {
            if let f = store.file(id: id), let before = store.version(fileID: id, asOf: run.startedAt) {
                s.modified.append((f.path, before))
            }
        }
        s.created = (try? store.db.query("SELECT path FROM files WHERE first_seen>? ORDER BY path", [.real(t0)]) { $0.text(0) }) ?? []
        return s
    }

    /// Restores everything the run deleted and puts modified files back as they were when it started.
    /// What the run wrote is kept as a version, so even the undo can be undone.
    @discardableResult
    public func undo(run: RunRecord) -> RestoreReport {
        let s = summary(for: run)
        for m in s.modified { snapshotNow(m.path) } // keep the run's version of each file
        let restorer = Restorer(store: store)
        let ids = s.deleted.map { $0.file.id } + s.modified.compactMap { store.file(atPath: $0.path)?.id }
        return restorer.restoreFiles(ids: ids, asOf: run.startedAt, prefix: nil, destination: nil, replaceChanged: true, now: now())
    }
}
