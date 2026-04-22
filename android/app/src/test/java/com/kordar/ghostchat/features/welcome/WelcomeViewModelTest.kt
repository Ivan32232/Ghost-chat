package com.kordar.ghostchat.features.welcome

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import org.mockito.kotlin.mock

class WelcomeViewModelTest {

    @Test
    fun `extractRoomId handles raw id`() {
        val vm = WelcomeViewModel(mock(), mock(), mock())
        assertThat(vm.extractRoomId("A".repeat(64))).isEqualTo("A".repeat(64))
    }

    @Test
    fun `extractRoomId handles ghostchat scheme`() {
        val vm = WelcomeViewModel(mock(), mock(), mock())
        assertThat(vm.extractRoomId("ghostchat://room/ABC123"))
            .isEqualTo("ABC123")
    }

    @Test
    fun `extractRoomId handles https query param`() {
        val vm = WelcomeViewModel(mock(), mock(), mock())
        assertThat(vm.extractRoomId("https://ghostchat.one/?room=XYZ789"))
            .isEqualTo("XYZ789")
    }

    @Test
    fun `extractRoomId trims whitespace`() {
        val vm = WelcomeViewModel(mock(), mock(), mock())
        assertThat(vm.extractRoomId("  abc123  ")).isEqualTo("abc123")
    }
}
