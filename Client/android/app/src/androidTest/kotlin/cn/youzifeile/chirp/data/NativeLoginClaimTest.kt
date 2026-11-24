package cn.youzifeile.chirp.data

import android.content.ContextWrapper
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class NativeLoginClaimTest {
    private val target = InstrumentationRegistry.getInstrumentation().targetContext
    @get:Rule val files = TemporaryFolder(target.cacheDir)

    @Test fun aPendingLoginCanBeClaimedOnlyOnceAcrossConcurrentAndRestoredCallbacks() = runBlocking {
        val context = object : ContextWrapper(target) {
            override fun getNoBackupFilesDir(): File = files.root
        }
        val origin = "https://auth.example/".toHttpUrl()
        val connection = ServerConnection(origin, origin, origin, null, origin, origin, origin, origin, "main", null)
        val login = NativeLogin.create(connection)
        val vault = IdentityVault(context)
        vault.savePendingLogin(login)
        assertFalse(vault.removePendingLogin("unrelated-state"))
        assertEquals(login, vault.pendingLogin())

        val start = CompletableDeferred<Unit>()
        val claims = List(2) {
            async(Dispatchers.IO) {
                start.await()
                IdentityVault(context).removePendingLogin(login.state)
            }
        }
        start.complete(Unit)
        assertEquals(1, claims.awaitAll().count { it })
        val restored = IdentityVault(context)
        assertNull(restored.pendingLogin())
        assertFalse(restored.removePendingLogin(login.state))
    }
}
