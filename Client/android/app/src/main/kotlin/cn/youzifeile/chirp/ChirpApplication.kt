package cn.youzifeile.chirp

import android.app.ActivityManager
import android.app.Application
import android.os.Process
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.youzifeile.chirp.data.ChirpHttp
import cn.youzifeile.chirp.data.BiometricLoginVault
import cn.youzifeile.chirp.data.ClientLog
import cn.youzifeile.chirp.data.LocalSettings
import cn.youzifeile.chirp.data.ServerRepository
import cn.youzifeile.chirp.media.CallController
import cn.youzifeile.chirp.media.CallPhase
import cn.youzifeile.chirp.ui.MainViewModel
import cn.youzifeile.chirp.ui.isKnownLocalError
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

class ChirpApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        logs = ClientLog.install(this, ::isKnownLocalError)
        io.livekit.android.LiveKit.loggingLevel = io.livekit.android.util.LoggingLevel.OFF
        io.livekit.android.LiveKit.enableWebRTCLogging = false
        cn.youzifeile.chirp.ui.AppLanguage.initialize(this)
        val controller = calls
        CoroutineScope(Dispatchers.IO).launch {
            cn.youzifeile.chirp.media.RoomAttachments.clearIfIdle(this@ChirpApplication) { controller.state.value.room == null }
        }
    }
    internal lateinit var logs: ClientLog
        private set
    internal val http by lazy { ChirpHttp() }
    internal val server by lazy { ServerRepository(http) }
    internal val settings by lazy { LocalSettings(this) }
    internal val identities by lazy { cn.youzifeile.chirp.data.IdentityVault(this) }
    internal val savedLogin by lazy { BiometricLoginVault(this) }
    internal val authorityKey by lazy {
        try {
            assets.open("AuthorizationTrust.json").use { cn.youzifeile.chirp.data.bundledAuthorizationKey(it.readBytes()) }
        } catch (_: java.io.IOException) {
            throw cn.youzifeile.chirp.data.ChirpException("AUTHORIZATION_TRUST_INVALID")
        }
    }
    internal val calls by lazy { CallController(this) }
    internal val taskCleanup = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    // Android can destroy the Activity while its task and foreground call are still alive.
    private class MainTask(app: ChirpApplication, val id: Int) {
        val store = ViewModelStore()
        val model = ViewModelProvider.create(store, viewModelFactory {
            initializer { MainViewModel(app, taskId = id) }
        })[MainViewModel::class]
    }

    private var mainTask: MainTask? = null

    internal fun modelForTask(id: Int): MainViewModel {
        val previous = mainTask
        if (previous?.id == id) return previous.model
        val next = MainTask(this, id)
        mainTask = next
        if (previous != null) releaseTask(previous)
        return next.model
    }

    internal fun finishRemovedTask() {
        val task = mainTask ?: return
        if (getSystemService(ActivityManager::class.java).appTasks.any { it.taskInfo?.taskId == task.id }) return
        mainTask = null
        releaseTask(task)
    }

    private fun releaseTask(task: MainTask) {
        val signingOut = task.model.endTaskSession()
        task.store.clear()
        taskCleanup.launch {
            // Removing the task releases its room entry. The login may still be resumed.
            withTimeoutOrNull(3_000) {
                calls.state.first { it.phase == CallPhase.Idle }
                signingOut?.join()
            }
            savedLogin.awaitPendingWrites()
            // A fresh task may already be opening while the old call disconnects.
            if (mainTask == null && getSystemService(ActivityManager::class.java).appTasks.isEmpty()) {
                Process.killProcess(Process.myPid())
            }
        }
    }
}
