package com.kordar.ghostchat.models

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class ContactTest {
    @Test
    fun `default TTL is five minutes`() {
        val c = Contact(
            label = "Alice",
            identityKey = ByteArray(65),
            publicKey = ByteArray(65)
        )
        assertThat(c.messageTTL).isEqualTo(300)
    }

    @Test
    fun `equality is by id only`() {
        val a = Contact(id = "same", label = "A", identityKey = ByteArray(1), publicKey = ByteArray(1))
        val b = Contact(id = "same", label = "B", identityKey = ByteArray(2), publicKey = ByteArray(2))
        assertThat(a).isEqualTo(b)
    }

    @Test
    fun `inequality different id`() {
        val a = Contact(id = "1", label = "A", identityKey = ByteArray(1), publicKey = ByteArray(1))
        val b = Contact(id = "2", label = "A", identityKey = ByteArray(1), publicKey = ByteArray(1))
        assertThat(a).isNotEqualTo(b)
    }
}
