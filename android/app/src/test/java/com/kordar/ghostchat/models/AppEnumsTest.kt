package com.kordar.ghostchat.models

import org.junit.Assert.assertEquals
import org.junit.Test

class AppEnumsTest {
    @Test
    fun `role wire values match iOS`() {
        assertEquals("host", Role.HOST.wire)
        assertEquals("guest", Role.GUEST.wire)
    }

    @Test
    fun `sender raw values match iOS integer`() {
        assertEquals(0, Sender.ME.raw)
        assertEquals(1, Sender.PEER.raw)
        assertEquals(2, Sender.SYSTEM.raw)
    }

    @Test
    fun `message type raw values match iOS integer`() {
        assertEquals(0, MessageType.TEXT.raw)
        assertEquals(1, MessageType.FILE.raw)
        assertEquals(2, MessageType.VOICE.raw)
        assertEquals(3, MessageType.SYSTEM.raw)
    }

    @Test
    fun `message ttl defaults to five minutes`() {
        assertEquals(MessageTTL.FIVE_MINUTES, MessageTTL.fromSeconds(300))
        assertEquals(MessageTTL.FIVE_MINUTES, MessageTTL.fromSeconds(-1)) // fallback
    }

    @Test
    fun `auto lock defaults to one minute`() {
        assertEquals(AutoLockTimeout.ONE_MINUTE, AutoLockTimeout.fromSeconds(60))
        assertEquals(AutoLockTimeout.ONE_MINUTE, AutoLockTimeout.fromSeconds(9999))
    }

    @Test
    fun `connection state wire parity`() {
        assertEquals(ConnectionState.ENCRYPTED, ConnectionState.fromWire("encrypted"))
        assertEquals(ConnectionState.WEB_RTC,   ConnectionState.fromWire("webRTC"))
    }

    @Test
    fun `call state wire parity`() {
        assertEquals(CallState.OUTGOING_PENDING, CallState.fromWire("outgoingPending"))
        assertEquals(CallState.OUTGOING_RINGING, CallState.fromWire("outgoingRinging"))
        assertEquals(CallState.INCOMING, CallState.fromWire("incoming"))
        assertEquals(CallState.ACTIVE, CallState.fromWire("active"))
    }
}
