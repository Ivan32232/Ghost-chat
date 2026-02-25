package com.ghost.chat.core.security

import android.content.Context
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity

/// Biometric authentication — port of iOS BiometricAuthService
/// Uses AndroidX BiometricPrompt (fingerprint / face)
object BiometricAuthService {

    private const val KEY_BIOMETRIC_ENABLED = "biometric_enabled"

    var isUnlocked: Boolean = true
        private set

    var isEnabled: Boolean
        get() = KeystoreService.loadBool(KEY_BIOMETRIC_ENABLED, false)
        set(value) = KeystoreService.saveBool(value, KEY_BIOMETRIC_ENABLED)

    /** Check if biometric auth is available on device */
    fun isAvailable(context: Context): Boolean {
        val biometricManager = BiometricManager.from(context)
        return biometricManager.canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL
        ) == BiometricManager.BIOMETRIC_SUCCESS
    }

    /** Authenticate with biometrics */
    fun authenticate(
        activity: FragmentActivity,
        title: String,
        subtitle: String,
        onSuccess: () -> Unit,
        onError: (String) -> Unit
    ) {
        val executor = ContextCompat.getMainExecutor(activity)

        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                isUnlocked = true
                onSuccess()
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                if (errorCode != BiometricPrompt.ERROR_USER_CANCELED &&
                    errorCode != BiometricPrompt.ERROR_NEGATIVE_BUTTON
                ) {
                    onError(errString.toString())
                }
            }

            override fun onAuthenticationFailed() {
                // Not an error — user can retry
            }
        }

        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                        BiometricManager.Authenticators.DEVICE_CREDENTIAL
            )
            .build()

        BiometricPrompt(activity, executor, callback).authenticate(promptInfo)
    }

    /** Lock (called on app background) */
    fun lock() {
        if (isEnabled) {
            isUnlocked = false
        }
    }

    /** Toggle biometric auth */
    fun toggle(
        activity: FragmentActivity,
        title: String,
        subtitle: String,
        onResult: (Boolean) -> Unit
    ) {
        if (isEnabled) {
            isEnabled = false
            isUnlocked = true
            onResult(false)
        } else {
            authenticate(activity, title, subtitle,
                onSuccess = {
                    isEnabled = true
                    onResult(true)
                },
                onError = { onResult(false) }
            )
        }
    }
}
