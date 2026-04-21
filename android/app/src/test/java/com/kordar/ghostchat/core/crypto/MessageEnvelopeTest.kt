package com.kordar.ghostchat.core.crypto

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class MessageEnvelopeTest {

    @Test
    fun `encode sorted keys exact JSON`() {
        val env = MessageEnvelope(m = "hello", t = 1_713_100_800_000L, c = 7L, id = "env-1")
        assertThat(MessageEnvelope.encode(env))
            .isEqualTo("""{"c":7,"id":"env-1","m":"hello","t":1713100800000}""")
    }

    @Test
    fun `decode roundtrip`() {
        val env = MessageEnvelope.decode("""{"m":"hi","t":1000,"c":0,"id":"x"}""")
        assertThat(env.m).isEqualTo("hi")
        assertThat(env.t).isEqualTo(1000L)
        assertThat(env.c).isEqualTo(0L)
        assertThat(env.id).isEqualTo("x")
    }

    @Test
    fun `matches cross-platform vector`() {
        // Mirror of docs/test-vectors.json > messageEnvelope — byte-identical iOS vs Android.
        val env = MessageEnvelope(m = "hello", t = 1_713_100_800_000L, c = 7L, id = "env-1")
        assertThat(MessageEnvelope.encode(env))
            .isEqualTo("""{"c":7,"id":"env-1","m":"hello","t":1713100800000}""")
    }

    @Test
    fun `encode then decode roundtrip with all fields`() {
        val env = MessageEnvelope(m = "complex \"quoted\" msg", t = 42L, c = 9_000_000L, id = "uuid-1")
        val decoded = MessageEnvelope.decode(MessageEnvelope.encode(env))
        assertThat(decoded).isEqualTo(env)
    }
}
