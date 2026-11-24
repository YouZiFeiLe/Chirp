import Dispatch
import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

@MainActor struct BrowserOpenerTests {
    private let url = URL(string: "https://keys.example.test/register")!

    @Test(arguments: [true, false])
    func completionCanArriveOnABackgroundQueue(accepted: Bool) async {
        let result = await BrowserOpener.open(url) { target, completion in
            MainActor.assertIsolated()
            #expect(target == url)
            DispatchQueue.global().async {
                #expect(!Thread.isMainThread)
                completion(accepted)
            }
        }
        MainActor.assertIsolated()
        #expect(result == accepted)
    }

    @Test func synchronousCompletionAlsoReturnsToTheCallingActor() async {
        let result = await BrowserOpener.open(url) { _, completion in completion(true) }
        MainActor.assertIsolated()
        #expect(result)
    }

    @Test func repeatedBackgroundCompletionsFinishWithoutCrashing() async {
        for index in 0..<20 {
            let accepted = index.isMultiple(of: 2)
            let result = await BrowserOpener.open(url) { _, completion in
                DispatchQueue.global().async { completion(accepted) }
            }
            MainActor.assertIsolated()
            #expect(result == accepted)
        }
    }
}
