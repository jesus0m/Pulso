package com.jesusom.pulso.core

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

/** Credential storage. Values never reach plain-text preferences. */
interface SecretStore {
    fun load(name: String): ByteArray?
    fun save(name: String, value: ByteArray)
    fun delete(name: String)
}

class SecretStoreUnavailable(cause: Throwable? = null) : Exception(cause), LocalizedError {
    override fun describe(c: Context): String =
        c.getString(com.jesusom.pulso.R.string.s_no_se_pudo_acceder_al_llavero_del_dispositiv, -1)
}

/** AES-GCM with a hardware-backed Android Keystore key; ciphertext lives in app-private preferences. */
class KeystoreSecretStore(context: Context, fileName: String = "pulso_secure") : SecretStore {
    private val prefs: SharedPreferences = context.applicationContext.getSharedPreferences(fileName, Context.MODE_PRIVATE)

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build()
        )
        return generator.generateKey()
    }

    @Synchronized
    override fun load(name: String): ByteArray? {
        val encoded = prefs.getString(name, null) ?: return null
        return try {
            val raw = Base64.decode(encoded, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, raw.copyOfRange(0, IV_BYTES)))
            cipher.updateAAD(name.toByteArray())
            cipher.doFinal(raw, IV_BYTES, raw.size - IV_BYTES)
        } catch (e: Exception) {
            throw SecretStoreUnavailable(e)
        }
    }

    @Synchronized
    override fun save(name: String, value: ByteArray) {
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key())
            cipher.updateAAD(name.toByteArray())
            val sealed = cipher.iv + cipher.doFinal(value)
            prefs.edit().putString(name, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
        } catch (e: Exception) {
            throw SecretStoreUnavailable(e)
        }
    }

    @Synchronized
    override fun delete(name: String) {
        prefs.edit().remove(name).apply()
    }

    private companion object {
        const val ALIAS = "com.jesusom.pulso.secrets"
        const val IV_BYTES = 12
    }
}

class InMemorySecretStore : SecretStore {
    private val values = HashMap<String, ByteArray>()
    @Synchronized override fun load(name: String) = values[name]
    @Synchronized override fun save(name: String, value: ByteArray) { values[name] = value }
    @Synchronized override fun delete(name: String) { values.remove(name) }
}
