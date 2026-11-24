package cn.youzifeile.chirp.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp

private val crest = floatArrayOf(.16f, .37f, .72f, 1f, .61f, .32f, .48f, .82f, .58f, .29f, .14f)

/** A finite reveal of the Chirp mark. No microphone or level-meter semantics. */
@Composable
internal fun SignalArtwork(
    modifier: Modifier,
    ink: Color,
    accent: Color,
    trailing: Boolean = false,
    emphasis: Float = 1f,
) {
    val reveal = remember { Animatable(0f) }
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    LaunchedEffect(Unit) {
        reveal.animateTo(1f, tween(520, easing = CubicBezierEasing(.05f, .7f, .1f, 1f)))
    }
    Canvas(modifier) {
        val progress = reveal.value
        val focal = when {
            !trailing -> center
            rtl -> Offset(size.width * .16f, size.height * .44f)
            else -> Offset(size.width * .84f, size.height * .44f)
        }
        val radius = minOf(size.height * .46f, size.width * if (trailing) .27f else .36f)
        if (radius <= 0f) return@Canvas
        drawCircle(
            brush = Brush.radialGradient(
                listOf(accent.copy(alpha = .28f * emphasis), Color.Transparent),
                center = focal,
                radius = radius * 1.66f,
            ),
            radius = radius * 1.66f,
            center = focal,
        )

        val spread = .84f + .16f * progress
        for (ring in 1..4) {
            val r = radius * (.45f + ring * .27f) * spread
            val arcTop = focal - Offset(r, r)
            drawCircle(ink.copy(alpha = (.34f - .056f * ring) * emphasis), r, focal,
                style = Stroke(1.dp.toPx()))
            drawArc(accent.copy(alpha = (.77f - .12f * ring) * emphasis), -128f + 28f * ring,
                (29f + ring * 4f) * progress, useCenter = false,
                topLeft = arcTop, size = Size(2 * r, 2 * r), style = Stroke(2.dp.toPx(), cap = StrokeCap.Round))
        }
        val nucleus = radius * .46f
        drawCircle(ink.copy(alpha = .13f * emphasis), nucleus, focal)
        val step = nucleus * 1.45f / crest.size
        crest.forEachIndexed { index, height ->
            val x = focal.x + (index - crest.lastIndex / 2f) * step
            val half = nucleus * .43f * height * (.48f + .52f * progress)
            val color = if (index <= crest.lastIndex / 2) ink else accent
            drawLine(color.copy(alpha = emphasis), Offset(x, focal.y - half), Offset(x, focal.y + half),
                step * .52f, StrokeCap.Round)
        }
    }
}

@Composable
internal fun SpeechSignal(ink: Color, modifier: Modifier = Modifier) {
    val amplitude = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        amplitude.animateTo(1f, spring(dampingRatio = .55f, stiffness = Spring.StiffnessMediumLow))
    }
    Canvas(modifier) {
        val bars = 5
        val step = size.width / bars
        for (index in 0 until bars) {
            val x = step * (index + .5f)
            val peak = crest[index + 2]
            val half = size.height * (.10f + .33f * peak * amplitude.value.coerceIn(0f, 1.12f))
            drawLine(ink, Offset(x, center.y - half), Offset(x, center.y + half), step * .55f, StrokeCap.Round)
        }
    }
}
