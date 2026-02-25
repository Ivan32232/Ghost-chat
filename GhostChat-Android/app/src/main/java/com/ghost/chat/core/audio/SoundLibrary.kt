package com.ghost.chat.core.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.VibrationEffect
import android.os.Vibrator

/// Sound library — port of iOS SoundLibrary
/// Uses system notification/ringtone sounds
object SoundLibrary {

    // Ringtone options (matching iOS names)
    val ringtones = listOf(
        "anticipate" to "Anticipate",
        "bloom" to "Bloom",
        "calypso" to "Calypso",
        "choo_choo" to "Choo Choo",
        "descent" to "Descent",
        "fanfare" to "Fanfare",
        "ladder" to "Ladder",
        "minuet" to "Minuet",
        "news_flash" to "News Flash",
        "noir" to "Noir",
        "sherwood" to "Sherwood",
        "spell" to "Spell",
        "suspense" to "Suspense",
        "telegraph" to "Telegraph",
        "tiptoes" to "Tiptoes",
        "typewriters" to "Typewriters",
        "update" to "Update"
    )

    // Message sound options
    val messageSounds = listOf(
        "none" to "None",
        "tock" to "Tock",
        "tink" to "Tink",
        "pop" to "Pop",
        "received" to "Received",
        "sent" to "Sent",
        "tweet" to "Tweet",
        "anticipate" to "Anticipate",
        "bloom" to "Bloom",
        "calypso" to "Calypso",
        "descent" to "Descent",
        "ladder" to "Ladder",
        "minuet" to "Minuet",
        "noir" to "Noir",
        "telegraph" to "Telegraph"
    )

    private var mediaPlayer: MediaPlayer? = null

    /** Play message notification sound */
    fun playMessageSound(context: Context, soundId: String, withVibration: Boolean = false) {
        if (soundId == "none") {
            if (withVibration) vibrate(context)
            return
        }

        try {
            // Use system notification sound as fallback
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            val player = MediaPlayer().apply {
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
        } catch (_: Exception) {
            // Fallback: just vibrate
            if (withVibration) vibrate(context)
        }
    }

    /** Play ringtone for incoming call */
    fun playRingtone(context: Context, ringtoneId: String) {
        try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            stopPreview()
            mediaPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setDataSource(context, uri)
                prepare()
                start()
                setOnCompletionListener { it.release() }
            }
        } catch (_: Exception) {}
    }

    /** Preview a sound (for sound picker) */
    fun previewSound(context: Context, soundId: String) {
        stopPreview()
        try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
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
        } catch (_: Exception) {}
    }

    fun stopPreview() {
        try {
            mediaPlayer?.stop()
            mediaPlayer?.release()
        } catch (_: Exception) {}
        mediaPlayer = null
    }

    private fun vibrate(context: Context) {
        val vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
        vibrator.vibrate(VibrationEffect.createOneShot(200, VibrationEffect.DEFAULT_AMPLITUDE))
    }
}
