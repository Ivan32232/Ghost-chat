package com.kordar.ghostchat.core.audio

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.File
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

/**
 * Records voice messages as AAC m4a — 44.1 kHz mono, 64 kbps.
 * Amplitude samples at 50 ms intervals feed the waveform UI.
 *
 * Mirror of iOS `VoiceRecorder`. Phase 4 scaffolds the recorder; transport over
 * DataChannel lands in Phase 5.
 */
class VoiceRecorder(private val context: Context) {

    sealed class Error(message: String) : RuntimeException(message) {
        data object NotRecording     : Error("not recording")
        data object AlreadyRecording : Error("already recording")
        data object TooShort         : Error("recording too short")
    }

    data class Result(
        val data: ByteArray,
        val durationMs: Long,
        val amplitudes: List<Float>
    )

    companion object {
        const val MIN_DURATION_MS: Long = 300L
        const val SAMPLE_RATE: Int = 44_100
        const val BIT_RATE: Int = 64_000
    }

    private var recorder: MediaRecorder? = null
    private var fileUri: File? = null
    private var startAtEpochMs: Long = 0L
    private val amplitudes = mutableListOf<Float>()
    private val meterHandler = Handler(Looper.getMainLooper())
    private val meterTick = object : Runnable {
        override fun run() {
            val rec = recorder ?: return
            val raw = try { rec.maxAmplitude } catch (_: IllegalStateException) { 0 }
            // Normalise roughly: max amplitude for 16-bit PCM is 32767.
            val normalised = min(1f, max(0f, raw.toFloat() / 32_767f))
            amplitudes += normalised
            meterHandler.postDelayed(this, 50)
        }
    }

    val isRecording: Boolean get() = recorder != null

    fun start() {
        if (recorder != null) throw Error.AlreadyRecording
        val outFile = File(context.cacheDir, "voice-${UUID.randomUUID()}.m4a")
        fileUri = outFile
        val rec = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(context)
                  else @Suppress("DEPRECATION") MediaRecorder()
        rec.setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
        rec.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        rec.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        rec.setAudioChannels(1)
        rec.setAudioSamplingRate(SAMPLE_RATE)
        rec.setAudioEncodingBitRate(BIT_RATE)
        rec.setOutputFile(outFile.absolutePath)
        rec.prepare()
        rec.start()
        recorder = rec
        startAtEpochMs = System.currentTimeMillis()
        amplitudes.clear()
        meterHandler.post(meterTick)
    }

    fun stop(): Result {
        val rec = recorder ?: throw Error.NotRecording
        meterHandler.removeCallbacks(meterTick)
        val duration = System.currentTimeMillis() - startAtEpochMs
        try { rec.stop() } catch (_: Throwable) {}
        rec.release()
        recorder = null
        val file = fileUri; fileUri = null
        startAtEpochMs = 0L
        val bytes = file?.readBytes() ?: throw Error.NotRecording
        file.delete()
        if (duration < MIN_DURATION_MS) throw Error.TooShort
        return Result(data = bytes, durationMs = duration, amplitudes = amplitudes.toList())
    }

    fun cancel() {
        meterHandler.removeCallbacks(meterTick)
        try { recorder?.stop() } catch (_: Throwable) {}
        recorder?.release()
        recorder = null
        fileUri?.delete()
        fileUri = null
        startAtEpochMs = 0L
        amplitudes.clear()
    }
}
