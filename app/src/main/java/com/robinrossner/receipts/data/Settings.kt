package com.robinrossner.receipts.data

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** The receipts token lives encrypted: AES-GCM with a key that never leaves the Android Keystore. */
interface TokenVault {
    fun read(): String?
    fun save(token: String): Boolean
    fun delete()
    fun contains(): Boolean = read() != null
}

/** AES-256-GCM over a text value, `base64(iv || ciphertext)`. The key comes from outside (Android Keystore in the app). */
class AesGcmCodec(private val key: () -> SecretKey) {
    fun encrypt(plain: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val body = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(cipher.iv + body, Base64.NO_WRAP)
    }

    fun decrypt(blob: String): String {
        val bytes = Base64.decode(blob, Base64.NO_WRAP)
        require(bytes.size > IV_BYTES) { "blob too short" }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, bytes, 0, IV_BYTES))
        return String(cipher.doFinal(bytes, IV_BYTES, bytes.size - IV_BYTES), Charsets.UTF_8)
    }

    companion object {
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val TAG_BITS = 128
    }
}

class KeystoreTokenVault(private val prefs: SharedPreferences) : TokenVault {
    private val codec = AesGcmCodec(::key)

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    override fun read(): String? {
        val blob = prefs.getString(PREF_TOKEN, null) ?: return null
        return runCatching { codec.decrypt(blob) }.getOrNull()
    }

    override fun save(token: String): Boolean = runCatching {
        prefs.edit().putString(PREF_TOKEN, codec.encrypt(token)).commit()
    }.getOrDefault(false)

    override fun delete() {
        prefs.edit().remove(PREF_TOKEN).apply()
    }

    private companion object {
        const val PROVIDER = "AndroidKeyStore"
        const val ALIAS = "receipts_token_key"
        const val PREF_TOKEN = "token_encrypted"
    }
}

/** Server address, sync switch and a stable device name. The token is NOT here (see [TokenVault]). */
class SyncSettings(context: Context) {
    val prefs: SharedPreferences = context.getSharedPreferences("receipts_settings", Context.MODE_PRIVATE)
    val vault: TokenVault = KeystoreTokenVault(prefs)

    var serverUrl: String
        get() = prefs.getString(KEY_URL, "").orEmpty()
        set(value) { prefs.edit().putString(KEY_URL, value.trim()).apply() }

    var enabled: Boolean
        get() = prefs.getBoolean(KEY_ENABLED, false)
        set(value) { prefs.edit().putBoolean(KEY_ENABLED, value).apply() }

    /** A stable name for this phone in sync requests (`device_id`), made up once and kept. */
    val deviceId: String
        get() = prefs.getString(KEY_DEVICE, null) ?: ("android-" + java.util.UUID.randomUUID().toString().take(8)).also {
            prefs.edit().putString(KEY_DEVICE, it).apply()
        }

    private companion object {
        const val KEY_URL = "server_url"
        const val KEY_ENABLED = "sync_enabled"
        const val KEY_DEVICE = "device_id"
    }
}
