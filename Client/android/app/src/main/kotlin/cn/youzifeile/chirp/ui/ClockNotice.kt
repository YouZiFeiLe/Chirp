package cn.youzifeile.chirp.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.Settings
import android.widget.Toast
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.ClockReading
import cn.youzifeile.chirp.data.ClockStatus
import kotlin.math.abs

@Composable
internal fun ClockNotice(reading: ClockReading, onRetry: () -> Unit) {
    val message = when (reading.status) {
        ClockStatus.Ready -> return
        ClockStatus.Checking -> stringResource(R.string.clock_checking)
        ClockStatus.Unavailable -> stringResource(R.string.clock_unavailable)
        ClockStatus.OutOfSync -> stringResource(
            if (reading.offsetMillis > 0) R.string.clock_ahead else R.string.clock_behind,
            abs(reading.offsetMillis / 1000.0))
    }
    val context = LocalContext.current
    Column {
        Notice(message, Modifier.semantics { liveRegion = LiveRegionMode.Polite }, isError = reading.status != ClockStatus.Checking)
        if (reading.status != ClockStatus.Checking) FlowRow {
            if (reading.status == ClockStatus.OutOfSync) TextButton(onClick = {
                try {
                    context.startActivity(Intent(Settings.ACTION_DATE_SETTINGS))
                } catch (_: ActivityNotFoundException) {
                    Toast.makeText(context, R.string.clock_settings_help, Toast.LENGTH_LONG).show()
                } catch (_: SecurityException) {
                    Toast.makeText(context, R.string.clock_settings_help, Toast.LENGTH_LONG).show()
                }
            }) { Text(stringResource(R.string.clock_settings)) }
            TextButton(onRetry, enabled = reading.canRetry) { Text(stringResource(R.string.clock_retry)) }
        }
    }
}
