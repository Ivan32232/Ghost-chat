package com.kordar.ghostchat.core.audio

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class VoiceRecorderTest {

    @Test
    fun `constants match iOS VoiceRecorder`() {
        assertThat(VoiceRecorder.MIN_DURATION_MS).isEqualTo(300L)  // 0.3s
        assertThat(VoiceRecorder.SAMPLE_RATE).isEqualTo(44_100)
        assertThat(VoiceRecorder.BIT_RATE).isEqualTo(64_000)
    }
}
