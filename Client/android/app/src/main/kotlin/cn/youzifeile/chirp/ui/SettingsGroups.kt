package cn.youzifeile.chirp.ui

import cn.youzifeile.chirp.data.ClientLog
import cn.youzifeile.chirp.data.LogEvent
import androidx.annotation.DrawableRes
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

@Composable
internal fun SettingsGroup(title: String? = null, inset: Boolean = false, content: @Composable ColumnScope.() -> Unit) {
    val colors = MaterialTheme.colorScheme
    if (title != null) {
        Text(title, Modifier.padding(start = 12.dp, top = 8.dp).semantics { heading() },
            style = MaterialTheme.typography.titleSmall, color = colors.primary)
    }
    Surface(modifier = Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.extraLarge,
        color = colors.surfaceContainerLow, border = BorderStroke(1.dp, colors.outlineVariant)) {
        Column(modifier = if (inset) Modifier.padding(16.dp) else Modifier,
            verticalArrangement = if (inset) Arrangement.spacedBy(8.dp) else Arrangement.Top) {
            ProvideTextStyle(MaterialTheme.typography.bodyMedium) { content() }
        }
    }
}

@Composable
internal fun SettingsDivider() {
    HorizontalDivider(Modifier.padding(start = 68.dp, end = 16.dp))
}

@Composable
internal fun SettingsDescription(text: String) {
    Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
internal fun SettingsDisclosure(@DrawableRes icon: Int, title: String, summary: String?,
    summaryColor: Color = MaterialTheme.colorScheme.onSurfaceVariant, logEvent: LogEvent = LogEvent.disclosure,
    content: @Composable ColumnScope.() -> Unit) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    SettingRow(icon, title, summary, onClick = {
        expanded = !expanded
        ClientLog.current?.screen(logEvent, expanded)
    }, expanded = expanded, supportingColor = summaryColor)
    AnimatedVisibility(visible = expanded) {
        Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            HorizontalDivider()
            ProvideTextStyle(MaterialTheme.typography.bodyMedium) { content() }
        }
    }
}
