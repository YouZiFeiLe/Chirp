package cn.youzifeile.chirp.media

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

class PreparedAvatarTest {
    @Test fun panoramaKeepsCenterDetailAndSavedPngMatchesThePreviewAfterSourceChanges() {
        val width = 4096
        val height = 512
        val start = (width - height) / 2
        val row = IntArray(width) { x -> when {
            x < start -> Color.RED
            x >= start + height -> Color.BLUE
            x % 2 == 0 -> Color.BLACK
            else -> Color.WHITE
        } }
        val original = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        for (y in 0 until height) original.setPixels(row, 0, width, 0, y, width, 1)
        val bytes = ByteArrayOutputStream().use { out ->
            assertTrue(original.compress(Bitmap.CompressFormat.PNG, 100, out))
            out.toByteArray()
        }
        original.recycle()
        val avatar = PreparedAvatar.read(bytes.inputStream())
        bytes.fill(0)
        val saved = BitmapFactory.decodeByteArray(avatar.png, 0, avatar.png.size)
        try {
            assertEquals(512, saved.width)
            assertEquals(512, saved.height)
            for (x in 0 until 512) assertEquals(row[start + x], saved.getPixel(x, 256))
            assertTrue(saved.sameAs(avatar.preview))
        } finally {
            saved.recycle()
            avatar.preview.recycle()
        }
    }
}
