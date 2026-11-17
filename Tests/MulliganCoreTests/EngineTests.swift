import Foundation
import Testing
@testable import MulliganCore

@Suite(.serialized)
struct EngineTests {

    // MARK: basics

    @Test func baselineScanTracksEveryFileAndHoldsNothing() throws {
        let sb = try Sandbox()
        for i in 0..<40 { sb.write("docs/f\(i).txt", "file \(i)") }
        let sum = sb.engine.scan()
        #expect(sum.visited == 40)
        #expect(sum.snapshotted == 40)
        let st = sb.store.stats()
        #expect(st.liveFiles == 40)
        #expect(st.versions == 40)
        #expect(st.heldBytes == 0, "unchanged files share their blocks with the vault copy")
        #expect(sb.engine.scan().snapshotted == 0, "a second scan of unchanged files does nothing")
    }

    @Test func cloneCostsNoDiskSpace() throws {
        let sb = try Sandbox()
        sb.writeRandom("big.bin", bytes: 120_000_000)
        sync()
        let before = Fs.freeBytes(at: sb.root)
        sb.engine.scan()
        sync()
        let used = before - Fs.freeBytes(at: sb.root)
        #expect(used < 15_000_000, "cloning 120 MB used \(used) bytes of disk")
        #expect(sb.store.stats().versions == 1)
    }

    @Test func modifyKeepsOldVersionIntact() throws {
        let sb = try Sandbox()
        let p = sb.write("a.txt", "version one")
        sb.engine.scan()
        sb.advance(30)
        sb.write("a.txt", "version two, longer")
        sb.engine.ingest([p])
        let vs = sb.store.versions(forPath: p)
        #expect(vs.count == 2)
        let blobs = vs.map { sb.paths.blobs.appendingPathComponent($0.blob).path }
        #expect(try String(contentsOfFile: blobs[0], encoding: .utf8) == "version two, longer")
        #expect(try String(contentsOfFile: blobs[1], encoding: .utf8) == "version one")
    }

    @Test func deleteThenRestoreIsByteIdentical() throws {
        let sb = try Sandbox()
        let p = sb.writeRandom("thesis/chapter1.bin", bytes: 3_000_000)
        let before = sha256(p)
        sb.engine.scan()
        sb.advance(60)
        sb.remove(p)
        sb.engine.ingest(events: removedEvents([p]))
        let gone = sb.store.deleted(minLifetime: 0)
        #expect(gone.count == 1)
        #expect(gone[0].file.path == p)
        let out = try Restorer(store: sb.store).restore(gone[0].latest)
        #expect(out == p)
        #expect(sha256(p) == before)
    }

    @Test func restoreNeverOverwritesAndKeepsModificationTime() throws {
        let sb = try Sandbox()
        let p = sb.write("note.txt", "original")
        let oldMtime = Fs.lstat(p)!.mtimeNs
        sb.engine.scan()
        sb.write("note.txt", "someone's new work")
        let v = sb.store.versions(forPath: p)[0]
        let out = try Restorer(store: sb.store).restore(v, now: sb.clock)
        #expect(out != p)
        #expect(out.contains("(restored"))
        #expect(try String(contentsOfFile: out, encoding: .utf8) == "original")
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "someone's new work")
        #expect(Fs.lstat(out)!.mtimeNs == oldMtime)
        let replaced = try Restorer(store: sb.store).restore(v, to: p, replace: true)
        #expect(replaced == p)
        #expect(sb.text("note.txt") == "original")
    }

    @Test func overwriteByAtomicSaveKeepsPreviousVersion() throws {
        let sb = try Sandbox()
        let p = sb.write("doc.txt", "draft 1")
        sb.engine.scan()
        sb.advance(30)
        let tmp = sb.path(".doc.txt.sb-1234")
        try "final".write(toFile: tmp, atomically: false, encoding: .utf8)
        _ = rename(tmp, p) // editors save by renaming a temp file over the original
        sb.engine.ingest(events: [FSEvent(path: p, flags: EvFlag.renamed | EvFlag.modified | EvFlag.isFile),
                                  FSEvent(path: tmp, flags: EvFlag.renamed | EvFlag.created | EvFlag.isFile)])
        #expect(sb.store.versions(forPath: p).count == 2)
        #expect(sb.store.deleted(minLifetime: 0).isEmpty)
    }

    // MARK: renames and moves

    @Test func renamedFileKeepsItsHistoryAndIsNotADeletion() throws {
        let sb = try Sandbox()
        let a = sb.write("old name.txt", "hello")
        sb.engine.scan()
        let b = sb.path("new name.txt")
        try FileManager.default.moveItem(atPath: a, toPath: b)
        sb.engine.ingest(events: [FSEvent(path: a, flags: EvFlag.renamed | EvFlag.isFile),
                                  FSEvent(path: b, flags: EvFlag.renamed | EvFlag.isFile)])
        #expect(sb.store.deleted(minLifetime: 0).isEmpty)
        #expect(sb.store.file(atPath: a) == nil)
        #expect(sb.store.versions(forPath: b).count == 1)
        #expect(sb.store.stats().liveFiles == 1)
    }

    @Test func renamedFolderMovesWholeTreeWithoutAlarm() throws {
        let sb = try Sandbox { $0.massDeleteThreshold = 5 }
        for i in 0..<30 { sb.write("proj/src/f\(i).swift", "code \(i)") }
        sb.engine.scan()
        sb.advance(60)
        let newDir = sb.path("proj-renamed")
        try FileManager.default.moveItem(atPath: sb.path("proj"), toPath: newDir)
        sb.engine.ingest(events: [FSEvent(path: sb.path("proj"), flags: EvFlag.renamed | EvFlag.isDir),
                                  FSEvent(path: newDir, flags: EvFlag.renamed | EvFlag.isDir)])
        #expect(sb.store.stats().liveFiles == 30)
        #expect(sb.store.stats().deletedFiles == 0)
        #expect(sb.store.stats().versions == 30, "history was carried over, nothing re-snapshotted")
        #expect(sb.store.alerts().isEmpty)
    }

    @Test func movingFilesOutOfWatchedFoldersIsNotAnAlarm() throws {
        let sb = try Sandbox { $0.massDeleteThreshold = 5 }
        var ps: [String] = []
        for i in 0..<20 { ps.append(sb.write("f\(i).txt", "x\(i)")) }
        sb.engine.scan()
        sb.advance(60)
        for p in ps { try FileManager.default.moveItem(atPath: p, toPath: sb.outside + "/" + Fs.lastComponent(p)) }
        sb.engine.ingest(events: ps.map { FSEvent(path: $0, flags: EvFlag.renamed | EvFlag.isFile) })
        #expect(sb.store.alerts().isEmpty, "moving to the Trash or another folder is the user's own action")
        let items = sb.store.deleted(minLifetime: 0)
        #expect(items.count == 20)
        #expect(items.allSatisfy { $0.file.deletedKind == 1 })
    }

    @Test func emptyingTheTrashDoesNotLoseTheFile() throws {
        let sb = try Sandbox()
        let p = sb.write("taxes.txt", "very important")
        sb.engine.scan()
        sb.advance(60)
        let trash = sb.outside + "/.Trash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: p, toPath: trash + "/taxes.txt")
        sb.engine.ingest(events: [FSEvent(path: p, flags: EvFlag.renamed | EvFlag.isFile)])
        try FileManager.default.removeItem(atPath: trash + "/taxes.txt") // "Empty Trash"
        let item = sb.store.deleted(minLifetime: 0)[0]
        _ = try Restorer(store: sb.store).restore(item.latest)
        #expect(sb.text("taxes.txt") == "very important")
    }

    // MARK: mass deletion

    @Test func rmRfRaisesOneAlertAndTreeRestoresExactly() throws {
        let sb = try Sandbox()
        var hashes: [String: String] = [:]
        var files: [String] = []
        for d in 0..<5 {
            for i in 0..<30 {
                let p = sb.writeRandom("project/mod\(d)/file\(i).dat", bytes: 2_000 + i * 17)
                files.append(p); hashes[p] = sha256(p)
            }
        }
        sb.engine.scan()
        sb.advance(120)
        let t0 = sb.clock
        sb.remove(sb.path("project")) // what an agent's rm -rf does
        sb.engine.ingest(events: removedEvents(files) + [FSEvent(path: sb.path("project"), flags: EvFlag.removed | EvFlag.isDir)])

        let alerts = sb.store.alerts()
        #expect(alerts.count == 1, "one alarm per spree, not one per file")
        #expect(alerts[0].count == 150)
        #expect(alerts[0].kind == "mass_delete")

        let rep = Restorer(store: sb.store).restoreTree(prefix: sb.path("project"), asOf: t0, destination: nil)
        #expect(rep.restored.count == 150)
        #expect(rep.failures.isEmpty)
        for (p, h) in hashes { #expect(sha256(p) == h) }
    }

    @Test func droppedEventsStillDetectedBySubtreeRescan() throws {
        let sb = try Sandbox()
        for i in 0..<10 { sb.write("big/f\(i).txt", "x") }
        sb.engine.scan()
        sb.advance(60)
        sb.remove(sb.path("big"))
        // under heavy load FSEvents says "rescan this folder" instead of listing every file
        sb.engine.ingest(events: [FSEvent(path: sb.path("big"), flags: EvFlag.mustScanSubDirs)])
        #expect(sb.store.stats().deletedFiles == 10)
    }

    @Test func restoreTreeAsOfEarlierTimeBringsBackOlderContent() throws {
        let sb = try Sandbox()
        let p = sb.write("notes/todo.txt", "buy milk")
        sb.engine.scan()
        sb.advance(100)
        let checkpoint = sb.clock
        sb.advance(100)
        sb.write("notes/todo.txt", "buy milk and eggs and a very long list")
        sb.engine.ingest([p])
        let out = sb.base + "/restored"
        let rep = Restorer(store: sb.store).restoreTree(prefix: sb.path("notes"), asOf: checkpoint, destination: out)
        #expect(rep.restored.count == 1)
        #expect(try String(contentsOfFile: out + "/notes/todo.txt", encoding: .utf8) == "buy milk")
        #expect(sb.text("notes/todo.txt") == "buy milk and eggs and a very long list", "restoring elsewhere leaves the live file alone")
    }

    @Test func restoreDeletedBringsBackOnlyWhatWentMissingSince() throws {
        let sb = try Sandbox()
        let early = sb.write("docs/early.txt", "deleted long ago")
        let late = sb.write("docs/late.txt", "deleted just now")
        let kept = sb.write("docs/kept.txt", "still here")
        sb.engine.scan()
        sb.advance(100)
        sb.remove(early); sb.engine.ingest(events: removedEvents([early]))
        sb.advance(3600)
        let cutoff = sb.clock.addingTimeInterval(-60)
        sb.remove(late); sb.engine.ingest(events: removedEvents([late]))
        let rep = Restorer(store: sb.store).restoreDeleted(prefix: sb.path("docs"), since: cutoff)
        #expect(rep.restored == [late])
        #expect(sb.exists(late) && !sb.exists(early) && sb.exists(kept))
        let all = Restorer(store: sb.store).restoreDeleted(prefix: sb.path("docs"))
        #expect(all.restored == [early], "the one already restored is no longer 'deleted'")
        #expect(sb.text("docs/early.txt") == "deleted long ago")
    }

    // MARK: rules

    @Test func excludedFoldersAndTempFilesAreIgnored() throws {
        let sb = try Sandbox()
        sb.write("keep.txt", "k")
        sb.write("node_modules/pkg/index.js", "x")
        sb.write("app/.cache/blob", "x")
        sb.write("download.crdownload", "x")
        sb.write("~$word.docx", "x")
        sb.write(".DS_Store", "x")
        sb.write("Photos.photoslibrary/db", "x")
        sb.engine.scan()
        #expect(sb.store.stats().liveFiles == 1)
        sb.write("node_modules/pkg/other.js", "y")
        sb.engine.ingest([sb.path("node_modules/pkg/other.js")])
        #expect(sb.store.stats().liveFiles == 1)
    }

    @Test func iCloudPlaceholdersAreNeverTouched() {
        var st = FileStat(ino: 1, size: 10, mtimeNs: 0, mode: 0o100644, flags: 0x4000_0000)
        #expect(st.isDataless)
        st.flags = 0
        #expect(!st.isDataless)
    }

    @Test func throttleDefersRapidSavesThenCatchesUp() throws {
        let sb = try Sandbox { $0.throttleScale = 1 }
        let p = sb.write("draft.txt", "v1")
        sb.engine.scan()
        sb.advance(5)
        sb.write("draft.txt", "v2 changed")
        sb.engine.ingest([p])
        #expect(sb.store.versions(forPath: p).count == 1, "5 s after the last version: deferred, not lost")
        sb.advance(30)
        sb.engine.ingest([p])
        #expect(sb.store.versions(forPath: p).count == 2)
    }

    @Test func throttleTiersFavourBigFiles() {
        let r = Rules(config: Config())
        #expect(r.minInterval(size: 1_000) == 20)
        #expect(r.minInterval(size: 50_000_000) == 300)
        #expect(r.minInterval(size: 5_000_000_000) == 1800)
        #expect(r.maxVersions(size: 5_000_000_000) == 3)
    }

    // MARK: retention

    @Test func retentionThinsHistoryAndExpiresDeletedFiles() throws {
        let sb = try Sandbox { $0.keepDeletedDays = 30; $0.keepHistoryDays = 14 }
        let p = sb.write("log.txt", "0")
        sb.engine.scan()
        for i in 1...30 { // one edit per 10 minutes
            sb.advance(600)
            sb.write("log.txt", "edit \(i) " + String(repeating: "x", count: i))
            sb.engine.snapshotNow(p)
        }
        #expect(sb.store.versions(forPath: p).count == 31)
        sb.advance(3 * 86400)
        let rep = sb.engine.prune()
        let after = sb.store.versions(forPath: p)
        #expect(after.count < 31)
        #expect(rep.versionsRemoved == 31 - after.count)
        #expect(after[0].takenAt > after[1].takenAt)
        #expect(sb.text("log.txt")!.hasPrefix("edit 30"), "pruning never touches the live file")
        let newest = try String(contentsOfFile: sb.paths.blobs.appendingPathComponent(after[0].blob).path, encoding: .utf8)
        #expect(newest.hasPrefix("edit 30"), "the newest version always survives")

        sb.remove(p)
        sb.engine.ingest(events: removedEvents([p]))
        sb.advance(20 * 86400)
        sb.engine.prune()
        #expect(sb.store.deleted(minLifetime: 0).count == 1, "still recoverable after 20 days")
        sb.advance(15 * 86400)
        let rep2 = sb.engine.prune()
        #expect(rep2.filesPurged == 1)
        #expect(sb.store.deleted(minLifetime: 0).isEmpty)
        let leftovers = (try? FileManager.default.subpathsOfDirectory(atPath: sb.paths.blobs.path))?.filter { $0.count > 3 } ?? []
        #expect(leftovers.isEmpty, "blobs are unlinked along with the index rows")
    }

    @Test func budgetReleasesOldestDeletedFilesFirst() throws {
        let sb = try Sandbox { $0.budgetGB = 0.004 } // 4 MB
        var paths: [String] = []
        for i in 0..<4 { paths.append(sb.writeRandom("f\(i).bin", bytes: 1_500_000)) }
        sb.engine.scan()
        for p in paths { // delete one per day: f0 oldest
            sb.advance(86400)
            sb.remove(p)
            sb.engine.ingest(events: removedEvents([p]))
        }
        #expect(sb.store.heldBytes() == 6_000_000)
        let rep = sb.engine.prune()
        #expect(rep.filesPurged >= 2)
        let left = Set(sb.store.deleted(minLifetime: 0).map { Fs.lastComponent($0.file.path) })
        #expect(left.contains("f3.bin") && left.contains("f2.bin") == (left.count == 2))
        #expect(!left.contains("f0.bin"), "oldest deletion goes first")
        #expect(sb.store.heldBytes() <= 4_000_000)
    }

    @Test func lowDiskGivesSpaceBackButKeepsLiveFiles() throws {
        let sb = try Sandbox { $0.lowDiskFreeGB = 8; $0.budgetGB = 100 }
        let keep = sb.writeRandom("keep.bin", bytes: 1_000_000)
        let gone = sb.writeRandom("gone.bin", bytes: 2_000_000)
        sb.engine.scan()
        sb.advance(100)
        sb.remove(gone)
        sb.engine.ingest(events: removedEvents([gone]))
        #expect(sb.store.deleted(minLifetime: 0).count == 1)
        sb.engine.freeSpace = { _ in 1_000_000_000 } // 1 GB free: tight
        let rep = sb.engine.prune()
        #expect(rep.bytesReleased >= 2_000_000)
        #expect(sb.store.deleted(minLifetime: 0).isEmpty)
        #expect(sb.store.versions(forPath: keep).count == 1, "live files' newest version is never released")
    }

    @Test func orphanBlobsAndDanglingRowsAreCleanedOnStartup() throws {
        let sb = try Sandbox()
        let p = sb.write("a.txt", "a")
        sb.engine.scan()
        let stray = sb.paths.blobs.appendingPathComponent("zz")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try "orphan".write(to: stray.appendingPathComponent("orphan-blob"), atomically: true, encoding: .utf8)
        let v = sb.store.versions(forPath: p)[0]
        unlink(sb.paths.blobs.appendingPathComponent(v.blob).path) // a blob lost to a crash
        let rep = sb.engine.prune(.startup)
        #expect(rep.orphansRemoved == 2)
        #expect(sb.store.versions(forPath: p).isEmpty)
    }

    // MARK: runs (undo what a command did)

    @Test func undoRunRestoresDeletedAndModifiedFiles() throws {
        let sb = try Sandbox()
        let keep = sb.write("keep.txt", "untouched")
        let edited = sb.write("edited.txt", "precious original text")
        let victim = sb.writeRandom("victim.bin", bytes: 50_000)
        let victimHash = sha256(victim)
        sb.engine.scan()
        sb.advance(30)

        let run = sb.engine.beginRun(label: "agent", command: "some-agent --clean")
        sb.advance(30)
        sb.write("edited.txt", "agent rewrote everything")
        sb.remove(victim)
        let created = sb.write("agent-notes.md", "created by the agent")
        let summary = sb.engine.endRun(run, status: 0)

        #expect(summary.deleted.map { $0.file.path } == [victim])
        #expect(summary.modified.map { $0.path } == [edited])
        #expect(summary.created == [created])

        let rep = sb.engine.undo(run: run)
        #expect(rep.failures.isEmpty)
        #expect(sha256(victim) == victimHash)
        #expect(sb.text("edited.txt") == "precious original text")
        #expect(sb.text("keep.txt") == "untouched")
        #expect(sb.exists(created), "files the run created are left alone")
        _ = keep
        // the agent's rewrite is not lost either: it is simply an older version now
        let texts = try sb.store.versions(forPath: edited).map {
            try String(contentsOfFile: sb.paths.blobs.appendingPathComponent($0.blob).path, encoding: .utf8)
        }
        #expect(texts.contains("agent rewrote everything"))
    }

    // MARK: live FSEvents

    @Test func liveWatcherCapturesCreateModifyDeleteAndMassDelete() async throws {
        let sb = try Sandbox { $0.massDeleteThreshold = 20 }
        sb.engine.now = { Date() }
        let p = sb.write("live.txt", "first")
        var spree: [String] = []
        for i in 0..<60 { spree.append(sb.write("spree/f\(i).txt", "content \(i)")) }
        sb.engine.start()
        #expect(await waitUntil(10) { sb.store.stats().liveFiles == 61 }, "baseline scan")

        sb.write("live.txt", "second, and longer")
        #expect(await waitUntil(8) { sb.store.versions(forPath: p).count == 2 }, "modification was versioned by the watcher")

        let fresh = sb.write("born-later.txt", "new file")
        #expect(await waitUntil(8) { sb.store.file(atPath: fresh) != nil }, "new files are picked up")

        sb.remove(p)
        #expect(await waitUntil(8) { sb.store.deleted(minLifetime: 0).contains { $0.file.path == p } }, "deletion noticed")

        let beforeSpree = Date()
        sb.remove(sb.path("spree"))
        #expect(await waitUntil(12) { !sb.store.alerts().isEmpty }, "mass deletion alarm")
        #expect(await waitUntil(8) { sb.store.stats().deletedFiles >= 61 })

        let rep = Restorer(store: sb.store).restoreTree(prefix: sb.path("spree"), asOf: beforeSpree, destination: nil)
        #expect(rep.restored.count == 60)
        for (i, f) in spree.enumerated() { #expect(try String(contentsOfFile: f, encoding: .utf8) == "content \(i)") }
        let first = sb.store.deleted(minLifetime: 0).first { $0.file.path == p }!
        _ = try Restorer(store: sb.store).restore(first.latest)
        #expect(sb.text("live.txt") == "second, and longer")
    }

    @Test func pauseStopsTrackingAndResumeCatchesUp() async throws {
        let sb = try Sandbox()
        sb.engine.now = { Date() }
        sb.write("a.txt", "a")
        sb.engine.start()
        #expect(await waitUntil(10) { sb.store.stats().liveFiles == 1 })
        var cfg = sb.engine.config
        cfg.paused = true
        sb.engine.apply(config: cfg)
        sb.write("while-paused.txt", "p")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(sb.store.file(atPath: sb.path("while-paused.txt")) == nil)
        cfg.paused = false
        sb.engine.apply(config: cfg)
        #expect(await waitUntil(10) { sb.store.file(atPath: sb.path("while-paused.txt")) != nil }, "resume reconciles what changed")
    }
}

// MARK: - small utilities

@Suite struct UtilityTests {
    @Test func parseWhenUnderstandsHumanTimes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Fmt.parseWhen("now", now: now) == now)
        #expect(Fmt.parseWhen("30m", now: now) == now.addingTimeInterval(-1800))
        #expect(Fmt.parseWhen("2h ago", now: now) == now.addingTimeInterval(-7200))
        #expect(Fmt.parseWhen("3 days ago", now: now) == now.addingTimeInterval(-259_200))
        #expect(Fmt.parseWhen("1w", now: now) == now.addingTimeInterval(-604_800))
        #expect(Fmt.parseWhen("2026-11-17 10:30") != nil)
        #expect(Fmt.parseWhen("2026-11-17") != nil)
        #expect(Fmt.parseWhen("yesterday 18:00", now: now) != nil)
        #expect(Fmt.parseWhen("whenever", now: now) == nil)
    }

    @Test func configSurvivesRoundTripAndOldFiles() throws {
        var c = Config()
        c.roots = ["/tmp/x"]; c.keepDeletedDays = 7
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "/mulligan-cfg-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try c.save(to: url)
        #expect(Config.load(from: url) == c)
        try #"{"roots":["/a"]}"#.write(to: url, atomically: true, encoding: .utf8)
        let old = Config.load(from: url)
        #expect(old.roots == ["/a"] && old.keepDeletedDays == 30, "missing keys fall back to defaults")
    }

    @Test func nestedRootsAreCollapsed() throws {
        let base = Fs.canonical(NSTemporaryDirectory()) + "/mulligan-roots-\(UUID())"
        try FileManager.default.createDirectory(atPath: base + "/a/b", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        #expect(Engine.canonicalRoots([base + "/a", base + "/a/b", base + "/missing"]) == [base + "/a"])
    }

    @Test func processLockIsExclusive() {
        let path = NSTemporaryDirectory() + "/mulligan-lock-\(UUID())"
        defer { unlink(path) }
        let first = ProcessLock(path: path)
        #expect(first != nil)
        #expect(ProcessLock(path: path) == nil)
        #expect(ProcessLock.isHeld(path: path))
        _ = first
    }
}

func sync() { Darwin.sync(); usleep(300_000) }
