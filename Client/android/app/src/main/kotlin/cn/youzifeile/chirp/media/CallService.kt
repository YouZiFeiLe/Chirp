package cn.youzifeile.chirp.media

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.IBinder
import android.telecom.DisconnectCause
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.app.ServiceCompat
import androidx.core.telecom.CallAttributesCompat
import androidx.core.telecom.CallControlResult
import androidx.core.telecom.CallControlScope
import androidx.core.telecom.CallEndpointCompat
import androidx.core.telecom.CallsManager
import cn.youzifeile.chirp.ChirpApplication
import cn.youzifeile.chirp.MainActivity
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.ClientFailure
import cn.youzifeile.chirp.data.clientFailure
import cn.youzifeile.chirp.data.ChirpException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

class CallService : Service() {
    private val jobs = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val calls get() = (application as ChirpApplication).calls
    private var control: CallControlScope? = null
    private var routeJob: Job? = null
    private var worker: Job? = null
    private var currentEntry: String? = null
    private var latestStartId = 0
    private var foreground = false
    private var remoteEnd = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        latestStartId = startId
        if (intent?.action == HANG_UP) {
            calls.leaveEntry(intent.identifier)
            if (worker == null) stopSelfResult(startId)
            return START_NOT_STICKY
        }
        val join = calls.claim(this, intent?.identifier)
        if (join == null) {
            if (worker == null) stopSelfResult(startId)
            return START_NOT_STICKY
        }
        currentEntry = join.admission.entryID
        remoteEnd = false
        val job = jobs.launch(start = CoroutineStart.LAZY) {
            var error: ClientFailure? = null
            try {
                openCall(join)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = e.clientFailure("CALL_SERVICE_UNAVAILABLE")
            } finally {
                foreground = false
                ServiceCompat.stopForeground(this@CallService, ServiceCompat.STOP_FOREGROUND_REMOVE)
                routeJob?.cancel()
                routeJob = null
                calls.finish(join, error)
                worker = null
                currentEntry = null
                stopSelfResult(latestStartId)
            }
        }
        worker = job
        calls.bind(job)
        job.start()
        return START_NOT_STICKY
    }

    private suspend fun openCall(join: JoinRequest): Unit = coroutineScope {
        val manager = CallsManager(applicationContext)
        manager.registerAppWithTelecom(CallsManager.CAPABILITY_BASELINE)
        val attributes = CallAttributesCompat(
            getString(R.string.app_name),
            Uri.fromParts("chirp", join.room.id, null),
            CallAttributesCompat.DIRECTION_OUTGOING,
            callCapabilities = CallAttributesCompat.SUPPORTS_SET_INACTIVE,
            isLogExcluded = true,
        )
        val opened = CompletableDeferred<CallControlScope>()
        val telecom = launch {
            manager.addCall(
                attributes,
                onAnswer = {},
                onDisconnect = {
                    withContext(Dispatchers.Main.immediate) {
                        if (currentEntry == join.admission.entryID) {
                            remoteEnd = true
                            calls.leaveEntry(join.admission.entryID)
                        }
                    }
                },
                onSetActive = { withContext(Dispatchers.Main.immediate) {
                    if (currentEntry == join.admission.entryID) calls.setHeld(false)
                } },
                onSetInactive = { withContext(Dispatchers.Main.immediate) {
                    if (currentEntry == join.admission.entryID) calls.setHeld(true)
                } },
            ) { opened.complete(this) }
            // Telecom owns the call lifetime. A closed system session must not leave MLS running.
            if (!opened.isCompleted) throw ChirpException("CALL_SERVICE_UNAVAILABLE")
            if (control != null) calls.leaveEntry(join.admission.entryID)
        }
        try {
            val active = opened.await()
            control = active
            startCallForeground(microphone = false)
            foreground = true
            if (active.setActive() !is CallControlResult.Success) throw ChirpException("CALL_SERVICE_UNAVAILABLE")
            launch { active.availableEndpoints.collect(calls::setEndpoints) }
            launch { active.currentCallEndpoint.collect(calls::setEndpoint) }
            launch { active.isMuted.collect(calls::setSystemMute) }
            calls.run(join)
        } finally {
            val active = control
            control = null
            withContext(NonCancellable) {
                if (active != null && !remoteEnd) withTimeoutOrNull(2_000) {
                    runCatching { active.disconnect(DisconnectCause(DisconnectCause.LOCAL)) }
                }
                telecom.cancel()
            }
        }
    }

    internal fun resumeHeldCall() {
        val active = control ?: return
        jobs.launch {
            val result = try { active.setActive() } catch (e: CancellationException) { throw e }
                catch (_: Exception) { null }
            if (control === active) {
                if (result is CallControlResult.Success) calls.setHeld(false)
                else calls.showError("AUDIO_RESUME_DECLINED")
            }
        }
    }

    internal fun route(endpoint: CallEndpointCompat) {
        val active = control ?: return
        val entryID = currentEntry ?: return
        if (routeJob?.isActive == true) return
        calls.setRouteChanging(entryID, true)
        routeJob = jobs.launch {
            try {
                val result = active.requestEndpointChange(endpoint)
                if (control === active && result !is CallControlResult.Success) calls.showError("AUDIO_ROUTE_UNAVAILABLE")
            } catch (e: CancellationException) { throw e }
            catch (_: Exception) { if (control === active) calls.showError("AUDIO_ROUTE_UNAVAILABLE") }
            finally { calls.setRouteChanging(entryID, false) }
        }
    }

    internal fun promoteMicrophone() {
        if (!foreground) throw ChirpException("CALL_SERVICE_UNAVAILABLE")
        startCallForeground(microphone = true)
    }

    internal fun demoteMicrophone() {
        if (foreground) runCatching { startCallForeground(microphone = false) }
    }

    private fun startCallForeground(microphone: Boolean) {
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.createNotificationChannel(NotificationChannel(
            CHANNEL, getString(R.string.call_channel), NotificationManager.IMPORTANCE_LOW,
        ))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val leave = PendingIntent.getService(this, 0, Intent(this, CallService::class.java).setAction(HANG_UP).setIdentifier(currentEntry),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val caller = Person.Builder().setName(getString(R.string.app_name)).setImportant(true).build()
        val notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_waveform)
            .setContentTitle(getString(R.string.call_notification))
            .setContentIntent(open)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setStyle(NotificationCompat.CallStyle.forOngoingCall(caller, leave))
            .setOngoing(true)
            .build()
        val type = ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or
            (if (microphone) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0)
        ServiceCompat.startForeground(this, 17, notification, type)
    }

    override fun onDestroy() {
        jobs.cancel()
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        (application as ChirpApplication).finishRemovedTask()
        super.onTaskRemoved(rootIntent)
    }

    private companion object {
        const val CHANNEL = "chirp-voice"
        const val HANG_UP = "cn.youzifeile.chirp.android.LEAVE"
    }
}
