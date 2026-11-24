package cn.youzifeile.chirp.media

import android.Manifest
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import io.livekit.android.LiveKit
import io.livekit.android.e2ee.chirpVoiceCryptoOptions
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import livekit.org.webrtc.*
import livekit.org.webrtc.audio.AudioProcessingOptions
import livekit.org.webrtc.audio.JavaAudioDeviceModule
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

class VoiceTransportTest {
    @Test fun webRtcSenderAndAndroidReceiverExchangeEncryptedOpusAcrossRekey() = runBlocking {
        val instrument = InstrumentationRegistry.getInstrumentation()
        val context = instrument.targetContext
        instrument.uiAutomation.grantRuntimePermission(context.packageName,Manifest.permission.RECORD_AUDIO)
        if (android.os.Build.VERSION.SDK_INT >= 37) {
            instrument.uiAutomation.grantRuntimePermission(context.packageName,"android.permission.ACCESS_LOCAL_NETWORK")
        }
        LiveKit.init(context)
        val captures = AtomicInteger()
        val module = JavaAudioDeviceModule.builder(context)
            .setAudioBufferCallback { data, _, _, _, length, timestamp ->
                // Both peers run in this process. Replace all microphone samples with synthetic PCM.
                for (i in 0 until minOf(data.limit(), length)) data.put(i, (i and 15).toByte())
                captures.incrementAndGet()
                timestamp
            }.createAudioDeviceModule()
        module.setSpeakerMute(true)
        val factory = PeerConnectionFactory.builder().setAudioDeviceModule(module).createPeerConnectionFactory()
        val config = PeerConnection.RTCConfiguration(emptyList()).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            cryptoOptions = chirpVoiceCryptoOptions()
        }
        val caller = requireNotNull(factory.createPeerConnection(config, LocalPeerObserver()))
        val sink = requireNotNull(factory.createPeerConnection(config, LocalPeerObserver()))
        val source = factory.createAudioSource(MediaConstraints())
        val track = factory.createAudioTrack("microphone", source)
        val sender = caller.addTrack(track,listOf("chirp"))
        val gate = MediaGate("room/group")
        val provider = RoomKeys(gate, this)
        val voice = provider.voice
        val first = ByteArray(32) { it.toByte() }
        val second = ByteArray(32) { (32+it).toByte() }
        provider.install(mapOf("alice" to first), 0)
        val encryptor = FrameCryptorFactory.createFrameCryptorForRtpSender(factory,sender,"alice",FrameCryptorAlgorithm.AES_GCM,provider.rtcKeyProvider)
        suspend fun inboundBytes(): Long = suspendCoroutine { continuation ->
            sink.getStats { report ->
                continuation.resume(report.statsMap.values.filter { it.type == "inbound-rtp" }
                    .sumOf { (it.members["bytesReceived"] as? Number)?.toLong() ?: 0L })
            }
        }
        suspend fun captureWindow() {
            val start = captures.get()
            while (captures.get() - start < 25) delay(20)
        }
        fun grant(epoch: ULong) = gate.grant(MediaPermit(gate.groupID,
            System.currentTimeMillis() + 10_000, SystemClock.elapsedRealtime() + 10_000, epoch))
        try {
            withTimeout(25000) {
                encryptor.keyIndex = 0; encryptor.isEnabled = true
                suspend fun negotiate(from: PeerConnection, to: PeerConnection, offer: Boolean) {
                    setDescription(from,localDescription(from,offer),true)
                    while (from.iceGatheringState() != PeerConnection.IceGatheringState.COMPLETE) delay(20)
                    setDescription(to,from.localDescription,false)
                }
                negotiate(caller,sink,true)
                val receiver = sink.receivers.single()
                val remoteTrack = receiver.track() as AudioTrack
                val trackID = remoteTrack.id()
                val audible = AtomicInteger()
                remoteTrack.addSink { buffer, _, _, _, _, _ ->
                    if ((0 until buffer.remaining()).any { buffer.get(buffer.position() + it) != 0.toByte() }) audible.incrementAndGet()
                }
                negotiate(sink,caller,false)
                module.requestStartRecording(AudioProcessingOptions(false,false,false,false))
                while (caller.iceConnectionState() !in setOf(PeerConnection.IceConnectionState.CONNECTED,
                        PeerConnection.IceConnectionState.COMPLETED)) delay(25)
                assertNull(voice.lastDecryption(trackID))
                grant(0UL)
                provider.authorize(0)
                gate.micAllowed = true
                assertTrue(provider.maySendData(0))
                captureWindow()
                assertEquals("Missing mandatory sender callback", 0L, inboundBytes())
                encryptor.isEnabled = false
                provider.installVoiceSender(sender, "alice")
                captureWindow()
                assertEquals("Disabled upstream transformer", 0L, inboundBytes())
                encryptor.isEnabled = true
                while (inboundBytes() == 0L) delay(20)
                captureWindow()
                assertEquals("Missing receive callback must produce silence", 0, audible.get())
                provider.installVoiceReceiver(receiver, "alice")
                while (voice.lastDecryption(trackID) == null) delay(25)
                while (audible.get() == 0) delay(25)
                provider.install(mapOf("alice" to second), 1)
                assertNull(provider.receiveDataEpoch(1))
                assertFalse(provider.mayDeliverData(1))
                val received = kotlinx.coroutines.CompletableDeferred<Long>()
                provider.receiveEncryptedData(1, 100) { received.complete(it) }
                assertFalse(received.isCompleted)
                assertThrows(cn.youzifeile.chirp.data.ChirpException::class.java) { provider.switch(1) {} }
                assertFalse(provider.maySendData(1))
                val last = voice.lastDecryption(trackID)
                while (voice.lastDecryption(trackID) == last) delay(25)
                assertFalse(received.isCompleted)
                grant(1UL)
                provider.switch(1) { encryptor.keyIndex = provider.getLatestKeyIndex("alice") }
                assertFalse(provider.maySendData(0))
                assertFalse(provider.maySendData(1))
                provider.authorize(1)
                assertEquals(1L, received.await())
                assertEquals(1L, provider.receiveDataEpoch(1))
                assertTrue(provider.maySendData(1))
                // Reusing the old wire slot invalidates its queued messages and cannot authorize the staged key.
                provider.install(mapOf("alice" to ByteArray(32) { (64 + it).toByte() }), 0)
                assertNull(provider.receiveDataEpoch(0))
                assertFalse(provider.mayDeliverData(0))
                val switchedAt = voice.lastDecryption(trackID)
                while (voice.lastDecryption(trackID) == switchedAt) delay(25)
                grant(2UL)
                provider.switch(0) { encryptor.keyIndex = provider.getLatestKeyIndex("alice") }
                provider.authorize(0)
                assertTrue(provider.mayDeliverData(2))
                assertFalse(provider.mayDeliverData(0))
                gate.revoke()
                assertFalse(provider.maySendData(2))
                assertFalse(provider.mayDeliverData(2))
                val revokedAt = voice.lastDecryption(trackID)
                delay(150)
                assertTrue(voice.lastDecryption(trackID) == null || voice.lastDecryption(trackID) == revokedAt)
            }
        } finally {
            module.requestStopRecording()
            provider.stop()
            caller.close(); sink.close(); encryptor.dispose()
            caller.dispose(); sink.dispose(); track.dispose(); source.dispose()
            provider.rtcKeyProvider.dispose(); factory.dispose(); module.release()
        }
    }
}
