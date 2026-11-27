package cn.youzifeile.chirp

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.res.Configuration
import android.app.LocaleManager
import android.content.Intent
import android.os.Bundle
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.net.toUri
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import cn.youzifeile.chirp.ui.ChirpApp
import cn.youzifeile.chirp.ui.ChirpTheme
import cn.youzifeile.chirp.ui.authenticateLogin
import cn.youzifeile.chirp.ui.MainViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private var callback by mutableStateOf<String?>(null)
    internal lateinit var model: MainViewModel
        private set
    private lateinit var taskPreview: TaskPreview

    override fun onStart() {
        super.onStart()
        (application as ChirpApplication).logs.foreground()
    }

    override fun onResume() {
        super.onResume()
        model.enterForeground(hasWindowFocus()) { cipher -> authenticateLogin(this, cipher) }
        taskPreview.update()
    }

    override fun onPause() {
        model.leaveForeground()
        super.onPause()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        taskPreview.update()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        model.cancelUnlock()
    }

    override fun onStop() {
        (application as ChirpApplication).logs.background()
        super.onStop()
    }

    override fun onDestroy() {
        taskPreview.close()
        super.onDestroy()
        if (isFinishing) (application as ChirpApplication).finishRemovedTask()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == Intent.ACTION_VIEW) callback = intent.dataString
    }

    override fun attachBaseContext(newBase: Context) {
        // On a fresh install ActivityThread may have prepared this activity before the application selected its language.
        val locales = newBase.getSystemService(LocaleManager::class.java).applicationLocales
        val base = if (!locales.isEmpty && locales[0] != newBase.resources.configuration.locales[0]) {
            newBase.createConfigurationContext(Configuration().apply { setLocales(locales) })
        } else newBase
        super.attachBaseContext(base)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setRecentsScreenshotEnabled(false)
        model = (application as ChirpApplication).modelForTask(taskId)
        taskPreview = TaskPreview(window.decorView, model::windowFocusChanged)
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.RESUMED) {
                while (isActive) {
                    model.checkClock()
                    delay(2_000)
                }
            }
        }
        if (intent.action == Intent.ACTION_VIEW) callback = intent.dataString
        enableEdgeToEdge()
        setContent {
            LaunchedEffect(callback) {
                val uri = callback ?: return@LaunchedEffect
                model.loginCallback(uri)
                callback = null
                if (intent.dataString == uri) setIntent(Intent(intent).setData(null))
            }
            val state by model.state.collectAsStateWithLifecycle()
            val call by model.calls.state.collectAsStateWithLifecycle()
            LaunchedEffect(state.browser) {
                val target = state.browser ?: return@LaunchedEffect
                if (state.authorizing && !model.clockReady()) return@LaunchedEffect
                val launched = try {
                    CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(this@MainActivity, target.toUri())
                    true
                } catch (_: ActivityNotFoundException) {
                    false
                } catch (_: SecurityException) {
                    false
                }
                model.browserOpened(launched)
            }
            ChirpTheme { ChirpApp(this@MainActivity, state, call, model) }
        }
    }
}
