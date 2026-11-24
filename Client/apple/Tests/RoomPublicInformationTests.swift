import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

private func publicInformationFixture() -> GroupRoomInformation {
    GroupRoomInformation(serverTimeMS: 1_800_000_000_000, rotationIntervalMS: 60_000,
        keyEpoch: 1, memberCount: 3, updateReason: "scheduled_rotation",
        establishedAtMS: 1_799_999_900_000, lastRotationAtMS: 1_799_999_980_000,
        nextRotationAtMS: 1_800_000_040_000)
}

@Test func roomInformationCountdownConsumesTransitAndSleepAndNeverImpliesCompletion() throws {
    let started = ContinuousClock.now
    let value = RoomPublicInformation(groupID: "room/server/session/1", information: publicInformationFixture(), requestStartedAt: started)
    #expect(value.nextRotationSeconds(at: started.advanced(by: .milliseconds(1_200))) == 39)
    #expect(value.isFresh(at: started.advanced(by: .milliseconds(5_999))))
    #expect(!value.isFresh(at: started.advanced(by: .seconds(6))))
    #expect(value.nextRotationSeconds(at: started.advanced(by: .seconds(40))) == nil)
    #expect(!value.isFresh(at: started.advanced(by: .seconds(-1))))
    var paused = value
    paused.unavailable = true
    #expect(paused.nextRotationSeconds(at: started) == nil)
    var due = publicInformationFixture()
    due.nextRotationAtMS = due.serverTimeMS + 1_000
    let rotating = RoomPublicInformation(groupID: value.groupID, information: due, requestStartedAt: started)
    #expect(rotating.nextRotationSeconds(at: started.advanced(by: .seconds(2))) == 0)
    #expect(rotating.information.lastRotationAtMS == due.lastRotationAtMS)
}

@Test func roomInformationRejectsImpossibleMetadataWithoutChangingMediaPermission() throws {
    #expect(publicInformationFixture().isValid)
    var cases: [GroupRoomInformation] = []
    var value = publicInformationFixture(); value.lastRotationAtMS = value.serverTimeMS + 1; cases.append(value)
    value = publicInformationFixture(); value.nextRotationAtMS = value.serverTimeMS + value.rotationIntervalMS + 1; cases.append(value)
    value = publicInformationFixture(); value.establishedAtMS = nil; cases.append(value)
    value = publicInformationFixture(); value.rotationPhase = "switching"; value.rotationEpoch = 5; cases.append(value)
    value = publicInformationFixture(); value.confirmedMembers = 4; cases.append(value)
    value = publicInformationFixture(); value.activatedMembers = 1; cases.append(value)
    for value in cases { #expect(!value.isValid) }
    let hostile = GroupRoomInformation(serverTimeMS: Int64.max, rotationIntervalMS: 60_000, keyEpoch: UInt64.max,
                                       memberCount: 3, updateReason: "scheduled_rotation")
    #expect(!hostile.isValid)

    let data = try JSONEncoder().encode(publicInformationFixture())
    let decoded = try JSONDecoder().decode(GroupRoomInformation.self, from: data)
    #expect(decoded == publicInformationFixture())
    var collecting = GroupRoomInformation(serverTimeMS: 1_800_000_000_000, rotationIntervalMS: 60_000,
                                          keyEpoch: 0, memberCount: 1, updateReason: "initial_connection")
    #expect(collecting.isValid && collecting.establishedAtMS == nil && collecting.lastRotationAtMS == nil)
    collecting.rotationPhase = "collecting"; collecting.rotationEpoch = 1
    #expect(collecting.isValid)
}

@Test func legacyGroupSnapshotsRemainDecodableWithoutPublicInformation() throws {
    let bytes = Data(#"{"room_id":"r","protocol":"chirp-mls-authenticated-v5","server_id":"s","session_id":"c","generation":1,"phase":"collecting","leader":"p","members":[],"welcome":"","confirmation":"","revision":2,"suspended":false}"#.utf8)
    let snapshot = try JSONDecoder().decode(GroupSnapshot.self, from: bytes)
    #expect(snapshot.roomInformation == nil)
}
