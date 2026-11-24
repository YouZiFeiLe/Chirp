import Foundation
import SQLite3

enum ChirpLogError: Error { case empty, storage }

/// Accessed only on ClientLog's serial utility queue. Each UTC hour is independently disposable.
final class ChirpLogStore {
    static let retentionMS: Int64 = 86_400_000
    static func hour(_ ms: Int64) -> Int64 { ms / 3_600_000 }
    private let directory: URL
    private let files = FileManager.default
    private var active: (hour: Int64, db: LogDatabase)?

    init(directory: URL) { self.directory = directory }

    private func prepareDirectory() throws {
        var url = directory
        try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func contents() throws -> [URL] {
        do { return try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return [] }
    }

    private func shardHour(_ url: URL) -> Int64? {
        guard url.pathExtension == "chirplog" else { return nil }
        return Int64(url.deletingPathExtension().lastPathComponent)
    }

    func write(_ entries: ArraySlice<ClientLogEntry>, hour: Int64) throws {
        if active?.hour != hour {
            try prepareDirectory()
            let url = directory.appending(path: "\(hour).chirplog")
            active = (hour, try LogDatabase(url: url, initialize: true))
        }
        guard let db = active?.db else { throw ChirpLogError.storage }
        try db.transaction { for entry in entries { try db.insert(entry) } }
    }

    func prune(at now: Int64) throws {
        let cutoff = now - Self.retentionMS
        let cutoffHour = Self.hour(cutoff)
        var boundary: URL?
        for url in try contents() {
            // A killed export may have left a partial snapshot or its rollback journal.
            if url.lastPathComponent.hasPrefix("export.") {
                try files.removeItem(at: url)
                continue
            }
            let base = url.lastPathComponent.components(separatedBy: ".chirplog-")
            if base.count == 2, let hour = Int64(base[0]), hour < cutoffHour {
                try files.removeItem(at: url)
                continue
            }
            guard let hour = shardHour(url) else { continue }
            if hour < cutoffHour {
                if active?.hour == hour { active = nil }
                try files.removeItem(at: url)
            } else if hour == cutoffHour { boundary = url }
        }
        if let boundary, try !pruneRows(in: boundary, before: cutoff) {
            if active?.hour == cutoffHour { active = nil }
            try files.removeItem(at: boundary)
        }
    }

    private func pruneRows(in url: URL, before cutoff: Int64) throws -> Bool {
        let db = try LogDatabase(url: url)
        try db.transaction {
            for table in LogCategory.allCases {
                try db.exec("DELETE FROM \(table.rawValue) WHERE time_ms < \(cutoff)")
            }
        }
        return try db.hasEvents()
    }

    func clear() throws {
        active = nil
        do { try files.removeItem(at: directory) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }

    func export(at now: Int64) throws -> Data {
        try prune(at: now)
        let shards = try contents().filter { shardHour($0) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !shards.isEmpty else { throw ChirpLogError.empty }
        let snapshot = directory.appending(path: "export.chirplog")
        defer { try? files.removeItem(at: snapshot) }
        let db = try LogDatabase(url: snapshot, initialize: true)
        var copied = 0
        for url in shards {
            try db.attach(url)
            try db.transaction {
                for table in LogCategory.allCases {
                    try db.exec("INSERT INTO main.\(table.rawValue) SELECT * FROM shard.\(table.rawValue) WHERE time_ms BETWEEN \(now - Self.retentionMS) AND \(now)")
                    copied += db.changes
                }
            }
            try db.exec("DETACH DATABASE shard")
        }
        guard copied > 0 else { throw ChirpLogError.empty }
        return try Data(contentsOf: snapshot, options: .mappedIfSafe)
    }
}

private final class LogDatabase {
    private let handle: OpaquePointer
    private var inserts: [LogCategory: OpaquePointer] = [:]
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    var changes: Int { Int(sqlite3_changes(handle)) }

    init(url: URL, initialize: Bool = false) throws {
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (initialize ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(url.path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            sqlite3_close(pointer)
            throw ChirpLogError.storage
        }
        handle = pointer
        try exec("PRAGMA secure_delete=ON")
        let version = try scalar("PRAGMA user_version")
        if version == 0, initialize, try scalar("PRAGMA application_id") == 0 {
            try exec("PRAGMA journal_mode=DELETE")
            try transaction {
                try exec("PRAGMA application_id=1128813136") // 0x43485250, CHRP
                try exec("PRAGMA user_version=1")
                for category in LogCategory.allCases {
                    let table = category.rawValue
                    try exec("""
                        CREATE TABLE \(table) (
                            time_ms INTEGER NOT NULL, event TEXT NOT NULL, outcome TEXT, error_code TEXT,
                            duration_us INTEGER, http_status INTEGER, details TEXT, segment TEXT NOT NULL, seq INTEGER NOT NULL
                        );
                        CREATE INDEX \(table)_time ON \(table)(time_ms)
                        """)
                }
            }
        } else { try validate(schema: "main") }
    }

    private func scalar(_ sql: String) throws -> Int32 {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw ChirpLogError.storage }
        return sqlite3_column_int(stmt, 0)
    }

    func hasEvents() throws -> Bool {
        let rows = LogCategory.allCases.map { "SELECT 1 FROM \($0.rawValue)" }.joined(separator: " UNION ALL ")
        return try scalar("SELECT EXISTS(\(rows))") != 0
    }

    private func validate(schema: String) throws {
        guard try scalar("PRAGMA \(schema).application_id") == 1128813136,
              try scalar("PRAGMA \(schema).user_version") == 1 else { throw ChirpLogError.storage }
    }

    deinit {
        for statement in inserts.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw ChirpLogError.storage }
    }

    func transaction(_ work: () throws -> Void) throws {
        try exec("BEGIN")
        do { try work(); try exec("COMMIT") }
        catch { try? exec("ROLLBACK"); throw error }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw ChirpLogError.storage }
        return stmt
    }

    private func bind(_ value: String?, _ index: Int32, to stmt: OpaquePointer) throws {
        let result = value.map { sqlite3_bind_text(stmt, index, $0, -1, transient) } ?? sqlite3_bind_null(stmt, index)
        guard result == SQLITE_OK else { throw ChirpLogError.storage }
    }

    func attach(_ url: URL) throws {
        let stmt = try prepare("ATTACH DATABASE ? AS shard")
        defer { sqlite3_finalize(stmt) }
        try bind(url.path, 1, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ChirpLogError.storage }
        try validate(schema: "shard")
    }

    func insert(_ entry: ClientLogEntry) throws {
        let stmt: OpaquePointer
        if let cached = inserts[entry.category] { stmt = cached }
        else {
            stmt = try prepare("INSERT INTO \(entry.category.rawValue) VALUES (?,?,?,?,?,?,?,?,?)")
            inserts[entry.category] = stmt
        }
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        sqlite3_bind_int64(stmt, 1, entry.timeMS)
        try bind(entry.event, 2, to: stmt)
        try bind(entry.outcome?.rawValue, 3, to: stmt)
        try bind(entry.failure?.rawValue, 4, to: stmt)
        if let duration = entry.durationUS { sqlite3_bind_int64(stmt, 5, duration) }
        if let status = entry.status { sqlite3_bind_int64(stmt, 6, Int64(status)) }
        try bind(try entry.details?.json(), 7, to: stmt)
        try bind(entry.segment, 8, to: stmt)
        sqlite3_bind_int64(stmt, 9, entry.sequence)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ChirpLogError.storage }
    }
}
