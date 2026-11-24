import AVFoundation
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

@MainActor
private final class TestRoomAudioPlayer: RoomAudioPlaying {
    var isPlaying = false
    var numberOfLoops = 0
    var canPlay = true
    var starts = 0
    var stops = 0
    var outputDeviceID: String?
    func play() -> Bool { starts += 1; isPlaying = canPlay; return canPlay }
    func pause() { isPlaying = false }
    func stop() { stops += 1; isPlaying = false }
    func setOutputDeviceID(_ id: String?) { outputDeviceID = id }
}

@Test @MainActor func listeningPlaybackOwnsOneSessionUntilRoomTeardown() throws {
    let player = TestRoomAudioPlayer()
    let playback = RoomAudioPlayback(makePlayer: { player })
    var acquisitions = 0, releases = 0
    let acquire = { acquisitions += 1; return { releases += 1 } }
    try playback.start(acquireSession: acquire)
    try playback.start(acquireSession: acquire)
    #expect(acquisitions == 1 && releases == 0)
    #expect(player.isPlaying && player.numberOfLoops == -1 && player.starts == 1)
    try playback.ensurePlaying()
    #expect(player.starts == 1)
    // A route/category change pauses output; restore it without a second session.
    player.isPlaying = false
    try playback.ensurePlaying()
    #expect(player.starts == 2 && acquisitions == 1 && releases == 0)
    playback.stop()
    playback.stop()
    try playback.ensurePlaying()
    #expect(releases == 1 && player.stops == 1 && !player.isPlaying && player.starts == 2)
    try playback.start(acquireSession: acquire)
    playback.stop()
    #expect(acquisitions == 2 && releases == 2)
}

@Test @MainActor func listeningPlaybackRollsBackFailedStartsAndReleasesOnDeinit() throws {
    let player = TestRoomAudioPlayer()
    var releases = 0
    var playback: RoomAudioPlayback? = RoomAudioPlayback(makePlayer: { player })
    player.canPlay = false
    #expect(throws: ClientFailure.self) {
        try playback?.start { { releases += 1 } }
    }
    #expect(releases == 1)
    player.canPlay = true
    try playback?.start { { releases += 1 } }
    player.isPlaying = false; player.canPlay = false
    #expect(throws: ClientFailure.self) { try playback?.ensurePlaying() }
    playback = nil
    #expect(releases == 2 && player.stops == 1)
}

@Test @MainActor func systemInterruptionDoesNotLetThePlaybackMonitorRestartAudioEarly() throws {
    let player = TestRoomAudioPlayer(), playback = RoomAudioPlayback(makePlayer: { player })
    var releases = 0
    try playback.start { { releases += 1 } }
    playback.suspend()
    try playback.ensurePlaying()
    #expect(!player.isPlaying && player.starts == 1 && releases == 0)
    try playback.resume()
    #expect(player.isPlaying && player.starts == 2 && releases == 0)
    playback.stop()
    #expect(releases == 1)
}

@Test @MainActor func listeningPlaybackFollowsTheRoomOutputWithoutReacquiringItsSession() throws {
    let player = TestRoomAudioPlayer(), playback = RoomAudioPlayback(makePlayer: { player })
    var acquisitions = 0, releases = 0
    try playback.setOutputDeviceID("usb-test")
    try playback.start { acquisitions += 1; return { releases += 1 } }
    #expect(player.outputDeviceID == "usb-test" && player.isPlaying)
    try playback.setOutputDeviceID("usb-test")
    #expect(player.starts == 1 && player.stops == 0)
    try playback.setOutputDeviceID("headphones-test")
    #expect(player.outputDeviceID == "headphones-test" && player.isPlaying)
    #expect(player.starts == 2 && player.stops == 1 && acquisitions == 1 && releases == 0)
    try playback.setOutputDeviceID(nil)
    #expect(player.outputDeviceID == nil && player.starts == 3 && player.isPlaying)
    playback.stop()
    try playback.setOutputDeviceID("usb-test")
    #expect(player.starts == 3 && releases == 1)
}

@Test @MainActor func changingListeningOutputDuringInterruptionWaitsForResume() throws {
    let player = TestRoomAudioPlayer(), playback = RoomAudioPlayback(makePlayer: { player })
    try playback.start { {} }
    defer { playback.stop() }
    playback.suspend()
    try playback.setOutputDeviceID("usb-test")
    try playback.ensurePlaying()
    #expect(player.outputDeviceID == "usb-test" && !player.isPlaying && player.starts == 1)
    try playback.resume()
    #expect(player.isPlaying && player.starts == 2)
    player.canPlay = false
    #expect(throws: ClientFailure.self) { try playback.setOutputDeviceID(nil) }
    #expect(!player.isPlaying)
}

@Test @MainActor func listeningPlaybackRollsBackPlayerConstructionFailure() {
    var releases = 0
    let playback = RoomAudioPlayback(makePlayer: { throw ClientFailure(.voiceConnectionFailed) })
    #expect(throws: ClientFailure.self) { try playback.start { { releases += 1 } } }
    playback.stop()
    #expect(releases == 1)
}

@Test @MainActor func listeningPlaybackDoesNotCreatePlayerWithoutSessionOwnership() {
    var created = false
    let playback = RoomAudioPlayback(makePlayer: { created = true; return TestRoomAudioPlayer() })
    #expect(throws: ClientFailure.self) {
        try playback.start { throw ClientFailure(.voiceConnectionFailed) }
    }
    #expect(!created)
}

@Test @MainActor func listeningSilenceDecodesWithoutOpeningAnyAudioDevice() throws {
    let data = RoomAudioPlayback.silence
    #expect(data.count == 16_044)
    #expect(data.dropFirst(44).allSatisfy { $0 == 0 })
    let player = try AVAudioPlayer(data: data)
    #expect(abs(player.duration - 1) < 0.001)
    #expect(player.numberOfChannels == 1 && !player.isPlaying)
}
