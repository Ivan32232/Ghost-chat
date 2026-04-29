package com.kordar.ghostchat.core.managers

import com.kordar.ghostchat.core.security.KeystoreServicing
import com.kordar.ghostchat.models.AutoLockTimeout
import com.kordar.ghostchat.models.MessageTTL
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.nio.charset.StandardCharsets

/**
 * Keystore-backed user preferences. Matches iOS `SettingsManager` key names so preferences
 * on one platform remain semantically compatible if later migrated.
 */
class SettingsManager(private val keystore: KeystoreServicing) {

    private object Keys {
        const val PRIVACY_MODE          = "settings.privacy_mode"
        const val BIOMETRIC_ENABLED     = "settings.biometric_enabled"
        const val SOUND_ENABLED         = "settings.sound_enabled"
        const val MESSAGE_TTL           = "settings.message_ttl"
        const val AUTO_LOCK             = "settings.auto_lock"
        const val NOTIFICATIONS_ENABLED = "settings.notifications_enabled"
    }

    private val _privacyMode      = MutableStateFlow(readBool(Keys.PRIVACY_MODE, false))
    private val _biometricEnabled = MutableStateFlow(readBool(Keys.BIOMETRIC_ENABLED, false))
    private val _soundEnabled     = MutableStateFlow(readBool(Keys.SOUND_ENABLED, true))
    private val _messageTTL       = MutableStateFlow(
        MessageTTL.fromSeconds(readInt(Keys.MESSAGE_TTL, MessageTTL.FIVE_MINUTES.seconds))
    )
    private val _autoLockTimeout  = MutableStateFlow(
        AutoLockTimeout.fromSeconds(readInt(Keys.AUTO_LOCK, AutoLockTimeout.ONE_MINUTE.seconds))
    )
    private val _notificationsEnabled = MutableStateFlow(readBool(Keys.NOTIFICATIONS_ENABLED, false))

    val privacyMode: StateFlow<Boolean> = _privacyMode.asStateFlow()
    val biometricEnabled: StateFlow<Boolean> = _biometricEnabled.asStateFlow()
    val soundEnabled: StateFlow<Boolean> = _soundEnabled.asStateFlow()
    val messageTTL: StateFlow<MessageTTL> = _messageTTL.asStateFlow()
    val autoLockTimeout: StateFlow<AutoLockTimeout> = _autoLockTimeout.asStateFlow()

    /**
     * User opt-in for receiving push notifications when contacts message
     * while you're offline. Default OFF — privacy-first. Setting `true`
     * should be paired with the runtime POST_NOTIFICATIONS prompt on API 33+;
     * the UI layer (Settings toggle) handles that.
     */
    val notificationsEnabled: StateFlow<Boolean> = _notificationsEnabled.asStateFlow()

    fun setPrivacyMode(value: Boolean)      { _privacyMode.value = value;      writeBool(Keys.PRIVACY_MODE, value) }
    fun setBiometricEnabled(value: Boolean) { _biometricEnabled.value = value; writeBool(Keys.BIOMETRIC_ENABLED, value) }
    fun setSoundEnabled(value: Boolean)     { _soundEnabled.value = value;     writeBool(Keys.SOUND_ENABLED, value) }
    fun setMessageTTL(value: MessageTTL)    { _messageTTL.value = value;       writeInt(Keys.MESSAGE_TTL, value.seconds) }
    fun setAutoLockTimeout(v: AutoLockTimeout) { _autoLockTimeout.value = v;   writeInt(Keys.AUTO_LOCK, v.seconds) }
    fun setNotificationsEnabled(value: Boolean) {
        _notificationsEnabled.value = value
        writeBool(Keys.NOTIFICATIONS_ENABLED, value)
    }

    private fun readBool(key: String, default: Boolean): Boolean {
        val raw = keystore.get(key) ?: return default
        return raw.isNotEmpty() && raw[0] == 0x01.toByte()
    }
    private fun readInt(key: String, default: Int): Int {
        val raw = keystore.get(key) ?: return default
        return String(raw, StandardCharsets.UTF_8).toIntOrNull() ?: default
    }
    private fun writeBool(key: String, value: Boolean) =
        keystore.set(key, byteArrayOf(if (value) 0x01 else 0x00))
    private fun writeInt(key: String, value: Int) =
        keystore.set(key, value.toString().toByteArray(StandardCharsets.UTF_8))
}
