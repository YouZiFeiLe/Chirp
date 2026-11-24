package cn.youzifeile.chirp.data

import android.content.Context
import android.util.AtomicFile
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.floatPreferencesKey
import cn.youzifeile.chirp.media.AudioPreset
import androidx.datastore.preferences.preferencesDataStore
import java.io.File
import java.security.KeyStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext

private val Context.settings by preferencesDataStore("chirp")
private val serverKey = stringPreferencesKey("confirmed_server")
private val connectionKey = stringPreferencesKey("confirmed_connection_v5")
private val presetKey = stringPreferencesKey("audio_preset")
private val activationKey = booleanPreferencesKey("voice_activation")
private val thresholdKey = floatPreferencesKey("voice_threshold")

internal class LocalSettings(private val context: Context) {
    suspend fun server(): String = context.settings.data.first()[serverKey].orEmpty()

    suspend fun audioSettings(): Triple<AudioPreset, Boolean, Float> {
        val saved = context.settings.data.first()
        val preset = saved[presetKey]?.let { runCatching { AudioPreset.valueOf(it) }.getOrNull() }
            ?: AudioPreset.RNNoise
        return Triple(preset, saved[activationKey] ?: false, (saved[thresholdKey] ?: -45f).coerceIn(-80f, -10f))
    }
    suspend fun saveAudioSettings(preset: AudioPreset, activation: Boolean, threshold: Float) {
        context.settings.edit { it[presetKey] = preset.name; it[activationKey] = activation; it[thresholdKey] = threshold.coerceIn(-80f, -10f) }
    }

    suspend fun clearServer() {
        context.settings.edit { it.remove(serverKey); it.remove(connectionKey) }
    }

    suspend fun savedConnection(discovery: String): ServerConnection? {
        val encoded = context.settings.data.first()[connectionKey] ?: return null
        return runCatching {
            wireJson.decodeFromString<ServerConnection>(encoded).also { it.validateSaved(discovery) }
        }.getOrNull()
    }

    suspend fun saveServer(connection: ServerConnection) {
        val origin = connection.origin.toString()
        connection.validateSaved(origin)
        context.settings.edit {
            it[serverKey] = origin
            it[connectionKey] = wireJson.encodeToString(connection)
        }
    }

    suspend fun discardPersistedLogin() = withContext(Dispatchers.IO) {
        AtomicFile(File(context.noBackupFilesDir, "session-v5")).delete()
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (store.containsAlias("chirp-session-aes-gcm")) store.deleteEntry("chirp-session-aes-gcm")
    }
}
