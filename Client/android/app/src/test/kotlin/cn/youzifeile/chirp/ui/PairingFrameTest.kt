package cn.youzifeile.chirp.ui

import cn.youzifeile.chirp.data.PairRequest
import cn.youzifeile.chirp.data.base64
import cn.youzifeile.chirp.data.nowSeconds
import cn.youzifeile.chirp.data.pairingCodeDigits
import cn.youzifeile.chirp.data.publicKey
import cn.youzifeile.chirp.data.sign
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test

class PairingFrameTest {
    @Test fun importedSecurityCodeRequiresThreeCompleteGroups() {
        assertEquals("123423453456", "1234 2345-3456".pairingCodeDigits())
        assertEquals("123423453456", "123423453456".pairingCodeDigits())
        assertNull("1234 2345 345".pairingCodeDigits())
        assertNull("1234 2345 34567".pairingCodeDigits())
        assertNull("1234 2345x3456".pairingCodeDigits())
    }

    @Test fun continuousFramesIgnoreOtherCodesAndDecodeSignedPairingWithPaddedLuminanceRows() {
        val seed = ByteArray(32) { it.toByte() }
        val request = PairRequest(origin = "https://example.test:443", account = "alice",
            root = publicKey(ByteArray(32)), key = publicKey(seed), nonce = base64(ByteArray(32) { 1 }),
            expires = nowSeconds() + 240, commitment = base64(ByteArray(32) { 2 }))
        val signed = request.copy(signature = sign(seed, request.message())).code()
        fun scan(code: String, pixelStride: Int): String? {
            val size = 512
            val rowStride = size * pixelStride + 13
            val start = 7
            val matrix = QRCodeWriter().encode(code, BarcodeFormat.QR_CODE, size, size)
            val plane = ByteBuffer.allocate(start + rowStride * size)
            for (y in 0 until size) for (x in 0 until size) {
                plane.put(start + rowStride * y + x * pixelStride, if (matrix[x, y]) 0 else (-1).toByte())
            }
            plane.position(start)
            return scanPairingFrame(plane, size, size, rowStride, pixelStride)
        }
        assertNull(scanPairingFrame(ByteBuffer.allocate(32), 20, 20, 48, 2))
        assertNull(scan("https://example.test/unrelated", 1))
        assertNull(scan(request.copy(signature = sign(seed, byteArrayOf(1))).code(), 1))
        assertEquals(signed, scan(signed, 1))
        assertEquals(signed, scan(signed, 2))
    }
}
