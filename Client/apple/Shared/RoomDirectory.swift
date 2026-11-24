import Foundation
import Combine

@MainActor
final class RoomDirectory: ObservableObject {
    @Published private(set) var rooms: [RoomOverview] = []
    @Published private(set) var syncMessage: LocalizedMessage?
    @Published private(set) var isFresh = false
    private var activeCredential: String?

    #if DEBUG
    /// UI-only directory. No watcher is started and no credential is supplied.
    static func designPreview(rooms: [RoomOverview]) -> RoomDirectory {
        let directory = RoomDirectory()
        directory.rooms = rooms
        directory.isFresh = true
        return directory
    }
    #endif

    var defaultRoomID: String { rooms.first(where: \.isDefault)?.roomID ?? rooms.first?.roomID ?? "" }
    func room(_ id: String) -> RoomOverview { rooms.first { $0.roomID == id } ?? .loading(id: id) }
    func reset(for login: ClientSession?) {
        activeCredential = login?.credential
        isFresh = false; syncMessage = nil
        rooms = login.map { [.loading(id: $0.connection.defaultRoomID)] } ?? []
    }
    func apply(_ rooms: [RoomOverview], credential: String) {
        guard activeCredential == credential else { return }
        isFresh = true; self.rooms = rooms; syncMessage = nil
    }
    func markStale(credential: String) {
        guard activeCredential == credential else { return }
        isFresh = false; syncMessage = "房间名单暂时无法同步；当前显示上次数据或默认房间。"
    }
}
