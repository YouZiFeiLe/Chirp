package cn.youzifeile.chirp.data

import java.io.RandomAccessFile

internal data class AttachmentPrefix(val bytes: Long, val chunks: Int)

internal fun verifiedAttachmentPrefix(file: RandomAccessFile, size: Long, hashes: List<String>, check: () -> Unit): AttachmentPrefix {
    var offset = 0L
    var chunks = 0
    file.seek(0)
    for (hash in hashes) {
        check()
        val count = minOf(NETWORK_CHUNK.toLong(), size - offset).toInt()
        if (count <= 0 || file.length() < offset + count) break
        val bytes = ByteArray(count)
        file.readFully(bytes)
        if (sha256(bytes).toHexString() != hash) break
        offset += count; chunks++
    }
    file.setLength(offset); file.seek(offset)
    return AttachmentPrefix(offset, chunks)
}
