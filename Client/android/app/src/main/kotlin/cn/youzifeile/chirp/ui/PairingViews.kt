package cn.youzifeile.chirp.ui

import cn.youzifeile.chirp.data.LogEvent
import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.PixelFormat
import android.graphics.PorterDuff
import android.hardware.biometrics.BiometricManager.Authenticators
import android.hardware.biometrics.BiometricPrompt
import android.net.Uri
import android.os.CancellationSignal
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.*
import com.google.zxing.*
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.multi.qrcode.QRCodeMultiReader
import com.google.zxing.qrcode.QRCodeWriter
import java.io.IOException
import java.nio.ByteBuffer
import kotlin.coroutines.resume
import kotlinx.coroutines.*

internal fun qrBitmap(text: String): Bitmap {
    val matrix = QRCodeWriter().encode(text,BarcodeFormat.QR_CODE,768,768)
    return Bitmap.createBitmap(IntArray(matrix.width * matrix.height) { i ->
        if (matrix[i % matrix.width,i / matrix.width]) Color.BLACK else Color.WHITE
    },matrix.width,matrix.height,Bitmap.Config.ARGB_8888)
}

internal suspend fun readPairingQrImage(resolver: ContentResolver, uri: Uri): String = withContext(Dispatchers.IO) {
    val maxBytes = 8 * 1024 * 1024
    val data = try {
        resolver.openInputStream(uri)?.use { it.readNBytes(maxBytes + 1) }
    } catch (_: IOException) {
        null
    } catch (_: SecurityException) {
        null
    } ?: throw ChirpException("PAIR_IMAGE_READ_FAILED")
    verify(data.isNotEmpty(), "PAIR_IMAGE_UNREADABLE")
    verify(data.size <= maxBytes, "PAIR_IMAGE_SIZE")
    val bitmap = try {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(data))) { decoder, info, _ ->
            verify(info.size.width in 1..4096 && info.size.height in 1..4096, "PAIR_IMAGE_SIZE")
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            if (maxOf(info.size.width, info.size.height) > 2048) decoder.setTargetSampleSize(2)
            decoder.setPostProcessor { canvas ->
                canvas.drawColor(Color.WHITE, PorterDuff.Mode.DST_OVER)
                PixelFormat.OPAQUE
            }
        }
    } catch (failure: ChirpException) {
        throw failure
    } catch (_: IOException) {
        throw ChirpException("PAIR_IMAGE_UNREADABLE")
    }
    try {
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        val image = BinaryBitmap(HybridBinarizer(RGBLuminanceSource(bitmap.width, bitmap.height, pixels)))
        val results = try {
            QRCodeMultiReader().decodeMultiple(image, mapOf(DecodeHintType.TRY_HARDER to true))
        } catch (_: NotFoundException) { throw ChirpException("PAIR_ONE_QR") }
        results.singleOrNull()?.text ?: throw ChirpException("PAIR_ONE_QR")
    } finally { bitmap.recycle() }
}

private suspend fun authenticate(activity: ComponentActivity): Boolean = suspendCancellableCoroutine { continuation ->
    val cancel = CancellationSignal()
    continuation.invokeOnCancellation { cancel.cancel() }
    val prompt = BiometricPrompt.Builder(activity).setTitle(activity.getString(R.string.pair_biometric))
        .setDescription(activity.getString(R.string.permission_biometric_purpose))
        .setAllowedAuthenticators(Authenticators.BIOMETRIC_STRONG or Authenticators.DEVICE_CREDENTIAL).build()
    prompt.authenticate(cancel,activity.mainExecutor,object : BiometricPrompt.AuthenticationCallback() {
        override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
            if (continuation.isActive) continuation.resume(true)
        }
        override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
            if (continuation.isActive) continuation.resume(false)
        }
    })
}

@Composable internal fun DeviceAuthorization(
    activity: ComponentActivity, model: MainViewModel, state: MainState, accountShortcut: Boolean = false,
) {
    val title = stringResource(if (accountShortcut) R.string.pair_other_devices else R.string.pair_device)
    if (!state.clock.ready) {
        SettingRow(R.drawable.ic_camera, title, onClick = {}, enabled = false)
        ClockNotice(state.clock) { model.checkClock(manual = true) }
        return
    }
    var options by rememberSaveable { mutableStateOf(false) }
    var approved by remember { mutableStateOf(false) }
    var pairing by remember { mutableStateOf<DevicePairing?>(null) }
    var imported by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<ClientFailure?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var scanning by remember { mutableStateOf(false) }
    fun approve(fromImage: Boolean, decode: suspend () -> String) {
        if (busy || pairing != null) return
        error = null
        busy = true
        scope.launch {
            try {
                pairing = model.approvePairing(decode())
                imported = fromImage
                error = null
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { error = e.clientFailure("DEVICE_PAIRING_INVALID") }
            finally { busy = false }
        }
    }
    val image = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) {
            options = false
            approve(true) { readPairingQrImage(activity.contentResolver, uri) }
        }
    }
    val chooseImage = { LogEvent.importPairingImage.record(); image.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
    val camera = rememberPermission(activity, ChirpPermission.Camera) {
        scanning = true
    }
    if (scanning) PairingScanner(activity, close = { scanning = false }, chooseImage = {
        scanning = false
        options = true
        chooseImage()
    }) { code ->
        scanning = false
        approve(false) { code }
    }
    val local = state.accountDevice
    val canEnroll = state.account == null || (local != null && local.certificates.size < 8 &&
        local.certificates.lastOrNull()?.canEnroll == true && local.leaf !in state.identity.revoked)
    val unavailable = if (canEnroll) null else stringResource(R.string.pair_enrollment_unavailable)
    val enabled = canEnroll && !busy && pairing == null
    val openOptions = {
        if (model.clockReady()) {
            approved = false
            options = true
        }
    }
    SettingRow(R.drawable.ic_camera, title, unavailable ?: stringResource(R.string.pair_other_devices_detail),
        onClick = openOptions, enabled = enabled)
    if (busy) {
        LinearProgressIndicator(Modifier.fillMaxWidth())
        Text(stringResource(R.string.pair_checking), style = MaterialTheme.typography.bodyMedium)
    }
    if (approved) Text(stringResource(R.string.pair_approved), color = MaterialTheme.colorScheme.primary)
    error?.let { ErrorNote(it) }
    if (options) ChirpDialog(icon = R.drawable.ic_key, onDismissRequest = { options = false }, title = { Text(title) },
        text = { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (!accountShortcut) SettingsDescription(stringResource(R.string.pair_purpose))
            Text(stringResource(R.string.pair_import_help))
            SettingRow(R.drawable.ic_camera, stringResource(R.string.pair_scan), onClick = { options = false; LogEvent.scanPairingCode.record(); camera() })
            SettingRow(R.drawable.ic_image, stringResource(R.string.pair_choose_image), onClick = chooseImage)
        } },confirmButton = { TextButton({ options = false }) { Text(stringResource(R.string.cancel)) } })
    pairing?.let { session -> PairingDialog(activity,session,imported,{ pairing = null }) { pairing = null; approved = true } }
}

@Composable internal fun PairingDialog(activity: ComponentActivity, session: DevicePairing, imported: Boolean,
    close: () -> Unit, completed: (DeviceIdentity) -> Unit) {
    val scope = rememberCoroutineScope()
    var digits by remember(session) { mutableStateOf(session.decimals) }
    val input = remember(session) { PairingCodeInputState() }
    val needsCode = imported && session.approving
    var canEnroll by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<ClientFailure?>(null) }
    var pollError by remember { mutableStateOf<ClientFailure?>(null) }
    var askApproval by remember(session) { mutableStateOf(false) }
    var remaining by remember(session) { mutableLongStateOf(session.remainingSeconds()) }
    LaunchedEffect(session) { while (remaining > 0) { delay(250); remaining = session.remainingSeconds() } }
    var confirmed by remember(session) { mutableStateOf(session.confirmed) }
    if (session.approving) DisposableEffect(session) { onDispose { session.close() } }
    val done by rememberUpdatedState(completed)
    LaunchedEffect(session) {
        while (isActive && !failed) {
            try {
                session.poll()
                pollError = null
                digits = session.decimals; confirmed = session.confirmed
                session.approval?.let { done(it); return@LaunchedEffect }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                pollError = e.clientFailure()
                if (e is ChirpException && e.status < 500 && e.status != 429 || e !is IOException) failed = true
            }
            delay(900)
        }
    }
    fun cancel() { scope.launch {
        try { session.cancel() } catch (e: CancellationException) { throw e } catch (_: java.io.IOException) { }
        finally { close() }
    } }
    fun confirm() {
        if (busy || failed || session.remainingSeconds() == 0L) return
        val code = if (needsCode) input.completeCode ?: return else null
        busy = true
        scope.launch {
            try {
                session.confirm(code,canEnroll) { authenticate(activity) }
                confirmed = session.confirmed
                error = null
            } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.clientFailure("DEVICE_PAIRING_INVALID") }
            finally { busy = false }
        }
    }
    if (!session.approving) {
        NewDeviceAuthorizationPage(session.request, remaining, digits, confirmed, busy, failed,
            pollError ?: error, close, ::confirm)
        return
    }
    if (askApproval && remaining > 0 && !failed) {
        ChirpDialog(icon = R.drawable.ic_key, onDismissRequest = { askApproval = false },
            title = { Text(stringResource(R.string.pair_double_title)) },
            text = { Text(stringResource(R.string.pair_double_body)) },
            confirmButton = { TextButton({ askApproval = false; confirm() }) { Text(stringResource(R.string.pair_double_confirm)) } },
            dismissButton = { TextButton({ askApproval = false }) { Text(stringResource(R.string.cancel)) } })
        return
    }
    ChirpDialog(icon = R.drawable.ic_key, onDismissRequest = ::cancel,title = { Text(stringResource(R.string.pair_device)) },
        text = { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(if (digits.isEmpty() && !failed && remaining > 0) R.string.pair_mutual_setup else R.string.device_auth_title))
            Text(stringResource(R.string.pair_owner_only))
            Notice(stringResource(R.string.pair_session_replaced), icon = R.drawable.ic_key)
            Text(stringResource(R.string.pair_remaining, remaining))
            Text(session.request.origin,style = MaterialTheme.typography.bodySmall)
            if (digits.isNotEmpty() && remaining > 0 && !failed) {
                Text(stringResource(R.string.pair_code_title), style = MaterialTheme.typography.titleSmall)
                Text(stringResource(if (needsCode) R.string.pair_type_digits else R.string.pair_check_digits))
                if (needsCode) PairingCodeFields(input, enabled = !busy && !confirmed)
                else { SasDigits(digits) }
                Row(Modifier.fillMaxWidth()
                    .toggleable(canEnroll, enabled = !busy && !confirmed, role = androidx.compose.ui.semantics.Role.Checkbox, onValueChange = { canEnroll = it })
                    .heightIn(min = 48.dp), horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Checkbox(canEnroll, onCheckedChange = null, enabled = !busy && !confirmed)
                    Text(stringResource(R.string.pair_enroll))
                }
                if (confirmed) Text(stringResource(R.string.pair_wait_new))
            }
            if (failed) Text(stringResource(R.string.pair_stopped))
            if (remaining == 0L) ErrorNote("DEVICE_PAIRING_EXPIRED") else (pollError ?: error)?.let { ErrorNote(it) }
        } },confirmButton = {
            if (!failed && remaining > 0 && digits.size == 3 && !confirmed) TextButton({
                askApproval = true
            }, enabled = !busy && (!needsCode || input.completeCode != null)) {
                Text(stringResource(R.string.pair_authorize))
            }
        },dismissButton = { TextButton(::cancel) { Text(stringResource(R.string.pairing_cancel)) } })
}
