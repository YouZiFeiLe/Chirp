import AVFoundation
import Foundation

enum RoomPresenceSound: String, CaseIterable, Sendable {
    case joined = "JoinTheRoom"
    case left = "LeftTheRoom"

    var resourceURL: URL? {
        AppLocalization.resourceBundle.url(forResource: rawValue, withExtension: "mp3")
    }
}

/// Compare confirmed membership, never speaking/mute updates or SDK reconnect callbacks.
struct RoomPresenceTracker {
    private var peers: Set<String>?
    private var needsBaseline = false

    mutating func confirm(_ identities: Set<String>, localIdentity: String) -> [RoomPresenceSound] {
        guard identities.contains(localIdentity) else { return [] }
        let next = identities.subtracting([localIdentity])
        defer { peers = next; needsBaseline = false }
        // The first ready group confirms our own entry once, regardless of room size.
        guard let peers else { return [.joined] }
        guard !needsBaseline else { return [] }
        var sounds: [RoomPresenceSound] = []
        if !peers.subtracting(next).isEmpty { sounds.append(.left) }
        if !next.subtracting(peers).isEmpty { sounds.append(.joined) }
        return sounds
    }

    /// Changes while we could not hear the room are not replayed on recovery.
    mutating func resynchronize() { needsBaseline = peers != nil }
}

@MainActor
protocol RoomSoundPlaying: AnyObject {
    var isPlaying: Bool { get }
    func play() -> Bool
    func stop()
    func setOutputDeviceID(_ id: String?)
}

extension AVAudioPlayer: RoomSoundPlaying {}

/// Local output only. The active call already owns the iOS audio session.
/// A small, expiring queue avoids overlapping sounds and stale announcements.
@MainActor
final class RoomPresenceSounds {
    private struct Pending {
        let sound: RoomPresenceSound
        let deadline: ContinuousClock.Instant
    }
    private let makePlayer: (RoomPresenceSound) throws -> any RoomSoundPlaying
    private let now: () -> ContinuousClock.Instant
    private var pending: [Pending] = []
    private var player: (any RoomSoundPlaying)?
    private var task: Task<Void, Never>?
    private var runID: UUID?
    private var outputDeviceID: String?

    init(makePlayer: @escaping (RoomPresenceSound) throws -> any RoomSoundPlaying = { sound in
        guard let url = sound.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        return try AVAudioPlayer(contentsOf: url)
    }, now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.makePlayer = makePlayer; self.now = now
    }

    isolated deinit { stop() }

    func enqueue(_ sound: RoomPresenceSound) {
        let instant = now()
        pending.removeAll { $0.deadline < instant }
        let next = Pending(sound: sound, deadline: instant.advanced(by: .seconds(3)))
        if pending.last?.sound == sound {
            pending[pending.count - 1] = next
        } else {
            if pending.count == 4 { pending.removeFirst() }
            pending.append(next)
        }
        guard task == nil else { return }
        let id = UUID()
        runID = id
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let player = self?.startNext(id) else { break }
                do {
                    while player.isPlaying { try await Task.sleep(for: .milliseconds(50)) }
                } catch { player.stop() }
                guard !Task.isCancelled else { return }
                self?.finishCurrent(id)
            }
            self?.finishRun(id)
        }
    }

    func setOutputDeviceID(_ id: String?) {
        guard id != outputDeviceID else { return }
        stop()
        outputDeviceID = id
    }

    func stop() {
        runID = nil; task?.cancel(); task = nil
        pending = []
        player?.stop(); player = nil
    }

    private func startNext(_ id: UUID) -> (any RoomSoundPlaying)? {
        guard runID == id else { return nil }
        while !pending.isEmpty {
            let next = pending.removeFirst()
            guard next.deadline >= now() else { continue }
            do {
                let player = try makePlayer(next.sound)
                player.setOutputDeviceID(outputDeviceID)
                if player.play() { self.player = player; return player }
                player.stop()
            } catch {
                // A missing/undecodable cue must never fail or tear down a call.
                ClientLog.shared.record(.audio, "presenceSound", outcome: .failed)
            }
        }
        return nil
    }

    private func finishCurrent(_ id: UUID) {
        guard runID == id else { return }
        player?.stop(); player = nil
    }

    private func finishRun(_ id: UUID) {
        guard runID == id else { return }
        finishCurrent(id)
        runID = nil; task = nil
    }
}
