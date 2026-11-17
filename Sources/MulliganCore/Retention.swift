import Foundation

public enum PruneReason { case startup, periodic, manual }

public struct PruneReport: Equatable {
    public var versionsRemoved = 0
    public var filesPurged = 0
    /// Logical size of what was released; real disk returned can be smaller where blocks were shared.
    public var bytesReleased: Int64 = 0
    public var orphansRemoved = 0
    public init() {}
}

/// Keeps the vault honest: bounded in age, in count and in disk used, and it gives space back
/// automatically when the disk runs low.
struct Retention {
    let store: Store
    let paths: Paths
    let config: Config
    let now: () -> Date
    let freeSpace: (String) -> Int64

    func budgetBytes() -> Int64 {
        if config.budgetGB > 0 { return Int64(config.budgetGB * 1_000_000_000) }
        let total = Fs.totalBytes(at: paths.vault.path)
        return min(50_000_000_000, total / 10)
    }

    func run(_ reason: PruneReason) -> PruneReport {
        var rep = PruneReport()
        let t = now()
        purgeExpiredDeleted(t, &rep)
        thinHistory(t, &rep)
        let budget = budgetBytes()
        let held = store.heldBytes()
        if held > budget { releaseOldest(bytes: held - Int64(Double(budget) * 0.9), &rep) }
        let low = Int64(config.lowDiskFreeGB * 1_000_000_000)
        let free = freeSpace(paths.vault.path)
        if free < low { releaseOldest(bytes: (low - free) + low / 10, &rep) }
        if reason == .startup { cleanOrphans(&rep) }
        return rep
    }

    private func unlinkBlobs(_ names: [String]) {
        for n in names { unlink(paths.blobs.appendingPathComponent(n).path) }
    }

    private func purgeExpiredDeleted(_ t: Date, _ rep: inout PruneReport) {
        let cutoff = t.addingTimeInterval(-Double(config.keepDeletedDays) * 86400).timeIntervalSince1970
        let ids = (try? store.db.query("SELECT id FROM files WHERE deleted_at IS NOT NULL AND deleted_at<?", [.real(cutoff)]) { $0.int(0) }) ?? []
        for id in ids {
            let size = store.db.scalarInt("SELECT COALESCE(SUM(size),0) FROM versions WHERE file_id=?", [.int(id)])
            let n = Int(store.db.scalarInt("SELECT COUNT(*) FROM versions WHERE file_id=?", [.int(id)]))
            unlinkBlobs(store.deleteFile(id: id))
            rep.filesPurged += 1; rep.versionsRemoved += n; rep.bytesReleased += size
        }
    }

    /// Everything for 24 h, then one version per hour for a week, then one per day, then only the newest.
    private func thinHistory(_ t: Date, _ rep: inout PruneReport) {
        let fileIDs = (try? store.db.query("SELECT file_id FROM versions GROUP BY file_id HAVING COUNT(*)>1") { $0.int(0) }) ?? []
        let maxAge = Double(config.keepHistoryDays) * 86400
        let rules = Rules(config: config)
        for fid in fileIDs {
            let vs = store.versions(fileID: fid) // newest first
            guard let newest = vs.first else { continue }
            var keep: Set<Int64> = [newest.id]
            var buckets = Set<String>()
            for v in vs.dropFirst() {
                let age = t.timeIntervalSince(v.takenAt)
                if age > maxAge { continue }
                if age <= 86400 { keep.insert(v.id); continue }
                let key = age <= 7 * 86400 ? "h\(Int(v.takenAt.timeIntervalSince1970 / 3600))" : "d\(Int(v.takenAt.timeIntervalSince1970 / 86400))"
                if buckets.insert(key).inserted { keep.insert(v.id) }
            }
            // per-file cap (big files keep fewer versions)
            let cap = rules.maxVersions(size: newest.size)
            var kept = 0
            var finalKeep = Set<Int64>()
            for v in vs where keep.contains(v.id) {
                if kept < cap { finalKeep.insert(v.id); kept += 1 }
            }
            let drop = vs.filter { !finalKeep.contains($0.id) }
            guard !drop.isEmpty else { continue }
            unlinkBlobs(store.deleteVersions(ids: drop.map { $0.id }))
            rep.versionsRemoved += drop.count
            rep.bytesReleased += drop.reduce(0) { $0 + $1.size }
        }
    }

    /// Oldest history of files that still exist goes first, then the oldest deleted files.
    private func releaseOldest(bytes needed: Int64, _ rep: inout PruneReport) {
        var freed: Int64 = 0
        while freed < needed {
            let rows = (try? store.db.query("""
                SELECT v.id, v.size FROM versions v JOIN files f ON f.id=v.file_id
                WHERE f.deleted_at IS NULL AND f.latest_version_id<>v.id ORDER BY v.taken_at ASC LIMIT 200
                """) { (id: $0.int(0), size: $0.int(1)) }) ?? []
            if rows.isEmpty { break }
            var ids: [Int64] = []
            for r in rows { ids.append(r.id); freed += r.size; if freed >= needed { break } }
            unlinkBlobs(store.deleteVersions(ids: ids))
            rep.versionsRemoved += ids.count
            rep.bytesReleased += ids.reduce(Int64(0)) { acc, id in acc + (rows.first { $0.id == id }?.size ?? 0) }
        }
        while freed < needed {
            let files = (try? store.db.query("SELECT id FROM files WHERE deleted_at IS NOT NULL ORDER BY deleted_at ASC LIMIT 50") { $0.int(0) }) ?? []
            if files.isEmpty { break }
            for id in files {
                let size = store.db.scalarInt("SELECT COALESCE(SUM(size),0) FROM versions WHERE file_id=?", [.int(id)])
                let n = Int(store.db.scalarInt("SELECT COUNT(*) FROM versions WHERE file_id=?", [.int(id)]))
                unlinkBlobs(store.deleteFile(id: id))
                freed += size
                rep.filesPurged += 1; rep.versionsRemoved += n; rep.bytesReleased += size
                if freed >= needed { break }
            }
        }
    }

    /// Crash recovery: blobs nobody points to, and index rows whose blob has gone.
    private func cleanOrphans(_ rep: inout PruneReport) {
        let fm = FileManager.default
        let known = store.allBlobNames()
        if let shards = try? fm.contentsOfDirectory(atPath: paths.blobs.path) {
            for s in shards {
                let dir = paths.blobs.appendingPathComponent(s).path
                guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for n in names where !known.contains(s + "/" + n) {
                    unlink(dir + "/" + n)
                    rep.orphansRemoved += 1
                }
            }
        }
        let rows = (try? store.db.query("SELECT id, blob FROM versions") { (id: $0.int(0), blob: $0.text(1)) }) ?? []
        let broken = rows.filter { Fs.lstat(paths.blobs.appendingPathComponent($0.blob).path) == nil }.map { $0.id }
        if !broken.isEmpty {
            _ = store.deleteVersions(ids: broken)
            rep.orphansRemoved += broken.count
        }
    }
}
