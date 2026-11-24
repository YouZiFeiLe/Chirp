package cn.youzifeile.chirp.ui

import android.Manifest
import android.os.Build
import androidx.test.platform.app.InstrumentationRegistry
import cn.youzifeile.chirp.ChirpApplication
import cn.youzifeile.chirp.data.*
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.rules.ExternalResource

/** Registers a local device and supplies the fixture login once MainActivity is on its login screen. */
internal class ProductionLoginFixture(private val selectAccount: (JsonObject) -> JsonObject = { fixture ->
    assumeTrue("Requires a real LiveKit server", fixture["production_flow"] is JsonObject)
    fixture.obj("production_flow")
}) : ExternalResource() {
    val app get() = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as ChirpApplication
    lateinit var fixture: JsonObject
        private set
    lateinit var data: JsonObject
        private set
    lateinit var connection: ServerConnection
        private set
    lateinit var login: Login
        private set
    private lateinit var scope: String
    private lateinit var local: LocalDevice
    private var previousConnection: ServerConnection? = null
    private var previousRecord: String? = null

    override fun before() {
        val instrument = InstrumentationRegistry.getInstrumentation()
        val filename = InstrumentationRegistry.getArguments().getString("attachment_fixture")
        assumeTrue("Requires the isolated Go and LiveKit fixture", filename != null)
        fixture = parseObject(File(app.getExternalFilesDir(null), requireNotNull(filename)).readBytes())
        data = selectAccount(fixture)
        assertEquals("The fixture must use this APK's authorization authority", app.authorityKey, fixture.text("authorization_key"))
        instrument.uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 37) instrument.uiAutomation.grantRuntimePermission(app.packageName, ChirpPermission.LocalNetwork.value)
        runBlocking {
            connection = app.server.discover(fixture.text("url"))
            local = LocalDevice(data.text("seed"), data.obj("device").decode<DeviceIdentity>())
            local.validate()
            login = Login(data.text("credential"), data.text("identity"), data.text("name"), data.long("expires_at"), local.device)
            assertEquals(data.text("account_id"), login.memberID)
            scope = IdentitySetup.scope(connection.passkeyOrigin.identityOrigin, login.memberID)
            val previousAddress = app.settings.server()
            previousConnection = app.settings.savedConnection(previousAddress)
            previousRecord = app.identities.read(scope)
            app.identities.write(scope, wireJson.encodeToString(SetupRecord(active = local)))
            app.settings.saveServer(connection)
        }
    }

    fun signIn(model: MainViewModel) = runBlocking {
        val start = withTimeout(15_000) { model.state.first { !it.checking } }
        assertNull(start.account)
        assertEquals(connection, start.connection)
        withContext(Dispatchers.Main) { model.activateSession(SessionRepository(connection, login, app.http), local) }
    }

    override fun after() {
        runBlocking {
            withContext(Dispatchers.Main) { app.calls.leaveAndWait() }
            previousConnection?.let { app.settings.saveServer(it) } ?: app.settings.clearServer()
            app.identities.write(scope, previousRecord ?: wireJson.encodeToString(SetupRecord()))
        }
    }
}
