package cn.youzifeile.chirp.data

import cn.youzifeile.chirp.media.VoiceKeys
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import android.content.Context
import android.database.DatabaseUtils
import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class ClientLogTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val id = UUID.randomUUID().toString()
    private val directory = File(context.noBackupFilesDir, "test-$id")
    private val prefs = context.getSharedPreferences("test-$id", Context.MODE_PRIVATE)
    private val start = 500_000L * ChirpLogStore.HOUR + 30_000
    private val time = AtomicLong(start)
    private lateinit var log: ClientLog

    private fun open() = ClientLog(ChirpLogStore(directory), prefs, setOf("CLIENT_NETWORK_FAILURE"), time::get).also { it.start() }
    @Before fun setup() { log = open() }
    @After fun tearDown() {
        runBlocking { log.clear() }
        log.close()
        check(!directory.exists() || directory.delete())
        context.deleteSharedPreferences("test-$id")
    }

    private suspend fun <T> export(check: (SQLiteDatabase, File) -> T): T {
        val name = requireNotNull(log.prepareExport())
        val file = File.createTempFile("support-", ".chirplog", context.cacheDir)
        try {
            log.finishExport(name) { file.outputStream() }
            return SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY).use { db -> check(db, file) }
        } finally { file.delete() }
    }

    private fun SQLiteDatabase.number(sql: String) = DatabaseUtils.longForQuery(this, sql, null)
    private fun SQLiteDatabase.text(sql: String) = DatabaseUtils.stringForQuery(this, sql, null)

    @Test fun consentPrivacyOrderingAndPortableSnapshot() = runBlocking {
        assertFalse(log.enabled.value)
        log.record(LogEvent.browserLogin)
        assertNull(log.prepareExport())
        assertFalse(directory.exists())
        log.setEnabled(true)
        val beforeStop = log.begin(LogEvent.preflight)
        log.record(LogEvent.phoneLogin, LogOutcome.failed, "PRIVATE_ACCOUNT_123")
        log.record(LogEvent.voiceDecrypt, details = LogDetails.Voice(2, 80_000, 50_000))
        log.record(LogEvent.voiceDecrypt, details = LogDetails.Voice(1, 70_000, 70_000))
        coroutineScope { repeat(4) { launch(Dispatchers.Default) { repeat(90) { log.record(LogEvent.rooms) } } } }
        log.setEnabled(false)
        beforeStop?.finish(ChirpException("PRIVATE_SERVER_TOKEN_123", 403))
        log.record(LogEvent.loginAccepted)
        export { db, file ->
            assertEquals("SQLite format 3\u0000", file.inputStream().use { it.readNBytes(16).decodeToString() })
            assertEquals("ok", db.text("PRAGMA integrity_check"))
            assertEquals(ChirpLogStore.APPLICATION_ID.toLong(), db.number("PRAGMA application_id"))
            assertEquals(1L, db.number("PRAGMA user_version"))
            val tables = db.rawQuery("SELECT name FROM sqlite_master WHERE type='table'", null).use { c ->
                buildSet { while (c.moveToNext()) add(c.getString(0)) }
            }
            assertEquals(LogTable.entries.map { it.name }.toSet(), tables)
            val columns = "time_ms,event,outcome,error_code,duration_us,http_status,details,segment,seq"
            for (table in tables) {
                assertEquals(columns, db.text("SELECT group_concat(name, ',') FROM pragma_table_info('$table')"))
                assertEquals(1L, db.number("SELECT count(*) FROM pragma_index_list('$table') WHERE name='${table}_time'"))
            }
            assertEquals(360L, db.number("SELECT count(*) FROM navigation"))
            assertEquals(0L, db.number("SELECT count(*) FROM network"))
            assertEquals(1L, db.number("SELECT count(*) FROM account"))
            assertEquals("CLIENT_UNKNOWN_SERVER_ERROR", db.text("SELECT error_code FROM account"))
            val all = LogTable.entries.joinToString(" UNION ALL ") { "SELECT seq,segment FROM $it" }
            assertEquals(365L, db.number("SELECT count(DISTINCT seq) FROM ($all)"))
            assertEquals(365L, db.number("SELECT max(seq) FROM ($all)"))
            UUID.fromString(db.text("SELECT segment FROM account"))
            assertEquals(1L, db.number("SELECT count(DISTINCT segment) FROM ($all)"))
            assertEquals(50L, db.number("SELECT sum(json_extract(details,'$.total_ns')) / (1000 * sum(json_extract(details,'$.frames'))) FROM crypto"))
            assertEquals(70L, db.number("SELECT max(json_extract(details,'$.max_ns')) / 1000 FROM crypto"))
            assertFalse(file.readBytes().decodeToString().contains("PRIVATE_"))
        }
        log.setEnabled(true)
        val inFlight = log.begin(LogEvent.admit)
        val stale = requireNotNull(log.prepareExport())
        log.clear()
        log.clear()
        assertTrue(log.enabled.value)
        inFlight?.finish()
        assertNull(log.prepareExport())
        assertTrue(runCatching { log.finishExport(stale) { error("stale snapshot") } }.isFailure)
        log.record(LogEvent.browserLogin)
        export { db, _ ->
            assertEquals(1L, db.number("SELECT seq FROM account"))
            assertEquals(0L, db.number("SELECT count(*) FROM network"))
        }
    }

    @Test fun exactHourlyRetentionEvenAfterDisabledRestart() = runBlocking {
        time.set(start - ChirpLogStore.HOUR)
        log.setEnabled(true)
        log.record(LogEvent.login)
        time.set(start - 1)
        log.record(LogEvent.friends)
        time.set(start)
        log.record(LogEvent.settings)
        time.set(start + 100)
        log.setEnabled(false)
        export { _, _ -> Unit }
        val old = File(directory, "${Math.floorDiv(start, ChirpLogStore.HOUR) - 1}.chirplog")
        assertTrue(old.exists())
        val interrupted = File(directory, "export-interrupted.chirplog").apply { writeText("test") }
        log.close()
        time.set(start + ChirpLogStore.RETENTION)
        log = open()
        assertFalse(log.enabled.value)
        kotlinx.coroutines.withTimeout(5_000) {
            while (old.exists() || interrupted.exists()) kotlinx.coroutines.delay(10)
        }
        export { db, _ ->
            assertEquals("settings", db.text("SELECT event FROM navigation"))
            assertEquals(1L, db.number("SELECT count(*) FROM navigation"))
        }
        assertFalse(old.exists())
        assertFalse(interrupted.exists())
        time.addAndGet(101)
        assertNull(log.prepareExport())
        assertTrue(directory.listFiles().orEmpty().isEmpty())
    }

    @Test fun networkUsesOnlyNamedOperationsStatusAndAllowlistedFailures() = runBlocking {
        log.setEnabled(true)
        var code = "PRIVATE_SERVER_TEXT"
        val http = ChirpHttp(OkHttpClient.Builder().addInterceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(403).message("PRIVATE_REASON")
                .body("""{"error":{"code":"$code"}}""".toResponseBody("application/json".toMediaType())).build()
        }, log)
        for (response in listOf("PRIVATE_SERVER_TEXT", "private prose", "CLIENT_NETWORK_FAILURE")) {
            code = response
            val request = Request.Builder().url("https://private-host.test/private-account")
                .header("Authorization", "Bearer PRIVATE_TOKEN").build()
            assertTrue(runCatching { http.json(request, operation = LogEvent.preflight) }.isFailure)
        }
        export { db, file ->
            assertEquals(3L, db.number("SELECT count(*) FROM network WHERE event='preflight' AND outcome='failed' " +
                "AND duration_us>=0 AND http_status=403 AND details IS NULL"))
            assertEquals(2L, db.number("SELECT count(*) FROM network WHERE error_code='CLIENT_UNKNOWN_SERVER_ERROR'"))
            assertEquals(1L, db.number("SELECT count(*) FROM network WHERE error_code='CLIENT_NETWORK_FAILURE'"))
            assertFalse(file.readBytes().decodeToString().contains("private", ignoreCase = true))
        }
    }

    @Test fun onlyFreshAuthorizedVoiceFramesFromTheCurrentConsentWindowAreCounted() = runBlocking {
        val material = ByteArray(32) { it.toByte() }
        val first = "f8b1da3285d1b49a75b87464a233efe1f25c700000000000000000000000010c00".hexToByteArray()
        val second = "f87c624d442c7488134062139d879cdcc467950000000000000000000000020c00".hexToByteArray()
        var allowed = true
        val keys = VoiceKeys({ allowed }, { 0L }, log)
        keys.install("PRIVATE_SENDER", 0, material)
        keys.activate(0)
        log.setEnabled(true)
        assertNotNull(keys.open("PRIVATE_SENDER", first))
        log.clear()
        assertNull(keys.open("PRIVATE_SENDER", first))
        assertNull(keys.open("PRIVATE_SENDER", second.copyOf().apply { this[0] = 0 }))
        allowed = false
        assertNull(keys.open("PRIVATE_SENDER", second))
        keys.flushTiming()
        assertNull(log.prepareExport())
        allowed = true
        assertNotNull(keys.open("PRIVATE_SENDER", second))
        keys.flushTiming()
        export { db, file ->
            assertEquals(1L, db.number("SELECT json_extract(details,'$.frames') FROM crypto"))
            val nanos = db.number("SELECT json_extract(details,'$.total_ns') FROM crypto")
            assertTrue(nanos > 0)
            assertEquals(nanos, db.number("SELECT json_extract(details,'$.max_ns') FROM crypto"))
            assertFalse(file.readBytes().decodeToString().contains("PRIVATE_SENDER"))
        }
    }

    @Test fun diskFailureHasBoundedBacklogAndReportsExactlyHowManyRowsWereDropped() = runBlocking {
        log.prepareExport() // Wait for startup maintenance.
        directory.writeText("unavailable")
        try {
            log.setEnabled(true)
            repeat(4096) { log.record(LogEvent.rooms) }
            assertTrue(runCatching { log.prepareExport() }.isFailure)
        } finally { check(directory.delete()) }
        export { db, _ ->
            val dropped = db.number("SELECT sum(json_extract(details,'$.count')) FROM application WHERE event='storageOverflow'")
            assertTrue(dropped > 0)
            assertEquals(4097L, dropped + db.number("SELECT count(*) FROM navigation") +
                db.number("SELECT count(*) FROM settings WHERE event='recordingEnabled'"))
        }
    }

    @Test fun snapshotExcludesFutureRowsAndRejectsForeignFiles() = runBlocking {
        log.setEnabled(true)
        log.record(LogEvent.profile)
        time.incrementAndGet()
        log.record(LogEvent.friends)
        time.decrementAndGet()
        export { db, _ -> assertEquals("profile", db.text("SELECT group_concat(event) FROM navigation")) }
        val shard = directory.listFiles()!!.single { it.nameWithoutExtension.toLongOrNull() != null }
        SQLiteDatabase.openDatabase(shard.path, null, SQLiteDatabase.OPEN_READWRITE).use { it.execSQL("PRAGMA user_version=2") }
        assertTrue(runCatching { log.prepareExport() }.isFailure)
        assertFalse(directory.listFiles().orEmpty().any { it.name.startsWith("export-") })
    }
}
