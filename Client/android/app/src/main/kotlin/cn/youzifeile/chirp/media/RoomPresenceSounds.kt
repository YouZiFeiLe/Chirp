package cn.youzifeile.chirp.media

import android.content.Context
import android.media.MediaPlayer
import cn.youzifeile.chirp.R
import kotlinx.coroutines.*
import kotlin.coroutines.resume

internal enum class PresenceSound { Joined, Left }
internal class RoomPresenceTracker {
    private var peers: Set<String>? = null
    private var baseline = false
    fun confirm(identities: Set<String>, local: String): List<PresenceSound> {
        if (local !in identities) return emptyList()
        val next = identities - local
        val previous = peers
        peers = next
        if (previous == null) return listOf(PresenceSound.Joined)
        if (baseline) { baseline = false; return emptyList() }
        return buildList { if ((previous - next).isNotEmpty()) add(PresenceSound.Left); if ((next - previous).isNotEmpty()) add(PresenceSound.Joined) }
    }
    fun resynchronize() { baseline = peers != null }
}

internal class RoomPresenceSounds(private val context: Context) {
    private data class Pending(val sound: PresenceSound, val deadline: Long)
    private val jobs = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val queue = ArrayDeque<Pending>()
    private var worker: Job? = null
    fun play(sounds: List<PresenceSound>) {
        val now = System.nanoTime()
        queue.removeAll { it.deadline < now }
        for (sound in sounds) {
            if (queue.lastOrNull()?.sound == sound) queue.removeLast()
            if (queue.size == 4) queue.removeFirst()
            queue.addLast(Pending(sound, now + 3_000_000_000))
        }
        if (worker?.isActive == true) return
        worker = jobs.launch {
            while (queue.isNotEmpty()) {
                val next = queue.removeFirst()
                if (next.deadline < System.nanoTime()) continue
                var player: MediaPlayer? = null
                try {
                    val id = if (next.sound == PresenceSound.Joined) R.raw.join_the_room else R.raw.left_the_room
                    val source = context.resources.openRawResourceFd(id)
                    val current = MediaPlayer()
                    player = current
                    current.setAudioAttributes(voiceAttributes())
                    source.use { current.setDataSource(it.fileDescriptor, it.startOffset, it.length) }
                    current.prepare()
                    withTimeout(3000) { suspendCancellableCoroutine { continuation ->
                        current.setOnCompletionListener { if (continuation.isActive) continuation.resume(Unit) }
                        current.setOnErrorListener { _, _, _ -> if (continuation.isActive) continuation.resume(Unit); true }
                        current.start()
                    } }
                } catch (e: CancellationException) { throw e }
                catch (_: Exception) { /* A cue cannot end a call. */ }
                finally { player?.release() }
            }
        }
    }
    fun stop() { queue.clear(); worker?.cancel(); worker = null }
}
