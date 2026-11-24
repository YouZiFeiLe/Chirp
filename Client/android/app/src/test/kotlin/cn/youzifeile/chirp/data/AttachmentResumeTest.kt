package cn.youzifeile.chirp.data

import java.io.File
import java.io.RandomAccessFile
import org.junit.Assert.*
import org.junit.Test

class AttachmentResumeTest {
    @Test fun keepsOnlyVerifiedCompleteChunksAndTruncatesCorruptOrTornPrefixes() {
        val first = ByteArray(NETWORK_CHUNK) { 1 }
        val second = ByteArray(NETWORK_CHUNK) { 2 }
        val tail = ByteArray(37) { 3 }
        val hashes = listOf(first, second, tail).map { sha256(it).toHexString() }
        val file = File.createTempFile("chirp-prefix", ".part")
        try {
            file.writeBytes(first + second.copyOf(100))
            RandomAccessFile(file, "rw").use { handle ->
                assertEquals(AttachmentPrefix(NETWORK_CHUNK.toLong(), 1), verifiedAttachmentPrefix(handle, 2L * NETWORK_CHUNK + 37, hashes) {})
                assertEquals(NETWORK_CHUNK.toLong(), handle.length())
            }
            file.writeBytes(first + second + tail)
            RandomAccessFile(file, "rw").use { handle ->
                handle.seek(NETWORK_CHUNK.toLong()); handle.write(9)
                assertEquals(AttachmentPrefix(NETWORK_CHUNK.toLong(), 1), verifiedAttachmentPrefix(handle, 2L * NETWORK_CHUNK + 37, hashes) {})
            }
            file.writeBytes(first + second + tail)
            RandomAccessFile(file, "rw").use { handle ->
                assertEquals(AttachmentPrefix(2L * NETWORK_CHUNK + 37, 3), verifiedAttachmentPrefix(handle, 2L * NETWORK_CHUNK + 37, hashes) {})
            }
        } finally { file.delete() }
    }
}
