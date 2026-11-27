package cn.youzifeile.chirp.data

import android.content.Context
import android.hardware.biometrics.BiometricManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.File
import java.io.FileNotFoundException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.spec.MGF1ParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.BadPaddingException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

internal typealias AuthenticateCipher = suspend (Cipher) -> Cipher?

internal class BiometricLoginVault(context: Context) {
    private val biometrics = context.getSystemService(BiometricManager::class.java)
    private val file = AtomicFile(File(context.noBackupFilesDir, "login-resumption-v1"))
    private val mutex = Mutex()
    private val cleanup = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val store get() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    fun available() = try {
        biometrics.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS
    } catch (_: RuntimeException) { false }

    private suspend fun <T> storage(block: () -> T): T = mutex.withLock { withContext(Dispatchers.IO) { block() } }

    suspend fun expiration(): Long? = storage {
        try { DataInputStream(file.openRead()).use { it.readLong() } }
        catch (_: FileNotFoundException) { null }
        catch (_: EOFException) { throw ChirpException("CLIENT_INVALID_LOGIN_SESSION") }
    }

    private fun erase() {
        file.delete()
        store.let { if (it.containsAlias(ALIAS)) it.deleteEntry(ALIAS) }
        verify(!file.baseFile.exists(), "IDENTITY_STORAGE_INVALID")
    }

    // Enqueue erasure before any subsequent task can read or replace the record.
    // It must survive cancellation of the signing-out task's ViewModel.
    fun clear() {
        // Normally the file is idle. Unlink it before returning to the login screen,
        // even if the process is killed immediately afterwards.
        if (mutex.tryLock()) {
            try { file.delete() } finally { mutex.unlock() }
        }
        cleanup.launch(start = CoroutineStart.UNDISPATCHED) {
            try { storage(::erase) }
            catch (_: Exception) { LogEvent.saveLoginForRelaunch.record(LogOutcome.failed, "IDENTITY_STORAGE_INVALID") }
        }
    }

    suspend fun awaitPendingWrites() = mutex.withLock { }

    suspend fun replace(saved: SavedLogin?) = storage {
        erase()
        if (saved == null) return@storage
        saved.checkDeadline()
        try {
            // Public-key encryption permits saving immediately after Passkey activation. Only
            // the Keystore private key can unwrap this AES key, with a fresh biometric operation.
            val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore")
            generator.initialize(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(2048).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
                .setDigests(KeyProperties.DIGEST_SHA256).setUserAuthenticationRequired(true)
                .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                .setInvalidatedByBiometricEnrollment(true).build())
            val publicKey = KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(generator.generateKeyPair().public.encoded))
            val wrap = wrappingCipher().apply { init(Cipher.ENCRYPT_MODE, publicKey, OAEP) }
            val key = randomBytes(32)
            val plaintext = wireJson.encodeToString(saved).encodeToByteArray()
            try {
                val aes = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES")) }
                val wrapped = wrap.doFinal(key)
                val ciphertext = aes.doFinal(plaintext)
                verify(wrapped.size == WRAPPED_BYTES && aes.iv.size == IV_BYTES && ciphertext.size <= MAX_CIPHERTEXT)
                saved.checkDeadline()
                val stream = file.startWrite()
                try {
                    DataOutputStream(stream).apply {
                        writeLong(saved.expiresAt); write(wrapped); write(aes.iv); write(ciphertext)
                    }
                    file.finishWrite(stream)
                } catch (e: Throwable) { file.failWrite(stream); throw e }
            } finally { key.fill(0); plaintext.fill(0) }
        } catch (e: Exception) { erase(); throw e }
    }

    private class SealedLogin(val cipher: Cipher, val wrapped: ByteArray, val iv: ByteArray, val ciphertext: ByteArray)

    suspend fun open(expiresAt: Long, authenticate: AuthenticateCipher): SavedLogin? {
        val sealed = storage {
            when (biometrics.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)) {
                BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> throw ChirpException("LOGIN_BIOMETRICS_CHANGED")
                BiometricManager.BIOMETRIC_SUCCESS -> Unit
                else -> throw ChirpException("CLIENT_LOCAL_UNLOCK_FAILED")
            }
            val privateKey = store.getKey(ALIAS, null) as? PrivateKey ?: throw ChirpException("LOGIN_BIOMETRICS_CHANGED")
            val cipher = try { wrappingCipher().apply { init(Cipher.DECRYPT_MODE, privateKey, OAEP) } }
                catch (_: KeyPermanentlyInvalidatedException) { throw ChirpException("LOGIN_BIOMETRICS_CHANGED") }
            try {
                DataInputStream(file.openRead()).use { input ->
                    verify(input.readLong() == expiresAt, "CLIENT_INVALID_LOGIN_SESSION")
                    val wrapped = ByteArray(WRAPPED_BYTES).also(input::readFully)
                    val iv = ByteArray(IV_BYTES).also(input::readFully)
                    val ciphertext = input.readNBytes(MAX_CIPHERTEXT + 1)
                    verify(ciphertext.size in 16..MAX_CIPHERTEXT, "CLIENT_INVALID_LOGIN_SESSION")
                    SealedLogin(cipher, wrapped, iv, ciphertext)
                }
            } catch (_: EOFException) { throw ChirpException("CLIENT_INVALID_LOGIN_SESSION") }
            catch (_: FileNotFoundException) { throw ChirpException("CLIENT_INVALID_LOGIN_SESSION") }
        }
        val authorized = authenticate(sealed.cipher) ?: return null
        verify(authorized === sealed.cipher, "CLIENT_LOCAL_UNLOCK_FAILED")
        return withContext(Dispatchers.IO) {
            try {
                val key = authorized.doFinal(sealed.wrapped)
                val aes = Cipher.getInstance("AES/GCM/NoPadding")
                val clear = try {
                    aes.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, sealed.iv))
                    aes.doFinal(sealed.ciphertext)
                } finally { key.fill(0) }
                val saved = try { wireJson.decodeFromString<SavedLogin>(clear.decodeToString(throwOnInvalidSequence = true)) }
                    finally { clear.fill(0) }
                verify(saved.expiresAt == expiresAt, "CLIENT_INVALID_LOGIN_SESSION")
                saved.checkDeadline()
                saved
            } catch (_: BadPaddingException) { throw ChirpException("CLIENT_INVALID_LOGIN_SESSION") }
            catch (_: IllegalArgumentException) { throw ChirpException("CLIENT_INVALID_LOGIN_SESSION") }
        }
    }

    private companion object {
        const val ALIAS = "chirp-login-resumption-v1"
        const val WRAPPED_BYTES = 256
        const val IV_BYTES = 12
        const val MAX_CIPHERTEXT = 65_536
        val OAEP = OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT)
        fun wrappingCipher(): Cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
    }
}
