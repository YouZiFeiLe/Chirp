package cn.youzifeile.chirp.data

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import cn.youzifeile.chirp.R
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit.MILLISECONDS
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal class ClientLog(
    private val store: ChirpLogStore,
    private val prefs: SharedPreferences,
    private val knownErrors: Set<String>,
    private val clock: () -> Long = System::currentTimeMillis,
    private val isKnownLocalError: (String) -> Boolean = { false },
) {
    companion object {
        @Volatile var current: ClientLog? = null
            private set

        fun install(context: Context, knownLocalError: (String) -> Boolean): ClientLog {
            val errors = context.resources.getStringArray(R.array.client_error_messages).map { it.substringBefore('=') }.toSet()
            return ClientLog(ChirpLogStore(File(context.noBackupFilesDir, "ClientLogs")),
                context.getSharedPreferences("client-log", Context.MODE_PRIVATE), errors, isKnownLocalError = knownLocalError).also { current = it; it.start() }
        }
    }

    private val lock = Any()
    private val writer = ScheduledThreadPoolExecutor(1) { task ->
        Thread({
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
            task.run()
        }, "chirplog-writer").apply { isDaemon = true }
    }.apply { removeOnCancelPolicy = true }
    private val recording = MutableStateFlow(prefs.getBoolean("enabled", false))
    val enabled = recording.asStateFlow()
    @Volatile private var epoch = if (recording.value) 1L else 0L
    val generation: Long get() = epoch.let { if (it % 2 == 0L) 0L else it }
    private var segment = UUID.randomUUID().toString()
    private var sequence = 0L
    private var clearEpoch = 0L
    private var pending = ArrayDeque<LogRow>()
    private var scheduled: ScheduledFuture<*>? = null
    private var scheduleVersion = 0L
    private var immediate = false
    private var retrying = false
    // Only the writer owns a staged export. A clear invalidates it even with the system picker open.
    private var staged: File? = null
    private var exportSpan: LogSpan? = null

    fun start() {
        writer.execute { runCatching { store.discardExports() }; runCatching { store.prune(clock()) } }
        writer.scheduleWithFixedDelay({ runCatching { store.prune(clock()) } }, 60_000, 60_000, MILLISECONDS)
        record(LogEvent.launch, details = LogDetails.Version)
    }

    fun foreground() {
        writer.execute { runCatching { store.prune(clock()) } }
        record(LogEvent.active)
    }

    fun background() {
        record(LogEvent.background)
        synchronized(lock) { if (pending.isNotEmpty()) scheduleLocked(0) }
    }

    fun setEnabled(value: Boolean) = synchronized(lock) {
        if (recording.value == value) return@synchronized
        if (value) {
            newSegment()
            epoch++
            append(LogEvent.recordingEnabled, details = LogDetails.Version)
        } else {
            append(LogEvent.recordingDisabled)
            epoch++
        }
        prefs.edit { putBoolean("enabled", value) }
        recording.value = value
        scheduleLocked(0)
    }

    private fun newSegment() {
        segment = UUID.randomUUID().toString()
        sequence = 0
    }

    private fun safeError(code: String?): String? = code?.let {
        when {
            it in knownErrors || isKnownLocalError(it) -> it
            "CLIENT_$it" in knownErrors -> "CLIENT_$it"
            else -> "CLIENT_UNKNOWN_SERVER_ERROR"
        }
    }

    fun screen(event: LogEvent, visible: Boolean) {
        val gen = generation
        if (gen != 0L) record(event, details = LogDetails.Screen(visible), expected = gen)
    }

    fun begin(event: LogEvent, started: Boolean = false): LogSpan? {
        val gen = generation
        if (gen == 0L) return null
        val span = LogSpan(this, event, gen)
        if (started) record(event, LogOutcome.started, expected = gen)
        return span
    }

    fun record(event: LogEvent, outcome: LogOutcome? = null, error: String? = null, duration: Long? = null,
        status: Int? = null, details: LogDetails? = null, expected: Long = generation) {
        if (expected == 0L) return
        synchronized(lock) {
            if (epoch == expected) append(event, outcome, safeError(error), duration, status, details)
        }
    }

    private fun append(event: LogEvent, outcome: LogOutcome? = null, error: String? = null, duration: Long? = null,
        status: Int? = null, details: LogDetails? = null) {
        pending.addLast(LogRow(clock(), event, outcome, error, duration, status, details, segment, ++sequence))
        boundBuffer()
        scheduleLocked(if (retrying) 5_000 else if (pending.size >= 64) 0 else 400)
    }

    private fun boundBuffer() {
        while (pending.size > 2048) {
            val first = pending.first()
            var lost = 0L
            repeat(512) { lost += (pending.removeFirst().details as? LogDetails.Dropped)?.count ?: 1L }
            pending.addFirst(first.copy(event = LogEvent.storageOverflow, outcome = null, error = null,
                duration = null, status = null, details = LogDetails.Dropped(lost)))
        }
    }

    private fun scheduleLocked(delay: Long) {
        if (scheduled != null && (delay > 0 || immediate)) return
        scheduled?.cancel(false)
        val token = clearEpoch
        val version = ++scheduleVersion
        immediate = delay == 0L
        scheduled = writer.schedule({
            synchronized(lock) {
                if (version != scheduleVersion || token != clearEpoch) return@schedule
                scheduled = null
                immediate = false
            }
            runCatching { flush(token) }
        }, delay, MILLISECONDS)
    }

    private fun flush(token: Long): Long {
        val now: Long
        val batch = synchronized(lock) {
            now = clock()
            if (token != clearEpoch) return now
            pending.also { pending = ArrayDeque() }
        }
        val cutoff = now - ChirpLogStore.RETENTION
        batch.removeAll { it.time < cutoff }
        try {
            while (batch.isNotEmpty()) {
                val hour = Math.floorDiv(batch.first().time, ChirpLogStore.HOUR)
                val rows = batch.takeWhile { Math.floorDiv(it.time, ChirpLogStore.HOUR) == hour }
                store.write(rows)
                repeat(rows.size) { batch.removeFirst() }
            }
            synchronized(lock) { if (token == clearEpoch) retrying = false }
            return now
        } catch (e: Exception) {
            synchronized(lock) {
                if (token == clearEpoch) {
                    batch.addAll(pending)
                    pending = batch
                    boundBuffer()
                    retrying = true
                    scheduleLocked(5_000)
                }
            }
            throw e
        }
    }

    private fun <T> submit(block: () -> T): CompletableDeferred<T> = CompletableDeferred<T>().also { result ->
        writer.execute {
            try { result.complete(block()) } catch (e: Exception) { result.completeExceptionally(e) }
        }
    }

    suspend fun clear() = synchronized(lock) {
        epoch += 2
        newSegment()
        clearEpoch++
        scheduled?.cancel(false)
        scheduled = null
        immediate = false
        retrying = false
        pending.clear()
        submit { staged = null; exportSpan = null; store.clear() }
    }.await()

    suspend fun prepareExport(): String? = synchronized(lock) {
        val token = clearEpoch
        val span = begin(LogEvent.exportLogs)
        submit {
            try {
                if (staged != null) store.discardExports()
                staged = null
                exportSpan = null
                val now = flush(token)
                staged = store.snapshot(now)
                exportSpan = span
                staged?.name
            } catch (e: Exception) {
                span?.finish(e)
                throw e
            }
        }
    }.await()

    fun abandonExport(name: String) {
        writer.execute { if (staged?.name == name) runCatching { deliver(name, null) } }
    }

    suspend fun finishExport(name: String, destination: (() -> OutputStream)?) = submit { deliver(name, destination) }.await()

    private fun deliver(name: String, destination: (() -> OutputStream)?) {
        val file = staged?.takeIf { it.name == name } ?: throw IOException("Log export expired")
        try {
            if (destination != null) {
                file.inputStream().use { source -> destination().use { source.copyTo(it) } }
                exportSpan?.finish()
            } else exportSpan?.finish(kotlinx.coroutines.CancellationException())
        } catch (e: Exception) {
            exportSpan?.finish(e)
            throw e
        } finally {
            staged = null
            exportSpan = null
            store.discardExports()
        }
    }

    internal fun close() {
        writer.submit { store.close() }.get()
        writer.shutdownNow()
    }
}
