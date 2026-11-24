package cn.youzifeile.chirp.ui

import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import cn.youzifeile.chirp.ChirpApplication
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.ClientLog
import cn.youzifeile.chirp.data.LogDetails
import cn.youzifeile.chirp.data.LogEvent
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
internal fun LogScreen(event: LogEvent, key: Any? = Unit) {
    DisposableEffect(event, key) {
        val log = ClientLog.current
        val generation = log?.generation ?: 0
        if (generation != 0L) log?.record(event, details = LogDetails.Screen(true), expected = generation)
        onDispose {
            if (generation != 0L) log?.record(event, details = LogDetails.Screen(false), expected = generation)
        }
    }
}

@Composable
internal fun LogSettingsRow(open: () -> Unit) {
    SettingRow(R.drawable.ic_notice, stringResource(R.string.log_management), stringResource(R.string.log_management_detail), open)
}

@Composable
internal fun LogSettings(activity: ComponentActivity, logs: ClientLog = (activity.application as ChirpApplication).logs, back: () -> Unit) {
    LogScreen(LogEvent.logSettings)
    val enabled by logs.enabled.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var snapshot by rememberSaveable { mutableStateOf<String?>(null) }
    DisposableEffect(activity, logs) {
        onDispose { if (!activity.isChangingConfigurations) snapshot?.let(logs::abandonExport) }
    }
    var busy by remember { mutableStateOf(false) }
    var confirm by rememberSaveable { mutableStateOf(false) }
    var notice by rememberSaveable { mutableStateOf<Int?>(null) }
    val create = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val name = snapshot ?: return@rememberLauncherForActivityResult
        busy = true
        scope.launch {
            try {
                logs.finishExport(name, uri?.let { { activity.contentResolver.openOutputStream(it, "wt") ?: throw IOException() } })
                notice = if (uri != null) R.string.logs_exported else null
            } catch (e: CancellationException) { throw e }
            catch (_: Exception) { notice = R.string.logs_export_failed }
            finally { snapshot = null; busy = false }
        }
    }
    SettingsPage(stringResource(R.string.log_management), back) {
        SettingsGroup(inset = true) {
            AudioToggle(stringResource(R.string.log_recording), enabled, logs::setEnabled)
            SettingsDescription(stringResource(R.string.log_retention))
        }
        SettingsGroup {
            SettingRow(R.drawable.ic_attach, stringResource(R.string.export_logs), stringResource(R.string.log_export_detail),
                enabled = !busy && snapshot == null, onClick = {
                    busy = true
                    notice = null
                    scope.launch {
                        try {
                            val name = withContext(NonCancellable) { logs.prepareExport() }
                            if (name == null) notice = R.string.logs_empty else {
                                try {
                                    ensureActive()
                                    snapshot = name
                                    create.launch("Chirp-Android.chirplog")
                                } catch (e: Exception) {
                                    snapshot = null
                                    withContext(NonCancellable) { logs.finishExport(name, null) }
                                    throw e
                                }
                            }
                        } catch (e: CancellationException) { throw e }
                        catch (_: Exception) { notice = R.string.logs_export_failed }
                        finally { busy = false }
                    }
                })
            SettingsDivider()
            SettingRow(R.drawable.ic_close, stringResource(R.string.clear_logs), onClick = { confirm = true },
                enabled = !busy && snapshot == null, destructive = true)
        }
        notice?.let { Text(stringResource(it)) }
    }
    if (confirm) ConfirmDestructiveAction(R.string.clear_logs, stringResource(R.string.clear_logs_confirm), R.string.clear_logs,
        close = { confirm = false }, action = {
            busy = true
            scope.launch {
                try { logs.clear(); notice = R.string.logs_cleared }
                catch (e: CancellationException) { throw e }
                catch (_: Exception) { notice = R.string.logs_clear_failed }
                finally { busy = false }
            }
        })
}
