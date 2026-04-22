package com.kordar.ghostchat.features.waiting

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.mockito.kotlin.mock

/**
 * State-only tests for [WaitingViewModel]. We don't exercise the clipboard
 * copy path here (that requires a real Android Context with CLIPBOARD_SERVICE,
 * which Robolectric offers but inflates the suite considerably for one thing);
 * the format + display-id helpers are what actually need cross-platform parity
 * with iOS.
 */
class WaitingViewModelTest {

    private lateinit var vm: WaitingViewModel

    @Before
    fun setup() {
        // Mocked Context: unused by display/share helpers.
        vm = WaitingViewModel(context = mock())
    }

    @Test
    fun `share URL is the ghostchat root with room query`() {
        assertEquals("https://ghostchat.one/?room=ABC123", vm.shareUrl("ABC123"))
    }

    @Test
    fun `share URL preserves base64url chars without encoding`() {
        // `-` and `_` are valid in base64url and RFC-3986 sub-delims.
        assertEquals("https://ghostchat.one/?room=a-b_c", vm.shareUrl("a-b_c"))
    }

    @Test
    fun `display id under 12 chars shows in full`() {
        assertEquals("abc", vm.displayId("abc"))
        assertEquals("1234567890", vm.displayId("1234567890"))
        assertEquals("123456789012", vm.displayId("123456789012"))
    }

    @Test
    fun `display id over 12 chars gets elided`() {
        assertEquals("12345678…abcd", vm.displayId("1234567890abcd"))
    }

    @Test
    fun `display id for 64-char base64url looks right`() {
        val id = "rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_"
        assertEquals(64, id.length)
        assertEquals("rBwU4hZ6…CD-_", vm.displayId(id))
    }

    @Test
    fun `copied feedback flag defaults to false`() {
        assertFalse(vm.copiedFeedbackVisible.value)
    }

    @Test
    fun `test hook flips copied flag`() {
        vm._test_markCopied()
        assertTrue(vm.copiedFeedbackVisible.value)
    }
}
