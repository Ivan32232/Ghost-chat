package com.kordar.ghostchat.models

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RoomTest {
    @Test
    fun `valid id is accepted`() {
        val id = "A".repeat(64)
        assertTrue(Room.isValidId(id))
    }

    @Test
    fun `id with dashes and underscores is accepted`() {
        val id = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" +
            "".padEnd(0, '_')
        assertTrue(Room.isValidId(id))
    }

    @Test
    fun `too short id is rejected`() {
        assertFalse(Room.isValidId("A".repeat(10)))
    }

    @Test
    fun `too long id is rejected`() {
        assertFalse(Room.isValidId("A".repeat(65)))
    }

    @Test
    fun `non base64url character is rejected`() {
        val bad = ("A".repeat(63)) + "+" // '+' not in base64url
        assertFalse(Room.isValidId(bad))
    }
}
