import Foundation
import MulliganCore

// MARK: - helpers

func out(_ s: String = "") { print(s) }
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func fail(_ s: String, code: Int32 = 1) -> Never { err("mulligan: " + s); exit(code) }
func tilde(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }
func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
func rpad(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }
func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
func json(_ obj: Any) {
    let d = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    out(String(data: d, encoding: .utf8)!)
}

struct Args {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var bools: Set<String> = []
    init(_ raw: [String], valueFlags: Set<String> = []) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") && a.count > 2 {
                let name = String(a.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    flags[String(name[..<eq])] = String(name[name.index(after: eq)...])
                } else if valueFlags.contains(name), i + 1 < raw.count {
                    flags[name] = raw[i + 1]; i += 1
                } else { bools.insert(name) }
            } else { positional.append(a) }
            i += 1
        }
    }
    func has(_ n: String) -> Bool { bools.contains(n) }
}

func ask(_ question: String) -> Bool {
    print(question + " [y/N] ", terminator: "")
    guard let line = readLine() else { return false }
    return ["y", "yes"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
}

func openEngine(createConfig: Bool = true) -> Engine {
    let paths = Paths.standard()
    do { try paths.ensureDirectories() } catch { fail("cannot create \(paths.support.path): \(error)") }
    var cfg = Config.load(from: paths.config)
    if cfg.roots.isEmpty && !FileManager.default.fileExists(atPath: paths.config.path) {
        cfg.roots = Config.defaultRoots()
        if createConfig { try? cfg.save(to: paths.config) }
    }
    do { return try Engine(paths: paths, config: cfg) } catch { fail("cannot open the vault: \(error)") }
}

func resolveFile(_ e: Engine, _ arg: String) -> FileRecord? {
    if arg.hasPrefix("#"), let id = Int64(arg.dropFirst()) { return e.store.file(id: id) }
    var p = (arg as NSString).expandingTildeInPath
    if !p.hasPrefix("/") { p = FileManager.default.currentDirectoryPath + "/" + p }
    p = (p as NSString).standardizingPath
    return e.store.file(atPath: Fs.canonical(p)) ?? e.store.file(atPath: p)
}

func resolvePath(_ arg: String) -> String {
    var p = (arg as NSString).expandingTildeInPath
    if !p.hasPrefix("/") { p = FileManager.default.currentDirectoryPath + "/" + p }
    return Fs.canonical((p as NSString).standardizingPath)
}

func notify(_ title: String, _ body: String) {
    func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\" sound name \"Basso\""]
    try? p.run()
}

let usage = """
mulligan — a do-over for your files. Undo for deletes, overwrites and runaway scripts or AI agents.

  How it works: every file in the folders you protect is kept as an instant, free (APFS clone) copy
  each time it changes. Deleting, overwriting or `rm -rf` never destroys the last copy.

USAGE
  mulligan status                      what is protected, space held, whether the watcher is running
  mulligan watch                       run the watcher in this terminal (the menu-bar app does the same)
  mulligan scan                        bring the vault up to date right now
  mulligan deleted [text] [--since 2h] [--limit N] [--hide-temp]   recently deleted files
  mulligan find <text>                 search live and deleted files by path
  mulligan history <path>              every saved version of a file
  mulligan restore <path|#id> [--version ID] [--at WHEN] [--to DIR] [--replace]
  mulligan restore-tree <folder> --deleted [--since WHEN] [--to DIR]    bring back everything deleted from a folder
  mulligan restore-tree <folder> --at WHEN [--to DIR] [--replace-changed]   the folder as it was at that time
  mulligan run [--label TEXT] -- <command…>   run a command; afterwards see what it changed
  mulligan undo-run [id|last] [--yes]  put back what that command deleted or rewrote
  mulligan runs                        recent runs
  mulligan checkpoint [label]          mark "now" so you can return to it with undo-run
  mulligan forget <path|#id> | --all-deleted [--yes]   erase from the vault immediately (privacy)
  mulligan prune                       apply retention now
  mulligan config [show | add-root DIR | remove-root DIR | set KEY VALUE]
  mulligan install-agent [--print] | uninstall-agent   start at login without the app
  mulligan doctor                      check that everything is set up properly

WHEN can be: 30m, 2h ago, 3 days ago, yesterday 18:00, 2026-11-17 10:30
Add --json to status, deleted, find, history and runs for scripts.
"""

// MARK: - commands

var argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else { out(usage); exit(0) }
argv.removeFirst()

switch cmd {
case "help", "-h", "--help":
    out(usage)

case "status":
    let a = Args(argv)
    let e = openEngine()
    let s = e.status()
    let running = ProcessLock.isHeld(path: e.paths.lock.path)
    let recent = e.store.deleted(limit: 1000, since: Date().addingTimeInterval(-86400), minLifetime: 0)
    let alerts = e.store.alerts(limit: 5, unhandledOnly: true)
    if a.has("json") {
        json(["roots": s.roots, "watcherRunning": running, "liveFiles": s.stats.liveFiles, "deletedFiles": s.stats.deletedFiles,
              "versions": s.stats.versions, "heldBytes": s.stats.heldBytes, "budgetBytes": s.budgetBytes,
              "freeBytes": s.freeBytes, "deletedLast24h": recent.count, "unhandledAlerts": alerts.count] as [String: Any])
    } else {
        out("Mulligan protects \(s.roots.count) folder\(s.roots.count == 1 ? "" : "s"):")
        for r in s.roots { out("   \(tilde(r))") }
        if s.roots.isEmpty { out("   (none yet — `mulligan config add-root ~/Documents`)") }
        out("Watcher:   " + (running ? "running" : "NOT running — open Mulligan.app, run `mulligan watch`, or `mulligan install-agent`"))
        out("Protected: \(s.stats.liveFiles) files, \(s.stats.versions) saved versions")
        out("Held:      \(Fmt.bytes(s.stats.heldBytes)) by older versions and deleted files (limit \(Fmt.bytes(s.budgetBytes)); it gives space back when the disk gets tight)")
        out("Deleted:   \(recent.count) file\(recent.count == 1 ? "" : "s") in the last 24 hours, \(s.stats.deletedFiles) recoverable in total")
        out("Disk free: \(Fmt.bytes(s.freeBytes))")
        for al in alerts { out("⚠️  \(al.count) files were removed from \(tilde(al.root)) \(Fmt.ago(al.at)). See `mulligan deleted --since 1h`.") }
    }

case "watch":
    let a = Args(argv)
    let paths = Paths.standard()
    try? paths.ensureDirectories()
    guard let lock = ProcessLock(path: paths.lock.path) else {
        fail("another Mulligan is already watching (the menu-bar app or a background agent)")
    }
    _ = lock
    let e = openEngine()
    let verbose = a.has("verbose")
    let doNotify = e.config.notify
    e.onEvent = { ev in
        switch ev {
        case .alert(let al):
            err("⚠️  \(al.count) files were just deleted from \(tilde(al.root)). Bring them back with:  mulligan restore-tree \"\(al.root)\" --deleted --since 10m")
            if doNotify { notify("Mulligan: \(al.count) files just disappeared", "From \(tilde(al.root)). They're safe — open Mulligan to restore.") }
        case .scanFinished(let s): err("scan: \(s.visited) files checked, \(s.snapshotted) saved, \(s.markedDeleted) gone (\(String(format: "%.1f", s.seconds))s)")
        case .snapshot(let p): if verbose { err("saved \(tilde(p))") }
        case .deleted(let n, let moved): if verbose { err("\(n) file\(n == 1 ? "" : "s") \(moved ? "moved away" : "deleted")") }
        case .pruned(let r): err("retention: released \(Fmt.bytes(r.bytesReleased)) (\(r.versionsRemoved) versions, \(r.filesPurged) expired files)")
        }
    }
    err("mulligan: watching \(e.roots.map(tilde).joined(separator: ", ")) (Ctrl-C to stop)")
    e.start()
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { e.stop(); exit(0) }
        src.resume()
        sources.append(src)
    }
    dispatchMain()

case "scan":
    let e = openEngine()
    err("scanning \(e.roots.map(tilde).joined(separator: ", ")) …")
    let s = e.scan()
    out("\(s.visited) files checked, \(s.snapshotted) saved, \(s.markedDeleted) found deleted — \(String(format: "%.1f", s.seconds))s")

case "deleted", "find":
    let a = Args(argv, valueFlags: ["since", "limit"])
    let e = openEngine()
    let limit = Int(a.flags["limit"] ?? "") ?? 50
    var since: Date?
    if let w = a.flags["since"] { guard let d = Fmt.parseWhen(w) else { fail("cannot understand --since \(w)") }; since = d }
    let match = a.positional.joined(separator: " ")
    var items: [DeletedItem]
    if cmd == "find" {
        guard !match.isEmpty else { fail("usage: mulligan find <text>") }
        items = e.store.search(match, limit: limit)
    } else {
        items = e.store.deleted(limit: limit, since: since, matching: match.isEmpty ? nil : match,
                                minLifetime: a.has("hide-temp") ? 5 : 0)
    }
    if a.has("json") {
        json(items.map { ["id": $0.file.id, "path": $0.file.path, "deleted": $0.file.deletedAt.map(iso) ?? NSNull(),
                          "size": $0.latest.size, "lastSaved": iso($0.latest.takenAt),
                          "movedAway": $0.file.deletedKind == 1] as [String: Any] })
    } else if items.isEmpty {
        out(cmd == "find" ? "nothing matches “\(match)”." : "nothing deleted recently. 🎉")
    } else {
        out(pad("ID", 7) + pad(cmd == "find" ? "STATE" : "DELETED", 20) + rpad("SIZE", 10) + "  PATH")
        for it in items {
            let id = "#\(it.file.id)"
            var when = "live"
            if let d = it.file.deletedAt { when = Fmt.ago(d) + (it.file.deletedKind == 1 ? " ↗" : "") }
            out(pad(id, 7) + pad(when, 20) + rpad(Fmt.bytes(it.latest.size), 10) + "  " + tilde(it.file.path))
        }
        out("\nRestore with: mulligan restore #ID      (↗ = moved out of the folder, e.g. to the Trash)")
    }

case "history":
    let a = Args(argv)
    let e = openEngine()
    guard let target = a.positional.first, let f = resolveFile(e, target) else { fail("no saved history for that path") }
    let vs = e.store.versions(fileID: f.id)
    if a.has("json") {
        json(vs.map { ["versionId": $0.id, "saved": iso($0.takenAt), "size": $0.size] as [String: Any] })
    } else {
        out("\(tilde(f.path))" + (f.deletedAt != nil ? "   (deleted \(Fmt.ago(f.deletedAt!)))" : ""))
        out(pad("VERSION", 9) + pad("SAVED", 18) + rpad("SIZE", 10))
        for v in vs { out(pad("\(v.id)", 9) + pad(Fmt.stamp(v.takenAt), 18) + rpad(Fmt.bytes(v.size), 10)) }
        out("\nRestore one with: mulligan restore \(tilde(f.path)) --version ID")
    }

case "restore":
    let a = Args(argv, valueFlags: ["version", "at", "to"])
    let e = openEngine()
    guard let target = a.positional.first, let f = resolveFile(e, target) else { fail("I have no saved copy of that. Try `mulligan find <part of the name>`.") }
    var version: VersionRecord?
    if let v = a.flags["version"], let id = Int64(v) { version = e.store.version(id: id); if version?.fileID != f.id { fail("version \(v) belongs to another file") } }
    else if let w = a.flags["at"] {
        guard let d = Fmt.parseWhen(w) else { fail("cannot understand --at \(w)") }
        version = e.store.version(fileID: f.id, asOf: d)
        if version == nil { fail("nothing was saved for that file before \(Fmt.stamp(d))") }
    } else { version = e.store.latestVersion(fileID: f.id) }
    guard let v = version else { fail("no saved versions") }
    var dest: String?
    if let to = a.flags["to"] {
        let dir = resolvePath(to)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dest = dir + "/" + f.name
    }
    do {
        let written = try Restorer(store: e.store).restore(v, to: dest, replace: a.has("replace"))
        out("restored → \(tilde(written))   (version from \(Fmt.stamp(v.takenAt)), \(Fmt.bytes(v.size)))")
        if written != f.path && dest == nil { out("(something already lives at the original path, so I put the copy next to it)") }
    } catch { fail("\(error)") }

case "restore-tree":
    let a = Args(argv, valueFlags: ["at", "to", "since"])
    let e = openEngine()
    guard let folder = a.positional.first else { fail("usage: mulligan restore-tree <folder> (--deleted [--since WHEN] | --at WHEN) [--to DIR]") }
    let prefix = resolvePath(folder)
    let dest = a.flags["to"].map(resolvePath)
    let rep: RestoreReport
    var when = Date()
    if a.has("deleted") {
        var since: Date?
        if let w = a.flags["since"] { guard let d = Fmt.parseWhen(w) else { fail("cannot understand --since \(w)") }; since = d }
        rep = Restorer(store: e.store).restoreDeleted(prefix: prefix, since: since, destination: dest)
    } else {
        guard let w = a.flags["at"], let d = Fmt.parseWhen(w) else { fail("give --deleted (everything that went missing) or --at WHEN (the folder as it was then, e.g. --at 2h or --at \"yesterday 18:00\")") }
        when = d
        rep = Restorer(store: e.store).restoreTree(prefix: prefix, asOf: when, destination: dest, replaceChanged: a.has("replace-changed"))
    }
    out("restored \(rep.restored.count) file\(rep.restored.count == 1 ? "" : "s")" +
        (rep.alongside.isEmpty ? "" : ", \(rep.alongside.count) next to existing ones") +
        (rep.skipped.isEmpty ? "" : ", \(rep.skipped.count) already fine") + (a.has("deleted") ? "" : " as of \(Fmt.stamp(when))") +
        (dest.map { " into \(tilde($0))" } ?? ""))
    for f in rep.failures.prefix(10) { err("  failed: \(f)") }
    if !rep.failures.isEmpty { exit(2) }

case "run":
    guard let dd = argv.firstIndex(of: "--") else { fail("usage: mulligan run [--label TEXT] -- <command…>") }
    let opts = Args(Array(argv[..<dd]), valueFlags: ["label"])
    let command = Array(argv[(dd + 1)...])
    guard !command.isEmpty else { fail("nothing to run after --") }
    let e = openEngine()
    guard !e.roots.isEmpty else { fail("no folders are protected yet: mulligan config add-root ~/Documents") }
    err("mulligan: saving a snapshot of \(e.roots.map(tilde).joined(separator: ", ")) …")
    let run = e.beginRun(label: opts.flags["label"] ?? Fs.lastComponent(command[0]), command: command.joined(separator: " "))
    signal(SIGINT) { _ in } // let Ctrl-C reach the child; we still want to summarise afterwards
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = command
    do { try p.run() } catch { fail("cannot start \(command[0]): \(error)") }
    p.waitUntilExit()
    let s = e.endRun(run, status: Int(p.terminationStatus))
    err("")
    if s.isClean && s.created.isEmpty {
        err("mulligan: `\(command[0])` finished (exit \(p.terminationStatus)); no protected files changed.")
    } else {
        err("mulligan: `\(command[0])` finished (exit \(p.terminationStatus)). In your protected folders it:")
        err("   deleted   \(s.deleted.count) file\(s.deleted.count == 1 ? "" : "s")")
        err("   modified  \(s.modified.count) file\(s.modified.count == 1 ? "" : "s")")
        err("   created   \(s.created.count) file\(s.created.count == 1 ? "" : "s")")
        for d in s.deleted.prefix(5) { err("     − \(tilde(d.file.path))") }
        if s.deleted.count > 5 { err("     … and \(s.deleted.count - 5) more deleted") }
        for m in s.modified.prefix(5) { err("     ~ \(tilde(m.path))") }
        if !s.isClean { err("   Undo it with:  mulligan undo-run \(run.id)") }
    }
    exit(p.terminationStatus)

case "undo-run":
    let a = Args(argv)
    let e = openEngine()
    let runs = e.store.runs(limit: 1000)
    let pick = a.positional.first ?? "last"
    guard let run = pick == "last" ? runs.first : runs.first(where: { "\($0.id)" == pick }) else { fail("no such run (see `mulligan runs`)") }
    let s = e.summary(for: run)
    out("Run #\(run.id) “\(run.label)” started \(Fmt.ago(run.startedAt)):")
    out("   \(s.deleted.count) deleted, \(s.modified.count) modified, \(s.created.count) created (created files are left alone)")
    if s.isClean { out("nothing to undo."); exit(0) }
    for d in s.deleted.prefix(10) { out("   − \(tilde(d.file.path))") }
    for m in s.modified.prefix(10) { out("   ~ \(tilde(m.path))") }
    if !a.has("yes") && !ask("Put \(s.deleted.count + s.modified.count) files back as they were before the run?") { out("nothing changed."); exit(0) }
    let rep = e.undo(run: run)
    out("restored \(rep.restored.count) file\(rep.restored.count == 1 ? "" : "s")" + (rep.alongside.isEmpty ? "" : " (\(rep.alongside.count) next to existing ones)"))
    for f in rep.failures.prefix(10) { err("  failed: \(f)") }
    if !rep.failures.isEmpty { exit(2) }

case "runs":
    let a = Args(argv)
    let e = openEngine()
    let runs = e.store.runs(limit: 20)
    if a.has("json") {
        json(runs.map { ["id": $0.id, "label": $0.label, "command": $0.command, "started": iso($0.startedAt)] as [String: Any] })
    } else if runs.isEmpty { out("no runs yet. Try: mulligan run -- <command>") }
    else {
        out(pad("RUN", 6) + pad("STARTED", 20) + pad("CHANGES", 22) + "COMMAND")
        for r in runs {
            let s = e.summary(for: r)
            out(pad("#\(r.id)", 6) + pad(Fmt.ago(r.startedAt), 20) + pad("−\(s.deleted.count) ~\(s.modified.count) +\(s.created.count)", 22) + r.command)
        }
    }

case "checkpoint":
    let e = openEngine()
    let label = argv.isEmpty ? "checkpoint" : argv.joined(separator: " ")
    let run = e.beginRun(label: label, command: "(checkpoint)")
    e.store.finishRun(id: run.id, at: Date(), status: 0)
    out("checkpoint #\(run.id) “\(label)” saved. Go back to it any time with: mulligan undo-run \(run.id)")

case "forget":
    let a = Args(argv)
    let e = openEngine()
    var ids: [Int64] = []
    if a.has("all-deleted") { ids = e.store.deleted(limit: 1_000_000, minLifetime: 0).map { $0.file.id } }
    else {
        guard let t = a.positional.first, let f = resolveFile(e, t) else { fail("no saved copy of that") }
        ids = [f.id]
    }
    guard !ids.isEmpty else { out("nothing to forget."); exit(0) }
    if !a.has("yes") && !ask("Permanently erase \(ids.count) file\(ids.count == 1 ? "" : "s") from the vault? This cannot be undone.") { out("nothing changed."); exit(0) }
    var freed: Int64 = 0
    for id in ids {
        freed += e.store.versions(fileID: id).reduce(0) { $0 + $1.size }
        for b in e.store.deleteFile(id: id) { unlink(e.paths.blobs.appendingPathComponent(b).path) }
    }
    out("erased \(ids.count) file\(ids.count == 1 ? "" : "s") (up to \(Fmt.bytes(freed))).")

case "prune":
    let e = openEngine()
    let r = e.prune()
    out("released up to \(Fmt.bytes(r.bytesReleased)): \(r.versionsRemoved) old versions, \(r.filesPurged) expired deleted files, \(r.orphansRemoved) orphans")

case "config":
    let paths = Paths.standard()
    try? paths.ensureDirectories()
    var cfg = Config.load(from: paths.config)
    if !FileManager.default.fileExists(atPath: paths.config.path) { cfg.roots = Config.defaultRoots() }
    let sub = argv.first ?? "show"
    switch sub {
    case "show":
        out("roots:              " + (cfg.roots.isEmpty ? "(none)" : cfg.roots.map(tilde).joined(separator: ", ")))
        out("keepDeletedDays:    \(cfg.keepDeletedDays)")
        out("keepHistoryDays:    \(cfg.keepHistoryDays)")
        out("budgetGB:           \(cfg.budgetGB == 0 ? "auto (10% of disk, max 50)" : String(cfg.budgetGB))")
        out("lowDiskFreeGB:      \(cfg.lowDiskFreeGB)")
        out("massDeleteThreshold:\(cfg.massDeleteThreshold) files within \(cfg.massDeleteWindowSeconds)s")
        out("paused:             \(cfg.paused)")
        out("config file:        \(paths.config.path)")
    case "add-root":
        guard argv.count > 1 else { fail("usage: mulligan config add-root DIR") }
        let p = resolvePath(argv[1])
        guard Fs.lstat(p)?.isDirectory == true else { fail("\(p) is not a folder") }
        if !cfg.roots.contains(p) { cfg.roots.append(p) }
        try cfg.save(to: paths.config)
        out("now protecting \(tilde(p)). Restart the watcher (or the app) to pick it up.")
    case "remove-root":
        guard argv.count > 1 else { fail("usage: mulligan config remove-root DIR") }
        let p = resolvePath(argv[1])
        cfg.roots.removeAll { $0 == p || Fs.canonical($0) == p }
        try cfg.save(to: paths.config)
        out("no longer watching \(tilde(p)); its saved history stays until retention removes it.")
    case "set":
        guard argv.count > 2 else { fail("usage: mulligan config set KEY VALUE") }
        let v = argv[2]
        switch argv[1] {
        case "keepDeletedDays": cfg.keepDeletedDays = Int(v) ?? cfg.keepDeletedDays
        case "keepHistoryDays": cfg.keepHistoryDays = Int(v) ?? cfg.keepHistoryDays
        case "budgetGB": cfg.budgetGB = Double(v) ?? cfg.budgetGB
        case "lowDiskFreeGB": cfg.lowDiskFreeGB = Double(v) ?? cfg.lowDiskFreeGB
        case "massDeleteThreshold": cfg.massDeleteThreshold = Int(v) ?? cfg.massDeleteThreshold
        case "paused": cfg.paused = (v == "true" || v == "1")
        case "notify": cfg.notify = (v == "true" || v == "1")
        default: fail("unknown key \(argv[1])")
        }
        try cfg.save(to: paths.config)
        out("saved.")
    default: fail("unknown config command \(sub)")
    }

case "install-agent":
    let a = Args(argv)
    guard let exe = Bundle.main.executablePath else { fail("cannot find my own path") }
    let paths = Paths.standard()
    let plist = LaunchAgent.plist(executable: exe, logPath: paths.support.appendingPathComponent("watch.log").path)
    if a.has("print") { out(plist); exit(0) }
    try? paths.ensureDirectories()
    let url = LaunchAgent.plistURL
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do { try plist.write(to: url, atomically: true, encoding: .utf8) } catch { fail("cannot write \(url.path): \(error)") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["bootstrap", "gui/\(getuid())", url.path]
    try? p.run(); p.waitUntilExit()
    out("installed \(tilde(url.path)); Mulligan now starts at login. (launchctl exit \(p.terminationStatus))")

case "uninstall-agent":
    let url = LaunchAgent.plistURL
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["bootout", "gui/\(getuid())/\(LaunchAgent.label)"]
    try? p.run(); p.waitUntilExit()
    try? FileManager.default.removeItem(at: url)
    out("removed the login agent. Your saved history is untouched.")

case "doctor":
    let e = openEngine(createConfig: false)
    var problems = 0
    func ok(_ s: String) { out("  ✓ " + s) }
    func warn(_ s: String) { problems += 1; out("  ! " + s) }
    out("Mulligan doctor")
    var fsStat = statfs()
    if statfs(e.paths.vault.path, &fsStat) == 0 {
        let type = withUnsafePointer(to: &fsStat.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
        type == "apfs" ? ok("vault is on an APFS volume (instant, space-free clones)") : warn("vault is on \(type), not APFS: every save would be a full copy")
    }
    var vaultDev = Darwin.stat()
    stat(e.paths.vault.path, &vaultDev)
    if e.roots.isEmpty { warn("no folders are protected: mulligan config add-root ~/Documents") }
    for r in e.roots {
        var st = Darwin.stat()
        if stat(r, &st) != 0 { warn("\(tilde(r)) cannot be read (grant Full Disk Access to your terminal or Mulligan.app)"); continue }
        if st.st_dev != vaultDev.st_dev { warn("\(tilde(r)) is on a different disk than the vault, so clones are impossible (copies are used, up to 256 MB per file)") }
        else { ok("\(tilde(r)) is on the same volume as the vault") }
        if access(r, R_OK) != 0 { warn("\(tilde(r)) is not readable") }
    }
    ProcessLock.isHeld(path: e.paths.lock.path) ? ok("a watcher is running") : warn("no watcher is running (open Mulligan.app, `mulligan watch`, or `mulligan install-agent`)")
    let free = Fs.freeBytes(at: e.paths.vault.path)
    free > 15_000_000_000 ? ok("\(Fmt.bytes(free)) free on this disk") : warn("only \(Fmt.bytes(free)) free; Mulligan will release old versions to keep the disk usable")
    let tm = Process()
    let pipe = Pipe()
    tm.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil"); tm.arguments = ["destinationinfo"]; tm.standardOutput = pipe; tm.standardError = pipe
    try? tm.run(); tm.waitUntilExit()
    let tmOut = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if tmOut.contains("No destinations configured") {
        warn("Time Machine has no backup disk. Mulligan undoes deletions and overwrites, but it is NOT a backup: a dead or stolen Mac takes the vault with it.")
    } else { ok("Time Machine is configured (keep it: Mulligan complements it)") }
    out(problems == 0 ? "All good." : "\(problems) thing\(problems == 1 ? "" : "s") to look at.")

default:
    err("mulligan: unknown command “\(cmd)”\n")
    err(usage)
    exit(64)
}
