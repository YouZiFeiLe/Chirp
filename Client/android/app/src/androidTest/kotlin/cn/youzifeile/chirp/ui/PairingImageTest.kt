package cn.youzifeile.chirp.ui

import android.app.Activity
import android.app.Instrumentation
import android.content.ContentUris
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.net.Uri
import android.provider.BaseColumns
import android.provider.MediaStore
import android.provider.MediaStore.MediaColumns
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.content.FileProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.test.platform.app.InstrumentationRegistry
import cn.youzifeile.chirp.ChirpApplication
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.*
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class PairingImageTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private fun request(expires: Long): PairRequest {
        val seed = ByteArray(32) { 7 }
        val request = PairRequest(origin = "https://example.test:443", account = "alice",
            root = publicKey(ByteArray(32)), key = publicKey(seed), nonce = base64(ByteArray(32) { 1 }),
            expires = expires, commitment = base64(ByteArray(32) { 2 }))
        return request.copy(signature = sign(seed, request.message()))
    }

    private fun Bitmap.write(file: File, format: Bitmap.CompressFormat = Bitmap.CompressFormat.PNG) {
        file.outputStream().use { assertTrue(compress(format, 55, it)) }
    }

    @Test fun newDeviceSavesOneScannablePngInTheGalleryThenShowsOnlyCurrentActions() {
        val activity = compose.activity
        val resolver = activity.contentResolver
        val images = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        fun ownImages(): Set<Long> = resolver.query(images, arrayOf(BaseColumns._ID),
            "${MediaColumns.OWNER_PACKAGE_NAME} = ? AND ${MediaColumns.RELATIVE_PATH} = ?",
            arrayOf(activity.packageName, "Pictures/Chirp/"), null)!!.use { cursor ->
            buildSet { while (cursor.moveToNext()) add(cursor.getLong(0)) }
        }
        val baseline = ownImages()
        val invitation = request(nowSeconds() + 240)
        var remaining by mutableLongStateOf(240L)
        var codes by mutableStateOf(emptyList<Int>())
        var confirmed by mutableStateOf(false)
        var closed = false
        fun node(id: Int) = compose.onNodeWithText(activity.getString(id))
        compose.setContent { ChirpTheme {
            NewDeviceAuthorizationPage(invitation, remaining, codes, confirmed, false, false, null,
                { closed = true }, { confirmed = true })
        } }
        try {
            val label = activity.getString(R.string.pairing_qr_label)
            compose.waitUntil(10_000) { compose.onAllNodesWithContentDescription(label).fetchSemanticsNodes().isNotEmpty() }
            snapshotSetupPage(activity, "device-qr", compose.onNode(isDialog()))
            val onScreen = compose.onNodeWithContentDescription(label).performScrollTo()
            val screenFile = File.createTempFile("rendered-qr-", ".png", activity.cacheDir)
            try {
                val pixels = onScreen.captureToImage().asAndroidBitmap()
                try { pixels.write(screenFile) } finally { pixels.recycle() }
                assertEquals(invitation.code(), runBlocking { readPairingQrImage(resolver, Uri.fromFile(screenFile)) })
            } finally { screenFile.delete() }
            node(R.string.pair_gallery_save).performScrollTo().performClick()
            val saved = activity.getString(R.string.pair_image_saved)
            compose.waitUntil(10_000) { compose.onAllNodesWithText(saved).fetchSemanticsNodes().isNotEmpty() }
            node(R.string.pair_gallery_save).assertDoesNotExist()
            val uri = ContentUris.withAppendedId(images, (ownImages() - baseline).single())
            resolver.query(uri, arrayOf(MediaColumns.DISPLAY_NAME, MediaColumns.MIME_TYPE, MediaColumns.IS_PENDING), null, null, null)!!.use {
                assertTrue(it.moveToFirst())
                assertTrue(it.getString(0).endsWith(".png"))
                assertEquals("image/png", it.getString(1))
                assertEquals(0, it.getInt(2))
            }
            assertEquals(invitation, runBlocking { PairRequest.parse(readPairingQrImage(resolver, uri)) })
            val instrument = InstrumentationRegistry.getInstrumentation()
            var shared: Intent? = null
            val monitor = object : Instrumentation.ActivityMonitor() {
                override fun onStartActivity(intent: Intent): Instrumentation.ActivityResult? {
                    if (intent.action != Intent.ACTION_CHOOSER) return null
                    shared = intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    return Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null)
                }
            }
            instrument.addMonitor(monitor)
            try {
                node(R.string.pair_share_png).performScrollTo().performClick()
                val send = requireNotNull(shared)
                assertEquals(Intent.ACTION_SEND, send.action)
                assertEquals("image/png", send.type)
                assertEquals(uri, send.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java))
                assertEquals(uri, send.clipData?.getItemAt(0)?.uri)
                assertEquals(Intent.FLAG_GRANT_READ_URI_PERMISSION, send.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } finally { instrument.removeMonitor(monitor) }
            compose.runOnIdle { codes = listOf(1234, 3567, 8000) }
            compose.onNodeWithContentDescription(label).assertDoesNotExist()
            node(R.string.pair_match_new).performScrollTo().performClick()
            node(R.string.pair_wait_old).assertIsDisplayed()
            compose.runOnIdle { remaining = 0 }
            node(R.string.pair_match_new).assertDoesNotExist()
            node(R.string.pair_gallery_save).assertDoesNotExist()
            node(R.string.pair_return_setup).performScrollTo().performClick()
            compose.runOnIdle { assertTrue(closed) }
        } finally {
            for (id in ownImages() - baseline) {
                val uri = ContentUris.withAppendedId(images, id)
                val code = runCatching { runBlocking { readPairingQrImage(resolver, uri) } }.getOrNull()
                if (code == invitation.code()) resolver.delete(uri, null, null)
            }
        }
    }

    @Test fun readsTranscodedAndTransparentCodesByContent() = runBlocking {
        val activity = compose.activity
        val file = File.createTempFile("pairing-", ".bin", activity.cacheDir)
        val code = request(nowSeconds() + 240).code()
        val source = qrBitmap(code)
        try {
            for (format in listOf(Bitmap.CompressFormat.PNG, Bitmap.CompressFormat.JPEG, Bitmap.CompressFormat.WEBP_LOSSY)) {
                source.write(file, format)
                assertEquals(format.name, code, readPairingQrImage(activity.contentResolver, Uri.fromFile(file)))
            }
            val pixels = IntArray(source.width * source.height)
            source.getPixels(pixels, 0, source.width, 0, 0, source.width, source.height)
            for (i in pixels.indices) if (pixels[i] == Color.WHITE) pixels[i] = Color.TRANSPARENT
            val transparent = Bitmap.createBitmap(pixels, source.width, source.height, Bitmap.Config.ARGB_8888)
            try { transparent.write(file) } finally { transparent.recycle() }
            assertEquals(code, readPairingQrImage(activity.contentResolver, Uri.fromFile(file)))
        } finally { source.recycle(); file.delete() }
    }

    @Test fun identifiesUnreadableOversizedAndAmbiguousImages() = runBlocking {
        val activity = compose.activity
        val file = File.createTempFile("pairing-", ".bin", activity.cacheDir)
        suspend fun expect(code: String) {
            val error = runCatching { readPairingQrImage(activity.contentResolver, Uri.fromFile(file)) }.exceptionOrNull()
            assertEquals(error.toString(), code, (error as? ChirpException)?.code)
        }
        try {
            file.writeText("unreadable image")
            expect("PAIR_IMAGE_UNREADABLE")
            file.writeBytes(ByteArray(8 * 1024 * 1024 + 1))
            expect("PAIR_IMAGE_SIZE")
            val wide = Bitmap.createBitmap(4097, 1, Bitmap.Config.ARGB_8888)
            try { wide.write(file) } finally { wide.recycle() }
            expect("PAIR_IMAGE_SIZE")
            val first = qrBitmap("one")
            val second = qrBitmap("two")
            val pair = Bitmap.createBitmap(first.width * 2, first.height, Bitmap.Config.ARGB_8888)
            try {
                pair.eraseColor(Color.WHITE)
                pair.write(file)
                expect("PAIR_ONE_QR")
                val canvas = Canvas(pair)
                canvas.drawBitmap(first, 0f, 0f, null)
                canvas.drawBitmap(second, first.width.toFloat(), 0f, null)
                pair.write(file)
                expect("PAIR_ONE_QR")
            } finally { first.recycle(); second.recycle(); pair.recycle() }
        } finally { file.delete() }
        expect("PAIR_IMAGE_READ_FAILED")
    }

    @Test fun galleryRequestsOneImageAndReturnsToAuthorizationAfterCancelOrSelection() {
        val activity = compose.activity
        val app = activity.application as ChirpApplication
        val instrument = InstrumentationRegistry.getInstrumentation()
        compose.setContent {
            val model = viewModel { MainViewModel(app, restoreOnStart = false, networkClock = synchronizedTestClock()) }
            val state by model.state.collectAsState()
            ChirpTheme { Column { DeviceAuthorization(activity, model, state) } }
        }
        compose.onNodeWithText(activity.getString(R.string.pair_device)).performClick()
        val choose = compose.onNodeWithText(activity.getString(R.string.pair_choose_image))
        fun pick(selection: Uri?) {
            var launched: Intent? = null
            val monitor = object : Instrumentation.ActivityMonitor() {
                override fun onStartActivity(intent: Intent): Instrumentation.ActivityResult? {
                    if (intent.action !in setOf(MediaStore.ACTION_PICK_IMAGES, Intent.ACTION_OPEN_DOCUMENT)) return null
                    launched = intent
                    return if (selection == null) Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null)
                    else Instrumentation.ActivityResult(Activity.RESULT_OK, Intent().setData(selection))
                }
            }
            instrument.addMonitor(monitor)
            try {
                choose.performScrollTo().performClick()
                val intent = requireNotNull(launched)
                assertEquals(MediaStore.ACTION_PICK_IMAGES, intent.action)
                assertEquals("image/*", intent.type)
                assertFalse(intent.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false))
                assertFalse(intent.hasExtra(MediaStore.EXTRA_PICK_IMAGES_MAX))
            } finally { instrument.removeMonitor(monitor) }
        }
        pick(null)
        choose.assertIsDisplayed()
        val directory = File(activity.cacheDir, "android-protocol").apply { mkdirs() }
        val file = File.createTempFile("pairing-", ".jpg", directory)
        try {
            val picture = qrBitmap(request(nowSeconds() - 1).code())
            try { picture.write(file, Bitmap.CompressFormat.JPEG) } finally { picture.recycle() }
            pick(FileProvider.getUriForFile(app, "${app.packageName}.test-files", file))
            val expired = activity.getString(R.string.pair_expired)
            compose.waitUntil(5_000) { compose.onAllNodesWithText(expired).fetchSemanticsNodes().isNotEmpty() }
            compose.onNode(isDialog()).assertDoesNotExist()
        } finally { file.delete() }
    }
}
