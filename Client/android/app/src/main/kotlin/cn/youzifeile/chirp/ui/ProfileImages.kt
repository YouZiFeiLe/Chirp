package cn.youzifeile.chirp.ui

import android.graphics.Bitmap
import android.util.LruCache
import cn.youzifeile.chirp.data.ChirpException
import cn.youzifeile.chirp.data.Profile
import cn.youzifeile.chirp.data.SessionRepository
import cn.youzifeile.chirp.media.PreparedAvatar
import java.io.IOException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Owned by one login. The main dispatcher serializes lookups, pruning and completion. */
internal class ProfileImages(parent: CoroutineScope, private val session: SessionRepository) {
    private data class Key(val member: String, val revision: String)

    private val scope = CoroutineScope(SupervisorJob(parent.coroutineContext[Job]) + Dispatchers.Main.immediate)
    private val pending = mutableMapOf<Key, Deferred<Bitmap?>>()
    private val fetched = mutableSetOf<Key>()
    private val snapshot = MutableStateFlow(0L)
    private var preload: Job? = null
    private val images = object : LruCache<Key, Bitmap>(16 * 1024 * 1024) {
        override fun sizeOf(key: Key, value: Bitmap) = value.allocationByteCount
    }

    suspend fun get(profile: Profile): Bitmap? = withContext(Dispatchers.Main.immediate) {
        val key = Key(profile.id, profile.avatar ?: return@withContext null)
        images.get(key)?.let { return@withContext it }
        val download = pending[key] ?: scope.async {
            suspend fun fetch(): Bitmap? {
                val data = session.avatar(profile) ?: return null
                return withContext(Dispatchers.Default) { PreparedAvatar.decodeStored(data) }
            }
            for (attempt in 1..2) {
                try {
                    return@async fetch()?.also { images.put(key, it); fetched.add(key) }
                } catch (e: IOException) {
                    if (!transient(e)) throw e
                    delay(500L * attempt)
                }
            }
            fetch()?.also { images.put(key, it); fetched.add(key) }
        }.also { job ->
            pending[key] = job
            job.invokeOnCompletion { if (pending[key] === job) pending.remove(key) }
        }
        download.await()
    }

    private fun transient(error: IOException) = error !is ChirpException || error.status >= 500

    suspend fun forDisplay(profile: Profile): Bitmap? {
        while (scope.isActive) {
            val revision = snapshot.value
            try { return get(profile) }
            catch (e: IOException) {
                if (!transient(e)) throw e
                // The visible avatar retries after the next complete directory snapshot.
                snapshot.first { it != revision }
            }
        }
        return null
    }

    fun retain(profiles: List<Profile>) {
        val keys = profiles.mapNotNull { p -> p.avatar?.let { Key(p.id, it) } }.toSet()
        images.snapshot().keys.filterNot(keys::contains).forEach(images::remove)
        pending.keys.filterNot(keys::contains).forEach { pending.remove(it)?.cancel() }
        fetched.retainAll(keys)
        snapshot.value++
        preload?.cancel()
        val missing = profiles.filter { profile -> profile.avatar?.let { Key(profile.id, it) !in fetched } == true }
        if (missing.isEmpty()) return
        preload = scope.launch {
            val queue = missing.iterator()
            repeat(minOf(4, missing.size)) {
                launch {
                    while (queue.hasNext()) {
                        try { get(queue.next()) }
                        catch (_: IOException) { /* The next snapshot schedules another read. */ }
                    }
                }
            }
        }
    }

    fun close() {
        scope.cancel()
        snapshot.value++
        images.evictAll()
        fetched.clear()
    }
}
