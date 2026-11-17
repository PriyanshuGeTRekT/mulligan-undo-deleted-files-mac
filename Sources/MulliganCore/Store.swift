import Foundation

public struct FileRecord: Hashable {
    public let id: Int64
    public let path: String
    public let root: String
    public let firstSeen: Date
    public let deletedAt: Date?
    /// 0 = removed, 1 = moved out of the watched folders (for example into the Trash)
    public let deletedKind: Int
    public let inode: UInt64
    public let latestVersionID: Int64?
    public var name: String { Fs.lastComponent(path) }
    public var folder: String { (path as NSString).deletingLastPathComponent }
}

public struct VersionRecord: Hashable {
    public let id: Int64
    public let fileID: Int64
    public let path: String
    public let takenAt: Date
    public let size: Int64
    public let mtimeNs: Int64
    public let blob: String
    public let isClone: Bool
    public let mode: Int
    public var name: String { Fs.lastComponent(path) }
}

public struct DeletedItem: Hashable {
    public let file: FileRecord
    public let latest: VersionRecord
    public var deletedAt: Date { file.deletedAt ?? latest.takenAt }
}

public struct AlertRecord: Hashable {
    public let id: Int64
    public let at: Date
    public let kind: String
    public let root: String
    public var count: Int
    public let detail: String
    public let handled: Bool
}

public struct RunRecord: Hashable {
    public let id: Int64
    public let label: String
    public let command: String
    public let startedAt: Date
    public let endedAt: Date?
    public let status: Int
}

public struct StoreStats {
    public var liveFiles = 0
    public var deletedFiles = 0
    public var versions = 0
    public var logicalBytes: Int64 = 0
    /// Disk that would come back if every old version and deleted file were released.
    public var heldBytes: Int64 = 0
    public init() {}
}

public final class Store {
    public let paths: Paths
    public let db: SQLiteDB

    public init(paths: Paths) throws {
        self.paths = paths
        try paths.ensureDirectories()
        db = try SQLiteDB(path: paths.db.path)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS files(
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            root TEXT NOT NULL,
            first_seen REAL NOT NULL,
            deleted_at REAL,
            deleted_kind INTEGER NOT NULL DEFAULT 0,
            inode INTEGER NOT NULL DEFAULT 0,
            latest_version_id INTEGER
        );
        CREATE INDEX IF NOT EXISTS files_deleted ON files(deleted_at);
        CREATE INDEX IF NOT EXISTS files_inode ON files(inode);
        CREATE INDEX IF NOT EXISTS files_root ON files(root);
        CREATE TABLE IF NOT EXISTS versions(
            id INTEGER PRIMARY KEY,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            taken_at REAL NOT NULL,
            size INTEGER NOT NULL,
            mtime_ns INTEGER NOT NULL,
            blob TEXT NOT NULL,
            is_clone INTEGER NOT NULL,
            mode INTEGER NOT NULL DEFAULT 420
        );
        CREATE INDEX IF NOT EXISTS versions_file ON versions(file_id, taken_at);
        CREATE TABLE IF NOT EXISTS alerts(
            id INTEGER PRIMARY KEY, at REAL NOT NULL, kind TEXT NOT NULL, root TEXT NOT NULL,
            count INTEGER NOT NULL, detail TEXT NOT NULL DEFAULT '', handled INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS runs(
            id INTEGER PRIMARY KEY, label TEXT NOT NULL, command TEXT NOT NULL,
            started_at REAL NOT NULL, ended_at REAL, status INTEGER
        );
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)
    }

    // MARK: - Row mapping

    static let fileCols = "f.id, f.path, f.root, f.first_seen, f.deleted_at, f.deleted_kind, f.inode, f.latest_version_id"
    static let versionCols = "v.id, v.file_id, f.path, v.taken_at, v.size, v.mtime_ns, v.blob, v.is_clone, v.mode"

    static func file(_ r: Row, at o: Int32 = 0) -> FileRecord {
        FileRecord(id: r.int(o), path: r.text(o + 1), root: r.text(o + 2),
                   firstSeen: Date(timeIntervalSince1970: r.real(o + 3)),
                   deletedAt: r.isNull(o + 4) ? nil : Date(timeIntervalSince1970: r.real(o + 4)),
                   deletedKind: Int(r.int(o + 5)),
                   inode: UInt64(bitPattern: r.int(o + 6)),
                   latestVersionID: r.isNull(o + 7) ? nil : r.int(o + 7))
    }

    static func version(_ r: Row, at o: Int32 = 0) -> VersionRecord {
        VersionRecord(id: r.int(o), fileID: r.int(o + 1), path: r.text(o + 2),
                      takenAt: Date(timeIntervalSince1970: r.real(o + 3)),
                      size: r.int(o + 4), mtimeNs: r.int(o + 5), blob: r.text(o + 6),
                      isClone: r.int(o + 7) != 0, mode: Int(r.int(o + 8)))
    }

    // MARK: - Files

    public func file(atPath p: String) -> FileRecord? {
        (try? db.query("SELECT \(Store.fileCols) FROM files f WHERE f.path=?", [.text(p)]) { Store.file($0) })?.first
    }

    public func file(id: Int64) -> FileRecord? {
        (try? db.query("SELECT \(Store.fileCols) FROM files f WHERE f.id=?", [.int(id)]) { Store.file($0) })?.first
    }

    @discardableResult
    public func insertFile(path: String, root: String, inode: UInt64, now: Date) -> FileRecord {
        _ = try? db.run("INSERT OR IGNORE INTO files(path, root, first_seen, inode) VALUES(?,?,?,?)",
                        [.text(path), .text(root), .real(now.timeIntervalSince1970), .int(Int64(bitPattern: inode))])
        return file(atPath: path)!
    }

    /// Same file, new path (a rename inside the watched folders): the history travels with it.
    public func relocate(fileID: Int64, path: String, root: String, inode: UInt64) {
        _ = try? db.run("UPDATE files SET path=?, root=?, inode=?, deleted_at=NULL, deleted_kind=0 WHERE id=?",
                        [.text(path), .text(root), .int(Int64(bitPattern: inode)), .int(fileID)])
    }

    public func setInode(_ fileID: Int64, _ inode: UInt64) {
        _ = try? db.run("UPDATE files SET inode=? WHERE id=?", [.int(Int64(bitPattern: inode)), .int(fileID)])
    }

    public func renameCandidates(inode: UInt64, notPath: String, deletedAfter: Date) -> [FileRecord] {
        (try? db.query("""
            SELECT \(Store.fileCols) FROM files f
            WHERE f.inode=? AND f.path<>? AND (f.deleted_at IS NULL OR f.deleted_at>?)
            """, [.int(Int64(bitPattern: inode)), .text(notPath), .real(deletedAfter.timeIntervalSince1970)]) { Store.file($0) }) ?? []
    }

    public func undelete(fileID: Int64) {
        _ = try? db.run("UPDATE files SET deleted_at=NULL, deleted_kind=0 WHERE id=?", [.int(fileID)])
    }

    static func prefixRange(_ p: String) -> (String, String) {
        let base = p.hasSuffix("/") ? String(p.dropLast()) : p
        return (base + "/", base + "0") // '0' sorts right after '/'
    }

    public func liveFiles(underPrefix p: String) -> [(id: Int64, path: String)] {
        let (lo, hi) = Store.prefixRange(p)
        return (try? db.query("SELECT id, path FROM files WHERE deleted_at IS NULL AND path>=? AND path<?",
                              [.text(lo), .text(hi)]) { (id: $0.int(0), path: $0.text(1)) }) ?? []
    }

    /// Marks a file, or everything beneath a directory path, as deleted. Returns the records that changed.
    @discardableResult
    public func markDeleted(path p: String, at: Date, kind: Int) -> [FileRecord] {
        let (lo, hi) = Store.prefixRange(p)
        let hits: [FileRecord] = (try? db.query("""
            SELECT \(Store.fileCols) FROM files f
            WHERE f.deleted_at IS NULL AND (f.path=? OR (f.path>=? AND f.path<?))
            """, [.text(p), .text(lo), .text(hi)]) { Store.file($0) }) ?? []
        guard !hits.isEmpty else { return [] }
        _ = try? db.transaction {
            for h in hits {
                try db.run("UPDATE files SET deleted_at=?, deleted_kind=? WHERE id=?",
                           [.real(at.timeIntervalSince1970), .int(Int64(kind)), .int(h.id)])
            }
        }
        return hits
    }

    @discardableResult
    public func markDeleted(ids: [Int64], at: Date, kind: Int) -> [FileRecord] {
        var out: [FileRecord] = []
        _ = try? db.transaction {
            for id in ids {
                if let f = file(id: id), f.deletedAt == nil {
                    try db.run("UPDATE files SET deleted_at=?, deleted_kind=? WHERE id=?",
                               [.real(at.timeIntervalSince1970), .int(Int64(kind)), .int(id)])
                    out.append(f)
                }
            }
        }
        return out
    }

    // MARK: - Versions

    public func latestVersion(fileID: Int64) -> VersionRecord? {
        (try? db.query("""
            SELECT \(Store.versionCols) FROM versions v JOIN files f ON f.id=v.file_id
            WHERE v.file_id=? ORDER BY v.taken_at DESC, v.id DESC LIMIT 1
            """, [.int(fileID)]) { Store.version($0) })?.first
    }

    @discardableResult
    public func addVersion(fileID: Int64, takenAt: Date, size: Int64, mtimeNs: Int64,
                           blob: String, isClone: Bool, mode: Int) -> Int64 {
        var id: Int64 = 0
        _ = try? db.transaction {
            try db.run("INSERT INTO versions(file_id, taken_at, size, mtime_ns, blob, is_clone, mode) VALUES(?,?,?,?,?,?,?)",
                       [.int(fileID), .real(takenAt.timeIntervalSince1970), .int(size), .int(mtimeNs),
                        .text(blob), .int(isClone ? 1 : 0), .int(Int64(mode))])
            id = db.lastInsertID
            try db.run("UPDATE files SET latest_version_id=? WHERE id=?", [.int(id), .int(fileID)])
        }
        return id
    }

    public func version(id: Int64) -> VersionRecord? {
        (try? db.query("SELECT \(Store.versionCols) FROM versions v JOIN files f ON f.id=v.file_id WHERE v.id=?",
                       [.int(id)]) { Store.version($0) })?.first
    }

    /// Newest first.
    public func versions(fileID: Int64) -> [VersionRecord] {
        (try? db.query("""
            SELECT \(Store.versionCols) FROM versions v JOIN files f ON f.id=v.file_id
            WHERE v.file_id=? ORDER BY v.taken_at DESC, v.id DESC
            """, [.int(fileID)]) { Store.version($0) }) ?? []
    }

    public func versions(forPath p: String) -> [VersionRecord] {
        guard let f = file(atPath: p) else { return [] }
        return versions(fileID: f.id)
    }

    public func version(fileID: Int64, asOf: Date) -> VersionRecord? {
        (try? db.query("""
            SELECT \(Store.versionCols) FROM versions v JOIN files f ON f.id=v.file_id
            WHERE v.file_id=? AND v.taken_at<=? ORDER BY v.taken_at DESC, v.id DESC LIMIT 1
            """, [.int(fileID), .real(asOf.timeIntervalSince1970)]) { Store.version($0) })?.first
    }

    /// Removes version rows and returns their blob names so the caller can unlink them.
    public func deleteVersions(ids: [Int64]) -> [String] {
        var blobs: [String] = []
        var touched = Set<Int64>()
        _ = try? db.transaction {
            for id in ids {
                if let v = version(id: id) {
                    blobs.append(v.blob)
                    touched.insert(v.fileID)
                    try db.run("DELETE FROM versions WHERE id=?", [.int(id)])
                }
            }
            for fid in touched {
                let latest = latestVersion(fileID: fid)?.id
                try db.run("UPDATE files SET latest_version_id=? WHERE id=?",
                           [latest.map { .int($0) } ?? .null, .int(fid)])
            }
        }
        return blobs
    }

    /// Removes a file and every version of it. Returns blob names to unlink.
    public func deleteFile(id: Int64) -> [String] {
        let blobs = (try? db.query("SELECT blob FROM versions WHERE file_id=?", [.int(id)]) { $0.text(0) }) ?? []
        _ = try? db.run("DELETE FROM files WHERE id=?", [.int(id)])
        return blobs
    }

    public func allBlobNames() -> Set<String> {
        Set((try? db.query("SELECT blob FROM versions", []) { $0.text(0) }) ?? [])
    }

    // MARK: - Queries for UI and CLI

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    /// Recently deleted files, newest first. Files that lived for less than `minLifetime` seconds
    /// (editor temp files and the like) are left out of the list; they stay in the vault until retention removes them.
    public func deleted(limit: Int = 200, since: Date? = nil, matching: String? = nil, kind: Int? = nil,
                        minLifetime: TimeInterval = 5) -> [DeletedItem] {
        var sql = """
            SELECT \(Store.fileCols), \(Store.versionCols)
            FROM files f JOIN versions v ON v.id=f.latest_version_id
            WHERE f.deleted_at IS NOT NULL AND (f.deleted_at - f.first_seen) >= ?
            """
        var binds: [Bind] = [.real(minLifetime)]
        if let since = since { sql += " AND f.deleted_at>=?"; binds.append(.real(since.timeIntervalSince1970)) }
        if let m = matching, !m.isEmpty { sql += " AND f.path LIKE ? ESCAPE '\\'"; binds.append(.text("%" + Store.escapeLike(m) + "%")) }
        if let k = kind { sql += " AND f.deleted_kind=?"; binds.append(.int(Int64(k))) }
        sql += " ORDER BY f.deleted_at DESC LIMIT ?"
        binds.append(.int(Int64(limit)))
        return (try? db.query(sql, binds) { DeletedItem(file: Store.file($0, at: 0), latest: Store.version($0, at: 8)) }) ?? []
    }

    /// Live and deleted files whose path contains `query`.
    public func search(_ query: String, limit: Int = 100) -> [DeletedItem] {
        let sql = """
            SELECT \(Store.fileCols), \(Store.versionCols)
            FROM files f JOIN versions v ON v.id=f.latest_version_id
            WHERE f.path LIKE ? ESCAPE '\\' ORDER BY (f.deleted_at IS NULL), f.deleted_at DESC, f.path LIMIT ?
            """
        return (try? db.query(sql, [.text("%" + Store.escapeLike(query) + "%"), .int(Int64(limit))]) {
            DeletedItem(file: Store.file($0, at: 0), latest: Store.version($0, at: 8))
        }) ?? []
    }

    public func stats() -> StoreStats {
        var s = StoreStats()
        s.liveFiles = Int(db.scalarInt("SELECT COUNT(*) FROM files WHERE deleted_at IS NULL"))
        s.deletedFiles = Int(db.scalarInt("SELECT COUNT(*) FROM files WHERE deleted_at IS NOT NULL"))
        s.versions = Int(db.scalarInt("SELECT COUNT(*) FROM versions"))
        s.logicalBytes = db.scalarInt("SELECT COALESCE(SUM(size),0) FROM versions")
        s.heldBytes = heldBytes()
        return s
    }

    /// Clones share disk blocks with the live file. Only versions that differ from the live content
    /// (older edits and deleted files) occupy extra space, and real copies always do.
    public func heldBytes() -> Int64 {
        let total = db.scalarInt("SELECT COALESCE(SUM(size),0) FROM versions")
        let shared = db.scalarInt("""
            SELECT COALESCE(SUM(v.size),0) FROM versions v JOIN files f ON f.latest_version_id=v.id
            WHERE f.deleted_at IS NULL AND v.is_clone=1
            """)
        return max(0, total - shared)
    }

    // MARK: - Alerts

    @discardableResult
    public func addAlert(at: Date, kind: String, root: String, count: Int, detail: String) -> AlertRecord {
        _ = try? db.run("INSERT INTO alerts(at, kind, root, count, detail) VALUES(?,?,?,?,?)",
                        [.real(at.timeIntervalSince1970), .text(kind), .text(root), .int(Int64(count)), .text(detail)])
        let id = db.lastInsertID
        return AlertRecord(id: id, at: at, kind: kind, root: root, count: count, detail: detail, handled: false)
    }

    public func updateAlert(id: Int64, count: Int, detail: String) {
        _ = try? db.run("UPDATE alerts SET count=?, detail=? WHERE id=?", [.int(Int64(count)), .text(detail), .int(id)])
    }

    public func alerts(limit: Int = 20, unhandledOnly: Bool = false) -> [AlertRecord] {
        let sql = "SELECT id, at, kind, root, count, detail, handled FROM alerts" +
            (unhandledOnly ? " WHERE handled=0" : "") + " ORDER BY at DESC LIMIT ?"
        return (try? db.query(sql, [.int(Int64(limit))]) {
            AlertRecord(id: $0.int(0), at: Date(timeIntervalSince1970: $0.real(1)), kind: $0.text(2), root: $0.text(3),
                        count: Int($0.int(4)), detail: $0.text(5), handled: $0.int(6) != 0)
        }) ?? []
    }

    public func markAlertHandled(id: Int64) {
        _ = try? db.run("UPDATE alerts SET handled=1 WHERE id=?", [.int(id)])
    }

    // MARK: - Runs

    public func startRun(label: String, command: String, at: Date) -> RunRecord {
        _ = try? db.run("INSERT INTO runs(label, command, started_at) VALUES(?,?,?)",
                        [.text(label), .text(command), .real(at.timeIntervalSince1970)])
        return RunRecord(id: db.lastInsertID, label: label, command: command, startedAt: at, endedAt: nil, status: 0)
    }

    public func finishRun(id: Int64, at: Date, status: Int) {
        _ = try? db.run("UPDATE runs SET ended_at=?, status=? WHERE id=?",
                        [.real(at.timeIntervalSince1970), .int(Int64(status)), .int(id)])
    }

    public func runs(limit: Int = 20) -> [RunRecord] {
        (try? db.query("SELECT id, label, command, started_at, ended_at, status FROM runs ORDER BY id DESC LIMIT ?",
                       [.int(Int64(limit))]) {
            RunRecord(id: $0.int(0), label: $0.text(1), command: $0.text(2),
                      startedAt: Date(timeIntervalSince1970: $0.real(3)),
                      endedAt: $0.isNull(4) ? nil : Date(timeIntervalSince1970: $0.real(4)),
                      status: Int($0.int(5)))
        }) ?? []
    }

    public func run(id: Int64) -> RunRecord? { runs(limit: 1000).first { $0.id == id } }

    // MARK: - Meta

    public func meta(_ key: String) -> String? {
        (try? db.query("SELECT value FROM meta WHERE key=?", [.text(key)]) { $0.text(0) })?.first
    }

    public func setMeta(_ key: String, _ value: String) {
        _ = try? db.run("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                        [.text(key), .text(value)])
    }
}
