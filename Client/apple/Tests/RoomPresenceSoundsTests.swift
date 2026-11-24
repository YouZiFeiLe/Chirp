import AVFoundation
import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

@MainActor
private final class TestRoomSoundPlayer: RoomSoundPlaying {
    var isPlaying = false
    var canPlay = true
    var outputDeviceID: String?
    var stops = 0
    func play() -> Bool { isPlaying = canPlay; return canPlay }
    func stop() { stops += 1; isPlaying = false }
    func setOutputDeviceID(_ id: String?) { outputDeviceID = id }
}

@MainActor
private func soundEventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw NSError(domain: "Room sound condition timed out", code: 1) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test func confirmedPresenceIgnoresRekeysAndCoalescesEachKindOfMembershipChange() {
    var tracker = RoomPresenceTracker()
    #expect(tracker.confirm(["self", "a", "b"], localIdentity: "self") == [.joined])
    #expect(tracker.confirm(["b", "self", "a"], localIdentity: "self").isEmpty)
    #expect(tracker.confirm(["self", "c", "d"], localIdentity: "self") == [.left, .joined])
    #expect(tracker.confirm(["self"], localIdentity: "self") == [.left])
    #expect(tracker.confirm(["self"], localIdentity: "self").isEmpty)
}

@Test func presenceRecoveryEstablishesASilentBaselineWithoutRepeatingOurEntry() {
    var tracker = RoomPresenceTracker()
    tracker.resynchronize() // An interruption before first readiness still allows our confirmation.
    #expect(tracker.confirm(["self", "a"], localIdentity: "self") == [.joined])
    tracker.resynchronize()
    #expect(tracker.confirm(["self", "b"], localIdentity: "self").isEmpty)
    #expect(tracker.confirm(["self", "b", "c"], localIdentity: "self") == [.joined])
    #expect(tracker.confirm([], localIdentity: "self").isEmpty)
    #expect(tracker.confirm(["self", "b", "c"], localIdentity: "self").isEmpty)
}

@Test @MainActor func roomSoundsPlaySeriallyAndCoalescePendingDuplicates() async throws {
    var requested: [RoomPresenceSound] = [], players: [TestRoomSoundPlayer] = []
    let audio = RoomPresenceSounds(makePlayer: { sound in
        requested.append(sound)
        let player = TestRoomSoundPlayer(); players.append(player); return player
    })
    defer { audio.stop() }
    audio.enqueue(.joined)
    try await soundEventually { players.count == 1 }
    audio.enqueue(.left); audio.enqueue(.left)
    #expect(requested == [.joined] && players[0].isPlaying)
    players[0].isPlaying = false
    try await soundEventually { players.count == 2 }
    #expect(requested == [.joined, .left] && players[0].stops > 0 && players[1].isPlaying)
    players[1].isPlaying = false
    audio.enqueue(.joined)
    try await soundEventually { players.count == 3 }
    #expect(requested == [.joined, .left, .joined])
}

@Test @MainActor func stoppingRoomSoundsDiscardsTheOldQueueWithoutCancellingNewPlayback() async throws {
    var requested: [RoomPresenceSound] = [], players: [TestRoomSoundPlayer] = []
    let audio = RoomPresenceSounds(makePlayer: { sound in
        requested.append(sound)
        let player = TestRoomSoundPlayer(); players.append(player); return player
    })
    defer { audio.stop() }
    audio.enqueue(.joined)
    try await soundEventually { players.count == 1 }
    audio.enqueue(.left)
    audio.stop()
    #expect(!players[0].isPlaying)
    audio.enqueue(.joined)
    try await soundEventually { players.count == 2 }
    #expect(requested == [.joined, .joined] && players[1].isPlaying)
}

@Test @MainActor func roomSoundsFollowExplicitOutputAndReturnToTheSystemDevice() async throws {
    var players: [TestRoomSoundPlayer] = []
    let audio = RoomPresenceSounds(makePlayer: { _ in
        let player = TestRoomSoundPlayer(); players.append(player); return player
    })
    defer { audio.stop() }
    audio.setOutputDeviceID("usb-test")
    audio.enqueue(.joined)
    try await soundEventually { players.count == 1 }
    #expect(players[0].outputDeviceID == "usb-test")
    audio.enqueue(.left)
    audio.setOutputDeviceID("headphones-test")
    #expect(!players[0].isPlaying)
    audio.enqueue(.joined)
    try await soundEventually { players.count == 2 }
    #expect(players[1].outputDeviceID == "headphones-test")
    audio.setOutputDeviceID(nil)
    audio.enqueue(.left)
    try await soundEventually { players.count == 3 }
    #expect(players[2].outputDeviceID == nil && !players[1].isPlaying)
}

@Test @MainActor func roomSoundsDropExpiredAnnouncementsInsteadOfBuildingABacklog() async throws {
    var instant = ContinuousClock.now
    var requested: [RoomPresenceSound] = [], players: [TestRoomSoundPlayer] = []
    let audio = RoomPresenceSounds(makePlayer: { sound in
        requested.append(sound)
        let player = TestRoomSoundPlayer(); players.append(player); return player
    }, now: { instant })
    defer { audio.stop() }
    audio.enqueue(.joined)
    try await soundEventually { players.count == 1 }
    audio.enqueue(.left)
    instant = instant.advanced(by: .seconds(4))
    players[0].isPlaying = false
    audio.enqueue(.joined)
    try await soundEventually { players.count == 2 }
    #expect(requested == [.joined, .joined])
}

@Test @MainActor func failedRoomSoundsDoNotBlockLaterAnnouncements() async throws {
    var attempts = 0, players: [TestRoomSoundPlayer] = []
    let audio = RoomPresenceSounds(makePlayer: { _ in
        attempts += 1
        if attempts == 1 { throw CocoaError(.fileReadCorruptFile) }
        let player = TestRoomSoundPlayer()
        player.canPlay = attempts != 2
        players.append(player)
        return player
    })
    defer { audio.stop() }
    audio.enqueue(.joined); audio.enqueue(.left); audio.enqueue(.joined)
    try await soundEventually { attempts == 3 }
    #expect(players.count == 2 && players[0].stops > 0 && players[1].isPlaying)
}

@Test @MainActor func coalescedRoomSoundsKeepTheNewestEventsDeadline() async throws {
    var instant = ContinuousClock.now
    var requested: [RoomPresenceSound] = [], players: [TestRoomSoundPlayer] = []
    let audio = RoomPresenceSounds(makePlayer: { sound in
        requested.append(sound)
        let player = TestRoomSoundPlayer(); players.append(player); return player
    }, now: { instant })
    defer { audio.stop() }
    audio.enqueue(.joined)
    try await soundEventually { players.count == 1 }
    audio.enqueue(.left)
    instant = instant.advanced(by: .seconds(2))
    audio.enqueue(.left)
    instant = instant.advanced(by: .seconds(2))
    players[0].isPlaying = false
    try await soundEventually { players.count == 2 }
    #expect(requested == [.joined, .left])
}

@Test @MainActor func releasingRoomSoundsStopsOutputAndPendingAnnouncements() async throws {
    let player = TestRoomSoundPlayer()
    var audio: RoomPresenceSounds? = RoomPresenceSounds(makePlayer: { _ in player })
    audio?.enqueue(.joined)
    try await soundEventually { player.isPlaying }
    audio?.enqueue(.left)
    audio = nil
    #expect(!player.isPlaying && player.stops > 0)
}

@Test @MainActor func bundledRoomSoundsDecodeWithoutStartingAudioOutput() throws {
    for sound in RoomPresenceSound.allCases {
        let player = try AVAudioPlayer(contentsOf: #require(sound.resourceURL))
        #expect(player.duration > 1 && player.duration < 3)
        #expect(player.numberOfChannels == 1 && !player.isPlaying)
    }
}

@MainActor
private final class RoomSoundCompletion: NSObject, AVAudioPlayerDelegate {
    var completed: [Bool] = []
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        completed.append(flag)
    }
}

/// Run in a separate process to exercise cold, output-only playback. No input
/// device, microphone permission, room, login, or network transport is involved.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CHIRP_ROOM_SOUND_PLAYBACK_CHECK"] == "1"))
@MainActor struct RoomPresencePlaybackHardwareTests {
    @Test func coldListeningKeepsOutputRunningBetweenCompleteRoomCues() async throws {
        let silence = try AVAudioPlayer(data: RoomAudioPlayback.silence)
        let playback = RoomAudioPlayback(makePlayer: { silence })
        let completion = RoomSoundCompletion()
        let cues = RoomPresenceSounds(makePlayer: { sound in
            let player = try AVAudioPlayer(contentsOf: #require(sound.resourceURL))
            player.volume = 0.05
            player.delegate = completion
            return player
        })
        defer { cues.stop(); playback.stop() }
        try playback.start { {} }
        for (index, sound) in RoomPresenceSound.allCases.enumerated() {
            // Let the output advance without a microphone or remote audio,
            // including an idle gap longer than the silence buffer itself.
            try await Task.sleep(for: .milliseconds(1_200))
            #expect(silence.isPlaying && silence.numberOfLoops == -1)
            cues.enqueue(sound)
            try await soundEventually { completion.completed.count == index + 1 }
            #expect(completion.completed.allSatisfy { $0 } && silence.isPlaying)
        }
        playback.stop()
        #expect(!silence.isPlaying)
    }
}
