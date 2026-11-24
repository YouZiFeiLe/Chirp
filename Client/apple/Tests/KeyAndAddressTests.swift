import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif
#if os(macOS) && !SWIFT_PACKAGE
import SwiftUI

@MainActor
struct ServerAddressFieldLayoutTests {
    @Test func placeholderMatchesTheAddressFontWhenTheLoginWindowResizes() throws {
        let identity = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
        let application = ApplicationSession(dependencies: .liveKit(identity: identity))
        application.login.server.address = ""
        let actions = LoginDeviceActions(hasSavedIdentity: false, authorizeDevice: {}, requestReset: {}, showLogs: {})
        let host = NSHostingView(rootView: LoginView(localActions: actions).environment(application).environment(application.login))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host

        func addressField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.accessibilityIdentifier() == "server-address" { return field }
            return view.subviews.lazy.compactMap { addressField(in: $0) }.first
        }

        host.layoutSubtreeIfNeeded()
        let field = try #require(addressField(in: host))
        #expect(window.makeFirstResponder(field))

        func promptSize(at width: CGFloat) throws -> CGFloat {
            window.setContentSize(NSSize(width: width, height: 700))
            host.layoutSubtreeIfNeeded()
            let prompt = try #require(field.placeholderAttributedString)
            let font = try #require(prompt.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(font == field.currentEditor()?.font)
            let cell = try #require(field.cell)
            #expect(prompt.size().width <= cell.titleRect(forBounds: field.bounds).width)
            return font.pointSize
        }

        let narrow = try promptSize(at: 800)
        let middle = try promptSize(at: 984)
        let wide = try promptSize(at: 1120)
        #expect(narrow < middle && middle < wide)
        #expect(try promptSize(at: 800) == narrow)
    }
}
#endif

@Test func validatesSelfHostedAddresses() throws {
    #expect(try ServerAddress.validate("https://api.example.test").host == "api.example.test")
    #expect(try ServerAddress.validate("wss://rtc.youzifeile.cn", websocket: true).host == "rtc.youzifeile.cn")
    for invalid in ["https://project.livekit.cloud", "https://project.livekit.cloud.", "https://api.example.com?token=secret", "https://user:password@api.example.com", "ftp://api.example.com"] {
        #expect(throws: (any Error).self) { try ServerAddress.validate(invalid) }
    }
    #expect(throws: (any Error).self) { try ServerAddress.validate("wss://project.livekit.cloud", websocket: true) }
}

@Test func serverAddressInputDefaultsToHTTPS() throws {
    let url = try ServerAddress.baseURL(forUserInput: "  API.example.test:8443/chirp  ")
    #expect(url.absoluteString == "https://api.example.test:8443/chirp/")
    #expect(try ServerAddress.baseURL(forUserInput: url.absoluteString) == url)
    for invalid in ["http://api.example.test", "ftp://api.example.test", "https:/api.example.test", "https://api.example.test:bad",
                    "//api.example.test", "user@api.example.test", "project.livekit.cloud"] {
        #expect(throws: (any Error).self) { try ServerAddress.baseURL(forUserInput: invalid) }
    }
    #expect(throws: (any Error).self) { try ServerAddress.baseURL("api.example.test") }
}

@Test func mediaLeaseCannotBeExtendedByDelayedReplies() throws {
    var lease = MediaLease()
    let started = ContinuousClock.now
    try lease.renew(requestStartedAt: started, milliseconds: 3000)
    #expect(lease.isValid(at: started.advanced(by: .milliseconds(2900))))
    #expect(!lease.isValid(at: started.advanced(by: .seconds(3))))
    #expect(!lease.isValid(at: started.advanced(by: .seconds(5))))
    #expect(throws: (any Error).self) { try lease.renew(requestStartedAt: started, milliseconds: 3001) }
    lease.revoke()
    #expect(!lease.isValid(at: started))
}
