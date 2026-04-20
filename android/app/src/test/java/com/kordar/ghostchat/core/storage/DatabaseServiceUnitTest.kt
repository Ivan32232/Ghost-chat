package com.kordar.ghostchat.core.storage

import com.google.common.truth.Truth.assertThat
import com.kordar.ghostchat.core.security.InMemoryKeystore
import org.junit.Test

/**
 * Unit-scope tests that don't require the SQLCipher native library.
 * Full round-trip (actual encryption) is covered by the androidTest on a real device/emulator.
 */
class DatabaseServiceUnitTest {

    @Test
    fun `ensureMasterKey generates 32 random bytes on first call`() {
        val store = InMemoryKeystore()
        val key = DatabaseService.ensureMasterKey(store)
        assertThat(key).hasLength(32)
    }

    @Test
    fun `ensureMasterKey returns identical bytes on subsequent calls`() {
        val store = InMemoryKeystore()
        val k1 = DatabaseService.ensureMasterKey(store)
        val k2 = DatabaseService.ensureMasterKey(store)
        assertThat(k2).isEqualTo(k1)
    }

    @Test
    fun `ensureMasterKey keys are unique across different keystores`() {
        val k1 = DatabaseService.ensureMasterKey(InMemoryKeystore())
        val k2 = DatabaseService.ensureMasterKey(InMemoryKeystore())
        assertThat(k1).isNotEqualTo(k2)
    }

    @Test
    fun `master key roundtrips through keystore storage`() {
        val store = InMemoryKeystore()
        val key = DatabaseService.ensureMasterKey(store)
        val fromStore = store.get("db.master.key")
        assertThat(fromStore).isEqualTo(key)
    }
}
