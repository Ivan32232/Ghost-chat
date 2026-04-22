package com.kordar.ghostchat.core.managers

import android.net.Uri
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Parser tests for [DeepLinkRouter]. We use Robolectric because Android's
 * [Uri] parser is not on the JVM classpath in plain unit tests.
 */
@RunWith(RobolectricTestRunner::class)
class DeepLinkRouterTest {

    private val goodId = "rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_"

    @Test
    fun `parses ghostchat scheme query form`() {
        assertEquals(goodId, DeepLinkRouter.parse(Uri.parse("ghostchat://?room=$goodId")))
    }

    @Test
    fun `parses ghostchat legacy path form`() {
        assertEquals(goodId, DeepLinkRouter.parse(Uri.parse("ghostchat://room/$goodId")))
    }

    @Test
    fun `parses universal https link`() {
        assertEquals(goodId, DeepLinkRouter.parse(Uri.parse("https://ghostchat.one/?room=$goodId")))
    }

    @Test
    fun `parses www subdomain universal link`() {
        assertEquals(goodId, DeepLinkRouter.parse(Uri.parse("https://www.ghostchat.one/?room=$goodId")))
    }

    @Test
    fun `rejects missing room param`() {
        assertNull(DeepLinkRouter.parse(Uri.parse("ghostchat://")))
        assertNull(DeepLinkRouter.parse(Uri.parse("https://ghostchat.one/")))
    }

    @Test
    fun `rejects empty room param`() {
        assertNull(DeepLinkRouter.parse(Uri.parse("https://ghostchat.one/?room=")))
    }

    @Test
    fun `rejects short room id`() {
        assertNull(DeepLinkRouter.parse(Uri.parse("ghostchat://?room=abc")))
    }

    @Test
    fun `rejects foreign host universal link`() {
        assertNull(DeepLinkRouter.parse(Uri.parse("https://evil.example.com/?room=$goodId")))
    }

    @Test
    fun `rejects unknown scheme`() {
        assertNull(DeepLinkRouter.parse(Uri.parse("file:///tmp/?room=$goodId")))
    }

    // --- Router instance --------------------------------------------------

    @Test
    fun `submit stores parsed room id`() {
        val router = DeepLinkRouter()
        router.submit(Uri.parse("https://ghostchat.one/?room=$goodId"))
        assertEquals(goodId, router.pendingRoomId.value)
    }

    @Test
    fun `submit with invalid uri does not overwrite pending`() {
        val router = DeepLinkRouter()
        router.submit(Uri.parse("https://ghostchat.one/?room=$goodId"))
        router.submit(Uri.parse("https://evil.example.com/?room=$goodId"))
        assertEquals(goodId, router.pendingRoomId.value)
    }

    @Test
    fun `clear nils pending`() {
        val router = DeepLinkRouter()
        router.submit(Uri.parse("https://ghostchat.one/?room=$goodId"))
        router.clear()
        assertNull(router.pendingRoomId.value)
    }
}
