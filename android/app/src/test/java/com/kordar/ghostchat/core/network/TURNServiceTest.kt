package com.kordar.ghostchat.core.network

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Before
import org.junit.Test

class TURNServiceTest {

    private lateinit var server: MockWebServer

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @After
    fun tearDown() { server.shutdown() }

    @Test
    fun `fetchCredentials parses server response`() = runTest {
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setBody(
                    """
                    {"username":"1735000000:abc",
                     "credential":"iGJb...=",
                     "urls":["turn:ghostchat.one:443?transport=tcp"],
                     "ttl":3600,
                     "pushAuth":"deadbeef"}
                    """.trimIndent()
                )
        )
        val svc = TURNService(server.url("/").toString().trimEnd('/'), OkHttpClient())
        val creds = svc.fetchCredentials()
        assertThat(creds.username).isEqualTo("1735000000:abc")
        assertThat(creds.credential).isEqualTo("iGJb...=")
        assertThat(creds.urls).containsExactly("turn:ghostchat.one:443?transport=tcp")
        assertThat(creds.ttl).isEqualTo(3600)
        assertThat(creds.pushAuth).isEqualTo("deadbeef")
        assertThat(creds.isExpired(nowEpochMs = creds.fetchedAtEpochMs)).isFalse()
    }

    @Test
    fun `HTTP 500 throws HttpStatus error`() = runTest {
        server.enqueue(MockResponse().setResponseCode(500))
        val svc = TURNService(server.url("/").toString().trimEnd('/'), OkHttpClient())
        val err = runCatching { svc.fetchCredentials() }.exceptionOrNull()
        assertThat(err).isInstanceOf(TURNService.Error.HttpStatus::class.java)
        assertThat((err as TURNService.Error.HttpStatus).code).isEqualTo(500)
    }

    @Test
    fun `missing required field throws MalformedResponse`() = runTest {
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"foo":"bar"}"""))
        val svc = TURNService(server.url("/").toString().trimEnd('/'), OkHttpClient())
        val err = runCatching { svc.fetchCredentials() }.exceptionOrNull()
        assertThat(err).isInstanceOf(TURNService.Error.MalformedResponse::class.java)
    }

    @Test
    fun `isExpired is false when recent`() {
        val creds = TURNCredentials("u", "c", listOf("turn:..."), 3600, null)
        assertThat(creds.isExpired(nowEpochMs = creds.fetchedAtEpochMs + 60 * 1000)).isFalse()
    }

    @Test
    fun `isExpired is true once beyond ttl minus skew`() {
        val creds = TURNCredentials("u", "c", listOf("turn:..."), 3600, null)
        val beyond = creds.fetchedAtEpochMs + (3600 - 299).toLong() * 1000 + 1
        assertThat(creds.isExpired(nowEpochMs = beyond)).isTrue()
    }
}
