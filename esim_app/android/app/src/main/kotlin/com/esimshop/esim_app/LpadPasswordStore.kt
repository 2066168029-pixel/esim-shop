package com.esimshop.esim_app

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * PSK storage for the Linksfield BLE path.
 *
 * The SDK asks for a password per device and expects it back synchronously on
 * its own thread. The vendor demo keeps these in a HashMap, which loses them on
 * every process restart -- meaning the user retypes the pairing password after
 * each kill. Keystore-backed storage fixes that and keeps the secret off disk
 * in plaintext.
 *
 * Falls back to a private SharedPreferences file when the Keystore is
 * unavailable (some heavily customised ROMs). Storing a PSK is still better
 * than silently failing to remember it, but the fallback is logged.
 */
class LpadPasswordStore(context: Context) {

    private val prefs: SharedPreferences = try {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            FILE_SECURE,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    } catch (t: Throwable) {
        android.util.Log.w("LpadPasswordStore", "Keystore unavailable, using plain prefs", t)
        context.getSharedPreferences(FILE_PLAIN, Context.MODE_PRIVATE)
    }

    fun get(mac: String): String? = prefs.getString(key(mac), null)

    fun save(mac: String, password: String) {
        if (mac.isBlank() || password.isEmpty()) return
        prefs.edit().putString(key(mac), password).apply()
    }

    fun remove(mac: String) {
        prefs.edit().remove(key(mac)).apply()
    }

    fun has(mac: String): Boolean = !prefs.getString(key(mac), null).isNullOrBlank()

    private fun key(mac: String) = "psk_${mac.uppercase()}"

    companion object {
        private const val FILE_SECURE = "lpad_secure"
        private const val FILE_PLAIN = "lpad_plain"
    }
}
