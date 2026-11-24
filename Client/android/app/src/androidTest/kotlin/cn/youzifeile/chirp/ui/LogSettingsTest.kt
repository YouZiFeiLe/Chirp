package cn.youzifeile.chirp.ui

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.database.DatabaseUtils
import android.database.sqlite.SQLiteDatabase
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.content.FileProvider
import androidx.test.platform.app.InstrumentationRegistry
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.ChirpLogStore
import cn.youzifeile.chirp.data.ClientLog
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class LogSettingsTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun exportThroughDocumentPickerAndClearWhileStopped() {
        val activity = compose.activity
        val id = UUID.randomUUID().toString()
        val directory = File(activity.noBackupFilesDir, "log-ui-$id")
        val logs = ClientLog(ChirpLogStore(directory), activity.getSharedPreferences(id, Context.MODE_PRIVATE), emptySet())
        val providerDir = File(activity.cacheDir, "android-protocol").apply { mkdirs() }
        val document = File.createTempFile("export-", ".chirplog", providerDir)
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.test-files", document)
        var picks = 0
        val monitor = object : Instrumentation.ActivityMonitor() {
            override fun onStartActivity(intent: Intent): Instrumentation.ActivityResult? {
                if (intent.action != Intent.ACTION_CREATE_DOCUMENT) return null
                assertTrue(intent.getStringExtra(Intent.EXTRA_TITLE)!!.endsWith(".chirplog"))
                return if (++picks == 1) Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null)
                else Instrumentation.ActivityResult(Activity.RESULT_OK, Intent().setData(uri))
            }
        }
        val instrument = InstrumentationRegistry.getInstrumentation()
        instrument.addMonitor(monitor)
        fun label(resource: Int) = activity.getString(resource)
        fun button(resource: Int) = compose.onNode(hasText(label(resource)) and hasClickAction())
        fun notice(resource: Int) = compose.waitUntil(5_000) { compose.onAllNodesWithText(label(resource)).fetchSemanticsNodes().isNotEmpty() }
        try {
            logs.start()
            compose.setContent { ChirpTheme { LogSettings(activity, logs) {} } }
            button(R.string.log_recording).assertIsOff()
            button(R.string.export_logs).performScrollTo().performClick()
            notice(R.string.logs_empty)
            assertEquals(0, picks)
            button(R.string.log_recording).performScrollTo().performClick().assertIsOn()
            button(R.string.log_recording).performClick().assertIsOff()
            button(R.string.export_logs).performScrollTo().performClick()
            compose.waitUntil(5_000) { picks == 1 && directory.listFiles().orEmpty().none { it.name.startsWith("export-") } }
            button(R.string.export_logs).performClick()
            notice(R.string.logs_exported)
            SQLiteDatabase.openDatabase(document.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
                assertEquals(2L, DatabaseUtils.longForQuery(db, "SELECT count(*) FROM settings", null))
                assertEquals("ok", DatabaseUtils.stringForQuery(db, "PRAGMA integrity_check", null))
            }
            button(R.string.clear_logs).performScrollTo().performClick()
            compose.onNode(hasText(label(R.string.clear_logs)) and hasClickAction() and hasAnyAncestor(isDialog())).performClick()
            notice(R.string.logs_cleared)
            button(R.string.log_recording).assertIsOff()
            button(R.string.export_logs).performClick()
            notice(R.string.logs_empty)
            assertTrue(document.length() > 0)
        } finally {
            instrument.removeMonitor(monitor)
            runBlocking { logs.clear() }
            logs.close()
            directory.delete()
            document.delete()
            activity.deleteSharedPreferences(id)
        }
    }
}
