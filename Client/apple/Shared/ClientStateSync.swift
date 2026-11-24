import Foundation

struct ClientStateSnapshot: Decodable, Sendable {
    let serverID: String
    let revision: UInt64
    let rooms: [RoomOverview]
    let members: [MemberProfile]
    enum CodingKeys: String, CodingKey { case serverID = "server_id", revision, rooms, members }

    func validated(defaultRoomID: String) throws -> ClientStateSnapshot {
        guard !serverID.isEmpty, serverID.utf8.count <= 128, revision > 0 else { throw ClientFailure(.invalidResponse) }
        _ = try RoomsResponse(rooms: rooms).validatedRooms(defaultRoomID: defaultRoomID)
        _ = try MemberProfilesResponse(members: members).validatedMembers()
        return self
    }
}

struct ClientStateHint: Decodable, Sendable {
    let serverID: String
    let revision: UInt64
    enum CodingKeys: String, CodingKey { case serverID = "server_id", revision }
}

struct ClientStateStream: Sendable {
    let events: AsyncThrowingStream<HTTPEvent, Error>
    let cancel: @Sendable () -> Void
}

struct ClientStateSource: Sendable {
    let snapshot: @Sendable () async throws -> ClientStateSnapshot
    let connect: @Sendable () -> ClientStateStream
    let close: @Sendable () -> Void

    static func live(_ login: ClientSession) -> ClientStateSource {
        let api = APIClient(baseURL: login.connection.apiURL, credential: login.credential)
        return ClientStateSource(snapshot: { try await api.state() }, connect: {
            var request = URLRequest(url: login.connection.apiURL.appendingPathComponent("v1/events"))
            request.setValue("Bearer \(login.credential)", forHTTPHeaderField: "Authorization")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let connection = HTTPEventConnection(request: request)
            return ClientStateStream(events: connection.events, cancel: { connection.cancel() })
        }, close: { api.close() })
    }
}

/// One foreground feed per application login. Windows register independently;
/// closing one window cannot stop synchronization for the remaining windows.
@MainActor
final class ClientStateSync {
    private let directory: RoomDirectory
    private let profiles: MemberProfiles
    private let invalidSession: @MainActor (ClientFailure) -> Void
    private let makeSource: @Sendable (ClientSession) -> ClientStateSource
    private var visible: Set<UUID> = []
    private var login: ClientSession?
    private var task: Task<Void, Never>?
    private var connection: ClientStateStream?
    private var source: ClientStateSource?
    private var epoch = UUID()

    init(directory: RoomDirectory, profiles: MemberProfiles,
         makeSource: @escaping @Sendable (ClientSession) -> ClientStateSource = ClientStateSource.live,
         invalidSession: @escaping @MainActor (ClientFailure) -> Void) {
        self.directory = directory; self.profiles = profiles
        self.makeSource = makeSource; self.invalidSession = invalidSession
    }

    func reset(for login: ClientSession?) {
        stop()
        self.login = login
        directory.reset(for: login)
        startIfNeeded()
    }

    func setVisible(_ window: UUID, _ isVisible: Bool) {
        if isVisible { visible.insert(window) } else { visible.remove(window) }
        if visible.isEmpty { stop(); markStale() } else { startIfNeeded() }
    }

    private func stop() {
        epoch = UUID()
        task?.cancel(); task = nil
        connection?.cancel(); connection = nil
        source?.close(); source = nil
    }

    private func markStale() {
        guard let login else { return }
        directory.markStale(credential: login.credential)
        profiles.markStale(credential: login.credential)
    }

    private func startIfNeeded() {
        guard task == nil, !visible.isEmpty, let login else { return }
        let operation = epoch, source = makeSource(login)
        self.source = source
        task = Task { [weak self] in await self?.run(login, source: source, operation: operation) }
    }

    private func run(_ login: ClientSession, source: ClientStateSource, operation: UUID) async {
        var failures = 0
        var previous: ClientStateSnapshot?
        while !Task.isCancelled, epoch == operation {
            let stream = source.connect()
            connection = stream
            do {
                // A new connection always obtains a complete snapshot. The
                // stream buffers its latest hint while this request is running.
                var state = try await fetch(login, source: source, operation: operation, previous: previous)
                previous = state
                for try await event in stream.events {
                    try check(operation)
                    if event.name == "revoked" { throw APIError.unauthorized }
                    guard event.name == "state" else { throw URLError(.networkConnectionLost) }
                    let hint = try JSONDecoder().decode(ClientStateHint.self, from: event.data)
                    guard !hint.serverID.isEmpty, hint.serverID.utf8.count <= 128, hint.revision > 0 else {
                        throw ClientFailure(.invalidResponse)
                    }
                    failures = 0
                    if hint.serverID != state.serverID || hint.revision > state.revision {
                        state = try await fetch(login, source: source, operation: operation, previous: state)
                        previous = state
                    }
                }
                throw URLError(.networkConnectionLost)
            } catch {
                stream.cancel()
                guard !Task.isCancelled, epoch == operation else { return }
                connection = nil
                if case APIError.unauthorized = error { invalidSession(ClientFailure(.unauthorized)); return }
                if case APIError.disabled = error { invalidSession(ClientFailure(.memberDisabled)); return }
                markStale()
                failures = min(failures + 1, 4)
                let delay = [500, 1_000, 2_000, 5_000][failures - 1]
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
            }
        }
    }

    private func fetch(_ login: ClientSession, source: ClientStateSource, operation: UUID,
                       previous: ClientStateSnapshot? = nil) async throws -> ClientStateSnapshot {
        let state = try await source.snapshot().validated(defaultRoomID: login.connection.defaultRoomID)
        try check(operation)
        if let previous, state.serverID == previous.serverID, state.revision < previous.revision {
            throw ClientFailure(.invalidResponse)
        }
        directory.apply(state.rooms, credential: login.credential)
        profiles.applySnapshot(state.members, credential: login.credential)
        return state
    }

    private func check(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard epoch == operation else { throw CancellationError() }
    }
}
