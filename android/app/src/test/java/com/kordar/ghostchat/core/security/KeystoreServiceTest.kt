package com.kordar.ghostchat.core.security

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class InMemoryKeystoreTest {

    @Test
    fun `set and get returns identical bytes`() {
        val store = InMemoryKeystore()
        val data = byteArrayOf(1, 2, 3, 4)
        store.set("k", data)
        val back = store.get("k")
        assertThat(back).isEqualTo(data)
    }

    @Test
    fun `get returns null for missing key`() {
        val store = InMemoryKeystore()
        assertThat(store.get("missing")).isNull()
    }

    @Test
    fun `delete removes the entry`() {
        val store = InMemoryKeystore()
        store.set("k", byteArrayOf(7))
        store.delete("k")
        assertThat(store.get("k")).isNull()
    }

    @Test
    fun `deleteAll wipes everything`() {
        val store = InMemoryKeystore()
        store.set("a", byteArrayOf(1))
        store.set("b", byteArrayOf(2))
        store.deleteAll()
        assertThat(store.get("a")).isNull()
        assertThat(store.get("b")).isNull()
    }

    @Test
    fun `returned bytes are independent copies`() {
        val store = InMemoryKeystore()
        val data = byteArrayOf(1, 2, 3)
        store.set("k", data)
        data[0] = 99 // mutate the caller's copy after write
        val back = store.get("k")!!
        assertThat(back[0]).isEqualTo(1.toByte())
        back[1] = 77 // mutate the returned copy
        val again = store.get("k")!!
        assertThat(again[1]).isEqualTo(2.toByte())
    }
}
