import SwiftUI
import AppKit
import MulliganCore
import UserNotifications
import ServiceManagement
import UniformTypeIdentifiers

extension AlertRecord: Identifiable {}
extension DeletedItem: Identifiable { public var id: Int64 { file.id } }

@MainActor
final class AppModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case deleted = "Deleted", search = "Find", settings = "Settings"
        var id: String { rawValue }
    }

    let engine: Engine
    let store: Store
    let paths: Paths
    var onAlert: (() -> Void)?

    @Published var config: Config
    @Published var status = EngineStatus()
    @Published var deleted: [DeletedItem] = []
    @Published var alerts: [AlertRecord] = []
    @Published var tab: Tab = .deleted
    @Published var query = "" { didSet { runSearch() } }
    @Published var results: [DeletedItem] = []
    @Published var expanded: Set<Int64> = []
    @Published var versionsByFile: [Int64: [VersionRecord]] = [:]
    @Published var message: String?
    @Published var isWatcher = true
    @Published var noBackup = false
    @Published var needsOnboarding = false
    @Published var onboardingChoices: [String: Bool] = [:]
    @Published var loginItemEnabled = false

    private var lock: ProcessLock?
    private var refreshTimer: Timer?
    private var messageTask: Task<Void, Never>?
    var popoverOpen = false

    init(engine: Engine, paths: Paths, config: Config, needsOnboarding: Bool = false) {
        self.engine = engine
        self.store = engine.store
        self.paths = paths
        self.config = config
        self.needsOnboarding = needsOnboarding
        if needsOnboarding {
            for r in Config.defaultRoots() { onboardingChoices[r] = true }
        }
    }

    static func makeDefault() throws -> AppModel {
        let paths = Paths.standard()
        try paths.ensureDirectories()
        let exists = FileManager.default.fileExists(atPath: paths.config.path)
        var cfg = Config.load(from: paths.config)
        if !exists { cfg.roots = [] }
        let engine = try Engine(paths: paths, config: cfg)
        return AppModel(engine: engine, paths: paths, config: cfg, needsOnboarding: !exists || cfg.roots.isEmpty)
    }

    // MARK: lifecycle

    func start() {
        lock = ProcessLock(path: paths.lock.path)
        isWatcher = (lock != nil)
        engine.onEvent = { [weak self] ev in
            guard case .alert(let a) = ev else { return }
            Task { @MainActor in self?.handleAlert(a) }
        }
        if isWatcher && !needsOnboarding { engine.start() }
        loginItemEnabled = (SMAppService.mainApp.status == .enabled)
        checkBackupState()
        setupNotifications()
        refresh()
        scheduleTimer()
    }

    func scheduleTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: popoverOpen ? 1.5 : 6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let engine = self.engine, store = self.store
        Task.detached(priority: .userInitiated) { [model = self] in
            let st = engine.status()
            let del = store.deleted(limit: 300)
            let al = store.alerts(limit: 5, unhandledOnly: true)
            await MainActor.run { model.status = st; model.deleted = del; model.alerts = al }
        }
    }

    /// Synchronous refresh (used when rendering screenshots).
    func refreshNow() {
        status = engine.status()
        deleted = store.deleted(limit: 300)
        alerts = store.alerts(limit: 5, unhandledOnly: true)
    }

    private func handleAlert(_ a: AlertRecord) {
        refresh()
        onAlert?()
        guard config.notify, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let c = UNMutableNotificationContent()
        c.title = "\(a.count) files just disappeared"
        c.body = "From \(Fs.lastComponent(a.root)). They're safe in Mulligan — click to restore."
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "mass-\(a.id)", content: c, trigger: nil))
    }

    private func setupNotifications() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func checkBackupState() {
        Task.detached { [model = self] in
            let p = Process(); let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil"); p.arguments = ["destinationinfo"]
            p.standardOutput = pipe; p.standardError = pipe
            try? p.run(); p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let none = out.contains("No destinations configured")
            await MainActor.run { model.noBackup = none }
        }
    }

    // MARK: messages

    func toast(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if !Task.isCancelled { self?.message = nil }
        }
    }

    // MARK: restore

    func restore(_ items: [DeletedItem]) {
        guard !items.isEmpty else { return }
        let store = self.store
        Task.detached { [model = self] in
            var ok = 0, alongside = 0, failed = 0
            let r = Restorer(store: store)
            for it in items {
                do { let w = try r.restore(it.latest); if w == it.file.path { ok += 1 } else { alongside += 1 } }
                catch { failed += 1 }
            }
            let text = failed == items.count ? "Couldn't restore — the saved copy is gone."
                : "Restored \(ok + alongside) file\(ok + alongside == 1 ? "" : "s")" + (alongside > 0 ? " (\(alongside) next to existing files)" : "") + (failed > 0 ? ", \(failed) failed" : "")
            await MainActor.run { model.toast(text); model.refresh(); model.runSearch() }
        }
    }

    func restore(_ v: VersionRecord, alongside: Bool) {
        do {
            let w = try Restorer(store: store).restore(v)
            toast("Restored → " + (w as NSString).abbreviatingWithTildeInPath)
        } catch { toast("Couldn't restore: \(error)") }
        refresh()
    }

    func restoreAll(for alert: AlertRecord) {
        let since = alert.at.addingTimeInterval(-Double(config.massDeleteWindowSeconds) - 5)
        let items = store.deleted(limit: 1_000_000, since: since, minLifetime: 0)
            .filter { $0.file.path.hasPrefix(alert.root + "/") && $0.file.deletedKind == 0 }
        restore(items)
        store.markAlertHandled(id: alert.id)
        refresh()
    }

    func dismiss(_ alert: AlertRecord) {
        store.markAlertHandled(id: alert.id)
        refresh()
    }

    func erase(_ item: DeletedItem) {
        for b in store.deleteFile(id: item.file.id) { unlink(paths.blobs.appendingPathComponent(b).path) }
        toast("Erased from Mulligan for good.")
        refresh(); runSearch()
    }

    func revealOriginalFolder(_ item: DeletedItem) {
        let folder = item.file.folder
        if FileManager.default.fileExists(atPath: folder) { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
        else { toast("That folder no longer exists; restoring will recreate it.") }
    }

    // MARK: search

    func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = []; return }
        let store = self.store
        Task.detached { [model = self] in
            let r = store.search(q, limit: 60)
            await MainActor.run { if model.query.trimmingCharacters(in: .whitespaces) == q { model.results = r } }
        }
    }

    func toggleExpand(_ item: DeletedItem) {
        if expanded.contains(item.file.id) { expanded.remove(item.file.id); return }
        expanded.insert(item.file.id)
        versionsByFile[item.file.id] = store.versions(fileID: item.file.id)
    }

    // MARK: settings

    func update(_ change: (inout Config) -> Void) {
        var c = config
        change(&c)
        config = c
        try? c.save(to: paths.config)
        engine.apply(config: c)
        refresh()
    }

    func togglePause() { update { $0.paused.toggle() } }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Protect"
        panel.message = "Choose folders for Mulligan to keep safe."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let picked = panel.urls.map { $0.path }
        if needsOnboarding {
            for p in picked { onboardingChoices[p] = true }
        } else {
            update { c in for p in picked where !c.roots.contains(p) { c.roots.append(p) } }
        }
    }

    func removeFolder(_ path: String) { update { $0.roots.removeAll { $0 == path } } }

    func finishOnboarding() {
        let chosen = onboardingChoices.filter { $0.value }.map { $0.key }.sorted()
        var c = config
        c.roots = chosen
        config = c
        try? c.save(to: paths.config)
        engine.apply(config: c)
        needsOnboarding = false
        if isWatcher { engine.start() }
        refresh()
    }

    func scanNow() {
        let engine = self.engine
        toast("Checking your folders…")
        Task.detached { [model = self] in
            let s = engine.scan()
            await MainActor.run { model.toast("Checked \(s.visited) files; saved \(s.snapshotted) new or changed."); model.refresh() }
        }
    }

    func freeSpaceNow() {
        let engine = self.engine
        Task.detached { [model = self] in
            let r = engine.prune()
            await MainActor.run {
                model.toast(r.bytesReleased > 0 ? "Released up to \(Fmt.bytes(r.bytesReleased))." : "Nothing needed releasing.")
                model.refresh()
            }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemEnabled = (SMAppService.mainApp.status == .enabled)
        } catch {
            loginItemEnabled = false
            toast("Couldn't change login item — move Mulligan to Applications first.")
        }
    }
}

// MARK: - file icons

enum FileIcons {
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]
    static func icon(for path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        if let c = cache[ext] { return c }
        let img: NSImage
        if let ut = UTType(filenameExtension: ext) { img = NSWorkspace.shared.icon(for: ut) }
        else { img = NSWorkspace.shared.icon(for: .data) }
        cache[ext] = img
        return img
    }
}
