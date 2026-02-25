package com.ghost.chat.core.security

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKeys

/// Secure storage — Android equivalent of iOS KeychainService
/// Uses EncryptedSharedPreferences backed by Android Keystore
object KeystoreService {

    private const val PREFS_NAME = "com.ghost.chat.secure"
    private var prefs: SharedPreferences? = null

    fun init(context: Context) {
        if (prefs != null) return
        val masterKeyAlias = MasterKeys.getOrCreate(MasterKeys.AES256_GCM_SPEC)
        prefs = EncryptedSharedPreferences.create(
            PREFS_NAME,
            masterKeyAlias,
            context.applicationContext,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    fun save(data: ByteArray, forKey: String) {
        prefs?.edit()?.putString(forKey, Base64.encodeToString(data, Base64.NO_WRAP))?.apply()
    }

    fun load(forKey: String): ByteArray? {
        val base64 = prefs?.getString(forKey, null) ?: return null
        return try {
            Base64.decode(base64, Base64.DEFAULT)
        } catch (e: Exception) {
            null
        }
    }

    fun saveString(value: String, forKey: String) {
        prefs?.edit()?.putString(forKey, value)?.apply()
    }

    fun loadString(forKey: String): String? {
        return prefs?.getString(forKey, null)
    }

    fun saveInt(value: Int, forKey: String) {
        prefs?.edit()?.putInt(forKey, value)?.apply()
    }

    fun loadInt(forKey: String, default: Int = 0): Int {
        return prefs?.getInt(forKey, default) ?: default
    }

    fun saveBool(value: Boolean, forKey: String) {
        prefs?.edit()?.putBoolean(forKey, value)?.apply()
    }

    fun loadBool(forKey: String, default: Boolean = false): Boolean {
        return prefs?.getBoolean(forKey, default) ?: default
    }

    fun delete(forKey: String) {
        prefs?.edit()?.remove(forKey)?.apply()
    }

    fun clear() {
        prefs?.edit()?.clear()?.apply()
    }
}
