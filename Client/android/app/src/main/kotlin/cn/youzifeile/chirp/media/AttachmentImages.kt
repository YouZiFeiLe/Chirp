package cn.youzifeile.chirp.media

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import androidx.core.graphics.scale
import cn.youzifeile.chirp.data.verify
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

internal object AttachmentImages {
    fun decode(bytes: ByteArray, maximum: Int = 2048): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        verify(bounds.outWidth > 0 && bounds.outHeight > 0 && bounds.outWidth.toLong() * bounds.outHeight <= 60_000_000,
            "ATTACHMENT_INVALID")
        return ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val largest = maxOf(info.size.width, info.size.height)
            if (largest > maximum) decoder.setTargetSize((info.size.width.toLong() * maximum / largest).toInt().coerceAtLeast(1),
                (info.size.height.toLong() * maximum / largest).toInt().coerceAtLeast(1))
        }
    }

    fun thumbnail(bytes: ByteArray): ByteArray {
        var image = decode(bytes, 128)
        try {
            while (true) {
                val output = ByteArrayOutputStream()
                image.compress(Bitmap.CompressFormat.JPEG, 55, output)
                val result = output.toByteArray()
                if (result.size <= 6 * 1024 - 28) return result
                verify(maxOf(image.width, image.height) > 16, "ATTACHMENT_INVALID")
                val smaller = image.scale((image.width * 3 / 4).coerceAtLeast(1), (image.height * 3 / 4).coerceAtLeast(1))
                image.recycle(); image = smaller
            }
        } finally { image.recycle() }
    }
}
