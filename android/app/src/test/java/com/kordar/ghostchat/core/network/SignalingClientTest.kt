package com.kordar.ghostchat.core.network

import com.kordar.ghostchat.models.Role
import okhttp3.OkHttpClient
import org.junit.Test

class SignalingClientTest {

    /**
     * Live-socket behaviour is covered by androidTest + real server integration.
     * Here we only verify outbound helpers do not throw before `connect()`.
     */
    @Test
    fun `outbound calls are no-op before connect`() {
        val client = SignalingClient(url = "ws://example.invalid/none", client = OkHttpClient())
        client.createRoom()
        client.leaveRoom()
        client.joinRoom("A".repeat(64))
        client.rejoinRoom("A".repeat(64), Role.HOST)
    }
}
