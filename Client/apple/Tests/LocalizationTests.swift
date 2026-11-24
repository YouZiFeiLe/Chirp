import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

@Test func languagePreferenceDefaultsToChineseAndPersistsIndependently() throws {
    let suite = "ChirpLanguageTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(AppLanguage.load(from: defaults) == .simplifiedChinese)
    AppLanguage.english.save(to: defaults)
    #expect(AppLanguage.load(from: try #require(UserDefaults(suiteName: suite))) == .english)
    AppLanguage.system.save(to: defaults)
    #expect(AppLanguage.load(from: defaults) == .system)
    defaults.set("removed-language", forKey: AppLanguage.preferenceKey)
    #expect(AppLanguage.load(from: defaults) == .simplifiedChinese)
}

@Test(arguments: [
    (["zh-Hans-CN"], AppLanguage.simplifiedChinese),
    (["zh-CN"], .simplifiedChinese),
    (["zh-SG"], .simplifiedChinese),
    (["en-US"], .english),
    (["en-GB"], .english),
    (["fr-FR", "zh-Hans"], .simplifiedChinese),
    (["zh-Hant-HK", "en-US"], .english),
    (["ja-JP"], .english),
    ([], .english),
]) func systemLanguageMatchesSupportedPreferencesAndFallsBackToEnglish(_ languages: [String], _ expected: AppLanguage) {
    #expect(AppLanguage.system.resolved(preferredLanguages: languages) == expected)
    #expect(AppLanguage.simplifiedChinese.resolved(preferredLanguages: languages) == .simplifiedChinese)
    #expect(AppLanguage.english.resolved(preferredLanguages: languages) == .english)
}

@Test func deferredTextChangesLanguageWithoutChangingItsStateOrUserContent() {
    let preset: LocalizedMessage = "Apple 系统处理＋RNNoise"
    let status: LocalizedMessage = "已选：\(preset)；麦克风已静音"
    #expect(status.localized(in: AppLanguage.english.locale) == "Selected: Apple audio processing + RNNoise. Your microphone is muted.")
    #expect(status.localized(in: AppLanguage.simplifiedChinese.locale) == "已选：Apple 系统处理＋RNNoise；麦克风已静音")
    let name = "你 %@ 小林"
    let message: LocalizedMessage = "返回\(name)，\(status)"
    #expect(message.localized(in: AppLanguage.english.locale).contains(name))
    #expect(message.localized(in: Locale(identifier: "ja-JP")).hasPrefix("Return to "))
    let heading: LocalizedMessage = "只有彼此能懂，\n他耳皆为鸟鸣。"
    #expect(heading.localized(in: AppLanguage.english.locale) == "Only you understand.\nOthers hear birdsong.")
}

@Test func builtInRoomNamesAreLocalizedWhileAdministratorNamesStayVerbatim() {
    #expect(RoomOverview.loading(id: "dynamic").localizedDisplayName(in: AppLanguage.english.locale) == "Loading rooms…")
    let room = RoomOverview(roomID: "friends", displayName: "公开大厅", keyProtocol: VoiceRooms.keyProtocol,
        maxParticipants: 0, participants: [], mediaStatus: "available", passwordRequired: false)
    #expect(room.localizedDisplayName(in: AppLanguage.english.locale) == "公开大厅")
}

@Test func appleOnlyPresetExplainsThatRNNoiseIsNotUsedInBothLanguages() {
    #expect(AudioPreset.appleOnly.title.localized(in: AppLanguage.english.locale) == "Apple audio processing (without RNNoise)")
    #expect(AudioPreset.appleOnly.title.localized(in: AppLanguage.simplifiedChinese.locale) == "Apple 系统处理（不使用 RNNoise）")
    #expect(AudioPreset.appleOnly.explanation.localized(in: AppLanguage.english.locale).contains("without RNNoise"))
}

@Test func errorsResolveLocallyAndExistingFailuresCanSwitchLanguages() {
    let data = Data(#"{"error":{"code":"ROOM_PASSWORD_INCORRECT","message":"untrusted server text secret_payload"}}"#.utf8)
    let failure = ClientFailure.response(data: data, status: 403)
    #expect(failure.code == "ROOM_PASSWORD_INCORRECT")
    #expect(failure.localized(in: AppLanguage.english.locale) == "The room password is incorrect. Please try again.")
    #expect(failure.localized(in: AppLanguage.simplifiedChinese.locale) == "房间密码不正确，请重新输入")
    #expect(APIError.roomAccess(failure).needsRoomPassword)
    #expect(ClientFailure.capture(APIError.roomAccess(failure)) == failure)
    let withoutMessage = Data(#"{"error":{"code":"ROOM_PASSWORD_REQUIRED"}}"#.utf8)
    #expect(ClientFailure.response(data: withoutMessage, status: 403).code == "ROOM_PASSWORD_REQUIRED")
}

@Test func unknownErrorsNeverExposeServerMessagesAndRetryDelayStaysStructured() {
    let data = Data(#"{"error":{"code":"FUTURE_ROOM_ERROR","message":"secret_payload"}}"#.utf8)
    let failure = ClientFailure.response(data: data, status: 429, retryAfter: "7")
    #expect(failure.code == "FUTURE_ROOM_ERROR")
    #expect(failure.retryAfter == 7)
    let english = failure.localized(in: AppLanguage.english.locale)
    #expect(english.contains("FUTURE_ROOM_ERROR"))
    #expect(english.contains("Retry in about 7 s."))
    #expect(!english.contains("secret_payload"))
    #expect(failure.localized(in: AppLanguage.simplifiedChinese.locale).contains("约 7 秒"))
    #expect(ClientFailure.response(data: data, status: 429, retryAfter: "-1").retryAfter == nil)
    #expect(ClientFailure.response(data: data, status: 403, retryAfter: "7").retryAfter == nil)
    #expect(ClientFailure(serverCode: "unsafe\ncode").code == ClientErrorCode.unknownServerError.rawValue)
    #expect(ClientFailure.response(data: Data(), status: 502).code == ClientErrorCode.httpFailure.rawValue)
}

@Test func operatingSystemAndSDKDescriptionsUseLocalMessages() {
    #expect(ClientFailure.capture(URLError(.notConnectedToInternet)).code == ClientErrorCode.networkUnavailable.rawValue)
    #expect(ClientFailure.capture(URLError(.timedOut)).code == ClientErrorCode.networkTimeout.rawValue)
    let sdkError = NSError(domain: "SDK", code: -1, userInfo: [NSLocalizedDescriptionKey: "secret_payload"])
    let failure = ClientFailure.capture(sdkError, fallback: .voiceConnectionFailed)
    #expect(failure.code == ClientErrorCode.voiceConnectionFailed.rawValue)
    #expect(!failure.localized(in: AppLanguage.english.locale).contains("secret_payload"))
}

@Test func everyDocumentedErrorCodeHasChineseAndEnglishResources() throws {
    for language in [AppLanguage.simplifiedChinese, .english] {
        let bundle = AppLocalization.bundle(for: language.locale)
        for code in ClientErrorCode.allCases {
            let missing = "__MISSING__"
            let message = bundle.localizedString(forKey: code.rawValue, value: missing, table: "Errors")
            #expect(message != missing, "Missing \(language.rawValue) error resource: \(code.rawValue)")
        }
    }
}
