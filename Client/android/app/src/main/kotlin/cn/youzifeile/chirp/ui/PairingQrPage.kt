package cn.youzifeile.chirp.ui

import cn.youzifeile.chirp.data.LogEvent
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.ClientFailure
import cn.youzifeile.chirp.data.PairRequest
import cn.youzifeile.chirp.data.nowSeconds
import java.io.IOException
import kotlinx.coroutines.*

internal suspend fun savePairingQrToGallery(resolver: ContentResolver, bitmap: Bitmap): Uri = withContext(Dispatchers.IO) {
    val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    val values = ContentValues().apply {
        put(MediaStore.Images.Media.DISPLAY_NAME, "Chirp-QR-${System.currentTimeMillis()}.png")
        put(MediaStore.Images.Media.MIME_TYPE, "image/png")
        put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/Chirp")
        put(MediaStore.Images.Media.IS_PENDING, 1)
    }
    val uri = resolver.insert(collection, values) ?: throw IOException("Could not create gallery image")
    var published = false
    try {
        val output = resolver.openOutputStream(uri) ?: throw IOException("Could not open gallery image")
        output.use { if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) throw IOException("PNG encoding failed") }
        ensureActive()
        values.clear()
        values.put(MediaStore.Images.Media.IS_PENDING, 0)
        if (resolver.update(uri, values, null, null) != 1) throw IOException("Could not publish gallery image")
        published = true
        uri
    } finally {
        if (!published) resolver.delete(uri, null, null)
    }
}

@Composable
internal fun NewDeviceAuthorizationPage(request: PairRequest, remaining: Long, digits: List<Int>, confirmed: Boolean,
    busy: Boolean, failed: Boolean, failure: ClientFailure?, close: () -> Unit, confirm: () -> Unit) {
    LogScreen(LogEvent.pairingRequest)
    val ended = failed || remaining == 0L
    val (title, detail) = when {
        remaining == 0L -> R.string.pair_request_expired to R.string.pair_request_again
        ended -> R.string.pair_request_ended to R.string.pair_request_again
        confirmed -> R.string.pair_wait_old to R.string.pair_keep_open
        digits.isNotEmpty() -> R.string.pair_code_title to R.string.pair_new_code_detail
        else -> R.string.pair_scan_this to R.string.pair_scan_this_detail
    }
    Dialog(onDismissRequest = close, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
            key(request, title) {
                SettingsPage(stringResource(R.string.setup_authorize_device), close) {
                    IdentityFlowHeading(request.origin, R.drawable.ic_link, title, detail)
                    if (remaining > 0L) failure?.let { ErrorNote(it) }
                    if (ended) {
                        IdentityActionButton(stringResource(R.string.pair_return_setup), R.drawable.ic_back, onClick = close)
                    } else {
                        if (digits.isEmpty()) PairingQrCard(request, remaining)
                        else {
                            SasDigits(digits)
                            if (confirmed) LinearProgressIndicator(Modifier.fillMaxWidth())
                            else IdentityActionButton(stringResource(R.string.pair_match_new), R.drawable.ic_check, !busy, confirm)
                            PairingTime(remaining)
                        }
                        TextButton(close) { Text(stringResource(R.string.pairing_cancel)) }
                    }
                }
            }
        }
    }
}

@Composable
private fun PairingTime(remaining: Long) {
    Text(stringResource(R.string.pair_time_left, remaining / 60, remaining % 60),
        style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun PairingQrCard(request: PairRequest, remaining: Long) {
    val context = LocalContext.current
    val resolver = context.contentResolver
    val scope = rememberCoroutineScope()
    val bitmap by produceState<Bitmap?>(null, request) {
        value = withContext(Dispatchers.Default) { qrBitmap(request.code()) }
    }
    var saving by remember(request) { mutableStateOf(false) }
    var savedUri by rememberSaveable(request.nonce) { mutableStateOf<Uri?>(null) }
    var saveFailed by remember(request) { mutableStateOf(false) }
    var shareUnavailable by remember(request) { mutableStateOf(false) }
    Surface(Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.extraLarge, color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Column(Modifier.padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            val ready = bitmap
            Surface(Modifier.widthIn(max = 288.dp).fillMaxWidth().aspectRatio(1f), color = Color.White, shape = MaterialTheme.shapes.large) {
                Box(contentAlignment = Alignment.Center) {
                    if (ready != null) Image(ready.asImageBitmap(), stringResource(R.string.pairing_qr_label),
                        Modifier.fillMaxSize(), filterQuality = FilterQuality.None)
                    else CircularProgressIndicator()
                }
            }
            PairingTime(remaining)
            val uri = savedUri
            if (uri != null) {
                Note(R.drawable.ic_check, stringResource(R.string.pair_image_saved),
                    Modifier.semantics { liveRegion = LiveRegionMode.Polite }, color = MaterialTheme.colorScheme.primary)
                val shareLabel = stringResource(R.string.pair_share_png)
                OutlinedButton(onClick = {
                    if (request.expires > nowSeconds()) {
                        val send = Intent(Intent.ACTION_SEND).setType("image/png").putExtra(Intent.EXTRA_STREAM, uri)
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        send.clipData = ClipData.newRawUri(shareLabel, uri)
                        try {
                            LogEvent.sharePairingImage.measure { context.startActivity(Intent.createChooser(send, shareLabel)) }
                            shareUnavailable = false
                        } catch (_: ActivityNotFoundException) { shareUnavailable = true }
                    }
                }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(shareLabel) }
                if (shareUnavailable) SettingsDescription(stringResource(R.string.pair_share_unavailable))
            } else {
                FilledTonalButton(onClick = {
                    if (ready != null && !saving && request.expires > nowSeconds()) {
                        saving = true
                        saveFailed = false
                        scope.launch {
                            try { savedUri = LogEvent.savePairingImage.measure { savePairingQrToGallery(resolver, ready) } }
                            catch (e: CancellationException) { throw e }
                            catch (_: Exception) { saveFailed = true }
                            finally { saving = false }
                        }
                    }
                }, enabled = ready != null && !saving, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                    Glyph(R.drawable.ic_image, Modifier.size(20.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(if (saving) R.string.pair_gallery_saving else R.string.pair_gallery_save))
                }
            }
            if (saveFailed) ErrorNote("PAIR_IMAGE_SAVE_FAILED")
            Text(stringResource(R.string.pair_new_help), style = MaterialTheme.typography.bodyMedium)
        }
    }
}
