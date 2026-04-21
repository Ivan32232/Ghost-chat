package com.kordar.ghostchat.core.localization

import android.content.Context
import android.content.res.Configuration
import com.kordar.ghostchat.core.security.KeystoreServicing
import java.util.Locale

/**
 * Locale resolver. Mirror of iOS [LocalizationManager]:
 *  1. If the user picked an override → use it.
 *  2. Otherwise, fall back to the device locale if supported (en/ru).
 *  3. Default to English.
 *
 * The override is persisted in the [KeystoreServicing] under the same key as iOS
 * (`settings.locale.override`) so cross-platform users see the same preference semantics.
 */
class LocalizationManager(
    private val context: Context,
    private val keystore: KeystoreServicing
) {

    companion object {
        const val KEYSTORE_KEY = "settings.locale.override"
        val SUPPORTED: List<Locale> = listOf(Locale("en"), Locale("ru"))
    }

    @Volatile
    var locale: Locale = resolve()
        private set

    fun setOverride(newLocale: Locale) {
        if (SUPPORTED.none { it.language == newLocale.language }) return
        locale = SUPPORTED.first { it.language == newLocale.language }
        keystore.set(KEYSTORE_KEY, locale.language.toByteArray(Charsets.UTF_8))
    }

    fun clearOverride() {
        keystore.delete(KEYSTORE_KEY)
        locale = resolve()
    }

    /**
     * Returns a [Context] whose resources are configured for the active [locale]. Useful for
     * ad-hoc string resolution from background components (FCM service, notifications).
     */
    fun localizedContext(base: Context = context): Context {
        val cfg = Configuration(base.resources.configuration)
        cfg.setLocale(locale)
        return base.createConfigurationContext(cfg)
    }

    fun localized(resId: Int): String = localizedContext().getString(resId)

    private fun resolve(): Locale {
        runCatching {
            val stored = keystore.get(KEYSTORE_KEY) ?: return@runCatching
            val code = String(stored, Charsets.UTF_8)
            SUPPORTED.firstOrNull { it.language == code }?.let { return it }
        }
        val systemCode = Locale.getDefault().language
        return SUPPORTED.firstOrNull { it.language == systemCode } ?: SUPPORTED[0]
    }
}
