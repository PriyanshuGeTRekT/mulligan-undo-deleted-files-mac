import Foundation
import CoreServices

public enum EvFlag {
    public static let mustScanSubDirs: UInt32 = 0x1
    public static let userDropped: UInt32 = 0x2
    public static let kernelDropped: UInt32 = 0x4
    public static let rootChanged: UInt32 = 0x20
    public static let created: UInt32 = 0x100
    public static let removed: UInt32 = 0x200
    public static let renamed: UInt32 = 0x800
    public static let modified: UInt32 = 0x1000
    public static let isFile: UInt32 = 0x10000
    public static let isDir: UInt32 = 0x20000
    public static let isSymlink: UInt32 = 0x40000
}

public struct FSEvent {
    public let path: String
    public let flags: UInt32
    public init(path: String, flags: UInt32) { self.path = path; self.flags = flags }
}

/// Thin FSEvents wrapper. File-level events, delivered on the queue you give it.
public final class Watcher {
    private var stream: FSEventStreamRef?
    private let roots: [String]
    private let latency: TimeInterval
    private let queue: DispatchQueue
    let handler: ([FSEvent]) -> Void

    public init(roots: [String], latency: TimeInterval = 0.3, queue: DispatchQueue, handler: @escaping ([FSEvent]) -> Void) {
        self.roots = roots
        self.latency = latency
        self.queue = queue
        self.handler = handler
    }

    @discardableResult
    public func start() -> Bool {
        guard stream == nil, !roots.isEmpty else { return false }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info = info else { return }
            let me = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as NSArray
            var events: [FSEvent] = []
            events.reserveCapacity(count)
            for i in 0..<count {
                if let p = paths[i] as? String { events.append(FSEvent(path: p, flags: flags[i])) }
            }
            me.handler(events)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer |
                           kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, roots as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return false }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            return false
        }
        stream = s
        return true
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}

/// One watcher process at a time (menu-bar app or `mulligan watch`).
public final class ProcessLock {
    private var fd: Int32 = -1
    public init?(path: String) {
        fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd) }
            return nil
        }
        let pid = "\(getpid())\n"
        ftruncate(fd, 0)
        _ = pid.withCString { write(fd, $0, strlen($0)) }
    }
    deinit { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }

    public static func isHeld(path: String) -> Bool {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return true
    }
}
