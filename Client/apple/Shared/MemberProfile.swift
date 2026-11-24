import Foundation

struct MemberProfile: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let displayName: String
    let profileRevision: Int64
    let avatarRevision: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name", profileRevision = "profile_revision", avatarRevision = "avatar_revision"
    }

    func validated() throws -> Self {
        let validAvatar = avatarRevision.map {
            $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        } ?? true
        guard id.hasPrefix("member_"), id.utf8.count <= 64,
              id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }),
              VoiceRooms.validName(displayName), profileRevision >= 0,
              validAvatar else {
            throw ClientFailure(.invalidMemberProfiles)
        }
        return self
    }

    static func memberID(for identity: String) -> String {
        String(identity.prefix { $0 != "." })
    }
}

struct MemberProfilesResponse: Decodable, Sendable {
    let members: [MemberProfile]

    func validatedMembers() throws -> [MemberProfile] {
        guard Set(members.map(\.id)).count == members.count else {
            throw ClientFailure(.invalidMemberProfiles)
        }
        return try members.map { try $0.validated() }
    }
}
