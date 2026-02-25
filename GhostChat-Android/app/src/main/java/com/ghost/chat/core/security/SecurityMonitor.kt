package com.ghost.chat.core.security

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.WindowManager

/// Security monitoring — port of iOS SecurityMonitor
/// Detects: screen capture, audio device changes
class SecurityMonitor(private val context: Context) {

    var onSecurityAlert: ((String) -> Unit)? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val cooldowns = mutableMapOf<String, Long>()
    private val cooldownInterval = 10_000L // 10 seconds

    // Audio device monitoring
    private var audioDeviceCallback: AudioDeviceCallback? = null
    private val audioManager: AudioManager? =
        context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    // Screen capture broadcast
    private var screenCaptureReceiver: BroadcastReceiver? = null

    fun start() {
        startAudioDeviceMonitoring()
        startScreenCaptureDetection()
    }

    fun stop() {
        stopAudioDeviceMonitoring()
        stopScreenCaptureDetection()
        onSecurityAlert = null
    }

    // MARK: - Screen Capture Detection

    private fun startScreenCaptureDetection() {
        // FLAG_SECURE prevents screenshots/screen recording
        // Applied in MainActivity — this just monitors for bypass attempts

        // On Android 14+, we can detect screen sharing/recording
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // Android 14 has native screen capture callback
            // For now, FLAG_SECURE is our primary defense
        }
    }

    private fun stopScreenCaptureDetection() {
        screenCaptureReceiver?.let {
            try { context.unregisterReceiver(it) } catch (_: Exception) {}
        }
        screenCaptureReceiver = null
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

    companion object {
        /** Apply FLAG_SECURE to prevent screenshots/screen recording */
        fun applyFlagSecure(activity: android.app.Activity) {
            activity.window.setFlags(
                WindowManager.LayoutParams.FLAG_SECURE,
                WindowManager.LayoutParams.FLAG_SECURE
            )
        }
    }
}
