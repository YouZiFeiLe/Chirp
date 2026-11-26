import ChirpMLS
import Foundation
import Testing

@Test func nativeRecoveryReadsIndependentGoContainerVector() async throws {
    let url = try #require(Bundle.module.url(forResource: "recovery-v1", withExtension: "json", subdirectory: "Fixtures"))
    let vector = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    let native = try MLSClient(identity: "public-recovery-vector")
    let response = try await native.security(["action": "decrypt", "file": vector["file"]!, "password": vector["password"]!])
    let decoded = try JSONDecoder().decode([String: String].self, from: response)
    #expect(decoded["payload"] == vector["payload"])
}
