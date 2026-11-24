package cn.youzifeile.chirp.data

import java.io.ByteArrayOutputStream
import java.io.EOFException
import javax.crypto.AEADBadTagException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class AttachmentCryptoTest {
    private val key = ByteArray(32) { it.toByte() }
    private val info = AttachmentInfo(
        id = "0123456789abcdef0123456789abcdef", roomID = "friends",
        sender = "member_${"m".repeat(16)}.login_${"l".repeat(16)}.entry_${"a".repeat(32)}",
        name = "文件.txt", mimeType = "text/plain", size = 0, digest = "0".repeat(64),
    )

    @Test
    fun thumbnailKeysAreDomainSeparatedAndBoundToTheFileContext() {
        val plain = "thumbnail pixels".encodeToByteArray()
        val sealed = AttachmentCrypto.thumbnail(info, key, plain, true)
        assertArrayEquals(plain, AttachmentCrypto.thumbnail(info, key, sealed, false))
        assertThrows(AEADBadTagException::class.java) { AttachmentCrypto.thumbnail(info.copy(roomID = "other"), key, sealed, false) }
        assertThrows(AEADBadTagException::class.java) { AttachmentCrypto.thumbnail(info.copy(id = "f".repeat(32)), key, sealed, false) }
        sealed[sealed.lastIndex] = (sealed.last().toInt() xor 1).toByte()
        assertThrows(AEADBadTagException::class.java) { AttachmentCrypto.thumbnail(info, key, sealed, false) }
    }

    @Test
    fun matchesIndependentAesGcmWireVectors() {
        val vectors = listOf(
            Triple("", "5fQdpoOh1gvqCr42jDBT9g==", "681e3e23314f85dd775f3ce6377ce21a31a3bf480b9d2c2f9052fd8e45f3ae85"),
            Triple("Chirp-附件\n", "TdTcrMUBaiSMTBKDEpRx+gbD5it6Evbh3ueDgxU=", "11c2e3cf63e32dbc96bd6aabb7d6bf1d5230cb43bcf0b29bff18b2aa74ec432d"),
        )
        for ((text, wire, digest) in vectors) {
            val plain = text.encodeToByteArray()
            val encrypted = ByteArrayOutputStream()
            val sealed = AttachmentCrypto.encrypt(info.copy(size = plain.size.toLong()), key, plain.inputStream(), encrypted) {}
            assertEquals(digest, sealed.digest)
            assertEquals(wire, base64(encrypted.toByteArray()))
            AttachmentCrypto.verifyCiphertext(sealed, encrypted.toByteArray().inputStream()) {}
            val damaged = encrypted.toByteArray().apply { this[lastIndex] = (last().toInt() xor 1).toByte() }
            assertThrows(ChirpException::class.java) { AttachmentCrypto.verifyCiphertext(sealed, damaged.inputStream()) {} }
            assertThrows(ChirpException::class.java) { AttachmentCrypto.verifyCiphertext(sealed, (damaged + 0.toByte()).inputStream()) {} }
            val restored = ByteArrayOutputStream()
            AttachmentCrypto.decrypt(sealed, key, encrypted.toByteArray().inputStream(), {}, restored::write)
            assertArrayEquals(plain, restored.toByteArray())
        }
    }

    @Test
    fun authenticatesEveryRecordAndRejectsTruncationOrWrongRoom() {
        val plain = ByteArray(RECORD_BYTES + 37) { it.toByte() }
        val encrypted = ByteArrayOutputStream()
        val sealed = AttachmentCrypto.encrypt(info.copy(size = plain.size.toLong()), key, plain.inputStream(), encrypted) {}
        val bytes = encrypted.toByteArray()
        val restored = ByteArrayOutputStream()
        AttachmentCrypto.decrypt(sealed, key, bytes.inputStream(), {}, restored::write)
        assertArrayEquals(plain, restored.toByteArray())
        assertThrows(EOFException::class.java) {
            AttachmentCrypto.decrypt(sealed, key, bytes.copyOf(bytes.size - 1).inputStream(), {})
        }
        assertThrows(AEADBadTagException::class.java) {
            AttachmentCrypto.decrypt(sealed.copy(roomID = "another-room"), key, bytes.inputStream(), {})
        }
    }
}
