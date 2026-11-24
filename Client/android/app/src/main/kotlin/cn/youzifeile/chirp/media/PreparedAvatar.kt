package cn.youzifeile.chirp.media

import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.graphics.Rect
import androidx.core.graphics.scale
import cn.youzifeile.chirp.data.verify
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer

internal class PreparedAvatar private constructor(val preview: Bitmap, val png: ByteArray) {
    companion object {
        private const val SIZE = 512
        private const val MAX_BYTES = 5_000_000
        private val formats = setOf("image/jpeg", "image/png", "image/heic", "image/heif")

        fun decodeStored(data: ByteArray): Bitmap? {
            val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
            android.graphics.BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
            if (bounds.outWidth != SIZE || bounds.outHeight != SIZE || bounds.outMimeType != "image/png") return null
            return android.graphics.BitmapFactory.decodeByteArray(data, 0, data.size)
        }

        fun read(input: InputStream): PreparedAvatar {
            val bytes = input.readNBytes(MAX_BYTES)
            verify(bytes.size < MAX_BYTES, "AVATAR_TOO_LARGE")
            val source = ImageDecoder.createSource(ByteBuffer.wrap(bytes))
            val cropped = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                val (width, height) = info.size.width to info.size.height
                verify(!info.isAnimated && info.mimeType in formats &&
                    width in 1..8192 && height in 1..8192 && width.toLong() * height <= 32_000_000, "AVATAR_INVALID")
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
                val side = minOf(width, height)
                val target = minOf(side, SIZE)
                val scaledWidth = (width.toLong() * target / side).toInt()
                val scaledHeight = (height.toLong() * target / side).toInt()
                decoder.setTargetSize(scaledWidth, scaledHeight)
                val left = (scaledWidth - target) / 2
                val top = (scaledHeight - target) / 2
                decoder.crop = Rect(left, top, left + target, top + target)
            }
            val square = if (cropped.width == SIZE && cropped.height == SIZE) cropped else
                cropped.scale(SIZE, SIZE).also { cropped.recycle() }
            try {
                val encoded = ByteArrayOutputStream()
                verify(square.compress(Bitmap.CompressFormat.PNG, 100, encoded), "AVATAR_INVALID")
                return PreparedAvatar(square, encoded.toByteArray())
            } catch (failure: Throwable) {
                square.recycle()
                throw failure
            }
        }
    }
}
