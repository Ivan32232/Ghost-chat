package com.kordar.ghostchat.models

import com.google.common.truth.Truth.assertThat
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertThrows
import org.junit.Test

class ControlMessageTest {

    private val json = Json { encodeDefaults = false }

    @Test
    fun `encode call request`() {
        val encoded = ControlMessage.encode(ControlMessage.CallRequest)
        val obj = json.parseToJsonElement(encoded).jsonObject
        assertThat(obj["_ctrl"]?.jsonPrimitive?.content).isEqualTo("true")
        assertThat(obj["type"]?.jsonPrimitive?.content).isEqualTo("call-request")
    }

    @Test
    fun `roundtrip every variant`() {
        val samples: List<ControlMessage> = listOf(
            ControlMessage.Renegotiate(sdp = "v=0\r\no=- 1 1 IN IP4 0.0.0.0"),
            ControlMessage.CallRequest,
            ControlMessage.CallResponse(accepted = true),
            ControlMessage.CallResponse(accepted = false),
            ControlMessage.CallEnd,
            ControlMessage.SecurityAlert(alert = "screenshot"),
            ControlMessage.MessageAck(counter = 42L),
            ControlMessage.MessageRead(counter = 13L),
            ControlMessage.Ready,
            ControlMessage.PushToken(token = "abc123"),
            ControlMessage.NotifyToken(token = "def456"),
            ControlMessage.Typing(isTyping = true),
            ControlMessage.Capabilities(features = listOf("pq", "voice", "files")),
            ControlMessage.FileStart(
                fileId = "f1", name = "a.png", size = 1024,
                mimeType = "image/png", totalChunks = 10
            ),
            ControlMessage.FileChunk(fileId = "f1", index = 3, data = "AAAA"),
            ControlMessage.FileComplete(fileId = "f1", sha256 = "a".repeat(64)),
            ControlMessage.FileRetransmit(fileId = "f1", indices = listOf(2, 5, 7)),
            ControlMessage.MessageDelete(messageId = "msg1"),
            ControlMessage.MessageEdit(messageId = "msg1", newText = "hi"),
            ControlMessage.MessagePin(messageId = "msg1", pinned = true)
        )
        for (original in samples) {
            val encoded = ControlMessage.encode(original)
            val decoded = ControlMessage.decode(encoded)
            assertThat(decoded).isEqualTo(original)
        }
    }

    @Test
    fun `missing ctrl marker is rejected`() {
        val plain = """{"type":"ready"}"""
        assertThrows(ControlMessage.DecodingError.MissingCtrlMarker::class.java) {
            ControlMessage.decode(plain)
        }
    }

    @Test
    fun `unknown type is rejected`() {
        val bogus = """{"_ctrl":true,"type":"no-such-thing"}"""
        val err = assertThrows(ControlMessage.DecodingError.UnknownType::class.java) {
            ControlMessage.decode(bogus)
        }
        assertThat(err.type).isEqualTo("no-such-thing")
    }

    @Test
    fun `ios wire sample decodes`() {
        // Byte-for-byte example captured from iOS encoder (field order may differ, JSON is unordered).
        val iosSample = """{"_ctrl":true,"type":"message-pin","messageId":"abc","pinned":true}"""
        val m = ControlMessage.decode(iosSample) as ControlMessage.MessagePin
        assertThat(m.messageId).isEqualTo("abc")
        assertThat(m.pinned).isTrue()
    }

    @Test
    fun `fileComplete carries hex sha256`() {
        val hex = "deadbeefcafebabefeedfacec0ffee00112233445566778899aabbccddeeff00"
        val encoded = ControlMessage.encode(ControlMessage.FileComplete(fileId = "f", sha256 = hex))
        val obj = json.parseToJsonElement(encoded).jsonObject
        assertThat(obj["fileId"]?.jsonPrimitive?.content).isEqualTo("f")
        assertThat(obj["sha256"]?.jsonPrimitive?.content).isEqualTo(hex)
        val back = ControlMessage.decode(encoded) as ControlMessage.FileComplete
        assertThat(back.sha256).isEqualTo(hex)
    }

    @Test
    fun `ios fileComplete wire sample decodes`() {
        val iosSample = """{"_ctrl":true,"type":"file-complete","fileId":"f1","sha256":"cafe"}"""
        val m = ControlMessage.decode(iosSample) as ControlMessage.FileComplete
        assertThat(m.fileId).isEqualTo("f1")
        assertThat(m.sha256).isEqualTo("cafe")
    }
}
