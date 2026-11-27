package cn.youzifeile.chirp.ui

import android.app.Activity
import android.app.LocaleManager
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricManager.Authenticators.BIOMETRIC_STRONG
import android.hardware.biometrics.BiometricPrompt
import android.os.CancellationSignal
import android.os.LocaleList
import android.view.ViewTreeObserver
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.round
import androidx.core.content.res.ResourcesCompat
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.ChirpException
import cn.youzifeile.chirp.data.ClockStatus
import javax.crypto.Cipher
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

internal suspend fun authenticateLogin(activity: Activity, cipher: Cipher): Cipher? = suspendCancellableCoroutine { result ->
    val signal = CancellationSignal()
    result.invokeOnCancellation { signal.cancel() }
    val prompt = BiometricPrompt.Builder(activity)
        .setTitle(activity.getString(R.string.unlock_chirp))
        .setDescription(activity.getString(R.string.unlock_prompt_detail))
        .setAllowedAuthenticators(BIOMETRIC_STRONG)
        .setNegativeButton(activity.getString(R.string.cancel), activity.mainExecutor) { _, _ ->
            if (result.isActive) result.resume(null)
        }.build()
    prompt.authenticate(BiometricPrompt.CryptoObject(cipher), signal, activity.mainExecutor,
        object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(auth: BiometricPrompt.AuthenticationResult) {
                if (!result.isActive) return
                val authorized = auth.cryptoObject?.cipher
                if (authorized === cipher) result.resume(authorized)
                else result.resumeWithException(ChirpException("CLIENT_LOCAL_UNLOCK_FAILED"))
            }
            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                if (!result.isActive) return
                when (errorCode) {
                    BiometricPrompt.BIOMETRIC_ERROR_CANCELED, BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED ->
                        result.resume(null)
                    BiometricPrompt.BIOMETRIC_ERROR_NO_BIOMETRICS, BiometricPrompt.BIOMETRIC_ERROR_NO_DEVICE_CREDENTIAL ->
                        result.resumeWithException(ChirpException("LOGIN_BIOMETRICS_CHANGED"))
                    else -> result.resumeWithException(ChirpException("CLIENT_LOCAL_UNLOCK_FAILED"))
                }
            }
        })
}

@Composable
internal fun LockedLoginScreen(state: MainState, unlock: () -> Unit, passkey: () -> Unit, retryClock: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val wash = Brush.verticalGradient(listOf(lerp(colors.surface, colors.primaryContainer, .65f), colors.surface, colors.surface))
    BoxWithConstraints(Modifier.fillMaxSize().background(wash).safeDrawingPadding(), contentAlignment = Alignment.Center) {
        val largeText = LocalDensity.current.fontScale >= 1.5f
        val compact = maxHeight < 520.dp || largeText
        val scroll = rememberScrollState()
        if (maxWidth >= 640.dp && maxWidth > maxHeight && !largeText) {
            Row(Modifier.widthIn(max = 824.dp).fillMaxWidth().verticalScroll(scroll).padding(horizontal = 32.dp, vertical = 20.dp),
                horizontalArrangement = Arrangement.spacedBy(48.dp), verticalAlignment = Alignment.CenterVertically) {
                UnlockWelcome(if (compact) 112.dp else 164.dp, state.unlocking, Modifier.weight(1f))
                UnlockActions(state, unlock, passkey, retryClock, Modifier.weight(1f))
            }
        } else {
            Column(Modifier.widthIn(max = 440.dp).fillMaxWidth().verticalScroll(scroll)
                .heightIn(min = maxHeight.coerceAtMost(800.dp)).padding(horizontal = 28.dp, vertical = 24.dp),
                verticalArrangement = Arrangement.SpaceEvenly, horizontalAlignment = Alignment.CenterHorizontally) {
                UnlockWelcome(if (compact) 108.dp else 184.dp, state.unlocking)
                UnlockActions(state, unlock, passkey, retryClock, Modifier.fillMaxWidth().padding(top = if (compact) 24.dp else 36.dp))
            }
        }
    }
}

@Composable
private fun UnlockWelcome(emblemSize: Dp, unlocking: Boolean, modifier: Modifier = Modifier) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        UnlockEmblem(emblemSize, unlocking)
        Text(stringResource(R.string.welcome_back), Modifier.padding(top = 16.dp).semantics { heading() },
            style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        Text(stringResource(R.string.unlock_login_intro), Modifier.padding(top = 8.dp), style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
    }
}

@Composable
private fun UnlockEmblem(size: Dp, unlocking: Boolean) {
    val decor = LocalView.current.rootView
    val resources = LocalResources.current
    val theme = LocalContext.current.theme
    val mark = remember(resources, theme, LocalConfiguration.current) {
        requireNotNull(ResourcesCompat.getDrawable(resources, R.drawable.unlock_emblem, theme)).mutate()
    }
    // The system prompt takes focus and TaskPreview covers all app content. Only this public mark stays visible.
    if (unlocking) DisposableEffect(decor, mark) {
        val listener = ViewTreeObserver.OnWindowFocusChangeListener { focused ->
            if (focused) decor.overlay.remove(mark) else decor.overlay.add(mark)
        }
        decor.viewTreeObserver.addOnWindowFocusChangeListener(listener)
        if (!decor.hasWindowFocus()) decor.overlay.add(mark)
        onDispose {
            if (decor.viewTreeObserver.isAlive) decor.viewTreeObserver.removeOnWindowFocusChangeListener(listener)
            decor.overlay.remove(mark)
        }
    }
    Image(painterResource(R.drawable.unlock_emblem), contentDescription = null, modifier = Modifier.size(size).onGloballyPositioned {
        val origin = it.positionInWindow().round()
        mark.setBounds(origin.x, origin.y, origin.x + it.size.width, origin.y + it.size.height)
    })
}

@Composable
private fun UnlockActions(state: MainState, unlock: () -> Unit, passkey: () -> Unit, retryClock: () -> Unit, modifier: Modifier) {
    val colors = MaterialTheme.colorScheme
    val context = LocalContext.current
    val (unlockLabel, unlockIcon) = remember(context, LocalConfiguration.current) { context.biometricAction() }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        if (state.clock.status == ClockStatus.Checking) {
            if (!state.unlocking) Text(stringResource(R.string.clock_checking), style = MaterialTheme.typography.bodySmall,
                color = colors.onSurfaceVariant, textAlign = TextAlign.Center)
        } else ClockNotice(state.clock, retryClock)
        state.error?.let { ErrorNote(it) }
        Button(unlock, Modifier.fillMaxWidth().heightIn(min = 56.dp).semantics { liveRegion = LiveRegionMode.Polite },
            enabled = !state.unlocking, shape = MaterialTheme.shapes.large, contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp),
            colors = ButtonDefaults.buttonColors(disabledContainerColor = colors.primaryContainer, disabledContentColor = colors.onPrimaryContainer)) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                if (state.unlocking) CircularProgressIndicator(Modifier.size(20.dp).clearAndSetSemantics {},
                    color = LocalContentColor.current, strokeWidth = 2.dp)
                else Glyph(unlockIcon, Modifier.size(20.dp))
                Text(if (state.unlocking) stringResource(R.string.unlocking_login) else unlockLabel,
                    style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
            }
        }
        TextButton(passkey, Modifier.heightIn(min = 48.dp)) {
            Text(stringResource(R.string.unlock_with_passkey), style = MaterialTheme.typography.labelLarge, textAlign = TextAlign.Center)
        }
    }
}

private fun Context.biometricAction(): Pair<String, Int> {
    val fallback = getString(R.string.unlock_with_biometrics) to R.drawable.ic_lock
    val systemLabel = try { getSystemService(BiometricManager::class.java)?.getStrings(BIOMETRIC_STRONG)?.buttonLabel }
        catch (_: RuntimeException) { null }
    if (systemLabel.isNullOrBlank()) return fallback
    if (packageManager.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT) &&
        !packageManager.hasSystemFeature(PackageManager.FEATURE_FACE) && !packageManager.hasSystemFeature(PackageManager.FEATURE_IRIS)) {
        return getString(R.string.unlock_with_fingerprint) to R.drawable.ic_fingerprint
    }
    // The system selects the active modality on multi-sensor devices and can return its label in the system language.
    val systemLocale = getSystemService(LocaleManager::class.java)?.systemLocales?.get(0)
    return if (systemLocale != null && LocaleList.matchesLanguageAndScript(resources.configuration.locales[0], systemLocale))
        systemLabel.toString() to R.drawable.ic_lock else fallback
}
