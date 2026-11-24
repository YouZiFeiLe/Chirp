package cn.youzifeile.chirp.ui

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.content.FileProvider
import androidx.lifecycle.viewModelScope
import androidx.test.platform.app.InstrumentationRegistry
import cn.youzifeile.chirp.ChirpApplication
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.*
import java.io.File
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

internal fun snapshotSetupPage(activity: ComponentActivity, name: String, node: SemanticsNodeInteraction) {
    val folder = File(activity.getExternalFilesDir(null), "ui-checks").apply { mkdirs() }
    val image = node.captureToImage().asAndroidBitmap()
    try { File(folder, "$name.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) } }
    finally { image.recycle() }
}

class IdentitySetupUiTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun firstLoginRetriesSavingVerifiesTheFileAndWaitsForFinalConfirmation() {
        val activity = compose.activity
        val fixtureFile = InstrumentationRegistry.getArguments().getString("attachment_fixture")
        assumeTrue("Run scripts/test-android-protocol.py with the isolated fixture", fixtureFile != null)
        val fixture = parseObject(File(activity.getExternalFilesDir(null), fixtureFile!!).readBytes())
        val app = activity.application as ChirpApplication
        val model = compose.runOnUiThread { MainViewModel(app, restoreOnStart = false, networkClock = synchronizedTestClock()) }
        compose.setContent {
            val state by model.state.collectAsState()
            ChirpTheme { IdentitySetupScreen(activity, state, model) }
        }
        val callback = runBlocking {
            val connection = app.server.discover(fixture.text("url"))
            val login = NativeLogin.create(connection)
            val url = login.authorizationURL(connection)
            val body = buildJsonObject { for (key in url.queryParameterNames) put(key, requireNotNull(url.queryParameter(key))) }
            val response = app.http.json(connection.origin.path("test", "native-authorization").request().jsonPost(body).build()).second
            app.identities.savePendingLogin(login)
            response.text("callback")
        }
        compose.runOnUiThread { model.loginCallback(callback) }
        compose.waitUntil(10_000) { model.state.value.setupStep == SetupStep.Create }
        val setup = requireNotNull(model.setup)
        val scope = IdentitySetup.scope(setup.grant.origin, setup.grant.account)
        val original = setup.record
        val directory = File(activity.cacheDir, "android-protocol").apply { mkdirs() }
        val document = File.createTempFile("test-recovery-", ".chirpkey", directory)
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.test-files", document)
        var cancelFirstSave = true
        val monitor = object : Instrumentation.ActivityMonitor() {
            override fun onStartActivity(intent: Intent): Instrumentation.ActivityResult? {
                if (intent.action == Intent.ACTION_CREATE_DOCUMENT) {
                    assertEquals("application/octet-stream", intent.type)
                    assertEquals(setup.filename, intent.getStringExtra(Intent.EXTRA_TITLE))
                    if (cancelFirstSave) {
                        cancelFirstSave = false
                        return Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null)
                    }
                } else if (intent.action != Intent.ACTION_OPEN_DOCUMENT) return null
                return Instrumentation.ActivityResult(Activity.RESULT_OK, Intent().setData(uri))
            }
        }
        val instrument = InstrumentationRegistry.getInstrumentation()
        instrument.addMonitor(monitor)
        fun node(id: Int) = compose.onNodeWithText(activity.getString(id))
        fun click(id: Int) = node(id).performScrollTo().performClick()
        fun awaitStep(step: SetupStep) = compose.waitUntil(15_000) { model.state.value.run { setupStep == step && !checking } }
        try {
            node(R.string.setup_backup_title).assertIsDisplayed()
            snapshotSetupPage(activity, "setup-password", compose.onRoot())
            val create = node(R.string.recovery_create)
            create.assertIsNotEnabled()
            val fields = compose.onAllNodes(hasSetTextAction())
            val passphrase = "一份仅用于测试的离线恢复文件密码 2026"
            fields[0].performTextInput(passphrase)
            fields[0].performImeAction()
            fields[1].assertIsFocused().performTextInput(passphrase.take(3))
            node(R.string.setup_password_mismatch).assertDoesNotExist()
            fields[1].performTextReplacement("mismatch")
            create.assertIsNotEnabled()
            node(R.string.setup_password_mismatch).assertExists()
            fields[1].performTextReplacement(passphrase)
            fields[1].performImeAction()
            node(R.string.create_backup_title).assertIsDisplayed()
            node(R.string.create_backup_confirm).performClick()
            awaitStep(SetupStep.Export)
            compose.waitUntil { !cancelFirstSave }
            click(R.string.recovery_export)
            awaitStep(SetupStep.Saved)
            assertArrayEquals(setup.backupBytes(), document.readBytes())
            node(R.string.backup_saved_title).assertIsDisplayed()
            snapshotSetupPage(activity, "setup-saved", compose.onRoot())
            click(R.string.parity_choose_backup)
            click(R.string.backup_file_check)
            compose.onNode(hasSetTextAction()).performTextInput(passphrase)
            compose.onNode(hasSetTextAction()).performImeAction()
            compose.waitUntil(15_000) { model.state.value.backupVerified && !model.state.value.checking }
            node(R.string.parity_backup_verified).assertExists()
            click(R.string.recovery_continue_setup)
            awaitStep(SetupStep.Confirm)
            node(R.string.setup_keep_file).assertExists()
            node(R.string.setup_keep_password).assertExists()
            snapshotSetupPage(activity, "setup-confirm", compose.onRoot())
            val confirmText = activity.getString(R.string.recovery_confirm)
            compose.waitUntil(8_000) { compose.onAllNodesWithText(confirmText).fetchSemanticsNodes().isNotEmpty() }
            node(R.string.recovery_confirm).assertIsEnabled()
            click(R.string.backup_return_file)
            awaitStep(SetupStep.Saved)
            node(R.string.parity_backup_verified).assertExists()
        } finally {
            instrument.removeMonitor(monitor)
            compose.runOnUiThread { model.cancelAuthorization(); model.viewModelScope.cancel() }
            runBlocking { app.identities.write(scope, wireJson.encodeToString(original)) }
            document.delete()
        }
    }
}
