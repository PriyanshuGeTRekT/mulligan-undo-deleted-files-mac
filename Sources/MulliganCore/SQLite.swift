import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DBError: Error, CustomStringConvertible {
    case failed(String)
    public var description: String {
        switch self { case .failed(let m): return m }
    }
}

public enum Bind {
    case int(Int64)
    case real(Double)
    case text(String)
    case null
}

public struct Row {
    let stmt: OpaquePointer
    public func int(_ c: Int32) -> Int64 { sqlite3_column_int64(stmt, c) }
    public func real(_ c: Int32) -> Double { sqlite3_column_double(stmt, c) }
    public func text(_ c: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, c) else { return "" }
        return String(cString: p)
    }
    public func isNull(_ c: Int32) -> Bool { sqlite3_column_type(stmt, c) == SQLITE_NULL }
}

/// Minimal thread-safe SQLite wrapper with a prepared-statement cache.
public final class SQLiteDB {
    private var handle: OpaquePointer?
    private var cache: [String: OpaquePointer] = [:]
    private let lock = NSRecursiveLock()
    private var txDepth = 0

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            throw DBError.failed("cannot open database: \(String(cString: sqlite3_errmsg(handle)))")
        }
        sqlite3_busy_timeout(handle, 15_000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
    }

    deinit {
        for (_, s) in cache { sqlite3_finalize(s) }
        sqlite3_close(handle)
    }

    private func message() -> String { String(cString: sqlite3_errmsg(handle)) }

    public func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw DBError.failed("\(m) [\(sql.prefix(60))]")
        }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        if let s = cache[sql] {
            sqlite3_reset(s); sqlite3_clear_bindings(s)
            return s
        }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &s, nil) == SQLITE_OK, let st = s else {
            throw DBError.failed("prepare failed: \(message()) [\(sql.prefix(60))]")
        }
        cache[sql] = st
        return st
    }

    private func bind(_ st: OpaquePointer, _ binds: [Bind]) {
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .int(let v): sqlite3_bind_int64(st, idx, v)
            case .real(let v): sqlite3_bind_double(st, idx, v)
            case .text(let v): sqlite3_bind_text(st, idx, v, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(st, idx)
            }
        }
    }

    /// Runs a statement; returns the number of rows changed.
    @discardableResult
    public func run(_ sql: String, _ binds: [Bind] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let st = try statement(sql)
        bind(st, binds)
        let rc = sqlite3_step(st)
        sqlite3_reset(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError.failed("step failed: \(message()) [\(sql.prefix(60))]")
        }
        return Int(sqlite3_changes(handle))
    }

    public func query<T>(_ sql: String, _ binds: [Bind] = [], _ map: (Row) -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let st = try statement(sql)
        bind(st, binds)
        var out: [T] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { out.append(map(Row(stmt: st))) }
            else if rc == SQLITE_DONE { break }
            else {
                sqlite3_reset(st)
                throw DBError.failed("step failed: \(message()) [\(sql.prefix(60))]")
            }
        }
        sqlite3_reset(st)
        return out
    }

    public func scalarInt(_ sql: String, _ binds: [Bind] = []) -> Int64 {
        (try? query(sql, binds) { $0.int(0) })?.first ?? 0
    }

    public var lastInsertID: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Nested calls join the outermost transaction.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if txDepth > 0 { return try body() }
        try exec("BEGIN IMMEDIATE")
        txDepth = 1
        do {
            let r = try body()
            txDepth = 0
            try exec("COMMIT")
            return r
        } catch {
            txDepth = 0
            _ = try? exec("ROLLBACK")
            throw error
        }
    }
}
