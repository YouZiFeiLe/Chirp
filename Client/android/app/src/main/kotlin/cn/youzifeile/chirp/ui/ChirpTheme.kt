package cn.youzifeile.chirp.ui

import android.app.UiModeManager
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.text.font.FontWeight
import cn.youzifeile.chirp.R

// Material roles for the Chirp Together palette in design-system/chirp-together/design-tokens.json.
private fun chirpColors(dark: Boolean, canvas: Color, brand: Color, contrast: Float): ColorScheme {
    fun tone(light: Long, night: Long) = Color(if (dark) night else light)
    val emphasis = contrast.coerceIn(0f, 1f)
    val strongestInk = if (dark) Color.White else Color.Black
    val ink = lerp(tone(0xFF1C3028, 0xFFEDF4EB), strongestInk, emphasis)
    val muted = lerp(tone(0xFF5C6D62, 0xFFAEC2B4), ink, emphasis)
    val accent = lerp(brand, strongestInk, emphasis * .5f)
    val onAccent = tone(0xFFFFFFFF, 0xFF123721)
    val card = tone(0xFFFFFFFF, 0xFF192A23)
    val subtle = tone(0xFFE8F0E7, 0xFF223A2E)
    val hero = tone(0xFFE2EEE2, 0xFF213C2D)
    val leaf = tone(0xFF47603E, 0xFFBDD0B2)
    val olive = tone(0xFFE4EBDE, 0xFF334530)
    val border = tone(0xFFD5DED3, 0xFF365044)
    return (if (dark) darkColorScheme() else lightColorScheme()).copy(
        primary = accent, onPrimary = onAccent, primaryContainer = hero, onPrimaryContainer = ink,
        secondary = muted, onSecondary = onAccent, secondaryContainer = subtle, onSecondaryContainer = ink,
        tertiary = leaf, onTertiary = onAccent, tertiaryContainer = olive, onTertiaryContainer = ink,
        background = canvas, onBackground = ink, surface = canvas, onSurface = ink,
        surfaceVariant = subtle, onSurfaceVariant = muted, surfaceTint = accent,
        surfaceContainerLowest = tone(0xFFFFFFFF, 0xFF0B1510), surfaceContainerLow = card,
        surfaceContainer = subtle, surfaceContainerHigh = tone(0xFFE2EBE0, 0xFF294234),
        surfaceContainerHighest = tone(0xFFDCE6DA, 0xFF324D3D),
        surfaceDim = tone(0xFFD5DED3, 0xFF101B17), surfaceBright = tone(0xFFFFFFFF, 0xFF354B3F),
        outline = lerp(tone(0xFF728376, 0xFF8CA292), ink, emphasis),
        outlineVariant = lerp(border, muted, emphasis),
        inverseSurface = tone(0xFF192A23, 0xFFEDF4EB), inverseOnSurface = tone(0xFFEDF4EB, 0xFF1C3028),
        inversePrimary = tone(0xFFA9DAB5, 0xFF246448),
        error = tone(0xFFAF403D, 0xFFFFB4A8), onError = tone(0xFFFFFFFF, 0xFF44211D),
        errorContainer = tone(0xFFFBE1DD, 0xFF42282B), onErrorContainer = tone(0xFF802B28, 0xFFFFD0C7),
        primaryFixed = Color(0xFFD2EBD6), primaryFixedDim = Color(0xFFA9DAB5),
        onPrimaryFixed = Color(0xFF123721), onPrimaryFixedVariant = Color(0xFF246448),
        secondaryFixed = Color(0xFFE2EBE0), secondaryFixedDim = Color(0xFFAEC2B4),
        onSecondaryFixed = Color(0xFF192A23), onSecondaryFixedVariant = Color(0xFF405549),
        tertiaryFixed = Color(0xFFE4EBDE), tertiaryFixedDim = Color(0xFFBDD0B2),
        onTertiaryFixed = Color(0xFF22321E), onTertiaryFixedVariant = Color(0xFF47603E),
    )
}

private val chirpTypography = Typography().let { defaults ->
    defaults.copy(
        headlineLarge = defaults.headlineLarge.copy(fontWeight = FontWeight.Medium),
        headlineMedium = defaults.headlineMedium.copy(fontWeight = FontWeight.Medium),
        titleLarge = defaults.titleLarge.copy(fontWeight = FontWeight.Medium),
    )
}

@Composable
internal fun ChirpTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val context = LocalContext.current
    val manager = context.getSystemService(UiModeManager::class.java)
    var contrast by remember(manager) { mutableFloatStateOf(manager.contrast) }
    DisposableEffect(context, manager) {
        val listener = UiModeManager.ContrastChangeListener { contrast = it }
        manager.addContrastChangeListener(context.mainExecutor, listener)
        contrast = manager.contrast
        onDispose { manager.removeContrastChangeListener(listener) }
    }
    val canvas = colorResource(if (darkTheme) R.color.chirp_canvas_dark else R.color.chirp_canvas_light)
    val brand = colorResource(if (darkTheme) R.color.chirp_accent_dark else R.color.chirp_accent_light)
    MaterialTheme(
        colorScheme = remember(darkTheme, canvas, brand, contrast) { chirpColors(darkTheme, canvas, brand, contrast) },
        typography = chirpTypography,
        content = content,
    )
}
