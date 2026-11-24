import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

@Test func onlyAnExactCurrentRoundCanGrantMediaPermission() throws {
    let expected = GroupSnapshot(roomID: "friends", protocolName: VoiceRooms.keyProtocol, serverID: "server", sessionID: "session",
                                 generation: 3, phase: "ready", leader: "member", members: [], welcome: "", confirmation: "confirmed", revision: 9, suspended: false)
    func pulse(room: String = "friends", server: String = "server", generation: UInt64 = 3, revision: UInt64 = 9,
               phase: String = "ready", suspended: Bool = false, lease: Int = 3000) -> GroupPulse {
        GroupPulse(roomID: room, protocolName: VoiceRooms.keyProtocol, serverID: server, sessionID: "session", generation: generation,
                   revision: revision, phase: phase, suspended: suspended, leaseMS: lease)
    }
    try pulse().validate(expected: expected, grantingLease: true)
    // A notification/heartbeat can announce a later generation, but cannot
    // authorize it before its complete snapshot and key installation.
    try pulse(generation: 4, revision: 10, phase: "collecting", lease: 0).validate(expected: expected, grantingLease: false)
    for reply in [pulse(room: "other"), pulse(server: "restarted"), pulse(generation: 4), pulse(generation: 4, revision: 10),
                  pulse(revision: 10), pulse(revision: 8), pulse(phase: "confirming"), pulse(suspended: true), pulse(lease: 0), pulse(lease: 3001)] {
        #expect(throws: (any Error).self) { try reply.validate(expected: expected, grantingLease: true) }
    }
    #expect(throws: (any Error).self) { try pulse().validate(expected: expected, grantingLease: false) }
}
