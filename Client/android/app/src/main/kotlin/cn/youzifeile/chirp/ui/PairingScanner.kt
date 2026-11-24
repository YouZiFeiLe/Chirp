package cn.youzifeile.chirp.ui

import android.os.SystemClock
import android.util.Size
import android.view.ViewOutlineProvider
import androidx.activity.ComponentActivity
import androidx.camera.core.CameraInfo
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraState
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Observer
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.PairRequest
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.ReaderException
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.multi.qrcode.QRCodeMultiReader
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

internal fun scanPairingFrame(plane: ByteBuffer, width: Int, height: Int, rowStride: Int, pixelStride: Int): String? {
    if (width <= 0 || height <= 0 || pixelStride <= 0) return null
    val rowBytes = (width - 1L) * pixelStride + 1
    if (rowStride < rowBytes || (height - 1L) * rowStride + rowBytes > plane.remaining()) return null
    val buffer = plane.duplicate()
    val start = buffer.position()
    val pixels = ByteArray(width * height)
    for (y in 0 until height) {
        val row = start + y * rowStride
        if (pixelStride == 1) {
            buffer.position(row)
            buffer.get(pixels, y * width, width)
        } else {
            for (x in 0 until width) pixels[y * width + x] = buffer[row + x * pixelStride]
        }
    }
    val source = PlanarYUVLuminanceSource(pixels, width, height, 0, 0, width, height, false)
    val result = try {
        QRCodeMultiReader().decodeMultiple(BinaryBitmap(HybridBinarizer(source)),
            mapOf(DecodeHintType.TRY_HARDER to true)).singleOrNull()?.text
    } catch (_: ReaderException) { null }
    return result?.takeIf { runCatching { PairRequest.parse(it) }.isSuccess }
}

@Composable
internal fun PairingScanner(activity: ComponentActivity, close: () -> Unit, chooseImage: () -> Unit, onCode: (String) -> Unit) {
    val previewView = remember(activity) { PreviewView(activity).apply {
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        // CameraX scales its TextureView past the square's edges to fill the viewfinder.
        outlineProvider = ViewOutlineProvider.BOUNDS
        clipToOutline = true
        contentDescription = activity.getString(R.string.scan_camera_preview)
    } }
    var failed by remember { mutableStateOf(false) }
    var cameraReady by remember { mutableStateOf(false) }
    val deliver by rememberUpdatedState(onCode)
    DisposableEffect(activity, previewView) {
        val active = AtomicBoolean(true)
        val delivered = AtomicBoolean(false)
        val executor = Executors.newSingleThreadExecutor()
        val main = activity.mainExecutor
        val preview = Preview.Builder().build().apply { surfaceProvider = previewView.surfaceProvider }
        val resolution = ResolutionSelector.Builder().setResolutionStrategy(ResolutionStrategy(
            Size(1280, 960), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER)).build()
        val analysis = ImageAnalysis.Builder().setResolutionSelector(resolution)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
        var lastFrame = -250L
        analysis.setAnalyzer(executor) { frame: ImageProxy ->
            try {
                val now = SystemClock.elapsedRealtime()
                if (active.get() && !delivered.get() && now - lastFrame >= 250) {
                    lastFrame = now
                    val y = frame.planes[0]
                    val code = scanPairingFrame(y.buffer, frame.width, frame.height, y.rowStride, y.pixelStride)
                    if (code != null && delivered.compareAndSet(false, true)) {
                        main.execute { if (active.get()) deliver(code) }
                    }
                }
            } finally { frame.close() }
        }
        var provider: ProcessCameraProvider? = null
        var camera: CameraInfo? = null
        val stateChanged = Observer<CameraState> { state ->
            if (active.get()) {
                cameraReady = state.type == CameraState.Type.OPEN
                failed = state.error?.type == CameraState.ErrorType.CRITICAL
            }
        }
        val pending = ProcessCameraProvider.getInstance(activity)
        pending.addListener({
            if (active.get()) {
                try {
                    val ready = pending.get()
                    provider = ready
                    val lens = if (ready.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA)) CameraSelector.DEFAULT_BACK_CAMERA
                        else CameraSelector.DEFAULT_FRONT_CAMERA
                    camera = ready.bindToLifecycle(activity, lens, preview, analysis).cameraInfo
                    camera.cameraState.observe(activity, stateChanged)
                } catch (_: Exception) { failed = true }
            }
        }, main)
        onDispose {
            active.set(false)
            camera?.cameraState?.removeObserver(stateChanged)
            analysis.clearAnalyzer()
            provider?.unbind(preview, analysis)
            executor.shutdown()
        }
    }
    ChirpDialog(icon = R.drawable.ic_camera, onDismissRequest = close, title = { Text(stringResource(R.string.pair_scan)) }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (!failed && !cameraReady) Text(stringResource(R.string.camera_preparing))
            if (!failed) AndroidView(factory = { previewView }, modifier = Modifier.fillMaxWidth().aspectRatio(1f))
            if (failed) Notice(stringResource(R.string.scan_camera_unavailable), icon = R.drawable.ic_camera)
            else {
                Text(stringResource(R.string.scan_camera_hint), style = androidx.compose.material3.MaterialTheme.typography.labelLarge)
                Text(stringResource(R.string.pair_camera_help))
            }
        }
    }, confirmButton = { TextButton(chooseImage) { Text(stringResource(R.string.pair_choose_image)) } },
        dismissButton = { TextButton(close) { Text(stringResource(R.string.cancel)) } })
}
