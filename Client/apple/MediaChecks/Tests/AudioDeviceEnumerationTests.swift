import Testing
@testable import LiveKit

#if os(macOS)
@Test func audioDevicesCanBePreparedAndSelectedWithoutStartingCaptureOrPlayout() async throws {
    let audio = AudioManager.shared
    try await audio.chirpPrepareAudioDevices()
    let inputs = audio.inputDevices, outputs = audio.outputDevices
    #expect(!inputs.isEmpty && !outputs.isEmpty)
    #expect(inputs.allSatisfy { !$0.deviceId.isEmpty && !$0.name.isEmpty })
    #expect(outputs.allSatisfy { !$0.deviceId.isEmpty && !$0.name.isEmpty })
    #expect(!audio.isRecording && !audio.isPlaying)
    for input in [true, false] {
        let devices = input ? inputs : outputs
        if let device = devices.first(where: { !$0.isDefault }) {
            try audio.chirpSelectAudioDevice(device, input: input)
        }
        try audio.chirpSelectAudioDevice(input ? audio.defaultInputDevice : audio.defaultOutputDevice, input: input)
    }
    #expect(!audio.isRecordingInitialized && !audio.isPlayoutInitialized)
    #expect(!audio.isRecording && !audio.isPlaying)
    #expect(!audio.engineState.inputEnabled.boolValue && !audio.engineState.outputEnabled.boolValue)
}
#endif
