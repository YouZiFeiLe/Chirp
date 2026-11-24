import CoreGraphics
import Foundation
import Observation

@MainActor @Observable
final class MemberProfiles {
    private(set) var members: [String: MemberProfile] = [:]
    private(set) var syncMessage: LocalizedMessage?
    private var images: [String: CachedAvatar] = [:]
    @ObservationIgnored private var downloads: [String: Download] = [:]
    @ObservationIgnored private var api: APIClient?
    @ObservationIgnored private var credential: String?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var avatarTask: Task<Void, Never>?
    @ObservationIgnored private var avatarUpdatePending = false

    private struct CachedAvatar {
        let revision: String
        let image: CGImage
    }

    private struct Download {
        let id = UUID()
        let task: Task<Data, Error>
    }

    var names: [String: String] { members.mapValues(\.displayName) }

    func displayName(for identity: String, fallback: String) -> String {
        members[MemberProfile.memberID(for: identity)]?.displayName ?? fallback
    }

    func image(for identity: String) -> CGImage? {
        let id = MemberProfile.memberID(for: identity)
        guard let revision = members[id]?.avatarRevision, images[id]?.revision == revision else { return nil }
        return images[id]?.image
    }

    func reset(credential: String?, server: URL?, configuration: URLSessionConfiguration? = nil) {
        epoch = UUID()
        avatarTask?.cancel(); avatarTask = nil
        avatarUpdatePending = false
        for download in downloads.values { download.task.cancel() }
        downloads = [:]
        api?.close()
        if let credential, let server {
            api = APIClient(baseURL: server, credential: credential, configuration: configuration)
        } else { api = nil }
        self.credential = credential
        members = [:]; images = [:]; syncMessage = nil
    }

    // Snapshot requests and local saves may overlap. Revisions prevent a
    // response started before a save from restoring the previous nickname.
    func apply(_ profile: MemberProfile, credential: String) {
        guard self.credential == credential,
              (members[profile.id]?.profileRevision ?? -1) <= profile.profileRevision else { return }
        if members[profile.id] != profile { members[profile.id] = profile }
        if images[profile.id]?.revision != profile.avatarRevision { images[profile.id] = nil }
    }

    func markStale(credential: String) {
        guard self.credential == credential else { return }
        syncMessage = "成员资料暂时无法同步，当前显示上次资料。"
    }

    func applySnapshot(_ list: [MemberProfile], credential: String) {
        guard self.credential == credential else { return }
        for profile in list { apply(profile, credential: credential) }
        let ids = Set(list.map(\.id))
        members = members.filter { ids.contains($0.key) }
        images = images.filter { ids.contains($0.key) }
        syncMessage = nil
        let validDownloads = Set(members.values.compactMap { profile in profile.avatarRevision.map { profile.id + "." + $0 } })
        for (key, download) in downloads where !validDownloads.contains(key) { download.task.cancel(); downloads[key] = nil }
        avatarUpdatePending = true
        guard avatarTask == nil else { return }
        let operation = epoch
        avatarTask = Task { [weak self] in
            guard let self else { return }
            defer { if epoch == operation { avatarTask = nil } }
            while !Task.isCancelled, epoch == operation, avatarUpdatePending {
                avatarUpdatePending = false
                let pending = Array(members.values.filter { $0.avatarRevision != nil })
                await withTaskGroup(of: Void.self) { group in
                    var next = 0
                    while next < min(4, pending.count) {
                        let profile = pending[next]; next += 1
                        group.addTask { await self.loadAvatar(profile) }
                    }
                    while await group.next() != nil {
                        guard !Task.isCancelled, epoch == operation else { group.cancelAll(); break }
                        if next < pending.count {
                            let profile = pending[next]; next += 1
                            group.addTask { await self.loadAvatar(profile) }
                        }
                    }
                }
            }
        }
    }

    func rename(_ name: String) async throws {
        guard let api, let credential else { throw APIError.unauthorized }
        let operation = epoch
        let profile = try await api.rename(name)
        guard epoch == operation else { throw CancellationError() }
        apply(profile, credential: credential)
    }

    func setAvatar(_ data: Data) async throws {
        guard let api, let credential else { throw APIError.unauthorized }
        let operation = epoch
        let profile = try await api.setAvatar(data)
        guard epoch == operation else { throw CancellationError() }
        apply(profile, credential: credential)
        await loadAvatar(profile)
    }

    func deleteAvatar() async throws {
        guard let api, let credential else { throw APIError.unauthorized }
        let operation = epoch
        let profile = try await api.deleteAvatar()
        guard epoch == operation else { throw CancellationError() }
        apply(profile, credential: credential)
    }

    private func loadAvatar(_ profile: MemberProfile) async {
        guard let api, let revision = profile.avatarRevision, images[profile.id]?.revision != revision else { return }
        let operation = epoch
        let key = profile.id + "." + revision
        let download: Download
        if let existing = downloads[key] { download = existing }
        else {
            download = Download(task: Task {
                for attempt in 0..<3 {
                    do { return try await api.avatar(memberID: profile.id, revision: revision) }
                    catch {
                        try Task.checkCancellation()
                        let status = (error as? ClientFailure)?.httpStatus ?? 0
                        let network = (error as? URLError).map {
                            [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed].contains($0.code)
                        } ?? false
                        guard attempt < 2, network || status >= 500 else { throw error }
                        try await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
                    }
                }
                throw CancellationError()
            })
            downloads[key] = download
        }
        defer { if epoch == operation, downloads[key]?.id == download.id { downloads[key] = nil } }
        do {
            let data = try await download.task.value
            guard epoch == operation, members[profile.id]?.avatarRevision == revision,
                  let image = AvatarImage.decoded(data) else { return }
            images[profile.id] = CachedAvatar(revision: revision, image: image)
        } catch { /* Keep initials; a later state update retries the download. */ }
    }
}
