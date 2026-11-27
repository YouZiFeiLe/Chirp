// swift-tools-version: 6.4
import PackageDescription

// Tests compile the same models and MLS coordinator used by both app targets.
// Run scripts/prepare-mls.sh before resolving this package.
let package = Package(
    name: "ChirpCoreChecks",
    defaultLocalization: "en",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    dependencies: [.package(path: "MLS")],
    targets: [
        .target(name: "ChirpCore", dependencies: [.product(name: "ChirpMLS", package: "MLS")], path: "Shared",
                exclude: ["ChirpApp.swift", "LiveKitCallMedia.swift", "LiveKitAudioHardware.swift", "ContentView.swift", "KeyStore.swift", "CaptureAudioProcessor.swift", "AudioPreset+LiveKit.swift", "AudioPresetSettingsView.swift", "Views"],
                sources: ["ClientLog.swift", "ChirpLogStore.swift", "AuthorizationAuthority.swift", "DevicePairingProtocol.swift", "DevicePairingSession.swift", "DevicePairingImages.swift", "IdentitySetup.swift", "RecoveryFile.swift", "RoomIdentity.swift", "SocialIdentity.swift", "DeviceIdentityStore.swift", "RoomDirectory.swift", "ClientStateSync.swift", "HTTPEventStream.swift", "HTTPDataSession.swift", "GroupTransport.swift", "RoomPublicInformation.swift", "MicrophoneAuthorization.swift", "MicrophoneSample.swift", "CallAudio.swift", "CallTrackDiagnostics.swift", "CallState.swift", "CallDependencies.swift", "CallController.swift", "ApplicationSession.swift", "LoginSession.swift", "SavedLogin.swift", "NetworkClock.swift", "Localization.swift", "ClientError.swift", "Models.swift", "ServerConnection.swift", "ClientVersion.swift", "BrowserOpener.swift", "APIClient.swift", "MemberProfile.swift", "MemberProfiles.swift", "AvatarImage.swift", "AudioPreset.swift", "VoiceActivation.swift", "ClientLogin.swift", "DeviceLogin.swift", "MediaLease.swift", "GroupSession.swift", "RoomChat.swift", "RoomAudioPlayback.swift", "RoomPresenceSounds.swift", "AttachmentCrypto.swift", "AttachmentCache.swift", "AttachmentImages.swift", "AttachmentTransport.swift", "AttachmentBandwidth.swift", "AttachmentTransfer.swift", "AttachmentPhotoSource.swift", "RoomAttachmentController.swift"],
                resources: [.process("Resources")]),
        .testTarget(name: "ChirpCoreTests", dependencies: ["ChirpCore", .product(name: "ChirpMLS", package: "MLS")], path: "Tests"),
    ]
)
