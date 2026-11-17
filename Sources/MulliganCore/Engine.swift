import Foundation

public enum EngineEvent {
    case snapshot(path: String)
    case deleted(count: Int, moved: Bool)
    case alert(AlertRecord)
    case scanFinished(ScanSummary)
    case pruned(PruneReport)
}

public struct ScanSummary: Equatable {
    public var visited = 0
    public var snapshotted = 0
    public var markedDeleted = 0
    public var seconds: Double = 0
    public init() {}
}

public struct EngineStatus {
    public var roots: [String] = []
    public var watching = false
    public var paused = false
    public var scanning = false
    public var lastEvent: Date?
    public var snapshotsThisSession = 0
    public var stats = StoreStats()
    public var freeBytes: Int64 = 0
    public var budgetBytes: Int64 = 0
    /// True if some files had to be copied because cloning was not possible (non-APFS volume).
    public var usingCopies = false
    public init() {}
}

/// Watches folders and keeps an instant, space-free (APFS clone) copy of every file as it changes,
/// so nothing that was deleted or overwritten is ever really gone.
public final class Engine {
    public let paths: Paths
    public let store: Store
    public private(set) var config: Config
    public private(set) var roots: [String] = []
    var rules: Rules

    let queue = DispatchQueue(label: "app.mulligan.engine", qos: .utility)
    private var watcher: Watcher?
    private var timer: DispatchSourceTimer?
    private var started = false
    private var dirty: [String: UInt32] = [:]
    private var walkDirs = Set<String>()
    private var firstDirtyAt: Date?
    private var lastEventAt = Date.distantPast
    private var deferred: [String: Date] = [:]
    private var lastPrune = Date.distantPast
    private var recentDeletes: [(at: Date, root: String, path: String)] = []
    private var liveAlert: [String: AlertRecord] = [:]

    private let statusLock = NSLock()
    private var _lastEvent: Date?
    private var _snapshots = 0
    private var _scanning = false
    private var _usingCopies = false

    public var onEvent: ((EngineEvent) -> Void)?
    public var now: () -> Date = { Date() }
    public var freeSpace: (String) -> Int64 = { Fs.freeBytes(at: $0) }
    public var copyFallbackLimit: Int64 = 256_000_000
    /// Files deleted sooner than this after first being seen (editor temp files) do not count towards the mass-deletion alarm.
    public var ephemeralLifetime: TimeInterval = 5

    public init(paths: Paths, config: Config) throws {
        self.paths = paths
        self.config = config
        self.rules = Rules(config: config)
        self.store = try Store(paths: paths)
        self.roots = Engine.canonicalRoots(config.roots)
    }

    static func canonicalRoots(_ r: [String]) -> [String] {
        var out: [String] = []
        for p in r {
            let c = Fs.canonical(p)
            if let st = Fs.lstat(c), st.isDirectory, !out.contains(c) { out.append(c) }
        }
        // a root nested inside another root is already covered
        return out.filter { a in !out.contains { b in b != a && a.hasPrefix(b + "/") } }
    }

    func rootFor(_ path: String) -> String? {
        var best: String?
        for r in roots where path == r || path.hasPrefix(r + "/") {
            if best == nil || r.count > best!.count { best = r }
        }
        return best
    }

    // MARK: - Lifecycle

    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            if !config.paused { beginWatching() }
            startTimer()
            scanLocked(force: false)
            runRetention(.startup)
        }
    }

    public func stop() {
        queue.sync {
            watcher?.stop(); watcher = nil
            timer?.cancel(); timer = nil
            started = false
        }
    }

    private func beginWatching() {
        guard watcher == nil, !roots.isEmpty else { return }
        let w = Watcher(roots: roots, latency: 0.3, queue: queue) { [weak self] events in self?.handleLocked(events) }
        if w.start() { watcher = w }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(400))
        t.setEventHandler { [weak self] in self?.tickLocked() }
        t.resume()
        timer = t
    }

    public func apply(config new: Config) {
        queue.sync {
            let newRoots = Engine.canonicalRoots(new.roots)
            let rootsChanged = newRoots != roots
            config = new
            rules = Rules(config: new)
            roots = newRoots
            guard started else { return }
            if new.paused {
                watcher?.stop(); watcher = nil
                return
            }
            if rootsChanged || watcher == nil {
                watcher?.stop(); watcher = nil
                beginWatching()
                scanLocked(force: false) // catches whatever changed while paused
            }
        }
    }

    public func status() -> EngineStatus {
        var s = EngineStatus()
        s.roots = roots
        s.paused = config.paused
        s.watching = watcher != nil
        statusLock.lock()
        s.lastEvent = _lastEvent; s.snapshotsThisSession = _snapshots; s.scanning = _scanning; s.usingCopies = _usingCopies
        statusLock.unlock()
        s.stats = store.stats()
        s.freeBytes = freeSpace(paths.vault.path)
        s.budgetBytes = Retention(store: store, paths: paths, config: config, now: now, freeSpace: freeSpace).budgetBytes()
        return s
    }

    // MARK: - Public operations (thread-safe)

    @discardableResult
    public func scan(force: Bool = false) -> ScanSummary {
        queue.sync { scanLocked(force: force) }
    }

    /// Feed paths as if the file system had reported them (tests, and "snapshot this now").
    public func ingest(_ ps: [String], flags: UInt32 = EvFlag.modified) {
        ingest(events: ps.map { FSEvent(path: $0, flags: flags) })
    }

    public func ingest(events: [FSEvent]) {
        queue.sync {
            handleLocked(events)
            flushLocked()
        }
    }

    /// Wait for everything queued so far.
    public func drain() { queue.sync {} }

    @discardableResult
    public func prune(_ reason: PruneReason = .manual) -> PruneReport {
        queue.sync { runRetention(reason) }
    }

    @discardableResult
    public func snapshotNow(_ path: String) -> Bool {
        queue.sync {
            guard let st = Fs.lstat(path) else { return false }
            return snapshotIfNeeded(path, st, force: true).snapped
        }
    }

    // MARK: - Event handling (engine queue)

    private func handleLocked(_ events: [FSEvent]) {
        guard !config.paused else { return }
        for e in events {
            if e.flags & EvFlag.rootChanged != 0 { continue }
            if e.flags & (EvFlag.mustScanSubDirs | EvFlag.userDropped | EvFlag.kernelDropped) != 0 {
                walkDirs.insert(e.path)
                continue
            }
            dirty[e.path, default: 0] |= e.flags
            if e.flags & EvFlag.isDir != 0, e.flags & (EvFlag.created | EvFlag.renamed) != 0 { walkDirs.insert(e.path) }
        }
        let t = now()
        lastEventAt = t
        if firstDirtyAt == nil { firstDirtyAt = t }
        statusLock.lock(); _lastEvent = t; statusLock.unlock()
    }

    private func tickLocked() {
        let t = now()
        for (p, due) in deferred where due <= t {
            dirty[p, default: 0] |= EvFlag.modified
            deferred[p] = nil
            if firstDirtyAt == nil { firstDirtyAt = t; lastEventAt = t.addingTimeInterval(-2) }
        }
        if !dirty.isEmpty || !walkDirs.isEmpty {
            let quiet = t.timeIntervalSince(lastEventAt) >= 1.0
            let waited = t.timeIntervalSince(firstDirtyAt ?? t) >= 5.0
            if quiet || waited { flushLocked() }
        }
        if t.timeIntervalSince(lastPrune) >= 600 { runRetention(.periodic) }
    }

    func flushLocked() {
        let items = dirty
        let walks = walkDirs
        dirty = [:]; walkDirs = []; firstDirtyAt = nil

        var existing: [(String, FileStat)] = []
        var seen = Set<String>()
        var missing: [(String, UInt32)] = []
        var vanishedIDs: [Int64] = []

        for (p, flags) in items.sorted(by: { $0.key < $1.key }) {
            guard let root = rootFor(p), !rules.excluded(path: p, root: root) else { continue }
            if let st = Fs.lstat(p) {
                if st.isRegular, seen.insert(p).inserted { existing.append((p, st)) }
            } else {
                missing.append((p, flags))
            }
        }

        for dir in walks.sorted() {
            guard let root = rootFor(dir) else { continue }
            if let st = Fs.lstat(dir), st.isDirectory {
                if rules.excludedDir(path: dir, root: root) { continue }
                Fs.walk(dir, descend: { _, n in !self.rules.skipDir(name: n) }) { p, st in
                    if st.isRegular, !self.rules.skipFile(name: Fs.lastComponent(p)), seen.insert(p).inserted {
                        existing.append((p, st))
                    }
                }
                // events may have been coalesced or dropped: anything tracked below that is gone, is gone
                for f in store.liveFiles(underPrefix: dir) where !seen.contains(f.path) && Fs.lstat(f.path) == nil {
                    vanishedIDs.append(f.id)
                }
            } else {
                missing.append((dir, EvFlag.removed))
            }
        }

        // Existing files first: a rename inside the watched folders is then matched by inode before the
        // old path is declared gone.
        _ = try? store.db.transaction {
            for (p, st) in existing { snapshotIfNeeded(p, st, force: false) }
        }
        for (p, flags) in missing { handleMissing(p, flags: flags) }
        if !vanishedIDs.isEmpty {
            let hits = store.markDeleted(ids: vanishedIDs, at: now(), kind: 0)
            if !hits.isEmpty { onEvent?(.deleted(count: hits.count, moved: false)); registerDeletions(hits) }
        }
    }

    private func handleMissing(_ path: String, flags: UInt32) {
        let moved = (flags & EvFlag.renamed != 0) && (flags & EvFlag.removed == 0)
        let hits = store.markDeleted(path: path, at: now(), kind: moved ? 1 : 0)
        guard !hits.isEmpty else { return }
        onEvent?(.deleted(count: hits.count, moved: moved))
        if !moved { registerDeletions(hits) }
    }

    // MARK: - Mass-deletion alarm

    private func registerDeletions(_ files: [FileRecord]) {
        let t = now()
        for f in files where t.timeIntervalSince(f.firstSeen) > ephemeralLifetime { // ignore short-lived temp files
            recentDeletes.append((t, f.root, f.path))
        }
        let window = Double(config.massDeleteWindowSeconds)
        recentDeletes.removeAll { t.timeIntervalSince($0.at) > window }
        for root in Set(recentDeletes.map { $0.root }) {
            let items = recentDeletes.filter { $0.root == root }
            guard items.count >= config.massDeleteThreshold else { continue }
            let sample = items.prefix(5).map { Fs.lastComponent($0.path) }.joined(separator: "\n")
            if let existing = liveAlert[root], t.timeIntervalSince(existing.at) < 180 {
                let count = max(existing.count, items.count)
                store.updateAlert(id: existing.id, count: count, detail: sample)
                var upd = existing; upd.count = count
                liveAlert[root] = upd
                continue
            }
            let alert = store.addAlert(at: t, kind: "mass_delete", root: root, count: items.count, detail: sample)
            liveAlert[root] = alert
            onEvent?(.alert(alert))
        }
    }

    // MARK: - Snapshots

    @discardableResult
    func snapshotIfNeeded(_ path: String, _ st: FileStat, force: Bool) -> (id: Int64?, snapped: Bool) {
        guard st.isRegular, !st.isDataless, st.size <= rules.maxFileBytes, let root = rootFor(path) else { return (nil, false) }
        let t = now()

        var file = store.file(atPath: path)
        if file == nil {
            // A rename inside the watched folders keeps the inode: carry the history over.
            let cands = store.renameCandidates(inode: st.ino, notPath: path, deletedAfter: t.addingTimeInterval(-300))
            if let moved = cands.first(where: { Fs.lstat($0.path) == nil }) {
                store.relocate(fileID: moved.id, path: path, root: root, inode: st.ino)
                file = store.file(atPath: path)
            }
        }
        let rec = file ?? store.insertFile(path: path, root: root, inode: st.ino, now: t)
        if rec.deletedAt != nil { store.undelete(fileID: rec.id) }

        if let last = store.latestVersion(fileID: rec.id) {
            if last.size == st.size && last.mtimeNs == st.mtimeNs {
                if rec.inode != st.ino { store.setInode(rec.id, st.ino) }
                return (rec.id, false)
            }
            if !force {
                let wait = rules.minInterval(size: st.size)
                if t.timeIntervalSince(last.takenAt) < wait {
                    deferred[path] = last.takenAt.addingTimeInterval(wait)
                    return (rec.id, false)
                }
            }
        }

        let blob = newBlobName()
        let dst = paths.blobs.appendingPathComponent(blob).path
        try? FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let outcome: CloneOutcome
        do { outcome = try Fs.clone(path, to: dst, copyLimit: copyFallbackLimit) } catch { return (rec.id, false) }
        if outcome == .copied { statusLock.lock(); _usingCopies = true; statusLock.unlock() }

        // Record the stat from *before* cloning: if the file changed meanwhile, the next pass sees a
        // different mtime and takes another version instead of trusting a stale one.
        store.addVersion(fileID: rec.id, takenAt: t, size: st.size, mtimeNs: st.mtimeNs, blob: blob,
                         isClone: outcome == .cloned, mode: Int(st.mode & 0o7777))
        if rec.inode != st.ino { store.setInode(rec.id, st.ino) }
        enforceVersionCap(fileID: rec.id, size: st.size)
        statusLock.lock(); _snapshots += 1; statusLock.unlock()
        onEvent?(.snapshot(path: path))
        return (rec.id, true)
    }

    private func newBlobName() -> String {
        let id = UUID().uuidString.lowercased()
        return String(id.prefix(2)) + "/" + id
    }

    private func enforceVersionCap(fileID: Int64, size: Int64) {
        let cap = rules.maxVersions(size: size)
        let vs = store.versions(fileID: fileID) // newest first
        guard vs.count > cap else { return }
        let drop = vs.dropFirst(cap).map { $0.id }
        for b in store.deleteVersions(ids: drop) { unlink(paths.blobs.appendingPathComponent(b).path) }
    }

    // MARK: - Scan

    @discardableResult
    func scanLocked(force: Bool) -> ScanSummary {
        statusLock.lock(); _scanning = true; statusLock.unlock()
        defer { statusLock.lock(); _scanning = false; statusLock.unlock() }
        let started = Date()
        var sum = ScanSummary()
        for root in roots { scanTree(root, force: force, &sum) }
        sum.seconds = Date().timeIntervalSince(started)
        onEvent?(.scanFinished(sum))
        return sum
    }

    private func scanTree(_ dir: String, force: Bool, _ sum: inout ScanSummary) {
        // A root that is not there right now (unplugged drive) must not look like a mass deletion.
        guard Fs.lstat(dir)?.isDirectory == true else { return }
        var files: [(String, FileStat)] = []
        Fs.walk(dir, descend: { _, n in !self.rules.skipDir(name: n) }) { p, st in
            guard st.isRegular, !self.rules.skipFile(name: Fs.lastComponent(p)) else { return }
            files.append((p, st))
        }
        var seen = Set<Int64>()
        var i = 0
        while i < files.count {
            let end = min(i + 500, files.count)
            _ = try? store.db.transaction {
                for (p, st) in files[i..<end] {
                    let r = snapshotIfNeeded(p, st, force: force)
                    sum.visited += 1
                    if r.snapped { sum.snapshotted += 1 }
                    if let id = r.id { seen.insert(id) }
                }
            }
            i = end
        }
        let gone = store.liveFiles(underPrefix: dir).filter { !seen.contains($0.id) && Fs.lstat($0.path) == nil }
        if !gone.isEmpty {
            sum.markedDeleted += store.markDeleted(ids: gone.map { $0.id }, at: now(), kind: 0).count
        }
    }

    // MARK: - Retention

    @discardableResult
    func runRetention(_ reason: PruneReason) -> PruneReport {
        lastPrune = now()
        let r = Retention(store: store, paths: paths, config: config, now: now, freeSpace: freeSpace)
        let rep = r.run(reason)
        if rep.versionsRemoved > 0 || rep.filesPurged > 0 { onEvent?(.pruned(rep)) }
        return rep
    }
}

extension Rules {
    public func excludedDir(path: String, root: String) -> Bool {
        guard path.hasPrefix(root) else { return true }
        return path.dropFirst(root.count).split(separator: "/").contains { skipDir(name: String($0)) }
    }
}
