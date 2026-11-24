import Foundation
import ChirpMLS

struct ChatEnvelope: Codable, Sendable {
    let version: Int
    let id: UUID
    let groupID: String
    let sender: String
    let sequence: UInt64
    let text: String
    var attachment: AttachmentDescriptor? = nil
}

struct ChatMessage: Identifiable, Sendable, Equatable {
    enum Delivery: Sendable, Equatable { case sending, sent, failed, received }
    let messageID: UUID
    let sender: String
    let senderName: String
    let text: String
    let time: Date
    var attachment: AttachmentInfo? = nil
    var delivery: Delivery
    var id: String { sender + ":" + messageID.uuidString }
}

// One admission owns all plaintext. Pausing a generation retains the transcript;
// ending the admission discards it. A user may copy failed text into this
// admission's empty draft; it is never replayed or sent automatically.
struct RoomChat {
    static let topic = "chirp.room-chat.v1"
    static let maxTextBytes = 4096
    static let maxPacketBytes = 12 * 1024
    static let maxMessages = 1000

    private(set) var admission: RoomAdmission?
    private(set) var groupID: String?
    private(set) var isVisible = false
    private(set) var isReady = false
    private(set) var messages: [ChatMessage] = []
    private(set) var pendingID: UUID?
    private(set) var error: ClientFailure?
    private(set) var hasTrimmedMessages = false
    private(set) var draft = ""
    private var names: [String: String] = [:]
    private var sequence: UInt64 = 0
    private var receivedSequences: [String: UInt64] = [:]

    var canSend: Bool { isReady && pendingID == nil && Self.validText(draft) }

    static func validText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.utf8.count <= maxTextBytes
            && !text.unicodeScalars.contains { scalar in
                scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\t"
            }
    }

    mutating func setDraft(_ text: String, entryID: String) {
        guard isVisible, admission?.entryID == entryID else { return }
        if draft.isEmpty && !text.isEmpty { ClientLog.shared.record(.chat, "compose") }
        if !draft.isEmpty && text.isEmpty { ClientLog.shared.record(.chat, "discardDraft") }
        // Also bound pasted input; do not hold an arbitrarily large draft.
        if text.utf8.count <= Self.maxTextBytes { draft = text; error = nil }
        else { error = ClientFailure(.chatTextTooLong) }
    }

    func canRestoreFailed(_ id: UUID, entryID: String) -> Bool {
        guard isVisible, admission?.entryID == entryID, draft.isEmpty, let identity = admission?.identity else { return false }
        return messages.contains { $0.messageID == id && $0.sender == identity && $0.delivery == .failed
            && $0.attachment == nil && Self.validText($0.text) }
    }

    @discardableResult
    mutating func restoreFailed(_ id: UUID, entryID: String) -> Bool {
        guard canRestoreFailed(id, entryID: entryID),
              let message = messages.first(where: { $0.messageID == id && $0.sender == admission?.identity }) else { return false }
        ClientLog.shared.record(.chat, "restoreDraft")
        draft = message.text; error = nil
        return true
    }

    mutating func begin(_ admission: RoomAdmission) {
        self = RoomChat()
        self.admission = admission
    }

    mutating func install(groupID: String, members: [MLSPeer]) {
        guard let admission, groupID.hasPrefix(admission.roomID + "/"),
              Set(members.map(\.identity)).count == members.count,
              members.contains(where: { $0.identity == admission.identity }) else { return }
        self.groupID = groupID
        names = Dictionary(uniqueKeysWithValues: members.map { ($0.identity, $0.name) })
        receivedSequences = receivedSequences.filter { names[$0.key] != nil }
    }

    mutating func activate() {
        guard admission != nil, groupID != nil else { return }
        isVisible = true
        isReady = true
    }

    // Update labels only for existing cryptographic members. Earlier messages
    // keep their send-time names; profile updates cannot authorize a new sender.
    mutating func updateDisplayNames(_ profiles: [String: String]) {
        for identity in Array(names.keys) {
            if let name = profiles[MemberProfile.memberID(for: identity)] { names[identity] = name }
        }
    }

    mutating func pause() {
        isReady = false
        if let pendingID { finish(pendingID, succeeded: false) }
    }

    mutating func end() { self = RoomChat() }

    mutating func prepare() throws -> (ChatEnvelope, Data) {
        guard canSend, let admission, let groupID, sequence < UInt64.max else {
            throw ClientFailure(.chatNotReady)
        }
        let envelope = ChatEnvelope(version: 1, id: UUID(), groupID: groupID,
                                    sender: admission.identity, sequence: sequence + 1, text: draft)
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= Self.maxPacketBytes else { throw ClientFailure(.chatPacketTooLong) }
        sequence = envelope.sequence
        append(ChatMessage(messageID: envelope.id, sender: envelope.sender,
                           senderName: names[envelope.sender] ?? envelope.sender, text: envelope.text,
                           time: Date(), delivery: .sending))
        ClientLog.shared.record(.chat, "sendMessage", outcome: .started)
        pendingID = envelope.id
        draft = ""
        error = nil
        return (envelope, data)
    }

    mutating func preparationFailed() { error = ClientFailure(.chatPreparationFailed) }

    mutating func prepareAttachment(_ descriptor: AttachmentDescriptor) throws -> (ChatEnvelope, Data) {
        guard isReady, pendingID == nil, let admission, let groupID, descriptor.isValid,
              descriptor.info.roomID == admission.roomID, descriptor.info.sender == admission.identity,
              sequence < UInt64.max else { throw ClientFailure(.chatNotReady) }
        let envelope = ChatEnvelope(version: 2, id: UUID(), groupID: groupID, sender: admission.identity,
            sequence: sequence + 1, text: "", attachment: descriptor)
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= Self.maxPacketBytes else { throw ClientFailure(.chatPacketTooLong) }
        sequence = envelope.sequence
        append(ChatMessage(messageID: envelope.id, sender: envelope.sender,
            senderName: names[envelope.sender] ?? envelope.sender, text: "", time: Date(), attachment: descriptor.info, delivery: .sending))
        ClientLog.shared.record(.chat, "sendAttachment", outcome: .started)
        pendingID = envelope.id; error = nil
        return (envelope, data)
    }

    mutating func finish(_ id: UUID, succeeded: Bool) {
        guard pendingID == id else { return }
        if let index = messages.firstIndex(where: { $0.messageID == id && $0.sender == admission?.identity }) {
            ClientLog.shared.record(.chat, messages[index].attachment == nil ? "sendMessage" : "sendAttachment",
                                    outcome: succeeded ? .succeeded : .failed)
            messages[index].delivery = succeeded ? .sent : .failed
        }
        pendingID = nil
        if !succeeded { error = ClientFailure(.chatSendFailed) }
    }

    @discardableResult
    mutating func receive(_ data: Data, sender: String?, encrypted: Bool,
                          onAttachment: ((AttachmentDescriptor) -> Bool)? = nil) -> Bool {
        guard isReady, let admission, encrypted, let sender, sender != admission.identity,
              let name = names[sender], data.count <= Self.maxPacketBytes,
              let envelope = try? JSONDecoder().decode(ChatEnvelope.self, from: data),
              envelope.groupID == groupID, envelope.sender == sender,
              envelope.sequence > (receivedSequences[sender] ?? 0),
              !messages.contains(where: { $0.sender == sender && $0.messageID == envelope.id }) else { return false }
        if let attachment = envelope.attachment {
            guard envelope.version == 2, envelope.text.isEmpty, attachment.isValid,
                  attachment.info.roomID == admission.roomID, attachment.info.sender == sender,
                  onAttachment?(attachment) == true else { return false }
        } else { guard envelope.version == 1, Self.validText(envelope.text) else { return false } }
        ClientLog.shared.record(.chat, envelope.attachment == nil ? "receiveMessage" : "receiveAttachment")
        receivedSequences[sender] = envelope.sequence
        append(ChatMessage(messageID: envelope.id, sender: sender, senderName: name,
                           text: envelope.text, time: Date(), attachment: envelope.attachment?.info, delivery: .received))
        return true
    }

    private mutating func append(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > Self.maxMessages {
            messages.removeFirst(messages.count - Self.maxMessages)
            hasTrimmedMessages = true
        }
    }
}
