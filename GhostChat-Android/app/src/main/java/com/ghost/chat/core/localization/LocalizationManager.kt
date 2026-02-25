package com.ghost.chat.core.localization

import android.content.Context
import android.content.res.Configuration
import com.ghost.chat.core.security.KeystoreService
import java.util.Locale

/// Runtime language switching — port of iOS LocalizationManager
/// Supports: English (en), Russian (ru)
object LocalizationManager {

    private const val KEY_LANGUAGE = "settings_language"

    var currentLanguage: String = "ru"
        private set

    /** Initialize from saved preference */
    fun init(context: Context) {
        currentLanguage = KeystoreService.loadString(KEY_LANGUAGE) ?: getSystemLanguage()
    }

    /** Set language and persist */
    fun setLanguage(languageCode: String, context: Context) {
        currentLanguage = languageCode
        KeystoreService.saveString(languageCode, KEY_LANGUAGE)
    }

    /** Apply locale to context (call in attachBaseContext) */
    fun applyLocale(context: Context): Context {
        val locale = Locale(currentLanguage)
        Locale.setDefault(locale)

        val config = Configuration(context.resources.configuration)
        config.setLocale(locale)

        return context.createConfigurationContext(config)
    }

    /** Get system language (default to Russian) */
    private fun getSystemLanguage(): String {
        val systemLang = Locale.getDefault().language
        return if (systemLang == "en") "en" else "ru"
    }
}
