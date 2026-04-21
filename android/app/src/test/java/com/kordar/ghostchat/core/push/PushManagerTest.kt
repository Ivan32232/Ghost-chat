package com.kordar.ghostchat.core.push

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Before
import org.junit.Test

class PushManagerTest {

    private lateinit var server: MockWebServer
    private lateinit var pm: PushManager

    @Before
    fun setUp() {
        server = MockWebServer().apply { start() }
        pm = PushManager(
            baseUrl = server.url("/").toString().trimEnd('/'),
            client = OkHttpClient()
        )
        pm.pushAuth = "test-hmac"
    }

    @After
    fun tearDown() { server.shutdown() }

    @Test
    fun `sendFCMCall posts correct payload`() = runTest {
        server.enqueue(MockResponse().setResponseCode(200))
        pm.sendFCMCall(token = "abc", roomId = "R1", callerName = "Alice")
        val req: RecordedRequest = server.takeRequest()
        assertThat(req.path).isEqualTo("/api/send-push-android")
        val body = req.body.readUtf8()
        assertThat(body).contains("\"token\":\"abc\"")
        assertThat(body).contains("\"roomId\":\"R1\"")
        assertThat(body).contains("\"callerName\":\"Alice\"")
        assertThat(body).contains("\"auth\":\"test-hmac\"")
    }

    @Test
    fun `sendInvite posts correct payload`() = runTest {
        server.enqueue(MockResponse().setResponseCode(200))
        pm.sendInvite(token = "tok", platform = "android", roomId = "R2", inviterName = "Bob")
        val req = server.takeRequest()
        assertThat(req.path).isEqualTo("/api/send-invite")
        val body = req.body.readUtf8()
        assertThat(body).contains("\"platform\":\"android\"")
        assertThat(body).contains("\"inviterName\":\"Bob\"")
    }

    @Test
    fun `sendNotify posts correct payload`() = runTest {
        server.enqueue(MockResponse().setResponseCode(200))
        pm.sendNotify(token = "tok", platform = "android", senderName = "Carol", type = "message")
        val req = server.takeRequest()
        assertThat(req.path).isEqualTo("/api/push/notify")
        val body = req.body.readUtf8()
        assertThat(body).contains("\"senderName\":\"Carol\"")
        assertThat(body).contains("\"type\":\"message\"")
    }

    @Test
    fun `non-2xx response is raised as HttpStatus`() = runTest {
        server.enqueue(MockResponse().setResponseCode(503))
        val err = runCatching {
            pm.sendFCMCall(token = "abc", roomId = "r", callerName = "n")
        }.exceptionOrNull()
        assertThat(err).isInstanceOf(PushManager.Error.HttpStatus::class.java)
        assertThat((err as PushManager.Error.HttpStatus).code).isEqualTo(503)
    }

    @Test
    fun `onNewFCMToken updates token and emits event`() = runTest {
        pm.onNewFCMToken("newtoken")
        assertThat(pm.fcmToken).isEqualTo("newtoken")
    }
}
