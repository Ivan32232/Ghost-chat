package com.kordar.ghostchat.core.audio

import android.content.Context
import android.media.MediaPlayer

/**
 * Plays short in-app sound effects. Assets live in `res/raw/` (ringtone.ogg etc.).
 * Missing files are logged-and-ignored — Phase 4 ships without assets committed
 * (placeholders in Phase 7).
 *
 * Mirror of iOS `SoundLibrary`.
 */
class SoundLibrary(
    private val context: Context,
    private val muted: () -> Boolean = { false }
) {
    enum class Sound(val resName: String) {
        Ringtone("ringtone"),
        IncomingMessage("message_in"),
        Sent("message_out"),
        Failed("failed")
    }

    private val players = mutableMapOf<Sound, MediaPlayer>()

    fun play(sound: Sound, loop: Boolean = false) {
        if (muted()) return
        val player = obtain(sound) ?: return
        player.isLooping = loop
        try {
            player.seekTo(0)
            player.start()
        } catch (_: IllegalStateException) {
            // Missing/broken file — silent no-op.
        }
    }

    fun stop(sound: Sound) {
        players[sound]?.takeIf { it.isPlaying }?.pause()
    }

    fun stopAll() {
        players.values.forEach { p -> if (p.isPlaying) p.pause() }
    }

    fun release() {
        players.values.forEach { it.release() }
        players.clear()
    }

    private fun obtain(sound: Sound): MediaPlayer? {
        players[sound]?.let { return it }
        val resId = context.resources.getIdentifier(sound.resName, "raw", context.packageName)
        if (resId == 0) return null
        return try {
            val p = MediaPlayer.create(context, resId) ?: return null
            players[sound] = p
            p
        } catch (_: Throwable) {
            null
        }
    }
}
