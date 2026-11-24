import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

@Test func attachmentBudgetIsAggregateWithinOneDirectionAndDoesNotBankIdleCredit() async throws {
    let chunk = AttachmentTransport.chunkBytes
    let budget = AttachmentBandwidth(normalRate: chunk * 10)
    let start=ContinuousClock.now, deadline=start.advanced(by:.seconds(3))
    async let upload: Void = budget.acquire(chunk,deadline:deadline)
    async let download: Void = budget.acquire(chunk,deadline:deadline)
    async let retry: Void = budget.acquire(chunk,deadline:deadline)
    _=try await (upload,download,retry)
    #expect(start.duration(to:.now) >= .milliseconds(190))
    try await Task.sleep(for:.milliseconds(150))
    let fresh=ContinuousClock.now
    try await budget.acquire(chunk,deadline:deadline)
    try await budget.acquire(chunk,deadline:deadline)
    #expect(fresh.duration(to:.now) >= .milliseconds(90))
}

@Test func attachmentUploadAndDownloadHaveIndependentBudgetsIncludingRetries() async throws {
    let chunk = AttachmentTransport.chunkBytes
    let budget = AttachmentBandwidth(normalRate: chunk)
    try await budget.acquire(chunk, direction: .upload, deadline: .now.advanced(by: .seconds(1)))
    try await budget.acquire(chunk, direction: .download, deadline: .now.advanced(by: .milliseconds(200)))
    do {
        try await budget.acquire(chunk, direction: .download, deadline: .now.advanced(by: .milliseconds(100)))
        Issue.record("A download retry bypassed its direction's budget")
    } catch let error as URLError { #expect(error.code == .timedOut) }
}

@Test func voicePauseCancellationAndSlowBudgetHaveBoundedWaits() async throws {
    let chunk=AttachmentTransport.chunkBytes
    let budget=AttachmentBandwidth(normalRate:chunk*100,constrainedRate:chunk*5)
    await budget.update(.paused)
    let pending=Task { try await budget.acquire(chunk,deadline:.now.advanced(by:.seconds(2))) }
    try await Task.sleep(for:.milliseconds(40)); pending.cancel()
    do { try await pending.value; Issue.record("Cancelled request consumed a grant") }
    catch { #expect(error is CancellationError) }
    do { try await budget.acquire(chunk,deadline:.now.advanced(by:.milliseconds(60))); Issue.record("Paused budget ignored its deadline") }
    catch let error as URLError { #expect(error.code == .timedOut) }
    await budget.update(.constrained)
    let start=ContinuousClock.now
    try await budget.acquire(chunk,deadline:.now.advanced(by:.seconds(2)))
    try await budget.acquire(chunk,deadline:.now.advanced(by:.seconds(2)))
    #expect(start.duration(to:.now) >= .milliseconds(190))
    await budget.update(.normal)
}

@Test func attachmentPolicyUsesActiveAudibleTrackQualityAndRecoversWithVoice() {
    var track=CallTrackDiagnostic(id:"track",identity:"peer.login.entry",muted:false,subscribed:true,
        encryption:.verified,quality:.good)
    #expect(AttachmentNetworkPolicy.forCall(phase:.recovering,tracks:[]) == .paused)
    #expect(AttachmentNetworkPolicy.forCall(phase:.active,tracks:[track]) == .normal)
    track.quality = .poor
    #expect(AttachmentNetworkPolicy.forCall(phase:.active,tracks:[track]) == .constrained)
    track.quality = .lost
    #expect(AttachmentNetworkPolicy.forCall(phase:.active,tracks:[track]) == .paused)
    track.muted=true
    #expect(AttachmentNetworkPolicy.forCall(phase:.active,tracks:[track]) == .normal)
    track.muted=false; track.quality = .good; track.jitterMS=60
    #expect(AttachmentNetworkPolicy.forCall(phase:.active,tracks:[track]) == .constrained)
    track.jitterMS=4; track.roundTripMS=10
    #expect(AttachmentNetworkPolicy.forCall(phase:.active,tracks:[track]) == .normal)
    track.roundTripMS=400
    #expect(AttachmentNetworkPolicy.forCall(phase:.active,tracks:[track]) == .normal)
}
