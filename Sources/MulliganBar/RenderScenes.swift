import SwiftUI
import AppKit
import MulliganCore

/// Builds a realistic demo vault with the real engine and renders each screen offscreen to PNG,
/// so the UI can be inspected without a display or screen-recording permission.
@MainActor
enum RenderScenes {
    @MainActor
    final class Demo {
        let base: String
        let engine: Engine
        var clock: Date
        let real = Date()

        init(mass: Bool) throws {
            let b = Fs.canonical(NSTemporaryDirectory()) + "/mulligan-demo-" + UUID().uuidString
            base = b
            try FileManager.default.createDirectory(atPath: b, withIntermediateDirectories: true)
            var cfg = Config()
            cfg.roots = ["Documents", "Desktop", "Downloads"].map { b + "/" + $0 }
            for r in cfg.roots { try FileManager.default.createDirectory(atPath: r, withIntermediateDirectories: true) }
            cfg.throttleScale = 0; cfg.lowDiskFreeGB = 0
            engine = try Engine(paths: Paths(support: URL(fileURLWithPath: base + "/.support")), config: cfg)
            let start = Date()
            clock = start.addingTimeInterval(-5 * 86400)
            engine.now = { [unowned self] in self.clock }
            engine.freeSpace = { _ in 120_000_000_000 }
            engine.ephemeralLifetime = 0
            PathDisplay.prefixes = [(base, "~")]
            try populate(mass: mass)
        }

        func file(_ rel: String, kb: Int) -> String {
            let p = base + "/" + rel
            try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? Data(repeating: UInt8.random(in: 1...250), count: kb * 1024).write(to: URL(fileURLWithPath: p))
            return p
        }

        func delete(_ p: String, at when: Date, moved: Bool = false) {
            clock = when
            try? FileManager.default.removeItem(atPath: p)
            engine.ingest(events: [FSEvent(path: p, flags: moved ? EvFlag.renamed | EvFlag.isFile : EvFlag.removed | EvFlag.isFile)])
        }

        func populate(mass: Bool) throws {
            var thesis: [String] = []
            let chapters = ["Chapter 1 - Introduction", "Chapter 2 - Literature Review", "Chapter 3 - Methods", "Chapter 4 - Results",
                            "Chapter 5 - Discussion", "Chapter 6 - Conclusion", "Abstract", "Acknowledgements"]
            for c in chapters { thesis.append(file("Documents/Thesis/\(c).docx", kb: 180 + Int.random(in: 0...400))) }
            for i in 1...10 { thesis.append(file("Documents/Thesis/figures/figure-\(i).png", kb: 300 + i * 40)) }
            for i in 1...12 { thesis.append(file("Documents/Thesis/data/run-\(String(format: "%03d", i)).csv", kb: 90 + i * 7)) }
            thesis.append(file("Documents/Thesis/references.bib", kb: 64))
            thesis.append(file("Documents/Thesis/Defense slides.key", kb: 4200))
            thesis.append(file("Documents/Thesis/notes.txt", kb: 2))
            let w2 = file("Documents/Taxes 2025/W-2 Acme Corp.pdf", kb: 240)
            let ret = file("Documents/Taxes 2025/Federal Return 2025.pdf", kb: 1800)
            let budget = file("Desktop/Household Budget.xlsx", kb: 96)
            let shot = file("Desktop/Screenshot 2026-11-16 at 9.41.02 AM.png", kb: 1300)
            let dmg = file("Downloads/Slack-installer.dmg", kb: 8800)
            let inv = file("Downloads/invoice-4821.pdf", kb: 150)
            _ = file("Desktop/keep-me.txt", kb: 1)
            engine.scan()

            // a few edits so the history view has something to show
            clock = real.addingTimeInterval(-3 * 86400)
            try? Data(repeating: 9, count: 210 * 1024).write(to: URL(fileURLWithPath: thesis[0])); engine.snapshotNow(thesis[0])
            clock = real.addingTimeInterval(-26 * 3600)
            try? Data(repeating: 7, count: 260 * 1024).write(to: URL(fileURLWithPath: thesis[0])); engine.snapshotNow(thesis[0])
            clock = real.addingTimeInterval(-20 * 60)
            try? Data(repeating: 5, count: 330 * 1024).write(to: URL(fileURLWithPath: thesis[0])); engine.snapshotNow(thesis[0])

            delete(dmg, at: real.addingTimeInterval(-4 * 86400 + 3600))
            delete(inv, at: real.addingTimeInterval(-2 * 86400))
            delete(budget, at: real.addingTimeInterval(-19 * 3600))
            delete(w2, at: real.addingTimeInterval(-3 * 3600))
            delete(ret, at: real.addingTimeInterval(-3 * 3600 + 40))
            delete(shot, at: real.addingTimeInterval(-22 * 60), moved: true)
            if mass {
                clock = real.addingTimeInterval(-110)
                try? FileManager.default.removeItem(atPath: base + "/Documents/Thesis")
                engine.ingest(events: thesis.map { FSEvent(path: $0, flags: EvFlag.removed | EvFlag.isFile) })
            }
            clock = real
        }

        func model(onboarding: Bool = false) -> AppModel {
            let m = AppModel(engine: engine, paths: engine.paths, config: engine.config, needsOnboarding: onboarding)
            m.refreshNow()
            return m
        }
    }

    static func renderPNG<V: View>(_ view: V, size: CGSize, to path: String, dark: Bool = false) {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: CGRect(origin: CGPoint(x: -6000, y: -6000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.contentView = host
        win.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        win.orderOut(nil)
    }

    static func run(outDir: String) {
        NSApplication.shared.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let size = CGSize(width: 420, height: 580)

        // 1. mass deletion in progress
        if let demo = try? Demo(mass: true) {
            defer { try? FileManager.default.removeItem(atPath: demo.base) }
            let m = demo.model()
            renderPNG(PopoverView(model: m), size: size, to: outDir + "/1-alert.png")
            // 2. search with history expanded
            m.tab = .search
            m.query = "chapter 1"
            m.results = demo.engine.store.search("chapter 1")
            if let first = m.results.first { m.toggleExpand(first) }
            renderPNG(PopoverView(model: m), size: size, to: outDir + "/2-search-history.png")
            // 3. settings
            m.tab = .settings; m.noBackup = true
            renderPNG(PopoverView(model: m), size: size, to: outDir + "/3-settings.png")
            m.tab = .deleted; m.toast("Restored 48 files")
            renderPNG(PopoverView(model: m), size: size, to: outDir + "/6-dark-alert.png", dark: true)
        }
        // 4. calm day
        if let demo = try? Demo(mass: false) {
            defer { try? FileManager.default.removeItem(atPath: demo.base) }
            renderPNG(PopoverView(model: demo.model()), size: size, to: outDir + "/4-deleted-list.png")
            let restored = demo.model()
            restored.toast("Restored 33 files")
            renderPNG(PopoverView(model: restored), size: size, to: outDir + "/7-restored.png")
        }
        // 5. first run
        let paths = Paths(support: URL(fileURLWithPath: NSTemporaryDirectory() + "/mulligan-onb-\(UUID())"))
        if let e = try? Engine(paths: paths, config: Config()) {
            PathDisplay.prefixes = []
            let m = AppModel(engine: e, paths: paths, config: Config(), needsOnboarding: true)
            renderPNG(PopoverView(model: m), size: size, to: outDir + "/5-onboarding.png")
        }
        print("rendered to \(outDir)")
    }

    // MARK: - headless self-test of the model actions the buttons trigger

    static func pump(_ timeout: TimeInterval, until cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return cond()
    }

    static func selftest() -> Int32 {
        NSApplication.shared.setActivationPolicy(.accessory)
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "  ✓ \(what)" : "  ✗ \(what)"); if !ok { failures += 1 } }
        func countFiles(_ dir: String) -> Int {
            (FileManager.default.enumerator(atPath: dir)?.allObjects as? [String] ?? []).filter { !$0.hasSuffix("/") && FileManager.default.fileExists(atPath: dir + "/" + $0, isDirectory: nil) && !($0 as NSString).pathExtension.isEmpty }.count
        }
        guard let demo = try? Demo(mass: true) else { print("cannot build demo vault"); return 1 }
        defer { try? FileManager.default.removeItem(atPath: demo.base) }
        let m = demo.model()
        let thesis = demo.base + "/Documents/Thesis"

        print("alert flow")
        check(m.alerts.count == 1 && m.alerts[0].count == 33, "the mass deletion shows up as one alert with 33 files")
        check(!FileManager.default.fileExists(atPath: thesis), "(the Thesis folder is really gone)")
        let alert = m.alerts[0]
        m.restoreAll(for: alert)
        let restored = pump(10) { countFiles(thesis) == 33 }
        check(restored, "'Restore all 33' brought back all 33 files (found \(countFiles(thesis)))")
        _ = pump(3) { m.message?.contains("Restored 33") == true }
        check(m.message?.contains("Restored 33") == true, "the confirmation toast says so")
        _ = pump(3) { m.alerts.isEmpty }
        check(m.alerts.isEmpty, "the alert is cleared afterwards")

        print("search and history")
        m.query = "household budget"
        _ = pump(5) { !m.results.isEmpty }
        check(m.results.first?.file.name == "Household Budget.xlsx", "searching finds a deleted file by name")
        if let it = m.results.first {
            m.toggleExpand(it)
            check(!(m.versionsByFile[it.file.id] ?? []).isEmpty, "expanding a result lists its versions")
            if let v = m.versionsByFile[it.file.id]?.first {
                m.restore(v, alongside: false)
                check(FileManager.default.fileExists(atPath: it.file.path), "restoring a version puts the file back")
            }
        }

        print("settings")
        m.update { $0.keepDeletedDays = 7; $0.notify = false }
        let saved = Config.load(from: demo.engine.paths.config)
        check(saved.keepDeletedDays == 7 && saved.notify == false, "settings are saved to disk")
        check(demo.engine.config.keepDeletedDays == 7, "and applied to the running engine")
        m.togglePause()
        check(m.config.paused && demo.engine.config.paused, "pause takes effect")
        m.togglePause()
        check(!m.config.paused, "resume takes effect")
        let docs = demo.base + "/Documents"
        m.removeFolder(docs)
        check(!m.config.roots.contains(docs) && !demo.engine.roots.contains(docs), "removing a folder stops watching it")

        print("erase")
        m.refreshNow()
        if let victim = m.deleted.first(where: { $0.file.name == "Slack-installer.dmg" }) {
            let blob = demo.engine.paths.blobs.appendingPathComponent(victim.latest.blob).path
            check(FileManager.default.fileExists(atPath: blob), "(the saved copy exists before erasing)")
            m.erase(victim)
            check(!FileManager.default.fileExists(atPath: blob) && demo.engine.store.file(id: victim.file.id) == nil, "erase removes the saved copy for good")
        } else { check(false, "Slack-installer.dmg is in the deleted list") }

        print("first run")
        let tmp = Fs.canonical(NSTemporaryDirectory()) + "/mulligan-onb-\(UUID())"
        let chosen = tmp + "/Protect Me"
        try? FileManager.default.createDirectory(atPath: chosen, withIntermediateDirectories: true)
        try? "hello".write(toFile: chosen + "/a.txt", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        if let e = try? Engine(paths: Paths(support: URL(fileURLWithPath: tmp + "/support")), config: Config()) {
            let om = AppModel(engine: e, paths: e.paths, config: Config(), needsOnboarding: true)
            om.onboardingChoices = [chosen: true, "/nonexistent-folder": false]
            om.finishOnboarding()
            check(!om.needsOnboarding, "onboarding completes")
            check(Config.load(from: e.paths.config).roots == [chosen], "only the ticked folders are saved")
            let saw = pump(10) { e.store.stats().liveFiles == 1 }
            check(saw, "protection starts immediately: the existing file was saved")
            e.stop()
        } else { check(false, "engine for onboarding") }

        print(failures == 0 ? "APP SELFTEST PASSED" : "APP SELFTEST FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }
}
