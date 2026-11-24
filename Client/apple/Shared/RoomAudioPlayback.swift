import AVFoundation
import Foundation

@MainActor
protocol RoomAudioPlaying: AnyObject {
    var isPlaying: Bool { get }
    var numberOfLoops: Int { get set }
    func play() -> Bool
    func pause()
    func stop()
    func setOutputDeviceID(_ id: String?)
}

extension AVAudioPlayer: RoomAudioPlaying {
    func setOutputDeviceID(_ id: String?) {
        #if os(macOS)
        currentDevice = id
        #endif
    }
}

/// Keeps room output running even before a peer publishes audio, so short cues
/// do not lose their beginning while a cold output device starts. On iOS this
/// also prevents background suspension; activating AVAudioSession alone cannot.
/// This local, silent output never opens the microphone or publishes a track.
@MainActor
final class RoomAudioPlayback {
    private let makePlayer: () throws -> any RoomAudioPlaying
    private var player: (any RoomAudioPlaying)?
    private var releaseSession: (() -> Void)?
    private var suspended = false
    private var outputDeviceID: String?

    init(makePlayer: @escaping () throws -> any RoomAudioPlaying = {
        try AVAudioPlayer(data: RoomAudioPlayback.silence)
    }) {
        self.makePlayer = makePlayer
    }

    isolated deinit { stop() }

    func start(acquireSession: () throws -> () -> Void) throws {
        guard player == nil else { return }
        let release = try acquireSession()
        do {
            let player = try makePlayer()
            player.numberOfLoops = -1
            player.setOutputDeviceID(outputDeviceID)
            guard player.play() else { throw ClientFailure(.voiceConnectionFailed) }
            self.player = player
            releaseSession = release
        } catch {
            release()
            throw error
        }
    }

    /// Audio route/category changes can pause a player. The room's existing
    /// audio monitor restarts it while the call still owns the session.
    func ensurePlaying() throws {
        guard !suspended else { return }
        guard let player, !player.isPlaying else { return }
        guard player.play() else { throw ClientFailure(.voiceConnectionFailed) }
    }

    func suspend() { suspended = true; player?.pause() }
    func resume() throws { suspended = false; try ensurePlaying() }

    func setOutputDeviceID(_ id: String?) throws {
        guard outputDeviceID != id else { return }
        outputDeviceID = id
        guard let player else { return }
        // AVAudioPlayer must release its prepared output before changing devices.
        player.stop()
        player.setOutputDeviceID(id)
        try ensurePlaying()
    }

    func stop() {
        let player = self.player
        let release = releaseSession
        self.player = nil
        releaseSession = nil
        suspended = false
        player?.stop()
        release?()
    }

    // One second of mono, 16-bit PCM silence in a WAV container, held only in
    // memory. An endless loop also covers empty rooms and all-muted peers.
    static var silence: Data {
        let sampleRate: UInt32 = 8_000
        let byteCount = sampleRate * 2
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(36) + byteCount)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // Mono
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2)) // Bytes per frame
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(byteCount)
        data.append(Data(count: Int(byteCount)))
        return data
    }
}
