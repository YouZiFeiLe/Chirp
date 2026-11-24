package cn.youzifeile.chirp.media

import cn.youzifeile.chirp.data.LogEvent
import android.content.ContentResolver
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import cn.youzifeile.chirp.data.Admission
import cn.youzifeile.chirp.data.AttachmentCrypto
import cn.youzifeile.chirp.data.AttachmentCatalog
import cn.youzifeile.chirp.data.AttachmentDescriptor
import cn.youzifeile.chirp.data.AttachmentInfo
import cn.youzifeile.chirp.data.AttachmentTransport
import cn.youzifeile.chirp.data.AttachmentBandwidth
import cn.youzifeile.chirp.data.ChirpException
import cn.youzifeile.chirp.data.NETWORK_CHUNK
import cn.youzifeile.chirp.data.RemoteAttachment
import cn.youzifeile.chirp.data.SessionRepository
import cn.youzifeile.chirp.data.base64
import cn.youzifeile.chirp.data.randomBytes
import cn.youzifeile.chirp.data.readExactly
import cn.youzifeile.chirp.data.temporaryAttachmentError
import cn.youzifeile.chirp.data.sha256
import cn.youzifeile.chirp.data.verify
import cn.youzifeile.chirp.data.verifiedAttachmentPrefix
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.FileVisitResult
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.attribute.BasicFileAttributes
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal enum class TransferPhase { Waiting, AwaitingUpload, Sending, Receiving, Verifying, Paused, Retryable, Available, Cancelling, Cancelled, Expired, Failed }
internal data class TransferState(val phase: TransferPhase, val progress: Int = 0, val outgoing: Boolean = false,
    val remote: String? = null) {
    val busy get() = phase in setOf(TransferPhase.AwaitingUpload, TransferPhase.Sending, TransferPhase.Receiving, TransferPhase.Verifying)
}

internal interface AttachmentAccess {
    val gate: MediaGate
    val recipients: List<String>
}

internal class RoomAttachments private constructor(
    private val resolver: ContentResolver,
    private val directory: File,
    private val entry: Admission,
    private val transport: AttachmentTransport,
    private val scope: CoroutineScope,
    private val onAuthorizationEnded: () -> Unit,
    private val publish: (Map<String, TransferState>) -> Unit,
    val bandwidth: AttachmentBandwidth,
) {
    private class Item(
        var info: AttachmentInfo,
        val key: ByteArray,
        val file: File,
        var state: TransferState,
        var receiptPending: Boolean = false,
        var recipients: List<String> = emptyList(),
        var announced: Boolean = false,
        var publicationAttempted: Boolean = false,
        var cancellationRequested: Boolean = false,
        var uploadJob: Job? = null,
        var thumbnail: String? = null,
        var groupID: String = "",
        var reservationAttempted: Boolean = false,
        var announce: (suspend (AttachmentDescriptor) -> Unit)? = null,
    ) {
        var lastRemote: RemoteAttachment? = null
        var seenInCatalog = false
        @Volatile var discarded = false
    }

    private val items = LinkedHashMap<String, Item>()
    private var catalog: AttachmentCatalog? = null
    private var applyingCatalog = false
    @Volatile private var media: AttachmentAccess? = null
    private var stream: Job? = null
    private var receiveJob: Job? = null
    private var closed = false
    private var preparation: Job? = null
    private val downloads = mutableMapOf<String, Job>()
    private val receipts = mutableMapOf<String, Job>()
    private val cancellations = mutableMapOf<String, Job>()
    val unpublished: List<AttachmentInfo> get() = if (closed) emptyList() else items.values.filter {
        !it.publicationAttempted && it.info.sender == entry.identity && it.state.phase in setOf(TransferPhase.Sending, TransferPhase.Retryable, TransferPhase.Cancelling)
    }.map { it.info }

    init {
        stream = scope.launch {
            var failures = 0
            while (isActive) {
                try {
                    applyCatalog(transport.catalog())
                    transport.watch().collect { hint ->
                        failures = 0
                        val current = catalog?.version
                        if (current == null || hint.server != current.server || hint.revision > current.revision) {
                            val snapshot = transport.catalog()
                            verify(snapshot.version.server == hint.server && snapshot.version.revision >= hint.revision)
                            applyCatalog(snapshot)
                        }
                    }
                } catch (e: IOException) {
                    if (closed) return@launch
                    if (e is ChirpException && (e.status in setOf(401, 403) || e.code == "ADMISSION_EXPIRED" ||
                        (e.status == 404 && e.code == "ATTACHMENT_UNAVAILABLE"))) {
                        authorizationEnded = true
                        revoke()
                        publish(emptyMap())
                        onAuthorizationEnded()
                        scope.launch { close() }
                        return@launch
                    }
                }
                delay(listOf(500L, 1000L, 2000L, 5000L)[failures])
                failures = (failures + 1).coerceAtMost(3)
            }
        }
    }

    private fun applyCatalog(snapshot: AttachmentCatalog) {
        val previous = catalog?.version
        if (closed || (previous?.server == snapshot.version.server && snapshot.version.revision < previous.revision)) return
        applyingCatalog = true
        try {
            for (item in items.values) {
                val remote = snapshot.files[item.info.id]
                if (remote != null) {
                    item.seenInCatalog = true
                    applyRemote(item, remote, fromCatalog = true)
                } else if (item.seenInCatalog && !item.discarded) {
                    if (item.state.phase == TransferPhase.Available) {
                        if (item.state.remote !in setOf("expired", "delivered")) item.state = item.state.copy(remote = "removed")
                    } else if (item.info.sender != entry.identity) {
                        update(item, TransferPhase.Expired)
                    }
                }
            }
            catalog = snapshot
        } finally {
            applyingCatalog = false
            refresh()
        }
        scheduleReceive()
    }

    /** May receive a catalog and an operation response in either order. */
    private fun applyRemote(item: Item, remote: RemoteAttachment, fromCatalog: Boolean = false) {
        if (closed || item.discarded || !remote.supersedes(item.lastRemote)) return
        remote.verifyInfo(item.info)
        item.lastRemote = remote
        if (fromCatalog || item.state.remote != "removed" || remote.state in setOf("cancelled", "expired", "delivered")) {
            item.state = item.state.copy(remote = remote.state)
        }
        val outgoing = item.info.sender == entry.identity
        val cached = item.state.phase == TransferPhase.Available ||
            (outgoing && item.reservationAttempted && item.file.length() == item.info.cipherSize)
        when {
            remote.state == "cancelled" -> update(item, TransferPhase.Cancelled)
            remote.state == "expired" && (!cached || remote.completedAt == 0L) -> update(item, TransferPhase.Expired)
            remote.state == "delivered" && !cached -> update(item, TransferPhase.Expired)
            outgoing && cached && remote.state in setOf("completed", "delivered", "expired") -> update(item, TransferPhase.Available, 100)
            else -> refresh()
        }
    }

    fun setMedia(current: AttachmentAccess?) {
        if (closed || media === current) return
        media = current
        if (current != null) scheduleReceive()
    }

    fun accept(descriptor: AttachmentDescriptor): Boolean {
        val info = descriptor.info
        if (closed || items.size >= 1000 || info.id in items || runCatching { info.validate() }.isFailure ||
            !hasSpace(info.cipherSize)) return false
        val key = runCatching { descriptor.validate() }.getOrNull() ?: return false
        val item = Item(info, key, File(directory, info.id), TransferState(TransferPhase.Waiting), thumbnail = descriptor.thumbnail)
        val remote = catalog?.files?.get(info.id)
        if (remote != null && runCatching { remote.verifyInfo(info) }.isFailure) { key.fill(0); return false }
        items[info.id] = item
        if (remote != null) {
            item.seenInCatalog = true
            applyRemote(item, remote, fromCatalog = true)
        }
        refresh()
        scheduleReceive()
        return true
    }

    suspend fun send(uri: Uri, current: AttachmentAccess, announce: suspend (AttachmentDescriptor) -> Unit) {
        checkAvailable()
        verify(preparation?.isActive != true && items.values.none { it.uploadJob?.isActive == true } &&
            items.values.count { it.info.sender == entry.identity && !it.discarded && it.state.phase != TransferPhase.Available } < 16,
            "ATTACHMENT_BUSY")
        val permit = transferCheck(current)
        var item: Item? = null
        var reserved = false
        var completed = false
        var failure: Throwable? = null
        preparation = currentCoroutineContext()[Job]
        try {
            withTimeout(900_000) {
                val info = withContext(Dispatchers.IO) { documentInfo(uri, permit) }
                verify(items.size < 1000 && hasSpace(info.cipherSize), "ATTACHMENT_CACHE_FULL")
                val file = File(directory, info.id)
                val fresh = Item(info, randomBytes(32), file, TransferState(TransferPhase.Sending))
                fresh.uploadJob = currentCoroutineContext()[Job]
                fresh.recipients = current.recipients.toList()
                fresh.groupID = current.gate.groupID
                fresh.announce = announce
                item = fresh
                items[info.id] = fresh
                update(fresh, TransferPhase.Sending)
                fresh.info = withContext(Dispatchers.IO) {
                    val source = resolver.openInputStream(uri) ?: throw ChirpException("ATTACHMENT_INVALID")
                    source.use { input ->
                        file.outputStream().use { out ->
                            AttachmentCrypto.encrypt(info, fresh.key, input, out, permit).also { out.fd.sync() }
                        }
                    }
                }
                permit()
                if (fresh.info.image) withContext(Dispatchers.IO) {
                    val bytes = ByteArray(fresh.info.size.toInt())
                    try {
                        var offset = 0
                        file.inputStream().use { encrypted ->
                            AttachmentCrypto.decrypt(fresh.info, fresh.key, encrypted, permit) { record ->
                                record.copyInto(bytes, offset)
                                offset += record.size
                            }
                        }
                        val plain = AttachmentImages.thumbnail(bytes)
                        try { fresh.thumbnail = base64(AttachmentCrypto.thumbnail(fresh.info, fresh.key, plain, encrypt = true)) }
                        finally { plain.fill(0) }
                        fresh.info = fresh.info.copy(hasThumbnail = true)
                    } finally { bytes.fill(0) }
                }
                // Cancellation or an uncertain POST may still leave a reservation. Always attempt cancel.
                reserved = true
                reserveAndAnnounce(fresh, current, permit)
                applyRemote(fresh, upload(fresh, permit))
                completed = true
                update(fresh, TransferPhase.Available, 100)
            }
        } catch (_: TimeoutCancellationException) {
            failure = java.net.SocketTimeoutException()
            throw ChirpException("ATTACHMENT_FAILED")
        } catch (e: Throwable) {
            failure = e
            throw e
        } finally {
            preparation = null
            if (!completed) item?.let { failed ->
                withContext(NonCancellable) {
                    if (!revoked && (failed.announced || !failed.publicationAttempted) && !failed.cancellationRequested &&
                        failed.file.exists() && failed.info.digest != "0".repeat(64) && retryable(failure)) {
                        update(failed, TransferPhase.Retryable)
                        if (reserved) runCatching { transport.pause(failed.info) }
                    } else if (reserved && !revoked && failed.state.phase != TransferPhase.Available) {
                        cancelUpload(failed.info.id)
                    } else if (failed.state.phase != TransferPhase.Available && !failed.cancellationRequested) update(failed, TransferPhase.Failed)
                }
            }
            item?.uploadJob = null
        }
    }

    private fun sameAudience(item: Item, current: AttachmentAccess) =
        current.gate.groupID == item.groupID && current.recipients.toSet() == item.recipients.toSet()

    private suspend fun reserveAndAnnounce(item: Item, current: AttachmentAccess, permit: () -> Unit) {
        permit()
        verify(sameAudience(item, current), "GROUP_CHANGED")
        item.reservationAttempted = true
        val remote = transport.reserve(item.info, item.recipients, permit)
        applyRemote(item, remote)
        remote.requireActive()
        checkItem(item)
        permit()
        verify(sameAudience(item, current), "GROUP_CHANGED")
        val publishDescriptor = item.announce ?: throw ChirpException("ATTACHMENT_INVALID")
        item.publicationAttempted = true
        refresh()
        publishDescriptor(AttachmentDescriptor(item.info, base64(item.key), item.thumbnail))
        item.announced = true
        item.announce = null
    }

    private suspend fun upload(item: Item, transferPermit: () -> Unit): RemoteAttachment = LogEvent.upload.measure(started = true) {
        val permit = { transferPermit(); checkItem(item) }
        val info = item.info
        withContext(Dispatchers.IO) {
            item.file.inputStream().use { AttachmentCrypto.verifyCiphertext(info, it, permit) }
        }
        val status = transport.status(info, permit)
        applyRemote(item, status)
        status.requireActive()
        withContext(Dispatchers.IO) {
            item.file.inputStream().use { input ->
                var offset = 0L
                var index = 0
                while (offset < info.cipherSize) {
                    permit()
                    val size = minOf(NETWORK_CHUNK.toLong(), info.cipherSize - offset).toInt()
                    val bytes = input.readExactly(size)
                    if (index < status.chunks) verify(status.hashes[index] == sha256(bytes).toHexString(), "ATTACHMENT_INTEGRITY")
                    else {
                        transport.uploadChunk(info, index, bytes, permit)
                    }
                    offset += size
                    index++
                    val progress = (offset * 100 / info.cipherSize).toInt()
                    withContext(Dispatchers.Main.immediate) { update(item, TransferPhase.Sending, progress) }
                }
            }
        }
        return@measure if (status.state in setOf("completed", "delivered")) status else transport.complete(info, permit)
    }

    private fun scheduleReceive() {
        val current = media ?: return
        if (closed || current.gate.remaining() == 0L || receiveJob?.isActive == true || downloads.size >= 2 ||
            items.values.none { it.state.phase == TransferPhase.Waiting && it.state.remote == "completed" && it.info.id !in downloads }) return
        receiveJob = scope.launch {
            val permit = transferCheck(current)
            val attempted = mutableSetOf<String>()
            while (current.gate.remaining() > 0 && downloads.size < 2) {
                val item = items.values.firstOrNull { item ->
                    item.info.id !in attempted && item.info.id !in downloads &&
                        item.state.phase == TransferPhase.Waiting && item.state.remote == "completed"
                } ?: break
                attempted += item.info.id
                try {
                    withTimeout(900_000) {
                        if (item.state.phase == TransferPhase.Waiting) {
                            downloads[item.info.id] = currentCoroutineContext()[Job]!!
                            try { download(item, permit) } finally { downloads.remove(item.info.id) }
                        }
                        sendReceipt(item)
                    }
                } catch (_: TimeoutCancellationException) {
                    if (!item.receiptPending) update(item, TransferPhase.Retryable)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    if (!item.receiptPending) update(item, failurePhase(e))
                } finally {
                    if (item.state.phase in setOf(TransferPhase.AwaitingUpload, TransferPhase.Receiving, TransferPhase.Verifying)) update(item, TransferPhase.Paused)
                }
            }
        }.also { job ->
            job.invokeOnCompletion {
                scope.launch {
                    if (receiveJob === job) scheduleReceive()
                }
            }
        }
    }

    fun retry(id: String) {
        val item = items[id] ?: return
        if (closed || item.discarded || (item.state.phase !in setOf(TransferPhase.Retryable, TransferPhase.Paused) &&
            !(item.state.phase == TransferPhase.Waiting && item.info.sender != entry.identity))) return
        val current = media ?: return
        if (current.gate.remaining() == 0L) return
        (if (item.info.sender == entry.identity) LogEvent.retryUpload else LogEvent.retryDownload).record()
        if (item.info.sender == entry.identity) {
            if (item.cancellationRequested || preparation?.isActive == true || items.values.any { it.uploadJob?.isActive == true }) return
            if (!item.announced && (item.publicationAttempted || !sameAudience(item, current))) {
                cancelUpload(id)
                return
            }
            item.uploadJob = scope.launch {
                try {
                    val permit = transferCheck(current)
                    withTimeout(900_000) {
                        update(item, TransferPhase.Sending, item.state.progress)
                        if (!item.announced) reserveAndAnnounce(item, current, permit)
                        applyRemote(item, upload(item, permit))
                    }
                    update(item, TransferPhase.Available, 100)
                } catch (e: CancellationException) { throw e }
                catch (e: Exception) {
                    if (item.publicationAttempted && !item.announced || !retryable(e)) cancelUpload(id)
                    else {
                        update(item, failurePhase(e))
                        if (item.reservationAttempted && !revoked) runCatching { transport.pause(item.info) }
                    }
                }
                finally { if (item.state.phase == TransferPhase.Sending) update(item, TransferPhase.Retryable); item.uploadJob = null }
            }
        } else {
            if (downloads.size >= 2 || id in downloads) return
            downloads[id] = scope.launch {
                try {
                    val permit = transferCheck(current)
                    withTimeout(900_000) { download(item, permit); sendReceipt(item) }
                } catch (e: CancellationException) { throw e }
                catch (e: Exception) { if (!item.receiptPending) update(item, failurePhase(e)) }
                finally {
                    downloads.remove(id)
                    if (item.state.phase in setOf(TransferPhase.AwaitingUpload, TransferPhase.Receiving, TransferPhase.Verifying))
                        update(item, TransferPhase.Paused, item.state.progress)
                    scheduleReceive()
                }
            }
        }
    }

    fun pauseDownload(id: String) {
        LogEvent.pauseDownload.record()
        val item = items[id] ?: return
        if (item.info.sender == entry.identity || closed || item.discarded) return
        val task = downloads[id]
        if (task == null && item.state.phase != TransferPhase.Waiting) return
        update(item, TransferPhase.Paused, item.state.progress)
        task?.cancel()
    }

    fun cancelPreparation() {
        LogEvent.cancelPreparation.record()
        val active = items.values.find { it.uploadJob?.isActive == true }
        if (active != null) cancelUpload(active.info.id) else preparation?.cancel()
    }

    fun cancelUpload(id: String) {
        LogEvent.cancelUpload.record()
        val item = items[id] ?: return
        if (closed || item.discarded || item.info.sender != entry.identity || item.state.phase == TransferPhase.Available || cancellations[id]?.isActive == true) return
        item.cancellationRequested = true
        val task = item.uploadJob
        task?.cancel()
        update(item, TransferPhase.Cancelling)
        cancellations[id] = scope.launch {
            task?.join()
            if (!item.reservationAttempted) {
                update(item, TransferPhase.Cancelled)
                return@launch
            }
            try {
                applyRemote(item, transport.cancel(item.info))
            } catch (e: IOException) {
                val phase = when ((e as? ChirpException)?.code) {
                    "ATTACHMENT_UNAVAILABLE", "ATTACHMENT_CANCELLED" -> TransferPhase.Cancelled
                    "ATTACHMENT_EXPIRED" -> TransferPhase.Expired
                    else -> TransferPhase.Cancelling
                }
                update(item, phase)
            }
        }
    }

    private suspend fun download(item: Item, transferPermit: () -> Unit) = LogEvent.download.measure(started = true) {
        val permit = { transferPermit(); checkItem(item) }
        val info = item.info
        update(item, TransferPhase.AwaitingUpload)
        var status: RemoteAttachment
        while (true) {
            status = transport.status(info, permit)
            applyRemote(item, status)
            status.requireActive()
            checkItem(item)
            if (status.state == "completed") break
            verify(status.state != "delivered", "ATTACHMENT_EXPIRED")
            delay(2000)
        }
        update(item, TransferPhase.Receiving)
        withContext(Dispatchers.IO) {
            val partial = File(directory, "${info.id}.part")
            try {
                RandomAccessFile(partial, "rw").use { out ->
                    val prefix = verifiedAttachmentPrefix(out, info.cipherSize, status.hashes, permit)
                    var offset = prefix.bytes
                    for (index in prefix.chunks until status.hashes.size) {
                        val hash = status.hashes[index]
                        permit()
                        val size = minOf(NETWORK_CHUNK.toLong(), info.cipherSize - offset).toInt()
                        val bytes = transport.downloadChunk(info, index, size, permit)
                        verify(sha256(bytes).toHexString() == hash, "ATTACHMENT_INTEGRITY")
                        out.write(bytes)
                        offset += bytes.size
                        withContext(Dispatchers.Main.immediate) {
                            update(item, TransferPhase.Receiving, (offset * 100 / info.cipherSize).toInt())
                        }
                    }
                    out.fd.sync()
                }
                withContext(Dispatchers.Main.immediate) { update(item, TransferPhase.Verifying, 100) }
                partial.inputStream().use { AttachmentCrypto.decrypt(info, item.key, it, permit) }
                permit()
                verify(partial.renameTo(item.file), "ATTACHMENT_CACHE_FULL")
            } catch (e: Exception) {
                if (e is java.security.GeneralSecurityException || e is ChirpException && e.code == "ATTACHMENT_INTEGRITY") partial.delete()
                throw e
            }
        }
        item.receiptPending = true
        update(item, TransferPhase.Available, 100)
    }

    private fun sendReceipt(item: Item) {
        if (closed || !item.receiptPending || receipts[item.info.id]?.isActive == true) return
        receipts[item.info.id] = scope.launch {
            val deadline = System.nanoTime() + 900_000_000_000L
            while (isActive && !revoked && System.nanoTime() < deadline) {
                try {
                    val current = media
                    if (current != null && current.gate.remaining() > 0) {
                        applyRemote(item, transport.received(item.info, transferCheck(current)))
                        item.receiptPending = false
                        return@launch
                    }
                } catch (e: CancellationException) { throw e }
                catch (e: Exception) { if (!retryable(e)) return@launch }
                delay(2000)
            }
        }
    }

    private fun failurePhase(error: Throwable): TransferPhase = when ((error as? ChirpException)?.code) {
        "ATTACHMENT_EXPIRED", "ATTACHMENT_UNAVAILABLE" -> TransferPhase.Expired
        "ATTACHMENT_CANCELLED" -> TransferPhase.Cancelled
        else -> if (retryable(error)) TransferPhase.Retryable else TransferPhase.Failed
    }

    private fun retryable(error: Throwable?): Boolean = when (error) {
        is ChirpException -> error.temporaryAttachmentError() || error.code in setOf("GROUP_LEASE_LOST", "GROUP_CHANGED")
        is IOException, is CancellationException -> true
        else -> false
    }

    suspend fun export(id: String, destination: Uri) = LogEvent.exportAttachment.measure(started = true) {
        val item = readyItem(id)
        var opened = false
        try {
            withContext(Dispatchers.IO) {
                val caller = currentCoroutineContext()
                val check = { caller.ensureActive(); checkItem(item) }
                item.file.inputStream().use { AttachmentCrypto.decrypt(item.info, item.key, it, check) }
                val output = resolver.openOutputStream(destination, "w") ?: throw ChirpException("ATTACHMENT_EXPORT_FAILED")
                opened = true
                output.use { out ->
                    item.file.inputStream().use { AttachmentCrypto.decrypt(item.info, item.key, it, check, out::write) }
                    check()
                }
            }
        } catch (e: Exception) {
            if (opened) withContext(NonCancellable + Dispatchers.IO) {
                val deleted = runCatching { DocumentsContract.deleteDocument(resolver, destination) }.getOrDefault(false) ||
                    runCatching { resolver.delete(destination, null, null) > 0 }.getOrDefault(false)
                if (!deleted) runCatching { resolver.openOutputStream(destination, "wt")?.close() }
            }
            throw e
        }
    }

    suspend fun preview(id: String): Bitmap = LogEvent.previewAttachment.measure(started = true) {
        val item = readyItem(id)
        verify(item.info.image, "ATTACHMENT_INVALID")
        return@measure withContext(Dispatchers.IO) {
            val caller = currentCoroutineContext()
            val bytes = ByteArray(item.info.size.toInt())
            var offset = 0
            try {
                item.file.inputStream().use { file ->
                    AttachmentCrypto.decrypt(item.info, item.key, file, { caller.ensureActive(); checkItem(item) }) {
                        it.copyInto(bytes, offset)
                        offset += it.size
                    }
                }
                AttachmentImages.decode(bytes).also { checkItem(item) }
            } finally {
                bytes.fill(0)
            }
        }
    }

    suspend fun thumbnail(id: String): Bitmap? {
        checkAvailable()
        val item = items[id] ?: return null
        checkItem(item)
        val encoded = item.thumbnail ?: return null
        return withContext(Dispatchers.IO) {
            val plain = AttachmentCrypto.thumbnail(item.info, item.key, java.util.Base64.getDecoder().decode(encoded), encrypt = false)
            try { AttachmentImages.decode(plain, 256).also { checkItem(item) } } finally { plain.fill(0) }
        }
    }

    private fun readyItem(id: String): Item {
        checkAvailable()
        val item = items[id] ?: throw ChirpException("ATTACHMENT_INVALID")
        checkItem(item)
        verify(item.state.phase == TransferPhase.Available, "ATTACHMENT_INVALID")
        if (!item.file.isFile || item.file.length() != item.info.cipherSize) {
            item.receiptPending = false
            if (item.info.sender != entry.identity && item.state.remote == "completed") {
                item.state = item.state.copy(phase = TransferPhase.Retryable, progress = 0)
                refresh()
            } else {
                update(item, TransferPhase.Expired)
            }
            throw ChirpException("ATTACHMENT_UNAVAILABLE")
        }
        sendReceipt(item)
        return item
    }

    private suspend fun transferCheck(current: AttachmentAccess): () -> Unit {
        val caller = currentCoroutineContext()
        return {
            caller.ensureActive()
            verify(!revoked && media === current && current.gate.remaining() > 0, "GROUP_LEASE_LOST")
        }
    }

    var authorizationEnded = false
        private set
    private val closeLock = Mutex()
    @Volatile private var revoked = false

    private fun checkAvailable() {
        verify(!revoked, "ATTACHMENT_INVALID")
    }

    private fun checkItem(item: Item) {
        checkAvailable()
        verify(!item.discarded, "ATTACHMENT_EXPIRED")
    }

    fun revoke() {
        revoked = true
        closed = true
        stream?.cancel()
        receiveJob?.cancel()
        preparation?.cancel()
        items.values.forEach { item ->
            item.discarded = true
            item.key.fill(0)
            item.thumbnail = null
            item.announce = null
            item.receiptPending = false
            item.uploadJob?.cancel()
        }
        downloads.values.forEach { it.cancel() }
        receipts.values.forEach { it.cancel() }
        cancellations.values.forEach { it.cancel() }
    }

    suspend fun close() = closeLock.withLock {
        revoke()
        stream?.cancelAndJoin()
        receiveJob?.cancelAndJoin()
        preparation?.cancelAndJoin()
        items.values.mapNotNull { it.uploadJob }.distinct().forEach { it.cancelAndJoin() }
        downloads.values.toList().forEach { it.cancelAndJoin() }
        receipts.values.toList().forEach { it.cancelAndJoin() }
        cancellations.values.toList().forEach { it.cancelAndJoin() }
        if (!authorizationEnded) kotlinx.coroutines.coroutineScope {
            for (item in items.values.filter { item -> item.reservationAttempted && item.info.sender == entry.identity &&
                item.state.phase !in setOf(TransferPhase.Available, TransferPhase.Cancelled, TransferPhase.Expired) &&
                item.lastRemote?.state !in setOf("completed", "delivered", "cancelled", "expired") }) {
                launch {
                    try { transport.cancel(item.info) } catch (_: IOException) { /* Admission expiry also releases the reservation. */ }
                }
            }
        }
        releaseDirectory(directory)
        catalog = null
        items.clear()
    }

    private fun update(item: Item, phase: TransferPhase, progress: Int = 0) {
        if (closed || item.discarded) return
        val discard = phase in setOf(TransferPhase.Cancelled, TransferPhase.Expired, TransferPhase.Failed)
        if (item.state.phase == TransferPhase.Available && phase !in setOf(TransferPhase.Available, TransferPhase.Cancelled, TransferPhase.Expired)) return
        if (item.cancellationRequested && phase in setOf(TransferPhase.Sending, TransferPhase.Retryable)) return
        item.state = item.state.copy(phase = phase, progress = progress, outgoing = item.info.sender == entry.identity)
        if (discard) {
            item.discarded = true
            item.key.fill(0)
            item.thumbnail = null
            item.announce = null
            item.receiptPending = false
            val upload = item.uploadJob
            val download = downloads[item.info.id]
            if (phase != TransferPhase.Failed) { upload?.cancel(); download?.cancel() }
            receipts[item.info.id]?.cancel()
            scope.launch {
                upload?.join()
                download?.join()
                withContext(Dispatchers.IO) { item.file.delete(); File(directory, "${item.info.id}.part").delete() }
            }
        }
        refresh()
    }

    private fun refresh() {
        if (!closed && !applyingCatalog) publish(items.mapValues { it.value.state })
    }

    private fun hasSpace(bytes: Long): Boolean =
        items.values.sumOf {
            if (it.state.phase in setOf(TransferPhase.Failed, TransferPhase.Cancelled, TransferPhase.Expired))
                it.file.length() + File(directory, "${it.info.id}.part").length() else it.info.cipherSize
        } +
            bytes <= 512L * NETWORK_CHUNK

    private fun documentInfo(uri: Uri, check: () -> Unit): AttachmentInfo = LogEvent.prepareAttachment.measure(started = true) {
        val mimeType = resolver.getType(uri)?.takeIf { it.length <= 100 && it.none(Char::isISOControl) }
            ?: "application/octet-stream"
        var name = "attachment"
        var size = -1L
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameColumn >= 0) name = cursor.getString(nameColumn)?.take(255)?.filterNot {
                    it.isISOControl() || it in "/\\\u2028\u2029"
                }?.trim()?.takeIf { it.isNotBlank() && it !in setOf(".", "..") } ?: name
                if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) size = cursor.getLong(sizeColumn)
            }
        }
        while (name.encodeToByteArray().size > 255) name = name.dropLast(1)
        val maximum = AttachmentInfo.maxSize(mimeType)
        if (size < 0) {
            val source = resolver.openInputStream(uri) ?: throw ChirpException("ATTACHMENT_INVALID")
            source.use { input ->
                val buffer = ByteArray(64 * 1024)
                size = 0
                try {
                    while (true) {
                        check()
                        val count = input.read(buffer)
                        if (count == -1) break
                        size += count
                        verify(size <= maximum, "ATTACHMENT_TOO_LARGE")
                    }
                } finally {
                    buffer.fill(0)
                }
            }
        }
        verify(size <= maximum, "ATTACHMENT_TOO_LARGE")
        return@measure AttachmentInfo(id = randomBytes(16).toHexString(), roomID = entry.room.id, sender = entry.identity,
            name = name, mimeType = mimeType, size = size, digest = "0".repeat(64)).also { it.validate() }
    }

    companion object {
        private val cacheLock = Mutex()
        private val activeDirectories = mutableSetOf<File>()

        private fun removeTree(file: File) {
            if (Files.notExists(file.toPath(), LinkOption.NOFOLLOW_LINKS)) return
            // The default walker unlinks symlinks without walking into their targets.
            Files.walkFileTree(file.toPath(), object : SimpleFileVisitor<Path>() {
                override fun visitFile(path: Path, attrs: BasicFileAttributes): FileVisitResult {
                    Files.deleteIfExists(path)
                    return FileVisitResult.CONTINUE
                }
                override fun postVisitDirectory(path: Path, failure: IOException?): FileVisitResult {
                    if (failure != null) throw failure
                    Files.deleteIfExists(path)
                    return FileVisitResult.CONTINUE
                }
            })
        }

        private fun removeUnused(root: File) {
            if (Files.isSymbolicLink(root.toPath()) || !root.isDirectory) {
                removeTree(root)
                return
            }
            val entries = root.listFiles() ?: throw ChirpException("ATTACHMENT_CACHE_FAILED")
            entries.filterNot(activeDirectories::contains).forEach(::removeTree)
        }

        private suspend fun releaseDirectory(folder: File) = cacheLock.withLock {
            withContext(Dispatchers.IO) {
                try {
                    if (Files.isSymbolicLink(folder.parentFile!!.toPath())) Files.deleteIfExists(folder.parentFile!!.toPath())
                    else removeTree(folder)
                } finally { activeDirectories.remove(folder) }
            }
            Unit
        }

        suspend fun cacheSize(context: Context): Long = cacheLock.withLock {
            withContext(Dispatchers.IO) {
                val root = File(context.cacheDir, "chirp-attachments").toPath()
                if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS)) return@withContext 0L
                Files.walk(root).use { entries ->
                    entries.filter { Files.isRegularFile(it, LinkOption.NOFOLLOW_LINKS) }.mapToLong(Files::size).sum()
                }
            }
        }

        suspend fun clearIfIdle(context: Context, idle: () -> Boolean) = cacheLock.withLock {
            withContext(Dispatchers.IO) {
                if (idle()) removeUnused(File(context.cacheDir, "chirp-attachments"))
            }
        }

        suspend fun open(context: Context, session: SessionRepository, entry: Admission, scope: CoroutineScope,
            onAuthorizationEnded: () -> Unit = {}, publish: (Map<String, TransferState>) -> Unit): RoomAttachments {
            val root = File(context.cacheDir, "chirp-attachments")
            val directory = File(root, randomBytes(16).toHexString())
            var claimed = false
            try {
                cacheLock.withLock {
                    withContext(Dispatchers.IO) {
                        // A delayed open or close from another admission may share this cache root.
                        removeUnused(root)
                        verify(directory.mkdirs(), "ATTACHMENT_CACHE_FULL")
                        activeDirectories += directory
                        claimed = true
                    }
                }
                currentCoroutineContext().ensureActive()
            } catch (e: Exception) {
                if (claimed) withContext(NonCancellable) { releaseDirectory(directory) }
                throw e
            }
            val bandwidth = AttachmentBandwidth()
            return RoomAttachments(context.contentResolver, directory, entry, AttachmentTransport(session, entry, bandwidth),
                scope, onAuthorizationEnded, publish, bandwidth)
        }
    }
}
