package com.kordar.ghostchat.core.audio

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class SoundLibraryTest {
    @Test
    fun `enum values map to resource names matching Phase 7 assets`() {
        assertThat(SoundLibrary.Sound.Ringtone.resName).isEqualTo("ringtone")
        assertThat(SoundLibrary.Sound.IncomingMessage.resName).isEqualTo("message_in")
        assertThat(SoundLibrary.Sound.Sent.resName).isEqualTo("message_out")
        assertThat(SoundLibrary.Sound.Failed.resName).isEqualTo("failed")
    }
}
