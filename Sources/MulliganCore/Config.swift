import Foundation

public struct Paths {
    public let support: URL
    public var vault: URL { support.appendingPathComponent("Vault", isDirectory: true) }
    public var blobs: URL { vault.appendingPathComponent("blobs", isDirectory: true) }
    public var db: URL { support.appendingPathComponent("index.sqlite") }
    public var config: URL { support.appendingPathComponent("config.json") }
    public var lock: URL { support.appendingPathComponent("watcher.lock") }

    public init(support: URL) { self.support = support }

    /// `MULLIGAN_HOME` overrides the location (used by tests and for portable setups).
    public static func standard() -> Paths {
        if let env = ProcessInfo.processInfo.environment["MULLIGAN_HOME"], !env.isEmpty {
            return Paths(support: URL(fileURLWithPath: env, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Paths(support: base.appendingPathComponent("Mulligan", isDirectory: true))
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Old versions must not be copied into Time Machine backups or indexed by Spotlight.
        var v = vault
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? v.setResourceValues(rv)
        let marker = vault.appendingPathComponent(".metadata_never_index")
        if !fm.fileExists(atPath: marker.path) { fm.createFile(atPath: marker.path, contents: Data()) }
    }
}

public struct Config: Codable, Equatable {
    public var roots: [String] = []
    public var excludeNames: [String] = Config.defaultExcludeNames
    public var excludeFileSuffixes: [String] = Config.defaultExcludeFileSuffixes
    public var excludeDirSuffixes: [String] = Config.defaultExcludeDirSuffixes
    /// How long a deleted file stays recoverable.
    public var keepDeletedDays: Int = 30
    /// How long earlier versions of files that still exist are kept.
    public var keepHistoryDays: Int = 14
    /// Cap on disk held by old versions and deleted files. 0 = automatic (10 % of the disk, at most 50 GB).
    public var budgetGB: Double = 0
    /// When free disk space drops below this, Mulligan gives space back, oldest first.
    public var lowDiskFreeGB: Double = 8
    public var maxFileGB: Double = 20
    public var massDeleteThreshold: Int = 25
    public var massDeleteWindowSeconds: Int = 60
    public var paused: Bool = false
    public var notify: Bool = true
    /// Multiplies the minimum gap between versions of one file (1 = default, 0 = no throttling).
    public var throttleScale: Double = 1

    public init() {}

    enum CodingKeys: String, CodingKey {
        case roots, excludeNames, excludeFileSuffixes, excludeDirSuffixes, keepDeletedDays, keepHistoryDays
        case budgetGB, lowDiskFreeGB, maxFileGB, massDeleteThreshold, massDeleteWindowSeconds, paused, notify, throttleScale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? d.roots
        excludeNames = try c.decodeIfPresent([String].self, forKey: .excludeNames) ?? d.excludeNames
        excludeFileSuffixes = try c.decodeIfPresent([String].self, forKey: .excludeFileSuffixes) ?? d.excludeFileSuffixes
        excludeDirSuffixes = try c.decodeIfPresent([String].self, forKey: .excludeDirSuffixes) ?? d.excludeDirSuffixes
        keepDeletedDays = try c.decodeIfPresent(Int.self, forKey: .keepDeletedDays) ?? d.keepDeletedDays
        keepHistoryDays = try c.decodeIfPresent(Int.self, forKey: .keepHistoryDays) ?? d.keepHistoryDays
        budgetGB = try c.decodeIfPresent(Double.self, forKey: .budgetGB) ?? d.budgetGB
        lowDiskFreeGB = try c.decodeIfPresent(Double.self, forKey: .lowDiskFreeGB) ?? d.lowDiskFreeGB
        maxFileGB = try c.decodeIfPresent(Double.self, forKey: .maxFileGB) ?? d.maxFileGB
        massDeleteThreshold = try c.decodeIfPresent(Int.self, forKey: .massDeleteThreshold) ?? d.massDeleteThreshold
        massDeleteWindowSeconds = try c.decodeIfPresent(Int.self, forKey: .massDeleteWindowSeconds) ?? d.massDeleteWindowSeconds
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? d.paused
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? d.notify
        throttleScale = try c.decodeIfPresent(Double.self, forKey: .throttleScale) ?? d.throttleScale
    }

    public static let defaultExcludeNames = [
        ".DS_Store", ".localized", ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems",
        "node_modules", ".venv", "venv", "__pycache__", ".cache", "DerivedData", ".build", "Pods",
        ".gradle", ".next", ".parcel-cache", ".pytest_cache", ".mypy_cache", ".tox",
    ]
    public static let defaultExcludeFileSuffixes = [".tmp", ".temp", ".part", ".crdownload", ".download", ".swp", ".swx", ".partial"]
    public static let defaultExcludeDirSuffixes = [
        ".photoslibrary", ".sparsebundle", ".sparseimage", ".vmwarevm", ".pvm", ".utm", ".app", ".xcarchive",
        ".musiclibrary", ".tvlibrary", ".imovielibrary", ".fcpbundle",
    ]

    public static func defaultRoots() -> [String] {
        let home = NSHomeDirectory()
        return ["Desktop", "Documents", "Downloads"]
            .map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    public static func load(from url: URL) -> Config {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return cfg
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: url, options: .atomic)
    }
}

/// Which files are worth versioning, and how often.
public struct Rules {
    public var excludeNames: Set<String>
    public var excludeFileSuffixes: [String]
    public var excludeDirSuffixes: [String]
    public var maxFileBytes: Int64
    public var throttleScale: Double

    public init(config: Config) {
        throttleScale = config.throttleScale
        excludeNames = Set(config.excludeNames)
        excludeFileSuffixes = config.excludeFileSuffixes.map { $0.lowercased() }
        excludeDirSuffixes = config.excludeDirSuffixes.map { $0.lowercased() }
        maxFileBytes = Int64(config.maxFileGB * 1_000_000_000)
    }

    public func skipDir(name: String) -> Bool {
        if excludeNames.contains(name) { return true }
        let l = name.lowercased()
        return excludeDirSuffixes.contains { l.hasSuffix($0) }
    }

    public func skipFile(name: String) -> Bool {
        if excludeNames.contains(name) || name.hasPrefix("~$") || name.hasPrefix(".~lock.") { return true }
        let l = name.lowercased()
        return excludeFileSuffixes.contains { l.hasSuffix($0) }
    }

    /// True if any directory between `root` and the file is excluded, or the file name itself is.
    public func excluded(path: String, root: String) -> Bool {
        guard path.hasPrefix(root) else { return true }
        let rel = path.dropFirst(root.count)
        let parts = rel.split(separator: "/").map(String.init)
        guard let last = parts.last else { return false }
        for p in parts.dropLast() where skipDir(name: p) { return true }
        return skipFile(name: last)
    }

    /// Minimum gap between two versions of the same file. Big, fast-changing files (VM images, databases)
    /// would otherwise keep every changed block alive.
    public func minInterval(size: Int64) -> TimeInterval {
        let base: TimeInterval = size < 10_000_000 ? 20 : (size < 1_000_000_000 ? 300 : 1800)
        return base * throttleScale
    }

    public func maxVersions(size: Int64) -> Int {
        if size < 10_000_000 { return 40 }
        if size < 1_000_000_000 { return 15 }
        return 3
    }
}
