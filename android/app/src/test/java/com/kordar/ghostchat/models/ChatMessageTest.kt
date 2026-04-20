package com.kordar.ghostchat.models

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class ChatMessageTest {
    @Test
    fun `defaults are sane`() {
        val m = ChatMessage(sender = Sender.ME, text = "hello")
        assertThat(m.type).isEqualTo(MessageType.TEXT)
        assertThat(m.isDelivered).isFalse()
        assertThat(m.isPending).isTrue()
        assertThat(m.id).isNotEmpty()
    }

    @Test
    fun `reply payload roundtrips via WirePayload`() {
        val reply = ChatMessage.WirePayload.Reply(id = "r1", t = "prev")
        val payload = ChatMessage.WirePayload(m = "hi", t = 1_700_000_000_000L, c = 5L, id = "id1", r = reply)
        assertThat(payload.r).isEqualTo(reply)
    }
}
