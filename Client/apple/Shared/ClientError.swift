import Foundation
import ChirpMLS

// Keep raw values stable. See ERROR_CODES.md for meanings and extension rules.
enum ClientErrorCode: String, Codable, CaseIterable, Sendable {
    case registrationPending = "REGISTRATION_PENDING"
    case registrationRejected = "REGISTRATION_REJECTED"
    case identityBlacklisted = "IDENTITY_BLACKLISTED"
    case identityConflict = "IDENTITY_CONFLICT"
    case currentDevice = "CURRENT_DEVICE"
    case lastDevice = "LAST_DEVICE"
    case socialConflict = "SOCIAL_CONFLICT"
    case authorizationStale = "CLIENT_AUTHORIZATION_STALE"
    case deviceIdentityRequired = "DEVICE_IDENTITY_REQUIRED"
    case devicePairingInvalid = "DEVICE_PAIRING_INVALID"
    case v5IdentityInvalid = "V5_IDENTITY_INVALID"
    case roomIdentityRequired = "ROOM_IDENTITY_REQUIRED"
    case roomAuthorizationInvalid = "ROOM_AUTHORIZATION_INVALID"
    case identityChanged = "CLIENT_IDENTITY_CHANGED"
    case identityExpired = "CLIENT_IDENTITY_EXPIRED"
    case unexpected = "CLIENT_UNEXPECTED"
    case unknownServerError = "CLIENT_UNKNOWN_SERVER_ERROR"
    case invalidResponse = "CLIENT_INVALID_RESPONSE"
    case httpFailure = "CLIENT_HTTP_FAILURE"
    case networkUnavailable = "CLIENT_NETWORK_UNAVAILABLE"
    case networkTimeout = "CLIENT_NETWORK_TIMEOUT"
    case networkFailure = "CLIENT_NETWORK_FAILURE"
    case networkTimeRequired = "NETWORK_TIME_REQUIRED"
    case invalidServerAddress = "CLIENT_INVALID_SERVER_ADDRESS"
    case hostedServerUnsupported = "CLIENT_HOSTED_SERVER_UNSUPPORTED"
    case insecureServerAddress = "CLIENT_INSECURE_SERVER_ADDRESS"
    case invalidServerConfiguration = "CLIENT_INVALID_SERVER_CONFIGURATION"
    case serverConfigurationChanged = "CLIENT_SERVER_CONFIGURATION_CHANGED"
    case serverNotConfigured = "CLIENT_SERVER_NOT_CONFIGURED"
    case browserOpenFailed = "CLIENT_BROWSER_OPEN_FAILED"
    case clientVersionInvalid = "CLIENT_VERSION_INVALID"
    case clientUpdateRequired = "CLIENT_UPDATE_REQUIRED"
    case clientVersionPolicyUnavailable = "CLIENT_VERSION_POLICY_UNAVAILABLE"
    case clientConfigUnavailable = "CLIENT_CONFIG_UNAVAILABLE"
    case databaseUnavailable = "DATABASE_UNAVAILABLE"
    case invalidRoomList = "CLIENT_INVALID_ROOM_LIST"
    case invalidPreflight = "CLIENT_INVALID_PREFLIGHT"
    case invalidAdmission = "CLIENT_INVALID_ADMISSION"
    case invalidJoinSequence = "CLIENT_INVALID_JOIN_SEQUENCE"
    case joinSequenceExhausted = "CLIENT_JOIN_SEQUENCE_EXHAUSTED"
    case leaveFailed = "CLIENT_LEAVE_FAILED"
    case invalidLoginCallback = "CLIENT_INVALID_LOGIN_CALLBACK"
    case loginVerificationFailed = "CLIENT_LOGIN_VERIFICATION_FAILED"
    case secureLoginFailed = "CLIENT_SECURE_LOGIN_FAILED"
    case invalidLoginSession = "CLIENT_INVALID_LOGIN_SESSION"
    case loginIncomplete = "CLIENT_LOGIN_INCOMPLETE"
    case loginExpired = "CLIENT_LOGIN_EXPIRED"
    case loginCancelled = "CLIENT_LOGIN_CANCELLED"
    case invalidDeviceAuthorization = "CLIENT_INVALID_DEVICE_AUTHORIZATION"
    case deviceLoginUnsupported = "CLIENT_DEVICE_LOGIN_UNSUPPORTED"
    case deviceRequestFailed = "CLIENT_DEVICE_REQUEST_FAILED"
    case deviceStatusInvalid = "CLIENT_DEVICE_STATUS_INVALID"
    case qrGenerationFailed = "CLIENT_QR_GENERATION_FAILED"
    case callBusy = "CLIENT_CALL_BUSY"
    case secureTransportMissing = "CLIENT_SECURE_TRANSPORT_MISSING"
    case microphonePermissionRequired = "CLIENT_MICROPHONE_PERMISSION_REQUIRED"
    case localEncryptionFailed = "CLIENT_LOCAL_ENCRYPTION_FAILED"
    case microphoneUpdateFailed = "CLIENT_MICROPHONE_UPDATE_FAILED"
    case audioPresetBusy = "CLIENT_AUDIO_PRESET_BUSY"
    case audioControlUnavailable = "CLIENT_AUDIO_CONTROL_UNAVAILABLE"
    case audioControlBusy = "CLIENT_AUDIO_CONTROL_BUSY"
    case audioDeviceChangeFailed = "CLIENT_AUDIO_DEVICE_CHANGE_FAILED"
    case microphoneTestFailed = "CLIENT_MICROPHONE_TEST_FAILED"
    case audioServicesReset = "CLIENT_AUDIO_SERVICES_RESET"
    case audioDecryptionRecoveryFailed = "CLIENT_AUDIO_DECRYPTION_RECOVERY_FAILED"
    case audioPresetRecoveryFailed = "CLIENT_AUDIO_PRESET_RECOVERY_FAILED"
    case secureConnectionNotReady = "CLIENT_SECURE_CONNECTION_NOT_READY"
    case microphoneEncryptorNotReady = "CLIENT_MICROPHONE_ENCRYPTOR_NOT_READY"
    case localTrackUnencrypted = "CLIENT_LOCAL_TRACK_UNENCRYPTED"
    case remoteTrackUnencrypted = "CLIENT_REMOTE_TRACK_UNENCRYPTED"
    case voiceDisconnected = "CLIENT_VOICE_DISCONNECTED"
    case voiceConnectionFailed = "CLIENT_VOICE_CONNECTION_FAILED"
    case secureConnectionRecoveryFailed = "CLIENT_SECURE_CONNECTION_RECOVERY_FAILED"
    case audioEncryptionFailed = "CLIENT_AUDIO_ENCRYPTION_FAILED"
    case audioEncryptionUnknown = "CLIENT_AUDIO_ENCRYPTION_UNKNOWN"
    case appleAudioUnavailable = "CLIENT_APPLE_AUDIO_UNAVAILABLE"
    case audioPresetUnconfirmed = "CLIENT_AUDIO_PRESET_UNCONFIRMED"
    case noiseSuppressionFailed = "CLIENT_NOISE_SUPPRESSION_FAILED"
    case noiseInitializationFailed = "CLIENT_NOISE_INITIALIZATION_FAILED"
    case noiseFormatInvalid = "CLIENT_NOISE_FORMAT_INVALID"
    case noiseProcessingFailed = "CLIENT_NOISE_PROCESSING_FAILED"
    case audioProcessingFailed = "CLIENT_AUDIO_PROCESSING_FAILED"
    case groupStateChanged = "CLIENT_GROUP_STATE_CHANGED"
    case groupUnavailable = "CLIENT_GROUP_UNAVAILABLE"
    case invalidGroupResponse = "CLIENT_INVALID_GROUP_RESPONSE"
    case groupIdentityInvalid = "CLIENT_GROUP_IDENTITY_INVALID"
    case groupRequestRejected = "CLIENT_GROUP_REQUEST_REJECTED"
    case groupLeaseExpired = "CLIENT_GROUP_LEASE_EXPIRED"
    case groupConnectionLost = "CLIENT_GROUP_CONNECTION_LOST"
    case groupMembersUnverified = "CLIENT_GROUP_MEMBERS_UNVERIFIED"
    case groupProtocolMismatch = "CLIENT_GROUP_PROTOCOL_MISMATCH"
    case previousGroupActive = "CLIENT_PREVIOUS_GROUP_ACTIVE"
    case groupMembershipLost = "CLIENT_GROUP_MEMBERSHIP_LOST"
    case groupAuthorizationLost = "CLIENT_GROUP_AUTHORIZATION_LOST"
    case groupConfirmationMismatch = "CLIENT_GROUP_CONFIRMATION_MISMATCH"
    case groupLeaseResponseExpired = "CLIENT_GROUP_LEASE_RESPONSE_EXPIRED"
    case groupUpdateTimedOut = "CLIENT_GROUP_UPDATE_TIMED_OUT"
    case groupCryptoFailed = "CLIENT_GROUP_CRYPTO_FAILED"
    case invalidMediaLease = "CLIENT_INVALID_MEDIA_LEASE"
    case chatTextTooLong = "CLIENT_CHAT_TEXT_TOO_LONG"
    case chatNotReady = "CLIENT_CHAT_NOT_READY"
    case chatPacketTooLong = "CLIENT_CHAT_PACKET_TOO_LONG"
    case chatPreparationFailed = "CLIENT_CHAT_PREPARATION_FAILED"
    case chatSendFailed = "CLIENT_CHAT_SEND_FAILED"
    case attachmentInvalid = "ATTACHMENT_INVALID"
    case attachmentUnavailable = "ATTACHMENT_UNAVAILABLE"
    case attachmentQuota = "ATTACHMENT_QUOTA"
    case attachmentConflict = "ATTACHMENT_CONFLICT"
    case attachmentPending = "ATTACHMENT_PENDING"
    case attachmentCancelled = "ATTACHMENT_CANCELLED"
    case attachmentExpired = "ATTACHMENT_EXPIRED"
    case attachmentIntegrity = "ATTACHMENT_INTEGRITY"
    case attachmentBusy = "ATTACHMENT_BUSY"
    case attachmentsUnavailable = "ATTACHMENTS_UNAVAILABLE"
    case attachmentCacheFailed = "CLIENT_ATTACHMENT_CACHE_FAILED"
    case attachmentTransferFailed = "CLIENT_ATTACHMENT_TRANSFER_FAILED"
    case passwordTooLong = "CLIENT_PASSWORD_TOO_LONG"
    case invalidMemberProfiles = "CLIENT_INVALID_MEMBER_PROFILES"
    case avatarTooLarge = "AVATAR_TOO_LARGE"
    case avatarInvalid = "AVATAR_INVALID"
    case avatarDimensionsExceeded = "AVATAR_DIMENSIONS_EXCEEDED"
    case avatarFormatUnsupported = "AVATAR_FORMAT_UNSUPPORTED"
    case avatarBusy = "AVATAR_BUSY"
    case invalidDisplayName = "INVALID_DISPLAY_NAME"
    case memberNotFound = "MEMBER_NOT_FOUND"
    case unauthorized = "UNAUTHORIZED"
    case memberDisabled = "MEMBER_DISABLED"
    case roomNotFound = "ROOM_NOT_FOUND"
    case admissionChanged = "ADMISSION_CHANGED"
    case roomPasswordRequired = "ROOM_PASSWORD_REQUIRED"
    case roomPasswordIncorrect = "ROOM_PASSWORD_INCORRECT"
    case roomPasswordChanged = "ROOM_PASSWORD_CHANGED"
    case roomPreflightExpired = "ROOM_PREFLIGHT_EXPIRED"
    case roomPasswordRateLimited = "ROOM_PASSWORD_RATE_LIMITED"
    case roomPasswordBusy = "ROOM_PASSWORD_BUSY"
    case badRequest = "BAD_REQUEST"
    case internalError = "INTERNAL_ERROR"
    case mediaServiceUnavailable = "MEDIA_SERVICE_UNAVAILABLE"
    case deviceAuthorizationExpired = "DEVICE_AUTHORIZATION_EXPIRED"
    case invalidAuthorization = "INVALID_AUTHORIZATION"
    case loginNotAllowed = "LOGIN_NOT_ALLOWED"
    case retryLogin = "RETRY_LOGIN"
    case tryLater = "TRY_LATER"
    case serviceUnavailable = "UNAVAILABLE"
    case invalidProof = "INVALID_PROOF"
    case admissionExpired = "ADMISSION_EXPIRED"
}

protocol ClientFailureProviding: Error {
    var clientFailure: ClientFailure { get }
}

extension V5IdentityError: ClientFailureProviding {
    var clientFailure: ClientFailure {
        switch self {
        case .notEnrolled: ClientFailure(.deviceIdentityRequired)
        case .untrusted: ClientFailure(.roomIdentityRequired)
        case .invalid, .wrongDevice: ClientFailure(.v5IdentityInvalid)
        case .changed: ClientFailure(.identityChanged)
        case .expired: ClientFailure(.identityExpired)
        }
    }
}

/// No server message, SDK description, credentials, or chat content is retained.
struct ClientFailure: LocalizedError, Equatable, Sendable, ClientFailureProviding {
    let code: String
    let retryAfter: Int?
    let httpStatus: Int?
    let clientPolicy: ClientVersionPolicy?

    init(_ code: ClientErrorCode, retryAfter: Int? = nil, httpStatus: Int? = nil, clientPolicy: ClientVersionPolicy? = nil) {
        self.code = code.rawValue
        self.retryAfter = retryAfter.flatMap { $0 > 0 ? $0 : nil }
        self.httpStatus = httpStatus
        self.clientPolicy = clientPolicy.flatMap { $0.isValid ? $0 : nil }
    }

    init(serverCode: String, retryAfter: Int? = nil, httpStatus: Int? = nil, clientPolicy: ClientVersionPolicy? = nil) {
        // Unknown codes remain available for diagnosis, without displaying an
        // arbitrary server-provided message or accepting unbounded input.
        let valid = !serverCode.isEmpty && serverCode.utf8.count <= 80
            && serverCode.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }
        code = valid ? serverCode : ClientErrorCode.unknownServerError.rawValue
        self.retryAfter = retryAfter.flatMap { $0 > 0 ? $0 : nil }
        self.httpStatus = httpStatus
        self.clientPolicy = clientPolicy.flatMap { $0.isValid ? $0 : nil }
    }

    var clientFailure: ClientFailure { self }
    var errorDescription: String? { localized(in: AppLanguage.load().locale) }

    func localized(in locale: Locale) -> String {
        let known = ClientErrorCode(rawValue: code) != nil
        let key = known ? code : ClientErrorCode.unknownServerError.rawValue
        let english = AppLocalization.bundle(for: AppLanguage.english.locale)
            .localizedString(forKey: key, value: "Something went wrong. Please try again.", table: "Errors")
        var message = AppLocalization.bundle(for: locale).localizedString(forKey: key, value: english, table: "Errors")
        if code == ClientErrorCode.clientUpdateRequired.rawValue, let clientPolicy {
            message += "\n" + clientPolicy.localizedDescription(in: locale)
        }
        if !known { message += " (\(code))" }
        if let retryAfter {
            let suffix: LocalizedMessage = "（约 \(retryAfter) 秒后可重试）"
            message += suffix.localized(in: locale)
        }
        return message
    }

    static func capture(_ error: any Error, fallback: ClientErrorCode = .unexpected) -> ClientFailure {
        if let error = error as? any ClientFailureProviding { return error.clientFailure }
        if let error = error as? URLError {
            return switch error.code {
            case .notConnectedToInternet: ClientFailure(.networkUnavailable)
            case .timedOut: ClientFailure(.networkTimeout)
            default: ClientFailure(.networkFailure)
            }
        }
        if error is DecodingError { return ClientFailure(.invalidResponse) }
        return ClientFailure(fallback)
    }

    static func response(data: Data, status: Int, retryAfter: String? = nil) -> ClientFailure {
        struct Envelope: Decodable {
            struct Detail: Decodable { let code: String }
            let error: Detail
            let policy: ClientVersionPolicy?
            enum CodingKeys: String, CodingKey { case error, policy = "client_policy" }
        }
        let delay = (status == 429 || status >= 500) ? retryAfter.flatMap { value -> Int? in
            if let seconds = Int(value) { return seconds }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return formatter.date(from: value).map { max(0, Int(ceil($0.timeIntervalSinceNow))) }
        } : nil
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return ClientFailure(serverCode: envelope.error.code, retryAfter: delay, httpStatus: status, clientPolicy: envelope.policy)
        }
        return ClientFailure(.httpFailure, retryAfter: delay, httpStatus: status)
    }
}
