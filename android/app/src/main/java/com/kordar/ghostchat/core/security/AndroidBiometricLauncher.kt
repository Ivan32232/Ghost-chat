package com.kordar.ghostchat.core.security

import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * Production implementation backed by `androidx.biometric.BiometricPrompt`.
 * Must be constructed with a `FragmentActivity` because BiometricPrompt needs a
 * Fragment lifecycle host.
 */
class AndroidBiometricLauncher(
    private val activityProvider: () -> FragmentActivity?
) : BiometricLauncher {

    override suspend fun prompt(reason: String): Boolean = suspendCancellableCoroutine { cont ->
        val activity = activityProvider() ?: run { cont.resume(false); return@suspendCancellableCoroutine }
        val canAuth = BiometricManager.from(activity).canAuthenticate(AUTHENTICATORS)
        if (canAuth != BiometricManager.BIOMETRIC_SUCCESS) { cont.resume(false); return@suspendCancellableCoroutine }

        val executor = ContextCompat.getMainExecutor(activity)
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(reason)
            .setAllowedAuthenticators(AUTHENTICATORS)
            .setNegativeButtonText("Cancel")
            .setConfirmationRequired(false)
            .build()
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                if (cont.isActive) cont.resume(true)
            }
            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                if (cont.isActive) cont.resume(false)
            }
            override fun onAuthenticationFailed() {
                // Keep trying — BiometricPrompt handles retries internally.
            }
        }
        val prompt = BiometricPrompt(activity, executor, callback)
        prompt.authenticate(info)
        cont.invokeOnCancellation { prompt.cancelAuthentication() }
    }

    companion object {
        private const val AUTHENTICATORS =
            BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
    }
}
