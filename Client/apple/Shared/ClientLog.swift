import Foundation

/// Only source-code literals, closed enums and explicitly allowlisted metrics cross this boundary.
enum LogCategory: String, CaseIterable, Sendable {
    case application, navigation, account, identity, network, room, call, audio, crypto, chat, attachment, settings
}

enum LogOutcome: String, Sendable { case started, succeeded, failed, cancelled }

struct ClientLogEntry: Sendable {
    let timeMS: Int64
    let segment: String
    let sequence: Int64
    let category: LogCategory
    let event: String
    var outcome: LogOutcome?
    var failure: ClientErrorCode?
    var durationUS: Int64?
    var status: Int?
    var details: LogDetails?
}

enum LogDetails: Sendable {
    case lifecycle(CallDiagnostic)
    case sample(CallDiagnosticSample)
    case decryption(frames: UInt64, totalNS: UInt64, maxNS: UInt64)
    case capture(rate: Int, channels: Int, denoising: Bool)
    case launch
    case screen(visible: Bool)
    case omitted(count: Int)

    func json() throws -> String {
        let data: Data
        switch self {
        case .lifecycle(let event): data = try JSONEncoder().encode(event)
        case .sample(let sample): data = try JSONEncoder().encode(sample)
        case let .decryption(frames, totalNS, maxNS):
            data = try JSONEncoder().encode(["frames": frames, "total_ns": totalNS, "max_ns": maxNS])
        case let .capture(rate, channels, denoising):
            data = try JSONEncoder().encode(["sample_rate_hz": rate, "channels": channels, "rnnoise": denoising ? 1 : 0])
        case let .screen(visible): data = try JSONEncoder().encode(["visible": visible])
        case let .omitted(count): data = try JSONEncoder().encode(["count": count])
        case .launch:
            #if os(macOS)
            let platform = "macos"
            #else
            let platform = "ios"
            #endif
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let client = try? ClientIdentity.current()
            struct Version: Encodable {
                let platform: String
                let app_version: String?
                let app_build: Int?
                let os_version: String
            }
            data = try JSONEncoder().encode(Version(platform: platform, app_version: client?.version, app_build: client?.build,
                os_version: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

final class ClientLog: @unchecked Sendable {
    static let preference = "clientLogRecordingEnabled"
    static let shared = ClientLog(directory: URL.applicationSupportDirectory.appending(path: "Chirp/ClientLogs"),
                                  defaults: .standard)
    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    // Odd while recording. Changing consent or clearing data invalidates outstanding measurements.
    private var generation: UInt64
    private var segment = UUID().uuidString.lowercased()
    private var sequence: Int64 = 0
    private let queue = DispatchQueue(label: "cn.youzifeile.chirp.client-log", qos: .utility)
    // Everything below is confined to the writer queue.
    private let store: ChirpLogStore
    private var pending: [ClientLogEntry] = []
    private var scheduled = false
    private var writeFailed = false
    private var lastMaintenance: Int64?
    private var maintenanceTimer: DispatchSourceTimer?

    init(directory: URL, defaults: UserDefaults, now: @escaping @Sendable () -> Date = Date.init) {
        self.defaults = defaults
        clock = now
        generation = defaults.bool(forKey: Self.preference) ? 1 : 0
        store = ChirpLogStore(directory: directory)
    }

    private var nowMS: Int64 { Int64(clock().timeIntervalSince1970 * 1_000) }
    var recordingGeneration: UInt64 { lock.withLock { generation.isMultiple(of: 2) ? 0 : generation } }

    func start() {
        queue.async { [self] in
            try? self.prune()
            guard self.maintenanceTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(3))
            timer.setEventHandler { [weak self] in try? self?.prune() }
            self.maintenanceTimer = timer
            timer.resume()
        }
        record(.application, "launch", details: .launch)
    }

    func maintain() {
        queue.async { try? self.prune() }
    }

    private func prune() throws {
        let now = nowMS
        try store.prune(at: now)
        lastMaintenance = now
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock {
            let wasEnabled = !generation.isMultiple(of: 2)
            guard enabled != wasEnabled else { return }
            generation &+= 1
            if enabled { newSegment() }
            defaults.set(enabled, forKey: Self.preference)
            sequence += 1
            let entry = ClientLogEntry(timeMS: nowMS, segment: segment, sequence: sequence, category: .settings, event: enabled ? "recordingEnabled" : "recordingDisabled",
                                       details: enabled ? .launch : nil)
            queue.async { self.append(entry); self.tryFlush() }
        }
    }

    // Only called under lock. The random ID never derives from an account, device or installation.
    private func newSegment() { segment = UUID().uuidString.lowercased(); sequence = 0 }

    struct Span: Sendable {
        fileprivate let generation: UInt64
        fileprivate let start = DispatchTime.now().uptimeNanoseconds
    }

    func begin() -> Span? {
        let epoch = recordingGeneration
        return epoch == 0 ? nil : Span(generation: epoch)
    }

    func finish(_ span: Span?, _ category: LogCategory, _ name: StaticString = #function,
                error: (any Error)? = nil, status: Int? = nil) {
        guard let span else { return }
        let elapsed = (DispatchTime.now().uptimeNanoseconds - span.start) / 1_000
        let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
        let failed = error != nil || status.map { !(200..<300).contains($0) } == true
        record(category, name, outcome: cancelled ? .cancelled : (failed ? .failed : .succeeded),
               failure: cancelled ? nil : error.map { ClientFailure.capture($0) }, durationUS: Int64(clamping: elapsed),
               status: status, generation: span.generation)
    }

    func record(_ category: LogCategory, _ name: StaticString = #function, outcome: LogOutcome? = nil,
                failure: ClientFailure? = nil, durationUS: Int64? = nil, status: Int? = nil,
                details: LogDetails? = nil, generation expected: UInt64? = nil) {
        lock.withLock {
            guard !generation.isMultiple(of: 2), expected == nil || expected == generation else { return }
            sequence += 1
            let event = String(name.description.prefix { $0 != "(" })
            let entry = ClientLogEntry(timeMS: nowMS, segment: segment, sequence: sequence,
                category: category, event: event, outcome: outcome,
                failure: failure.map { ClientErrorCode(rawValue: $0.code) ?? .unknownServerError },
                durationUS: durationUS, status: status ?? failure?.httpStatus, details: details)
            queue.async { self.append(entry) }
        }
    }

    func measure<T>(_ category: LogCategory, _ name: StaticString, _ operation: () throws -> T) rethrows -> T {
        let span = begin()
        do {
            let result = try operation()
            finish(span, category, name)
            return result
        } catch {
            finish(span, category, name, error: error)
            throw error
        }
    }

    func measure<T: Sendable>(_ category: LogCategory, _ name: StaticString,
                              isolation: isolated (any Actor)? = #isolation, _ operation: () async throws -> T) async rethrows -> T {
        let span = begin()
        do {
            let result = try await operation()
            finish(span, category, name)
            return result
        } catch {
            finish(span, category, name, error: error)
            throw error
        }
    }

    private func append(_ entry: ClientLogEntry) {
        if pending.count >= 2048 {
            // A persistently unavailable disk must not exhaust memory. Preserve an explicit
            // loss count at the position of the discarded events, including prior loss markers.
            let oldest = pending[0]
            let count = pending.prefix(512).reduce(0) { total, row in
                if case let .omitted(count) = row.details { return total + count }
                return total + 1
            }
            let marker = ClientLogEntry(timeMS: oldest.timeMS, segment: oldest.segment, sequence: oldest.sequence,
                category: .application, event: "storageOverflow", details: .omitted(count: count))
            pending.replaceSubrange(0..<512, with: [marker])
        }
        pending.append(entry)
        if pending.count >= 64 && !writeFailed { tryFlush() }
        scheduleFlush()
    }

    private func tryFlush() {
        do { try flush(); writeFailed = false }
        catch { writeFailed = true }
    }

    private func scheduleFlush() {
        guard !pending.isEmpty, !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + (writeFailed ? .seconds(5) : .milliseconds(400))) { [weak self] in
            guard let self else { return }
            scheduled = false
            tryFlush()
            scheduleFlush()
        }
    }

    private func flush() throws {
        guard !pending.isEmpty else { return }
        let now = nowMS
        if lastMaintenance.map({ now < $0 || now - $0 >= 60_000 }) ?? true { try prune() }
        pending.removeAll { $0.timeMS < now - ChirpLogStore.retentionMS }
        while let first = pending.first {
            let hour = ChirpLogStore.hour(first.timeMS)
            let batch = pending.prefix { ChirpLogStore.hour($0.timeMS) == hour }
            try store.write(batch, hour: hour)
            pending.removeFirst(batch.count)
        }
    }

    func flushSoon() { queue.async { try? self.flush() } }

    // macOS gives applications a synchronous last opportunity to persist a small pending batch.
    func flushAtExit() { queue.sync { try? flush() } }

    func export() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try self.flush()
                    return try self.store.export(at: self.nowMS)
                })
            }
        }
    }

    func clear() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                generation &+= 2
                newSegment()
                queue.async {
                    self.pending.removeAll()
                    self.writeFailed = false
                    continuation.resume(with: Result { try self.store.clear() })
                }
            }
        }
    }
}
