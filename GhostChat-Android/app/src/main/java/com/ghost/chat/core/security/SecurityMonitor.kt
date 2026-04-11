package com.ghost.chat.core.security

import android.app.Activity
import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.WindowManager

/// Security monitoring — port of iOS SecurityMonitor
/// Detects: screen capture (API 34+), audio device changes
class SecurityMonitor(private val context: Context) {

    var onSecurityAlert: ((String) -> Unit)? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val cooldowns = mutableMapOf<String, Long>()
    private val cooldownInterval = 10_000L // 10 seconds

    // Audio device monitoring
    private var audioDeviceCallback: AudioDeviceCallback? = null
    private val audioManager: AudioManager? =
        context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    // Screen capture (API 34+)
    private var screenCaptureCallback: Any? = null  // Activity.ScreenCaptureCallback
    private var activityRef: Activity? = null

    fun start() {
        startAudioDeviceMonitoring()
    }

    /// Register screen capture detection — requires Activity (not just Context)
    /// Call from MainActivity/Activity after SecurityMonitor is created
    fun registerScreenCaptureDetection(activity: Activity) {
        activityRef = activity
        startScreenCaptureDetection(activity)
    }

    fun stop() {
        stopAudioDeviceMonitoring()
        stopScreenCaptureDetection()
        onSecurityAlert = null
        activityRef = null
    }

    // MARK: - Screen Capture Detection (API 34+)

    private fun startScreenCaptureDetection(activity: Activity) {
        // FLAG_SECURE is applied in MainActivity (primary defense)
        // On Android 14+ (API 34), we also get real-time callbacks for screen capture
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val callback = Activity.ScreenCaptureCallback {
                fireAlert("screen-capture-detected")
            }
            screenCaptureCallback = callback
            val mainExecutor = java.util.concurrent.Executor { command ->
                mainHandler.post(command)
            }
            activity.registerScreenCaptureCallback(mainExecutor, callback)
        }
    }

    private fun stopScreenCaptureDetection() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val callback = screenCaptureCallback as? Activity.ScreenCaptureCallback
            if (callback != null) {
                try {
                    activityRef?.unregisterScreenCaptureCallback(callback)
                } catch (_: Exception) {}
            }
        }
        screenCaptureCallback = null
    }

    // MARK: - Audio Device Monitoring

    private fun startAudioDeviceMonitoring() {
        audioDeviceCallback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                for (device in addedDevices) {
                    when (device.type) {
                        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> {
                            fireAlert("bluetooth-device-connected")
                        }
                        AudioDeviceInfo.TYPE_WIRED_HEADSET,
                        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> {
                            fireAlert("wired-headset-connected")
                        }
                        AudioDeviceInfo.TYPE_USB_DEVICE,
                        AudioDeviceInfo.TYPE_USB_HEADSET -> {
                            fireAlert("usb-device-connected")
                        }
                        else -> {}
                    }
                }
            }

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                for (device in removedDevices) {
                    when (device.type) {
                        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                        AudioDeviceInfo.TYPE_WIRED_HEADSET,
                        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> {
                            fireAlert("audio-device-disconnected")
                        }
                        else -> {}
                    }
                }
            }
        }

        audioManager?.registerAudioDeviceCallback(audioDeviceCallback, mainHandler)
    }

    private fun stopAudioDeviceMonitoring() {
        audioDeviceCallback?.let { audioManager?.unregisterAudioDeviceCallback(it) }
        audioDeviceCallback = null
    }

    // MARK: - Alert Firing

    private fun fireAlert(alertType: String) {
        val now = System.currentTimeMillis()
        val lastAlert = cooldowns[alertType] ?: 0

        if (now - lastAlert < cooldownInterval) return
        cooldowns[alertType] = now

        mainHandler.post { onSecurityAlert?.invoke(alertType) }
    }

    /** Detect rooted/compromised device (su binaries, Magisk, test-keys) */
    fun isDeviceRooted(): Boolean {
        val paths = arrayOf(
            "/system/app/Superuser.apk", "/sbin/su", "/system/bin/su",
            "/system/xbin/su", "/data/local/xbin/su", "/data/local/bin/su",
            "/system/sd/xbin/su", "/system/bin/failsafe/su", "/data/local/su",
            "/su/bin/su", "/system/app/SuperSU.apk"
        )
        for (path in paths) {
            if (java.io.File(path).exists()) return true
        }
        // Check for Magisk
        try {
            Runtime.getRuntime().exec("su")
            return true
        } catch (_: Exception) {}
        // Check build tags
        val buildTags = Build.TAGS
        if (buildTags != null && buildTags.contains("test-keys")) return true
        return false
    }

    companion object {
        /** Apply FLAG_SECURE to prevent screenshots/screen recording */
        fun applyFlagSecure(activity: Activity) {
            activity.window.setFlags(
                WindowManager.LayoutParams.FLAG_SECURE,
                WindowManager.LayoutParams.FLAG_SECURE
            )
        }
    }
}
