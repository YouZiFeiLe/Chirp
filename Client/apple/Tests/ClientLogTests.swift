import Foundation
import SQLite3
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

/// Read the actual exported file using a fresh, read-only SQLite connection.
final class ClientLogFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let suite = UUID().uuidString
    final class Clock: Sendable {
        private let instant = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        var now: Date { instant.withLock { $0 } }
        func set(_ date: Date) { instant.withLock { $0 = date } }
    }
    let clock = Clock()
    let log: ClientLog
    var directory: URL { root.appending(path: "logs") }

    init(enabled: Bool = false) throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        log = ClientLog(directory: root.appending(path: "logs"), defaults: defaults, now: { [clock] in clock.now })
        if enabled { log.setEnabled(true) }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    func callEvents() async throws -> [CallDiagnostic] {
        let data = try await log.export()
        return try rows(data, "SELECT details FROM call WHERE event='lifecycle' ORDER BY rowid").map {
            try JSONDecoder().decode(CallDiagnostic.self, from: Data($0[0].utf8))
        }
    }

    func rows(_ data: Data, _ sql: String) throws -> [[String]] {
        let url = root.appending(path: UUID().uuidString + ".chirplog")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try rows(at: url, sql)
    }

    func rows(at url: URL, _ sql: String) throws -> [[String]] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        try #require(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try #require(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        var rows: [[String]] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return rows }
            try #require(step == SQLITE_ROW)
            rows.append((0..<sqlite3_column_count(stmt)).map { index in
                sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
            })
        }
    }
}

@Suite struct ClientLogTests {
    @Test func consentClearAndSnapshotAreOrdered() async throws {
        let fixture = try ClientLogFixture(), log = fixture.log
        log.start()
        log.record(.account, "beforeConsent")
        await #expect(throws: ChirpLogError.empty) { try await log.export() }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))

        log.setEnabled(true)
        let oldSpan = log.begin()
        log.record(.account, "firstLogin")
        log.setEnabled(false)
        log.record(.account, "afterOptOut")
        let snapshot = try await log.export()
        #expect(try fixture.rows(snapshot, "SELECT event FROM account") == [["firstLogin"]])
        #expect(try fixture.rows(snapshot, "SELECT event FROM settings ORDER BY rowid") == [["recordingEnabled"], ["recordingDisabled"]])
        #expect(try fixture.rows(snapshot, "PRAGMA application_id") == [["1128813136"]])
        #expect(try fixture.rows(snapshot, "PRAGMA user_version") == [["1"]])
        #expect(try fixture.rows(snapshot, "PRAGMA integrity_check") == [["ok"]])
        let tables = try fixture.rows(snapshot, "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name").flatMap { $0 }
        #expect(tables == LogCategory.allCases.map(\.rawValue).sorted())

        log.setEnabled(true)
        let clearedSpan = log.begin()
        log.record(.account, "pendingAtClear")
        try await log.clear()
        try await log.clear()
        #expect(log.recordingGeneration != 0)
        log.finish(oldSpan, .crypto, "beforeOptOut")
        log.finish(clearedSpan, .crypto, "beforeClear")
        await #expect(throws: ChirpLogError.empty) { try await log.export() }
        log.record(.account, "secondLogin")
        let next = try await log.export()
        #expect(try fixture.rows(next, "SELECT event FROM account") == [["secondLogin"]])
        #expect(try fixture.rows(next, "SELECT COUNT(*) FROM crypto") == [["0"]])
        #expect(try fixture.rows(next, "SELECT seq FROM account") == [["1"]])
        #expect(try fixture.rows(next, "SELECT segment FROM account") != fixture.rows(snapshot, "SELECT segment FROM account"))
        #expect(try fixture.rows(snapshot, "SELECT event FROM account") == [["firstLogin"]])
    }

    @Test func disabledRelaunchDeletesExpiredShardsAndOnlyExpiredRowsOfBoundaryHour() async throws {
        let fixture = try ClientLogFixture(enabled: true), log = fixture.log
        let hour = 3_600.0
        let start = fixture.clock.now
        log.record(.navigation, "expiredWholeHour")
        _ = try await log.export()
        fixture.clock.set(start.addingTimeInterval(hour + 28))
        log.record(.navigation, "expiredOneSecondAgo")
        _ = try await log.export()
        fixture.clock.set(start.addingTimeInterval(hour + 29))
        log.record(.navigation, "atCutoff")
        fixture.clock.set(start.addingTimeInterval(hour * 2))
        log.record(.navigation, "recent")
        log.setEnabled(false)
        _ = try await log.export()
        let manager = FileManager.default
        #expect(try manager.contentsOfDirectory(atPath: fixture.directory.path).count == 3)

        fixture.clock.set(start.addingTimeInterval(hour * 25 + 29))
        let defaults = try #require(UserDefaults(suiteName: fixture.suite))
        let reopened = ClientLog(directory: fixture.directory, defaults: defaults, now: { fixture.clock.now })
        #expect(reopened.recordingGeneration == 0)
        reopened.start()
        reopened.flushAtExit() // Wait for startup cleanup without letting export perform it.
        let shards = try manager.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
        #expect(shards.count == 2)
        let boundary = try #require(shards.min { $0.lastPathComponent < $1.lastPathComponent })
        #expect(try fixture.rows(at: boundary, "SELECT event FROM navigation") == [["atCutoff"]])
        let exported = try await reopened.export()
        #expect(try fixture.rows(exported, "SELECT event FROM navigation ORDER BY time_ms") == [["atCutoff"], ["recent"]])

        fixture.clock.set(start.addingTimeInterval(hour * 26 + 1))
        reopened.maintain()
        reopened.flushAtExit()
        #expect(try manager.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
        await #expect(throws: ChirpLogError.empty) { try await reopened.export() }
    }

    @Test func requestLogsOnlyAllowlistedMetadataAndKeepsUnknownServerCodesPrivate() async throws {
        let fixture = try ClientLogFixture(enabled: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivateLogResponse.self]
        let session = HTTPDataSession(configuration: configuration, log: fixture.log)
        defer { session.close() }
        var request = URLRequest(url: URL(string: "https://private-address.invalid/private-account?code=private-query")!)
        request.setValue("Bearer private-credential", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("private-message private-secret-key".utf8)
        request.httpMethod = "POST"
        _ = try await session.data(for: request, operation: "profileUpdate")
        fixture.log.finish(fixture.log.begin(), .account, "browserLogin", error: CancellationError())
        let data = try await fixture.log.export()
        #expect(try fixture.rows(data, "SELECT outcome, error_code IS NULL FROM account") == [["cancelled", "1"]])
        let rows = try fixture.rows(data, "SELECT event,outcome,error_code,http_status,duration_us FROM network")
        #expect(rows.count == 1)
        #expect(rows.first?.prefix(4) == ["profileUpdate", "failed", ClientErrorCode.unknownServerError.rawValue, "403"])
        #expect(Int64(rows.first?.last ?? "") != nil)
        for marker in ["private-address", "private-account", "private-query", "private-message", "private-secret-key",
                       "private-credential", "PRIVATE_SERVER_VALUE", "private-response"] {
            #expect(data.range(of: Data(marker.utf8)) == nil)
        }
    }

    @MainActor @Test func switchingAccountsKeepsOnlyAnonymousLoginEvents() async throws {
        let fixture = try ClientLogFixture(enabled: true)
        let login = LoginSession(log: fixture.log)
        for marker in ["a", "b"] {
            let value = try ClientSession(data: JSONSerialization.data(withJSONObject: [
                "member": ["id": "account-" + marker, "display_name": "Private Name"],
                "credential": "chirp_" + String(repeating: marker, count: 43),
                "participant_identity": "account-" + marker + ".login_private",
                "expires_at": Int(Date().timeIntervalSince1970) + 3600
            ]), connection: testServerConnection)
            login.accept(value)
            login.clear(ClientFailure(.loginExpired))
        }
        let data = try await fixture.log.export()
        #expect(try fixture.rows(data, "SELECT event FROM account ORDER BY rowid")
                == [["loginAccepted"], ["sessionEnded"], ["loginAccepted"], ["sessionEnded"]])
        for marker in ["Private Name", "account-a", "account-b", "login_private", "chirp_aaaa", "chirp_bbbb"] {
            #expect(data.range(of: Data(marker.utf8)) == nil)
        }
    }

    @Test func unavailableStorageRetriesWithAnExplicitLossCount() async throws {
        let fixture = try ClientLogFixture(), log = fixture.log
        let manager = FileManager.default
        try manager.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try Data().write(to: fixture.directory) // A file in place of the directory prevents all writes.
        log.setEnabled(true)
        for _ in 0..<2200 { log.record(.room, "join") }
        do {
            _ = try await log.export()
            Issue.record("Export unexpectedly succeeded without writable storage")
        } catch {}
        try manager.removeItem(at: fixture.directory)
        let data = try await log.export()
        let count = try fixture.rows(data, """
            SELECT (SELECT count(*) FROM room) + (SELECT count(*) FROM settings) +
                   (SELECT sum(json_extract(details, '$.count')) FROM application WHERE event='storageOverflow')
            """)
        #expect(count == [["2201"]])
    }

    @Test func concurrentProducersAndExportKeepCommittedBatches() async throws {
        let fixture = try ClientLogFixture(enabled: true), log = fixture.log
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    for _ in 0..<70 { log.record(.chat, "receiveMessage") }
                }
            }
            group.addTask { _ = try? await log.export() }
        }
        let data = try await log.export()
        #expect(try fixture.rows(data, "SELECT COUNT(*) FROM chat") == [["840"]])
    }
}

private final class PrivateLogResponse: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"code":"PRIVATE_SERVER_VALUE","message":"private-response"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
