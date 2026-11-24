package cn.youzifeile.chirp.ui

import cn.youzifeile.chirp.data.LogEvent
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

@Composable
internal fun IdentityFlowHeading(context: String, @DrawableRes icon: Int, @StringRes title: Int,
    @StringRes detail: Int, stage: Int? = null) {
    val colors = MaterialTheme.colorScheme
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Glyph(icon, Modifier.size(18.dp), tint = colors.primary)
            Text(context, Modifier.weight(1f), style = MaterialTheme.typography.labelLarge, color = colors.onSurfaceVariant)
            if (stage != null) Text(stringResource(R.string.setup_step_count, stage), style = MaterialTheme.typography.labelLarge,
                color = colors.primary)
        }
        if (stage != null) Row(Modifier.fillMaxWidth().padding(bottom = 4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            for (index in 1..3) Spacer(Modifier.weight(1f).height(4.dp).background(
                if (index <= stage) colors.primary else colors.surfaceContainerHighest, MaterialTheme.shapes.small))
        }
        Text(stringResource(title), Modifier.semantics { heading() }, style = MaterialTheme.typography.headlineMedium)
        Text(stringResource(detail), style = MaterialTheme.typography.bodyLarge, color = colors.onSurfaceVariant)
    }
}

@Composable
internal fun IdentityActionButton(label: String, @DrawableRes icon: Int, enabled: Boolean = true, onClick: () -> Unit) {
    Button(onClick, Modifier.fillMaxWidth().heightIn(min = 52.dp), enabled = enabled) {
        Glyph(icon, Modifier.size(20.dp))
        Spacer(Modifier.width(8.dp))
        Text(label)
    }
}

@Composable
internal fun IdentitySetupScreen(activity: ComponentActivity, state: MainState, model: MainViewModel) {
    val setup = model.setup ?: return
    val step = state.setupStep ?: return
    val setupId = remember(setup) { digest(setup.grant.token.encodeToByteArray()) }
    var exportFor by rememberSaveable { mutableStateOf<String?>(null) }
    var importFor by rememberSaveable { mutableStateOf<String?>(null) }
    var importFile by rememberSaveable(setupId, step) { mutableStateOf<Uri?>(null) }
    var inspectPassword by rememberSaveable(setupId, step) { mutableStateOf(false) }
    var verifySelection by rememberSaveable(setupId, step) { mutableStateOf(false) }
    var saveOnCreate by rememberSaveable(setupId) { mutableStateOf(false) }
    val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        if (uri != null && exportFor == setupId && model.setup === setup) model.exportBackup(uri, setup)
        exportFor = null
    }
    fun exportFile() {
        exportFor = setupId
        save.launch(setup.filename)
    }
    LaunchedEffect(setup, step, state.checking) {
        if (saveOnCreate && !state.checking) {
            saveOnCreate = false
            if (step == SetupStep.Export) exportFile()
        }
    }
    val importKey = "$setupId/${step.name}"
    val open = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null && importFor == importKey && model.setup === setup) {
            importFile = uri
            inspectPassword = false
            verifySelection = false
            model.clearError()
        }
        importFor = null
    }
    fun chooseFile() {
        LogEvent.chooseRecoveryFile.record()
        importFor = importKey
        open.launch(arrayOf("*/*"))
    }
    LaunchedEffect(state.backupVerified, state.checking) {
        if (verifySelection && state.backupVerified && !state.checking) {
            importFile = null
            inspectPassword = false
            verifySelection = false
        }
    }
    fun back() {
        if (state.checking) return
        when {
            inspectPassword -> { inspectPassword = false; model.clearError() }
            importFile != null -> { importFile = null; model.clearError() }
            step == SetupStep.Confirm -> model.setupAction { it.backToSave() }
            else -> model.cancelAuthorization()
        }
    }
    BackHandler(onBack = ::back)
    key(setupId, step, importFile, inspectPassword) {
        SettingsPage(stringResource(R.string.identity_setup), ::back) {
            val enabled = !state.checking && state.clock.ready
            val uri = importFile
            val stage = when (step) {
                SetupStep.Create -> 1
                SetupStep.Saved, SetupStep.Export -> 2
                SetupStep.Confirm -> 3
                else -> null
            }
            val paired = step == SetupStep.Activate && setup.record.pairingSeed != null &&
                setup.record.candidate?.seed == setup.record.pairingSeed
            val (title, description) = when {
                uri != null && inspectPassword -> R.string.unlock_backup to R.string.backup_decrypt_help
                uri != null -> R.string.setup_selected_file to R.string.backup_file_next
                else -> when (step) {
                    SetupStep.Create -> R.string.setup_backup_title to R.string.recovery_create_help
                    SetupStep.Resume -> R.string.setup_resume_title to R.string.parity_resume_detail
                    SetupStep.Export -> R.string.setup_save_title to R.string.backup_ready
                    SetupStep.Saved -> R.string.backup_saved_title to R.string.backup_readback_help
                    SetupStep.Confirm -> R.string.setup_final_title to R.string.recovery_confirm_help
                    SetupStep.Restore -> R.string.setup_authorize_device to R.string.recovery_restore_hint
                    SetupStep.Activate -> (if (paired) R.string.pairing_authenticated else R.string.setup_activate_title) to R.string.setup_activate_detail
                }
            }
            IdentityFlowHeading(state.setupAccount, R.drawable.ic_account, title, description, stage)
            ClockNotice(state.clock) { model.checkClock(manual = true) }
            if (state.checking) LinearProgressIndicator(Modifier.fillMaxWidth())
            state.error?.let { ErrorNote(it) }
            if (state.error?.code == "IDENTITY_CONFLICT" && setup.record.candidate != null)
                Notice(stringResource(R.string.recovery_identity_conflict))
            if (uri != null) {
                val filename by produceState<String?>(null, uri) {
                    value = withContext(Dispatchers.IO) {
                        try {
                            activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                                if (it.moveToFirst()) it.getString(0) else null
                            }
                        } catch (_: RuntimeException) { null }
                    }
                }
                BackupFileSummary(filename)
                if (inspectPassword) {
                    UnlockBackupForm(enabled, if (step == SetupStep.Saved) R.string.parity_verify_backup else R.string.backup_decrypt) { password ->
                        verifySelection = step == SetupStep.Saved
                        model.recover(uri, password, verifyOnly = verifySelection)
                    }
                } else IdentityActionButton(stringResource(if (step == SetupStep.Saved) R.string.backup_file_check else R.string.backup_file_use),
                    R.drawable.ic_key, enabled) { inspectPassword = true }
                TextButton(::chooseFile, enabled = enabled) { Text(stringResource(R.string.backup_reselect)) }
                return@SettingsPage
            }
            when (step) {
                SetupStep.Create -> CreateBackupForm(enabled) { password, repeated ->
                    saveOnCreate = true
                    model.setupAction { it.create(password, repeated) }
                }
                SetupStep.Resume -> UnlockBackupForm(enabled, R.string.parity_resume_backup) { password ->
                    model.setupAction { it.resume(password) }
                }
                SetupStep.Export -> {
                    BackupFileSummary(setup.filename)
                    IdentityActionButton(stringResource(R.string.recovery_export), R.drawable.ic_attach, enabled, ::exportFile)
                }
                SetupStep.Saved -> {
                    if (state.backupVerified) Note(R.drawable.ic_check, stringResource(R.string.parity_backup_verified),
                        Modifier.semantics { liveRegion = LiveRegionMode.Polite }, color = MaterialTheme.colorScheme.primary)
                    IdentityActionButton(stringResource(R.string.recovery_continue_setup), R.drawable.ic_chevron, enabled) {
                        model.setupAction { it.showConfirmation() }
                    }
                    SettingsGroup {
                        SettingRow(R.drawable.ic_key, stringResource(R.string.parity_choose_backup), onClick = ::chooseFile, enabled = enabled)
                        SettingsDivider()
                        SettingRow(R.drawable.ic_attach, stringResource(R.string.backup_save_another), onClick = ::exportFile, enabled = enabled)
                    }
                }
                SetupStep.Confirm -> ConfirmBackup(activity, setup, enabled, ::back) { model.setupAction { it.confirmBackup() } }
                SetupStep.Restore, SetupStep.Activate -> {
                    if (step == SetupStep.Activate) {
                        if (state.checking) Note(R.drawable.ic_lock, stringResource(R.string.pairing_finishing_login))
                        else IdentityActionButton(stringResource(if (paired) R.string.pairing_retry_login else R.string.activate_device),
                            R.drawable.ic_check, enabled) { model.setupAction {} }
                    }
                    if (setup.grant.root.isNotEmpty()) {
                        IdentityActionButton(stringResource(R.string.pair_new), R.drawable.ic_qr, enabled && state.setupPairing == null) {
                            model.newPairing(setup)
                        }
                        SettingsGroup {
                            SettingRow(R.drawable.ic_attach, stringResource(R.string.recovery_import),
                                stringResource(R.string.backup_choose_help), onClick = ::chooseFile, enabled = enabled)
                        }
                    }
                }
            }
        }
    }
    state.setupPairing?.let { session ->
        key(session) {
            PairingDialog(activity, session, false, { if (model.state.value.setupPairing === session) model.closeSetupPairing() }) { approved ->
                if (model.setup === setup && model.state.value.setupPairing === session) {
                    model.closeSetupPairing()
                    model.setupAction { it.paired(approved) }
                }
            }
        }
    }
}

@Composable
private fun BackupFileSummary(name: String?) {
    SettingsGroup {
        val kind = stringResource(R.string.backup_file_kind)
        if (name.isNullOrBlank()) SettingRow(R.drawable.ic_attach, kind)
        else SettingRow(R.drawable.ic_attach, name, kind)
    }
}

@Composable
private fun UnlockBackupForm(enabled: Boolean, @StringRes action: Int, unlock: (String) -> Unit) {
    var password by remember { mutableStateOf("") }
    val focus = LocalFocusManager.current
    val submit = { if (enabled && password.isNotEmpty()) { focus.clearFocus(); unlock(password) } }
    PasswordField(password, { password = it }, R.string.recovery_password, enabled = enabled, onDone = submit)
    IdentityActionButton(stringResource(action), R.drawable.ic_key, enabled && password.isNotEmpty(), submit)
}

@Composable
internal fun CreateBackupForm(enabled: Boolean, create: (String, String) -> Unit) {
    var password by remember { mutableStateOf("") }
    var repeated by remember { mutableStateOf("") }
    var ask by remember { mutableStateOf(false) }
    var finishedTyping by remember { mutableStateOf(false) }
    val valid = validRecoveryPassword(password)
    val matches = repeated.isNotEmpty() && repeated == password
    val mismatch = repeated.isNotEmpty() && !matches && (finishedTyping || !password.startsWith(repeated))
    val ready = enabled && valid && matches
    val focus = LocalFocusManager.current
    val repeatFocus = remember { FocusRequester() }
    val reviewPassword = { if (ready) { focus.clearFocus(); ask = true } }
    SettingsGroup(inset = true) {
        PasswordField(password, { password = it }, R.string.recovery_password, enabled = enabled, imeAction = ImeAction.Next,
            modifier = Modifier.focusProperties { next = repeatFocus },
            supportingText = { Text(stringResource(if (valid) R.string.backup_length_ok else R.string.backup_length_hint),
                color = if (valid) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant) })
        PasswordField(repeated, { repeated = it; finishedTyping = false }, R.string.recovery_repeat, enabled = enabled,
            onDone = { finishedTyping = true; reviewPassword() },
            modifier = Modifier.focusRequester(repeatFocus),
            isError = mismatch, supportingText = {
                Text(stringResource(when {
                    matches -> R.string.backup_match_ok
                    mismatch -> R.string.setup_password_mismatch
                    else -> R.string.backup_match_hint
                }))
            })
    }
    Note(R.drawable.ic_lock, stringResource(R.string.setup_password_manager))
    IdentityActionButton(stringResource(R.string.recovery_create), R.drawable.ic_key, ready, reviewPassword)
    if (ask) ChirpDialog(icon = R.drawable.ic_key, onDismissRequest = { ask = false },
        title = { Text(stringResource(R.string.create_backup_title)) }, text = { Text(stringResource(R.string.create_backup_detail)) },
        confirmButton = { Button({ ask = false; create(password, repeated) }, enabled = ready) { Text(stringResource(R.string.create_backup_confirm)) } },
        dismissButton = { TextButton({ ask = false }) { Text(stringResource(R.string.create_backup_back)) } })
}

@Composable
private fun ConfirmBackup(activity: ComponentActivity, setup: IdentitySetup, enabled: Boolean, back: () -> Unit, confirm: () -> Unit) {
    var seconds by remember(setup) { mutableIntStateOf(setup.confirmationSeconds()) }
    LaunchedEffect(setup, activity) {
        activity.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            setup.setConfirmationVisible(true)
            try {
                do { seconds = setup.confirmationSeconds(); if (seconds > 0) delay(200) } while (seconds > 0)
            } finally { setup.setConfirmationVisible(false) }
        }
    }
    SettingsGroup {
        SettingRow(R.drawable.ic_attach, stringResource(R.string.setup_keep_file), stringResource(R.string.setup_keep_file_detail))
        SettingsDivider()
        SettingRow(R.drawable.ic_lock, stringResource(R.string.setup_keep_password), stringResource(R.string.setup_keep_password_detail))
    }
    SettingsGroup {
        SettingsDisclosure(R.drawable.ic_key, stringResource(R.string.backup_risk_title), null) {
            SettingsDescription(stringResource(R.string.setup_backup_scope))
        }
    }
    IdentityActionButton(if (seconds == 0) stringResource(R.string.recovery_confirm) else stringResource(R.string.recovery_wait, seconds),
        R.drawable.ic_check, enabled && seconds == 0, confirm)
    TextButton(back, enabled = enabled) { Text(stringResource(R.string.backup_return_file)) }
}
