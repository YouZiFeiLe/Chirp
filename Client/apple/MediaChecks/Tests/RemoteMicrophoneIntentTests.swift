import Foundation
import LiveKitWebRTC
import Testing
@testable import LiveKit
@testable import LiveKitNanopb

@Test func serverCannotUnmuteAUserMutedMicrophoneWithoutLocalAuthorization() async throws {
    let room = Room()
    let track = await LocalAudioTrack.createTrack()
    try await track.mute()
    let publication = LocalTrackPublication(info: .with {
        $0.sid = "TR_audit_muted"
        $0.type = .audio
        $0.source = .microphone
        $0.encryption = .gcm
    }, participant: room.localParticipant)
    await publication.set(track: track)
    room.localParticipant.add(publication: publication)
    #expect(track.isMuted)
    #expect(await RTC.run { !track.mediaTrack.raw.isEnabled })
    await room.signalClient(room.signalClient, didUpdateRemoteMute: publication.sid, muted: false)
    #expect(track.isMuted)
    #expect(await RTC.run { !track.mediaTrack.raw.isEnabled })
    #expect(Room.chirpLocalMicrophoneIntent)
    #expect(track.trackState == .stopped)
}
