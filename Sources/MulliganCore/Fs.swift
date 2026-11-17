import Foundation
import Darwin

public struct FileStat {
    public var ino: UInt64
    public var size: Int64
    public var mtimeNs: Int64
    public var mode: UInt16
    public var flags: UInt32

    public var isRegular: Bool { (mode & 0o170000) == 0o100000 }
    public var isDirectory: Bool { (mode & 0o170000) == 0o040000 }
    public var isSymlink: Bool { (mode & 0o170000) == 0o120000 }
    /// SF_DATALESS: an iCloud "optimised storage" placeholder. Touching it would trigger a download.
    public var isDataless: Bool { (flags & 0x4000_0000) != 0 }
}

public enum FsError: Error, CustomStringConvertible {
    case errno(Int32, String)
    case tooBigForCopy
    public var description: String {
        switch self {
        case .errno(let e, let what): return "\(what): \(String(cString: strerror(e)))"
        case .tooBigForCopy: return "file too large to copy on a non-APFS volume"
        }
    }
}

public enum CloneOutcome { case cloned, copied }

public enum Fs {
    public static func lstat(_ path: String) -> FileStat? {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return nil }
        return FileStat(
            ino: UInt64(st.st_ino),
            size: Int64(st.st_size),
            mtimeNs: Int64(st.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(st.st_mtimespec.tv_nsec),
            mode: UInt16(st.st_mode),
            flags: UInt32(st.st_flags))
    }

    public static func freeBytes(at path: String) -> Int64 {
        var s = Darwin.statfs()
        guard statfs(path, &s) == 0 else { return Int64.max }
        return Int64(s.f_bavail) &* Int64(s.f_bsize)
    }

    public static func totalBytes(at path: String) -> Int64 {
        var s = Darwin.statfs()
        guard statfs(path, &s) == 0 else { return 0 }
        return Int64(s.f_blocks) &* Int64(s.f_bsize)
    }

    /// Resolves symlinks (FSEvents reports canonical paths). Works for missing leaves by resolving the parent.
    public static func canonical(_ path: String) -> String {
        if let p = Darwin.realpath(path, nil) {
            defer { free(p) }
            return String(cString: p)
        }
        let ns = path as NSString
        let parent = ns.deletingLastPathComponent
        if parent == path || parent.isEmpty { return path }
        return (canonical(parent) as NSString).appendingPathComponent(ns.lastPathComponent)
    }

    /// Instant copy-on-write clone (APFS). Falls back to a real copy when cloning is not possible.
    public static func clone(_ src: String, to dst: String, copyLimit: Int64) throws -> CloneOutcome {
        if clonefile(src, dst, UInt32(CLONE_NOFOLLOW)) == 0 { return .cloned }
        var e = errno
        if e == EEXIST {
            unlink(dst)
            if clonefile(src, dst, UInt32(CLONE_NOFOLLOW)) == 0 { return .cloned }
            e = errno
        }
        if e == ENOTSUP || e == EXDEV || e == EOPNOTSUPP {
            guard let st = lstat(src), st.size <= copyLimit else { throw FsError.tooBigForCopy }
            // COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA
            if copyfile(src, dst, nil, copyfile_flags_t(0b1110)) == 0 { return .copied }
            e = errno
        }
        throw FsError.errno(e, "clone \((src as NSString).lastPathComponent)")
    }

    public static func setMtime(_ path: String, ns: Int64) {
        var ts = [timespec(tv_sec: Int(ns / 1_000_000_000), tv_nsec: Int(ns % 1_000_000_000)),
                  timespec(tv_sec: Int(ns / 1_000_000_000), tv_nsec: Int(ns % 1_000_000_000))]
        _ = utimensat(AT_FDCWD, path, &ts, 0)
    }

    /// Iterative directory walk. `descend` decides whether to enter a directory; `visit` sees every non-directory.
    public static func walk(_ root: String,
                            descend: (_ path: String, _ name: String) -> Bool,
                            visit: (_ path: String, _ st: FileStat) -> Void) {
        var stack = [root]
        while let dir = stack.popLast() {
            guard let d = opendir(dir) else { continue }
            while let ent = readdir(d) {
                let name = withUnsafePointer(to: &ent.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                let full = dir == "/" ? "/" + name : dir + "/" + name
                guard let st = lstat(full) else { continue }
                if st.isDirectory {
                    if descend(full, name) { stack.append(full) }
                } else {
                    visit(full, st)
                }
            }
            closedir(d)
        }
    }

    public static func lastComponent(_ path: String) -> String {
        if let i = path.lastIndex(of: "/") { return String(path[path.index(after: i)...]) }
        return path
    }
}
