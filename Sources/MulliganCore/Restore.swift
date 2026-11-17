import Foundation

public enum RestoreError: Error, CustomStringConvertible {
    case missingBlob(String)
    case failed(String)
    public var description: String {
        switch self {
        case .missingBlob(let p): return "the saved copy of \(p) is no longer in the vault"
        case .failed(let m): return m
        }
    }
}

public struct RestoreReport: Equatable {
    public var restored: [String] = []
    /// Restored next to the original because something already lives at the original path.
    public var alongside: [String] = []
    public var skipped: [String] = []
    public var failures: [String] = []
    public init() {}
    public var total: Int { restored.count + alongside.count }

    public mutating func merge(_ o: RestoreReport) {
        restored += o.restored; alongside += o.alongside; skipped += o.skipped; failures += o.failures
    }
}

public struct Restorer {
    public let store: Store
    public let paths: Paths

    public init(store: Store) {
        self.store = store
        self.paths = store.paths
    }

    func blobPath(_ v: VersionRecord) -> String { paths.blobs.appendingPathComponent(v.blob).path }

    static func alongsideName(_ path: String, stamp: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let ns = path as NSString
        let ext = ns.pathExtension
        let base = (ns.deletingPathExtension as NSString).lastPathComponent
        let dir = ns.deletingLastPathComponent
        var n = 0
        while true {
            let suffix = " (restored \(f.string(from: stamp))" + (n == 0 ? "" : " \(n + 1)") + ")"
            let name = base + suffix + (ext.isEmpty ? "" : "." + ext)
            let candidate = (dir as NSString).appendingPathComponent(name)
            if Fs.lstat(candidate) == nil { return candidate }
            n += 1
        }
    }

    /// Puts one version back. It never overwrites a file unless `replace` is set; otherwise the
    /// restored copy lands next to the original. Returns the path that was written.
    @discardableResult
    public func restore(_ v: VersionRecord, to destination: String? = nil, replace: Bool = false, now: Date = Date()) throws -> String {
        let src = blobPath(v)
        guard Fs.lstat(src) != nil else { throw RestoreError.missingBlob(v.name) }
        var target = destination ?? v.path
        let dir = (target as NSString).deletingLastPathComponent
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        catch { throw RestoreError.failed("cannot create \(dir): \(error.localizedDescription)") }
        if Fs.lstat(target) != nil && !replace { target = Restorer.alongsideName(target, stamp: now) }

        let tmp = (dir as NSString).appendingPathComponent(".mulligan-restore-" + UUID().uuidString)
        do { _ = try Fs.clone(src, to: tmp, copyLimit: Int64.max) }
        catch { throw RestoreError.failed("\(error)") }
        Fs.setMtime(tmp, ns: v.mtimeNs)
        guard rename(tmp, target) == 0 else {
            let e = errno
            unlink(tmp)
            throw RestoreError.failed("cannot write \(target): \(String(cString: strerror(e)))")
        }
        return target
    }

    /// Restores the files whose newest version at or before `asOf` is wanted, as they were then.
    /// With `destination == nil` they go back where they were; otherwise into that folder,
    /// keeping their layout relative to `prefix`.
    public func restoreFiles(ids: [Int64], asOf: Date, prefix: String?, destination: String?,
                             replaceChanged: Bool, now: Date = Date()) -> RestoreReport {
        var rep = RestoreReport()
        for id in ids {
            guard let f = store.file(id: id), let v = store.version(fileID: id, asOf: asOf) else { continue }
            var target = f.path
            if let dest = destination, let prefix = prefix {
                let base = (prefix as NSString).lastPathComponent
                let rel = f.path.hasPrefix(prefix + "/") ? String(f.path.dropFirst(prefix.count + 1)) : f.name
                target = (dest as NSString).appendingPathComponent(base + "/" + rel)
            } else if Fs.lstat(f.path) != nil {
                // live at the original path: only replace when it has changed since and the caller wants that
                let current = store.latestVersion(fileID: id)
                if current?.id == v.id { rep.skipped.append(f.path); continue }
                if !replaceChanged { rep.skipped.append(f.path); continue }
                do { rep.restored.append(try restore(v, to: f.path, replace: true, now: now)) }
                catch { rep.failures.append("\(f.path): \(error)") }
                continue
            }
            do {
                let written = try restore(v, to: target, replace: false, now: now)
                if written == target { rep.restored.append(written) } else { rep.alongside.append(written) }
            } catch { rep.failures.append("\(f.path): \(error)") }
        }
        return rep
    }

    /// "Put this folder back the way it was at `asOf`."
    public func restoreTree(prefix: String, asOf: Date, destination: String?, replaceChanged: Bool = false,
                            now: Date = Date()) -> RestoreReport {
        let (lo, hi) = Store.prefixRange(prefix)
        let ids = (try? store.db.query("""
            SELECT f.id FROM files f
            WHERE f.path>=? AND f.path<? AND (f.deleted_at IS NULL OR f.deleted_at>=?)
              AND EXISTS (SELECT 1 FROM versions v WHERE v.file_id=f.id AND v.taken_at<=?)
            """, [.text(lo), .text(hi), .real(asOf.timeIntervalSince1970), .real(asOf.timeIntervalSince1970)]) { $0.int(0) }) ?? []
        return restoreFiles(ids: ids, asOf: asOf, prefix: prefix, destination: destination,
                            replaceChanged: replaceChanged, now: now)
    }

    /// "Bring back everything that was deleted from this folder" (optionally only what went missing since `since`).
    /// Each file returns in its most recent saved state.
    public func restoreDeleted(prefix: String, since: Date? = nil, destination: String? = nil, now: Date = Date()) -> RestoreReport {
        let (lo, hi) = Store.prefixRange(prefix)
        var sql = "SELECT f.id FROM files f WHERE f.path>=? AND f.path<? AND f.deleted_at IS NOT NULL AND f.latest_version_id IS NOT NULL"
        var binds: [Bind] = [.text(lo), .text(hi)]
        if let since = since { sql += " AND f.deleted_at>=?"; binds.append(.real(since.timeIntervalSince1970)) }
        let ids = (try? store.db.query(sql, binds) { $0.int(0) }) ?? []
        return restoreFiles(ids: ids, asOf: Date.distantFuture, prefix: prefix, destination: destination,
                            replaceChanged: false, now: now)
    }
}
