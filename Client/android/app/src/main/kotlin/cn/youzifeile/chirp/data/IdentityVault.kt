package cn.youzifeile.chirp.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@kotlinx.serialization.Serializable
internal data class SavedIdentity(
    val origin: String, val account: String, val name: String, val root: String, val discovery: String,
) {
    val scope get() = IdentitySetup.scope(origin, account)
}

internal class IdentityVault(context: Context) {
    private val directory = File(context.noBackupFilesDir, "identity-v5")
    private val alias = "chirp-identity-v5"
    private val store get() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun file(scope: String) = AtomicFile(File(directory, sha256(scope.encodeToByteArray()).toHexString()))

    private fun key(create: Boolean): SecretKey = synchronized(keyLock) {
        (store.getKey(alias, null) as? SecretKey)?.let { return@synchronized it }
        verify(create, "IDENTITY_STORAGE_INVALID")
        KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    suspend fun read(scope: String): String? = withContext(Dispatchers.IO) {
        val file = file(scope)
        val bytes = try { file.readFully() } catch (e: java.io.FileNotFoundException) {
            if (file.baseFile.exists()) throw e
            return@withContext null
        }
        verify(bytes.size >= 28, "IDENTITY_STORAGE_INVALID")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, bytes, 0, 12))
        cipher.updateAAD(scope.encodeToByteArray())
        val clear = cipher.doFinal(bytes, 12, bytes.size - 12)
        try { clear.decodeToString(throwOnInvalidSequence = true) } finally { clear.fill(0) }
    }
    suspend fun write(scope: String, contents: String) = withContext(Dispatchers.IO) {
        verify(directory.isDirectory || directory.mkdirs() || directory.isDirectory, "IDENTITY_STORAGE_INVALID")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(true))
        cipher.updateAAD(scope.encodeToByteArray())
        val plaintext = contents.encodeToByteArray()
        val ciphertext = try { cipher.doFinal(plaintext) } finally { plaintext.fill(0) }
        val file = file(scope)
        val stream = file.startWrite()
        try { stream.write(cipher.iv); stream.write(ciphertext); file.finishWrite(stream) }
        catch (e: Throwable) { file.failWrite(stream); throw e }
    }
    suspend fun savedIdentities(): List<SavedIdentity> = indexLock.withLock {
        indexed().filter { entry ->
            IdentitySetup.loadRecord(this, entry.scope).active?.device?.accountKey == entry.root
        }
    }

    suspend fun rememberIdentity(entry: SavedIdentity) = indexLock.withLock {
        val current = indexed()
        if (current.firstOrNull { it.scope == entry.scope } != entry) {
            write(INDEX, wireJson.encodeToString(current.filterNot { it.scope == entry.scope } + entry))
        }
    }

    suspend fun pendingLogin(): NativeLogin? = pendingLock.withLock {
        val stored = read(NativeLogin.PENDING)?.let { wireJson.decodeFromString<NativeLogin>(it) } ?: return@withLock null
        if (stored.expires <= nowSeconds()) {
            withContext(Dispatchers.IO) { file(NativeLogin.PENDING).delete() }
            throw ChirpException("DEVICE_AUTHORIZATION_EXPIRED")
        }
        stored
    }

    suspend fun savePendingLogin(login: NativeLogin) = pendingLock.withLock {
        write(NativeLogin.PENDING, wireJson.encodeToString(login))
    }

    suspend fun removePendingLogin(state: String): Boolean = pendingLock.withLock {
        val encoded = read(NativeLogin.PENDING) ?: return@withLock false
        if (wireJson.decodeFromString<NativeLogin>(encoded).state != state) return@withLock false
        withContext(Dispatchers.IO) { file(NativeLogin.PENDING).delete() }
        // AtomicFile.delete() does not report failures. A recoverable record must never authorize a second POST.
        verify(read(NativeLogin.PENDING) == null, "IDENTITY_STORAGE_INVALID")
        true
    }

    private suspend fun indexed(): List<SavedIdentity> =
        read(INDEX)?.let { wireJson.decodeFromString<List<SavedIdentity>>(it) }.orEmpty()

    private companion object {
        const val INDEX = "saved-account-identities-v1"
        val keyLock = Any()
        val pendingLock = kotlinx.coroutines.sync.Mutex()
        val indexLock = kotlinx.coroutines.sync.Mutex()
    }
}
