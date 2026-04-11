package com.ghost.chat.core.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log

/// Sound library — Android port of iOS SoundLibrary.
///
/// Android doesn't ship with named ringtones like iOS does, so we index into
/// the device's actual system ringtone / notification cursors. The stored
/// `ringtoneId` (and `soundId`) is a stable string key that maps to a real
/// Uri at playback time via RingtoneManager. This way when the user picks
/// a different ringtone in settings, the different one actually plays.
object SoundLibrary {

    private const val TAG = "GhostChat"

    // MARK: - Public option lists (for picker UI)

    /// Returns available ringtones as (id, displayName). The id is stable
    /// across launches — either "system:default" or "system_ringtone_<index>".
    fun ringtoneOptions(context: Context): List<Pair<String, String>> {
        return cachedOrBuildOptions(context, RingtoneManager.TYPE_RINGTONE, ringtoneCache)
    }

    /// Returns available notification (message) sounds.
    fun messageSoundOptions(context: Context): List<Pair<String, String>> {
        val base = cachedOrBuildOptions(context, RingtoneManager.TYPE_NOTIFICATION, notificationCache)
        // Prepend "none" so users can disable message sounds entirely
        return listOf("none" to "None") + base
    }

    private val ringtoneCache = mutableListOf<Pair<String, String>>()
    private val notificationCache = mutableListOf<Pair<String, String>>()

    private fun cachedOrBuildOptions(
        context: Context,
        type: Int,
        cache: MutableList<Pair<String, String>>
    ): List<Pair<String, String>> {
        if (cache.isNotEmpty()) return cache.toList()
        val prefix = if (type == RingtoneManager.TYPE_RINGTONE) "system_ringtone_" else "system_notification_"
        cache.add("system:default" to "System default")
        try {
            val rm = RingtoneManager(context).apply { setType(type) }
            val cursor = rm.cursor
            var i = 0
            while (cursor.moveToNext()) {
                val title = try {
                    cursor.getString(RingtoneManager.TITLE_COLUMN_INDEX)
                } catch (_: Exception) { null } ?: "Tone ${i + 1}"
                cache.add("${prefix}${i}" to title)
                i++
                if (i > 40) break // guard against huge lists
            }
        } catch (e: Exception) {
            Log.w(TAG, "[SoundLibrary] Failed to enumerate type=$type: ${e.message}")
        }
        return cache.toList()
    }

    /// Resolve a stored id → actual Uri. Falls back to system default if the
    /// indexed entry is missing (e.g. user uninstalled a ringtone app).
    private fun resolveUri(context: Context, soundId: String, fallbackType: Int): Uri? {
        if (soundId.isBlank() || soundId == "system:default") {
            return RingtoneManager.getDefaultUri(fallbackType)
        }
        return try {
            val (type, idxStr) = when {
                soundId.startsWith("system_ringtone_") ->
                    RingtoneManager.TYPE_RINGTONE to soundId.removePrefix("system_ringtone_")
                soundId.startsWith("system_notification_") ->
                    RingtoneManager.TYPE_NOTIFICATION to soundId.removePrefix("system_notification_")
                else -> return RingtoneManager.getDefaultUri(fallbackType)
            }
            val idx = idxStr.toIntOrNull() ?: return RingtoneManager.getDefaultUri(fallbackType)
            val rm = RingtoneManager(context).apply { setType(type) }
            rm.getRingtoneUri(idx) ?: RingtoneManager.getDefaultUri(fallbackType)
        } catch (e: Exception) {
            Log.w(TAG, "[SoundLibrary] resolveUri failed for $soundId: ${e.message}")
            RingtoneManager.getDefaultUri(fallbackType)
        }
    }

    private var mediaPlayer: MediaPlayer? = null

    /** Play message notification sound */
    fun playMessageSound(context: Context, soundId: String, withVibration: Boolean = false) {
        if (soundId == "none") {
            if (withVibration) vibrate(context)
            return
        }
        val uri = resolveUri(context, soundId, RingtoneManager.TYPE_NOTIFICATION) ?: return
        Log.d(TAG, "[SoundLibrary] playMessageSound: soundId=$soundId uri=$uri")
        try {
            MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setDataSource(context, uri)
                prepare()
                start()
                setOnCompletionListener { it.release() }
            }
            if (withVibration) vibrate(context)
        } catch (e: Exception) {
            Log.w(TAG, "[SoundLibrary] playMessageSound failed: ${e.message}")
            if (withVibration) vibrate(context)
        }
    }

    /** Play ringtone for incoming call */
    fun playRingtone(context: Context, ringtoneId: String) {
        val uri = resolveUri(context, ringtoneId, RingtoneManager.TYPE_RINGTONE) ?: return
        Log.d(TAG, "[SoundLibrary] playRingtone: ringtoneId=$ringtoneId uri=$uri")
        try {
            stopPreview()
            mediaPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setDataSource(context, uri)
                isLooping = true  // Ringtone keeps looping until call is answered/declined
                prepare()
                start()
            }
        } catch (e: Exception) {
            Log.w(TAG, "[SoundLibrary] playRingtone failed: ${e.message}")
        }
    }

    /** Preview a sound (for sound picker) */
    fun previewSound(context: Context, soundId: String) {
        stopPreview()
        // Use notification type as fallback since picker is typically for message sounds;
        // ringtone picker explicitly calls previewRingtone() below.
        val uri = resolveUri(context, soundId, RingtoneManager.TYPE_NOTIFICATION) ?: return
        Log.d(TAG, "[SoundLibrary] previewSound: soundId=$soundId uri=$uri")
        try {
            mediaPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setDataSource(context, uri)
                prepare()
                start()
                setOnCompletionListener {
                    it.release()
                    mediaPlayer = null
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "[SoundLibrary] previewSound failed: ${e.message}")
        }
    }

    /** Preview a ringtone (for ringtone picker, uses TYPE_RINGTONE fallback) */
    fun previewRingtone(context: Context, ringtoneId: String) {
        stopPreview()
        val uri = resolveUri(context, ringtoneId, RingtoneManager.TYPE_RINGTONE) ?: return
        try {
            mediaPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setDataSource(context, uri)
                prepare()
                start()
                setOnCompletionListener {
                    it.release()
                    mediaPlayer = null
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "[SoundLibrary] previewRingtone failed: ${e.message}")
        }
    }

    fun stopPreview() {
        try {
            mediaPlayer?.stop()
            mediaPlayer?.release()
        } catch (_: Exception) {}
        mediaPlayer = null
    }

    /// Alias for call-screen teardown — matches iOS name used in ChatViewModel.kt
    fun stopRingtone() = stopPreview()

    private fun vibrate(context: Context) {
        val vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
        vibrator.vibrate(VibrationEffect.createOneShot(200, VibrationEffect.DEFAULT_AMPLITUDE))
    }
}
