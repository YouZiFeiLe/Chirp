package cn.youzifeile.chirp.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import cn.youzifeile.chirp.R

@Composable
internal fun RoomCodeComparison(
    peerName: String?,
    numbers: List<Int>,
    confirmed: Boolean,
    secondsLeft: Long,
    onMatch: () -> Unit,
    onMismatch: () -> Unit,
    onCancel: () -> Unit,
    fingerprints: @Composable () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    Dialog(onDismissRequest = onCancel, properties = DialogProperties(
        dismissOnClickOutside = false, usePlatformDefaultWidth = false, decorFitsSystemWindows = false,
    )) {
        Box(Modifier.windowInsetsPadding(WindowInsets.safeDrawing).padding(horizontal = 12.dp, vertical = 8.dp)) {
            Surface(Modifier.widthIn(max = 520.dp).fillMaxWidth(), shape = MaterialTheme.shapes.extraLarge,
                color = colors.surfaceContainerLow, contentColor = colors.onSurface) {
                Column {
                    Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(20.dp),
                        verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Surface(shape = MaterialTheme.shapes.medium, color = colors.primary, contentColor = colors.onPrimary) {
                                Glyph(R.drawable.ic_lock, Modifier.padding(11.dp).size(22.dp))
                            }
                            Column(Modifier.weight(1f)) {
                                val context = stringResource(R.string.room_device_verification)
                                if (peerName != null) Text(context, style = MaterialTheme.typography.labelLarge, color = colors.primary)
                                Text(peerName ?: context, Modifier.semantics { heading() },
                                    style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                            }
                            IconButton(onClick = onCancel) {
                                Glyph(R.drawable.ic_close, label = stringResource(R.string.verify_mismatch), tint = colors.onSurfaceVariant)
                            }
                        }
                        ComparisonCodes(numbers, secondsLeft)
                        Text(stringResource(R.string.room_compare_channel), style = MaterialTheme.typography.bodyMedium,
                            color = colors.onSurfaceVariant)
                        fingerprints()
                    }
                    HorizontalDivider(color = colors.outlineVariant)
                    Box(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp)) {
                        if (confirmed) {
                            Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
                                horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                                CircularProgressIndicator(Modifier.size(22.dp).clearAndSetSemantics {}, strokeWidth = 2.dp)
                                Column {
                                    Text(stringResource(R.string.sas_compared_all), style = MaterialTheme.typography.titleSmall)
                                    SettingsDescription(stringResource(R.string.sas_peer_proof))
                                }
                            }
                        } else {
                            ComparisonActions(secondsLeft > 0, onMatch, onMismatch)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ComparisonCodes(numbers: List<Int>, secondsLeft: Long) {
    val colors = MaterialTheme.colorScheme
    val type = MaterialTheme.typography
    val digits = type.headlineLarge.copy(fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold, letterSpacing = 1.sp)
    val digitSize = TextAutoSize.StepBased(minFontSize = 20.sp, maxFontSize = digits.fontSize, stepSize = 1.sp)
    Surface(Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.large,
        color = colors.primaryContainer, contentColor = colors.onPrimaryContainer) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                verticalArrangement = Arrangement.spacedBy(4.dp), itemVerticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.sas_compare_together), Modifier.padding(end = 8.dp).semantics { heading() },
                    style = type.titleMedium, fontWeight = FontWeight.SemiBold)
                val spokenTime = stringResource(R.string.verification_remaining, secondsLeft)
                Text(if (secondsLeft == 0L) stringResource(R.string.verification_expired)
                    else stringResource(R.string.room_code_time, secondsLeft / 60, secondsLeft % 60),
                    Modifier.clearAndSetSemantics { contentDescription = spokenTime },
                    style = type.labelLarge.copy(fontFeatureSettings = "tnum"), color = colors.primary)
            }
            HorizontalDivider(color = colors.primary.copy(alpha = .22f))
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                numbers.forEachIndexed { index, number ->
                    if (index > 0) VerticalDivider(Modifier.height(40.dp), color = colors.primary.copy(alpha = .18f))
                    val description = spokenCodeGroup(index + 1, number)
                    Column(Modifier.weight(1f).clearAndSetSemantics { contentDescription = description },
                        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(stringResource(R.string.sas_group, index + 1), style = type.labelLarge, color = colors.primary)
                        Text(number.toString(), Modifier.fillMaxWidth(), style = digits, textAlign = TextAlign.Center,
                            maxLines = 1, autoSize = digitSize)
                    }
                }
            }
        }
    }
}

@Composable
internal fun spokenCodeGroup(group: Int, number: Int): String =
    stringResource(R.string.sas_group_accessible, group) + ", " + number.toString().toList().joinToString(" ")

@Composable
private fun ComparisonActions(enabled: Boolean, onMatch: () -> Unit, onMismatch: () -> Unit) {
    val padding = PaddingValues(horizontal = 16.dp, vertical = 10.dp)
    FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp), itemVerticalAlignment = Alignment.CenterVertically) {
        OutlinedButton(onMismatch, Modifier.heightIn(min = 48.dp), enabled = enabled, contentPadding = padding) {
            Text(stringResource(R.string.numbers_differ), textAlign = TextAlign.Center)
        }
        Button(onMatch, Modifier.weight(1f).widthIn(min = 152.dp).heightIn(min = 48.dp),
            enabled = enabled, contentPadding = padding) {
            Glyph(R.drawable.ic_check, Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text(stringResource(R.string.verify_match), textAlign = TextAlign.Center)
        }
    }
}
