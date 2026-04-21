package com.kordar.ghostchat.core.localization

import com.google.common.truth.Truth.assertThat
import com.kordar.ghostchat.core.security.InMemoryKeystore
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.util.Locale

@RunWith(RobolectricTestRunner::class)
class LocalizationManagerTest {

    @Test
    fun `supports exactly two locales`() {
        assertThat(LocalizationManager.SUPPORTED.map { it.language })
            .containsExactly("en", "ru")
    }

    @Test
    fun `setOverride persists locale in keystore`() {
        val store = InMemoryKeystore()
        val mgr = LocalizationManager(RuntimeEnvironment.getApplication(), store)
        mgr.setOverride(Locale("ru"))
        assertThat(mgr.locale.language).isEqualTo("ru")
        val raw = store.get(LocalizationManager.KEYSTORE_KEY)
        assertThat(raw).isNotNull()
        assertThat(String(raw!!, Charsets.UTF_8)).isEqualTo("ru")
    }

    @Test
    fun `clearOverride removes stored locale`() {
        val store = InMemoryKeystore()
        val mgr = LocalizationManager(RuntimeEnvironment.getApplication(), store)
        mgr.setOverride(Locale("ru"))
        mgr.clearOverride()
        assertThat(store.get(LocalizationManager.KEYSTORE_KEY)).isNull()
    }

    @Test
    fun `unsupported locale is rejected`() {
        val store = InMemoryKeystore()
        val mgr = LocalizationManager(RuntimeEnvironment.getApplication(), store)
        val before = mgr.locale
        mgr.setOverride(Locale("es"))
        assertThat(mgr.locale).isEqualTo(before)
        assertThat(store.get(LocalizationManager.KEYSTORE_KEY)).isNull()
    }

    @Test
    fun `resolves stored override on construction`() {
        val store = InMemoryKeystore()
        store.set(LocalizationManager.KEYSTORE_KEY, "ru".toByteArray(Charsets.UTF_8))
        val mgr = LocalizationManager(RuntimeEnvironment.getApplication(), store)
        assertThat(mgr.locale.language).isEqualTo("ru")
    }
}
