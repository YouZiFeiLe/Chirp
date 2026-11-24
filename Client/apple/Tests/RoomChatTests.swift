import ChirpMLS
import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

private func admission(_ name: String, entry: String = "first", room: String = "friends") -> RoomAdmission {
    RoomAdmission(roomID: room, entryID: entry, identity: "\(name).login.\(entry)")
}

private func install(_ chat: inout RoomChat, group: String, peers: [RoomAdmission]) {
    chat.pause()
    chat.install(groupID: group, members: peers.map {
        MLSPeer(identity: $0.identity, name: $0.identity.components(separatedBy: ".")[0], publicKey: "", keyPackage: "")
    })
    chat.activate()
}

private func send(_ chat: inout RoomChat, _ text: String) throws -> Data {
    chat.setDraft(text, entryID: chat.admission!.entryID)
    let (envelope, data) = try chat.prepare()
    chat.finish(envelope.id, succeeded: true)
    return data
}

@Test func chatSupportsMoreThanTwentyAuthorizedMembers() throws {
    let peers = (0..<32).map { admission("member_\($0)", room: "room_dynamic") }
    var chat = RoomChat()
    chat.begin(peers[0])
    install(&chat, group: "room_dynamic/server/session/1", peers: peers)
    #expect(chat.isReady)
    #expect(try !send(&chat, "多人房间").isEmpty)
}

@Test func nicknameRefreshChangesFutureLabelsWithoutChangingMembershipOrEarlierMessages() throws {
    let a = admission("member_alice"), b = admission("member_bob"), c = admission("member_carol")
    var alice = RoomChat(), bob = RoomChat(), carol = RoomChat()
    alice.begin(a); bob.begin(b); carol.begin(c)
    install(&alice, group: "friends/server/session/1", peers: [a, b])
    install(&bob, group: "friends/server/session/1", peers: [a, b])
    install(&carol, group: "friends/server/session/1", peers: [a, b, c])
    let before = try send(&bob, "before")
    #expect({ alice.receive(before, sender: b.identity, encrypted: true) }())
    alice.updateDisplayNames(["member_bob": "新昵称", "member_carol": "unapproved"])
    let after = try send(&bob, "after")
    #expect({ alice.receive(after, sender: b.identity, encrypted: true) }())
    #expect(alice.messages.map(\.senderName) == ["member_bob", "新昵称"])
    let forged = try send(&carol, "forged membership")
    #expect({ !alice.receive(forged, sender: c.identity, encrypted: true) }())
    #expect(alice.groupID == "friends/server/session/1" && alice.isReady)
}

@Test func chatAdmissionScenarioKeepsOnlyMessagesActuallyReceivedAndClearsOnReentry() throws {
    let a = admission("A"), b = admission("B"), c = admission("C")
    var alice = RoomChat(), bob = RoomChat(), carol = RoomChat()
    alice.begin(a)
    #expect(!alice.isVisible && !alice.canSend)
    install(&alice, group: "friends/server/session/1", peers: [a])
    _ = try send(&alice, "消息 1")

    bob.begin(b)
    install(&alice, group: "friends/server/session/2", peers: [a, b])
    install(&bob, group: "friends/server/session/2", peers: [a, b])
    #expect(try { alice.receive(try send(&bob, "消息 2"), sender: b.identity, encrypted: true) }())
    #expect(try { bob.receive(try send(&alice, "消息 3"), sender: a.identity, encrypted: true) }())

    carol.begin(c)
    for target in [0, 1, 2] {
        switch target {
        case 0: install(&alice, group: "friends/server/session/3", peers: [a, b, c])
        case 1: install(&bob, group: "friends/server/session/3", peers: [a, b, c])
        default: install(&carol, group: "friends/server/session/3", peers: [a, b, c])
        }
    }
    let fourth = try send(&carol, "消息 4")
    #expect({ alice.receive(fourth, sender: c.identity, encrypted: true) }())
    #expect({ bob.receive(fourth, sender: c.identity, encrypted: true) }())
    #expect(alice.messages.map(\.text) == ["消息 1", "消息 2", "消息 3", "消息 4"])
    #expect(bob.messages.map(\.text) == ["消息 2", "消息 3", "消息 4"])
    #expect(carol.messages.map(\.text) == ["消息 4"])

    carol.setDraft("离房前草稿", entryID: carol.admission!.entryID)
    carol.end()
    #expect(!carol.isVisible && carol.messages.isEmpty && carol.draft.isEmpty && carol.groupID == nil)
    let c2 = admission("C", entry: "second")
    carol.begin(c2)
    for target in [0, 1, 2] {
        switch target {
        case 0: install(&alice, group: "friends/server/session/5", peers: [a, b, c2])
        case 1: install(&bob, group: "friends/server/session/5", peers: [a, b, c2])
        default: install(&carol, group: "friends/server/session/5", peers: [a, b, c2])
        }
    }
    #expect(carol.messages.isEmpty)
    #expect({ !carol.receive(fourth, sender: c.identity, encrypted: true) }())
    #expect(try { carol.receive(try send(&alice, "重进后的新消息"), sender: a.identity, encrypted: true) }())
    #expect(carol.messages.map(\.text) == ["重进后的新消息"])

    alice.end(); bob.end(); carol.end()
    alice.begin(admission("A", entry: "second"))
    install(&alice, group: "friends/server/new-session/1", peers: [admission("A", entry: "second")])
    #expect(alice.messages.isEmpty && alice.draft.isEmpty)
    #expect({ !alice.receive(fourth, sender: c.identity, encrypted: true) }())
}

@Test func chatRejectsPlaintextWrongEpochIdentityReplayAndInvalidContent() throws {
    let a = admission("A"), b = admission("B")
    let group = "friends/server/session/1"
    var chat = RoomChat()
    chat.begin(a); install(&chat, group: group, peers: [a, b])
    func packet(version: Int = 1, groupID: String = "friends/server/session/1", sender: String? = nil,
                sequence: UInt64 = 1, text: String = "hello") throws -> Data {
        try JSONEncoder().encode(ChatEnvelope(version: version, id: UUID(), groupID: groupID,
            sender: sender ?? b.identity, sequence: sequence, text: text))
    }
    let good = try packet()
    #expect({ !chat.receive(good, sender: b.identity, encrypted: false) }())
    #expect({ !chat.receive(good, sender: nil, encrypted: true) }())
    #expect({ !chat.receive(good, sender: "unknown", encrypted: true) }())
    #expect(try { !chat.receive(try packet(sender: a.identity), sender: b.identity, encrypted: true) }())
    #expect(try { !chat.receive(try packet(version: 2), sender: b.identity, encrypted: true) }())
    #expect(try { !chat.receive(try packet(groupID: "room-2/server/session/1"), sender: b.identity, encrypted: true) }())
    #expect(try { !chat.receive(try packet(groupID: "friends/server/session/0"), sender: b.identity, encrypted: true) }())
    #expect(try { !chat.receive(try packet(sequence: 0), sender: b.identity, encrypted: true) }())
    #expect(try { !chat.receive(try packet(text: " \n\t"), sender: b.identity, encrypted: true) }())
    #expect(try { !chat.receive(try packet(text: "hidden\u{0}control"), sender: b.identity, encrypted: true) }())
    #expect(try { !chat.receive(try packet(text: String(repeating: "a", count: 4097)), sender: b.identity, encrypted: true) }())
    #expect({ !chat.receive(Data(repeating: 0, count: RoomChat.maxPacketBytes + 1), sender: b.identity, encrypted: true) }())
    #expect({ !chat.receive(Data("invalid JSON".utf8), sender: b.identity, encrypted: true) }())
    #expect({ chat.receive(good, sender: b.identity, encrypted: true) }())
    #expect({ !chat.receive(good, sender: b.identity, encrypted: true) }())
    let original = try JSONDecoder().decode(ChatEnvelope.self, from: good)
    let reusedID = try JSONEncoder().encode(ChatEnvelope(version: 1, id: original.id, groupID: group,
        sender: b.identity, sequence: 2, text: "reused display identity"))
    #expect({ !chat.receive(reusedID, sender: b.identity, encrypted: true) }())
    #expect(chat.messages.count == 1)
    chat.pause()
    #expect(try { !chat.receive(try packet(sequence: 2), sender: b.identity, encrypted: true) }())
    install(&chat, group: "friends/server/session/2", peers: [a, b])
    #expect(try { !chat.receive(try packet(), sender: b.identity, encrypted: true) }())
    #expect(try { !chat.receive(try packet(groupID: "friends/server/session/2"), sender: b.identity, encrypted: true) }())
    #expect(try { chat.receive(try packet(groupID: "friends/server/session/2", sequence: 2), sender: b.identity, encrypted: true) }())
}

@Test func chatPauseRetainsTranscriptAndDraftButCancelsPendingAndIgnoresLateCompletion() throws {
    let a = admission("A")
    var chat = RoomChat()
    chat.begin(a); install(&chat, group: "friends/server/session/1", peers: [a])
    chat.setDraft("waiting", entryID: chat.admission!.entryID)
    let (pending, _) = try chat.prepare()
    #expect(chat.messages.last?.delivery == .sending && chat.pendingID != nil)
    chat.setDraft("next draft", entryID: chat.admission!.entryID)
    chat.pause()
    #expect(chat.isVisible && !chat.isReady && !chat.canSend)
    #expect(chat.messages.last?.delivery == .failed && chat.pendingID == nil)
    #expect(chat.draft == "next draft")
    chat.finish(pending.id, succeeded: true)
    #expect(chat.messages.last?.delivery == .failed)
    install(&chat, group: "friends/server/session/2", peers: [a])
    #expect(chat.canSend && chat.messages.count == 1)
    chat.end(); chat.begin(admission("A", entry: "second", room: "room-2"))
    chat.finish(pending.id, succeeded: true)
    #expect(!chat.isVisible && chat.messages.isEmpty && chat.draft.isEmpty && chat.error == nil)
}

@Test func chatBoundsUTF8DraftAndTranscriptWithoutPersistingHistory() throws {
    let a = admission("A"), b = admission("B")
    var chat = RoomChat()
    chat.begin(a); install(&chat, group: "friends/server/session/1", peers: [a, b])
    chat.setDraft(String(repeating: "😀", count: 1024), entryID: chat.admission!.entryID)
    #expect(chat.canSend && chat.draft.utf8.count == 4096)
    chat.setDraft(String(repeating: "😀", count: 1025), entryID: chat.admission!.entryID)
    #expect(chat.draft.utf8.count == 4096 && chat.error != nil)
    let (pending, _) = try chat.prepare()
    chat.setDraft("next message", entryID: chat.admission!.entryID)
    for index in 1...1001 {
        let data = try JSONEncoder().encode(ChatEnvelope(version: 1, id: UUID(), groupID: "friends/server/session/1",
            sender: b.identity, sequence: UInt64(index), text: "message \(index)"))
        #expect({ chat.receive(data, sender: b.identity, encrypted: true) }())
    }
    #expect(chat.messages.count == 1000 && chat.messages.first?.text == "message 2")
    #expect(chat.hasTrimmedMessages)
    chat.finish(pending.id, succeeded: true)
    #expect(chat.pendingID == nil && chat.canSend)
    chat.end()
    #expect(chat.messages.isEmpty && chat.draft.isEmpty && chat.admission == nil)
}

@Test func lateEditorBindingCannotRestoreADraftAfterLeavingOrIntoANewAdmission() {
    let old = admission("A")
    var chat = RoomChat()
    chat.begin(old)
    chat.setDraft("not joined yet", entryID: old.entryID)
    #expect(chat.draft.isEmpty)
    install(&chat, group: "friends/server/session/1", peers: [old])
    chat.setDraft("draft", entryID: old.entryID)
    chat.end()
    chat.setDraft("late update", entryID: old.entryID)
    #expect(chat.draft.isEmpty)
    let next = admission("A", entry: "second")
    chat.begin(next)
    install(&chat, group: "friends/server/session/2", peers: [next])
    chat.setDraft("late update from old editor", entryID: old.entryID)
    #expect(chat.draft.isEmpty)
    chat.setDraft("new draft", entryID: next.entryID)
    #expect(chat.draft == "new draft")
}

@Test func failedTextRestoresOnlyByUserActionWithoutOverwritingDraftOrCrossingAdmission() throws {
    let a = admission("A"), b = admission("B")
    var chat = RoomChat()
    chat.begin(a); install(&chat, group: "friends/server/session/1", peers: [a,b])
    chat.setDraft("Please resend this", entryID: a.entryID)
    let (failed, _) = try chat.prepare()
    chat.pause()
    #expect(chat.draft.isEmpty && chat.messages.last?.delivery == .failed)
    chat.setDraft("Already editing", entryID: a.entryID)
    #expect({ !chat.restoreFailed(failed.id, entryID: a.entryID) }())
    #expect(chat.draft == "Already editing")
    chat.setDraft("", entryID: a.entryID)
    #expect({ !chat.restoreFailed(failed.id, entryID: "another-entry") }())
    #expect({ chat.restoreFailed(failed.id, entryID: a.entryID) }())
    #expect(chat.draft == failed.text && chat.pendingID == nil && !chat.canSend)
    // A later explicit send creates a fresh envelope for current membership.
    install(&chat, group: "friends/server/session/2", peers: [a])
    let (resent, _) = try chat.prepare()
    #expect(resent.id != failed.id && resent.sequence > failed.sequence && resent.groupID != failed.groupID)
    #expect(resent.text == failed.text && chat.messages[0].delivery == .failed)
    chat.finish(resent.id, succeeded: true)
    #expect({ !chat.restoreFailed(resent.id, entryID: a.entryID) }())
    chat.end(); let next = admission("A", entry: "new-entry")
    chat.begin(next); install(&chat, group: "friends/server/session/3", peers: [next])
    #expect({ !chat.restoreFailed(failed.id, entryID: a.entryID) }())
    #expect({ !chat.restoreFailed(failed.id, entryID: next.entryID) }() && chat.draft.isEmpty && chat.messages.isEmpty)
}

@Test func failedAttachmentDescriptorsCannotBeRestoredAsTextOrRebroadcast() throws {
    let a=admission("A")
    var chat=RoomChat(); chat.begin(a); install(&chat, group:"friends/server/session/1",peers:[a])
    let info=AttachmentInfo(version:1,id:String(repeating:"a",count:32),roomID:a.roomID,sender:a.identity,
        name:"file.bin",mimeType:"application/octet-stream",size:32,digest:String(repeating:"0",count:64),hasThumbnail:false)
    let (message,_)=try chat.prepareAttachment(AttachmentDescriptor(info:info,key:Data(repeating:1,count:32),thumbnail:nil))
    chat.finish(message.id,succeeded:false)
    #expect({ !chat.restoreFailed(message.id,entryID:a.entryID) }() && chat.draft.isEmpty)
}
