package cn.youzifeile.chirp.data

import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.Serializable

internal const val RECORD_BYTES = 256 * 1024
internal const val NETWORK_CHUNK = 1024 * 1024
internal const val MAX_ATTACHMENT = 100L * NETWORK_CHUNK
internal val attachmentIDPattern = Regex("[a-f0-9]{32}")
internal val digestPattern = Regex("[a-f0-9]{64}")
private val imageTypes = setOf("image/jpeg", "image/png", "image/heic", "image/heif", "image/webp", "image/gif")

@Serializable
internal data class AttachmentInfo(
    val version: Int = 1,
    val id: String,
    val roomID: String,
    val sender: String,
    val name: String,
    val mimeType: String,
    val size: Long,
    val digest: String,
    val hasThumbnail: Boolean = false,
) {
    val image: Boolean get() = mimeType in imageTypes
    val recordCount: Int get() = ((size + RECORD_BYTES - 1) / RECORD_BYTES).toInt().coerceAtLeast(1)
    val cipherSize: Long get() = size + 16L * recordCount

    fun validate() {
        verify(version == 1 && attachmentIDPattern.matches(id) && roomIDPattern.matches(roomID) &&
            entryIdentityPattern.matches(sender) && name.isNotBlank() && name !in setOf(".", "..") &&
            name.encodeToByteArray().size <= 255 && name.none { it.isISOControl() || it in "/\\\u2028\u2029" } &&
            mimeType.encodeToByteArray().size <= 100 && mimeType.none(Char::isISOControl) &&
            size in 0..maxSize(mimeType) && digestPattern.matches(digest), "ATTACHMENT_INVALID")
    }

    companion object {
        fun maxSize(mimeType: String): Long = if (mimeType in imageTypes) 20L * NETWORK_CHUNK else MAX_ATTACHMENT
    }
}

@Serializable
internal data class AttachmentDescriptor(
    val info: AttachmentInfo,
    val key: String,
    val thumbnail: String? = null,
) {
    fun validate(): ByteArray {
        info.validate()
        verify(info.hasThumbnail == (thumbnail != null), "ATTACHMENT_INVALID")
        thumbnail?.base64Bytes(28, 6 * 1024)
        return key.base64Bytes(32)
    }
}

internal object AttachmentCrypto {
    fun thumbnail(info: AttachmentInfo, key: ByteArray, bytes: ByteArray, encrypt: Boolean): ByteArray = (if (encrypt) LogEvent.thumbnailEncrypt else LogEvent.thumbnailDecrypt).measure {
        verify(bytes.size <= 6 * 1024 && key.size == 32, "ATTACHMENT_INVALID")
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(info.id.encodeToByteArray(), "HmacSHA256"))
        val extracted = mac.doFinal(key)
        val expanded = try {
            mac.init(SecretKeySpec(extracted, "HmacSHA256"))
            mac.doFinal("Chirp attachment thumbnail v1".encodeToByteArray() + byteArrayOf(1))
        } finally { extracted.fill(0) }
        try {
            val nonce = if (encrypt) randomBytes(12) else bytes.copyOfRange(0, 12)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(if (encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE, SecretKeySpec(expanded, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD("Chirp attachment AES256GCM v1\n${info.roomID}\n${info.sender}\n${info.id}\n${info.size}\n${info.recordCount}\n-1\n".encodeToByteArray())
            val result = if (encrypt) nonce + cipher.doFinal(bytes) else cipher.doFinal(bytes, 12, bytes.size - 12)
            verify(result.size <= 6 * 1024, "ATTACHMENT_INVALID")
            return@measure result
        } finally { expanded.fill(0) }
    }
    fun encrypt(
        info: AttachmentInfo,
        key: ByteArray,
        source: InputStream,
        encrypted: OutputStream,
        check: () -> Unit,
    ): AttachmentInfo = LogEvent.attachmentEncrypt.measure {
        val digest = MessageDigest.getInstance("SHA-256")
        repeat(info.recordCount) { index ->
            check()
            val plain = source.readExactly(recordLength(info, index))
            try {
                val record = cipher(Cipher.ENCRYPT_MODE, key, info, index).doFinal(plain)
                encrypted.write(record)
                digest.update(record)
            } finally {
                plain.fill(0)
            }
        }
        verify(source.read() == -1, "ATTACHMENT_INVALID")
        return@measure info.copy(digest = digest.digest().toHexString())
    }

    fun verifyCiphertext(info: AttachmentInfo, source: InputStream, check: () -> Unit) {
        val hash = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        var remaining = info.cipherSize
        while (remaining > 0) {
            check()
            val count = source.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
            verify(count > 0, "ATTACHMENT_INTEGRITY")
            hash.update(buffer, 0, count)
            remaining -= count
        }
        verify(source.read() == -1 && hash.digest().toHexString() == info.digest, "ATTACHMENT_INTEGRITY")
        check()
    }

    fun decrypt(
        info: AttachmentInfo,
        key: ByteArray,
        source: InputStream,
        check: () -> Unit,
        consume: (ByteArray) -> Unit = {},
    ) = LogEvent.attachmentDecrypt.measure {
        info.validate()
        val digest = MessageDigest.getInstance("SHA-256")
        repeat(info.recordCount) { index ->
            check()
            val record = source.readExactly(recordLength(info, index) + 16)
            digest.update(record)
            val plain = cipher(Cipher.DECRYPT_MODE, key, info, index).doFinal(record)
            try {
                check()
                consume(plain)
            } finally {
                plain.fill(0)
            }
        }
        verify(source.read() == -1 && digest.digest().toHexString() == info.digest, "ATTACHMENT_INTEGRITY")
        check()
    }

    private fun recordLength(info: AttachmentInfo, index: Int): Int =
        minOf(RECORD_BYTES.toLong(), info.size - index.toLong() * RECORD_BYTES).toInt()

    private fun cipher(mode: Int, key: ByteArray, info: AttachmentInfo, index: Int): Cipher {
        val nonce = ByteBuffer.allocate(12).putInt(0).putLong(index.toLong()).array()
        val aad = "Chirp attachment AES256GCM v1\n${info.roomID}\n${info.sender}\n${info.id}\n${info.size}\n${info.recordCount}\n$index\n"
        return Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            updateAAD(aad.encodeToByteArray())
        }
    }
}

internal fun InputStream.readExactly(count: Int): ByteArray {
    val bytes = ByteArray(count)
    var offset = 0
    while (offset < count) {
        val next = read(bytes, offset, count - offset)
        if (next <= 0) {
            bytes.fill(0)
            throw EOFException("Incomplete attachment record")
        }
        offset += next
    }
    return bytes
}
