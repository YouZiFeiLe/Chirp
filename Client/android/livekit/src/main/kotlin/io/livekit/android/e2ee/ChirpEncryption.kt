package io.livekit.android.e2ee

import livekit.org.webrtc.CryptoOptions
import livekit.org.webrtc.RtpReceiver
import livekit.org.webrtc.RtpSender

/** Preserve WebRTC's SRTP defaults and require a native frame callback on every network audio stream. */
fun chirpVoiceCryptoOptions(): CryptoOptions = CryptoOptions.builder()
    .setEnableGcmCryptoSuites(true)
    .setEnableEncryptedRtpHeaderExtensions(true)
    .setRequireFrameEncryption(true)
    .createCryptoOptions()

/** No data has been passed to SCTP when this is returned by sendData. */
class ChirpDataKeyNotReady : IllegalStateException("Chirp data key is not authorized")

interface ChirpDataGate {
    val dataEpoch: Long
    fun maySendData(epoch: Long): Boolean
    fun receiveEncryptedData(index: Int, wireBytes: Int, deliver: (Long) -> Unit)
    /** Return the full locally leased epoch of this wire slot, including any still-leased receive overlap. */
    fun receiveDataEpoch(index: Int): Long?
    fun installVoiceSender(sender: RtpSender, identity: String)
    fun installVoiceReceiver(receiver: RtpReceiver, identity: String)
}
