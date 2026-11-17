import Foundation
import CryptoKit
import Testing
@testable import MulliganCore

/// A throw-away watched folder, vault and engine with a controllable clock.
final class Sandbox {
    let base: String
    let root: String
    let outside: String
    let paths: Paths
    let engine: Engine
    var clock = Date()

    init(_ configure: (inout Config) -> Void = { _ in }) throws {
        let tmp = Fs.canonical(NSTemporaryDirectory())
        base = tmp + "/mulligan-test-" + UUID().uuidString
        root = base + "/watched"
        outside = base + "/outside"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        paths = Paths(support: URL(fileURLWithPath: base + "/support"))
        var cfg = Config()
        cfg.roots = [root]
        cfg.lowDiskFreeGB = 0
        cfg.throttleScale = 0
        configure(&cfg)
        engine = try Engine(paths: paths, config: cfg)
        engine.freeSpace = { _ in Int64.max }
        engine.ephemeralLifetime = 0
        engine.now = { [unowned self] in self.clock }
    }

    deinit {
        engine.stop()
        try? FileManager.default.removeItem(atPath: base)
    }

    var store: Store { engine.store }
    func path(_ rel: String) -> String { root + "/" + rel }
    func advance(_ s: TimeInterval) { clock = clock.addingTimeInterval(s) }

    @discardableResult
    func write(_ rel: String, _ text: String) -> String {
        let p = path(rel)
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! text.write(toFile: p, atomically: false, encoding: .utf8)
        return p
    }

    @discardableResult
    func writeRandom(_ rel: String, bytes: Int) -> String {
        let p = path(rel)
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var d = Data(count: bytes)
        d.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        try! d.write(to: URL(fileURLWithPath: p))
        return p
    }

    func text(_ rel: String) -> String? { try? String(contentsOfFile: path(rel), encoding: .utf8) }
    func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }
    func remove(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
}

func sha256(_ path: String) -> String {
    guard let d = FileManager.default.contents(atPath: path) else { return "missing" }
    return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
}

func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return cond()
}

func removedEvents(_ paths: [String]) -> [FSEvent] {
    paths.map { FSEvent(path: $0, flags: EvFlag.removed | EvFlag.isFile) }
}
