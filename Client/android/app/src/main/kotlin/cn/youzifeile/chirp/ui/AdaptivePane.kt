package cn.youzifeile.chirp.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfoV2
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.round
import kotlin.math.roundToInt

/** Keeps a single screen on one display region, including when a navigation rail precedes it. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
internal fun FormPane(content: @Composable () -> Unit) {
    val hinges = currentWindowAdaptiveInfoV2().windowPosture.hingeList.filter { it.isSeparating || it.isOccluding }
    var origin by remember { mutableStateOf(IntOffset.Zero) }
    val frame = if (hinges.isEmpty()) Modifier else Modifier.onGloballyPositioned { origin = it.positionInWindow().round() }
    Layout(content = { Box(Modifier.fillMaxSize()) { content() } }, modifier = Modifier.fillMaxSize().then(frame)) { children, bounds ->
        val width = bounds.maxWidth
        val height = bounds.maxHeight
        var left = 0
        var top = 0
        var right = width
        var bottom = height
        val gap = 8.dp.roundToPx()
        for (hinge in hinges) {
            val x1 = hinge.bounds.left.roundToInt() - origin.x
            val x2 = hinge.bounds.right.roundToInt() - origin.x
            val y1 = hinge.bounds.top.roundToInt() - origin.y
            val y2 = hinge.bounds.bottom.roundToInt() - origin.y
            if (x1 >= right || x2 <= left || y1 >= bottom || y2 <= top) continue
            if (hinge.isVertical) {
                if (x1 - left >= right - x2) right = (x1 - gap).coerceAtLeast(left)
                else left = (x2 + gap).coerceAtMost(right)
            } else {
                if (y1 - top >= bottom - y2) bottom = (y1 - gap).coerceAtLeast(top)
                else top = (y2 + gap).coerceAtMost(bottom)
            }
        }
        val pane = children.single().measure(Constraints.fixed(right - left, bottom - top))
        layout(width, height) { pane.place(left, top) }
    }
}
