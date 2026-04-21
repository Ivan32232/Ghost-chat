package com.kordar.ghostchat.core.managers

import com.google.common.truth.Truth.assertThat
import com.kordar.ghostchat.models.MessageTTL
import com.kordar.ghostchat.models.Sender
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class MessageManagerTest {

    @Test
    fun `send adds a pending message`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val mgr = MessageManager(
            store = null,
            defaultTtlSeconds = 1000L,
            scope = CoroutineScope(dispatcher)
        )
        val m = mgr.send("hello")
        assertThat(m.sender).isEqualTo(Sender.ME)
        assertThat(m.isPending).isTrue()
        assertThat(mgr.messages.value).hasSize(1)
    }

    @Test
    fun `received marks delivered`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val mgr = MessageManager(
            store = null,
            defaultTtlSeconds = 1000L,
            scope = CoroutineScope(dispatcher)
        )
        val m = mgr.received("ping")
        assertThat(m.isDelivered).isTrue()
        assertThat(m.isPending).isFalse()
    }

    @Test
    fun `messages auto-delete after TTL`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val mgr = MessageManager(
            store = null,
            defaultTtlSeconds = 1L,
            scope = CoroutineScope(dispatcher)
        )
        mgr.send("transient")
        assertThat(mgr.messages.value).hasSize(1)
        advanceTimeBy(1100L)
        assertThat(mgr.messages.value).isEmpty()
    }

    @Test
    fun `setTtl changes default`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val mgr = MessageManager(
            store = null,
            defaultTtlSeconds = 1000L,
            scope = CoroutineScope(dispatcher)
        )
        mgr.setTtl(MessageTTL.ONE_HOUR) // 3600 seconds
        mgr.send("persistent")
        advanceTimeBy(2000L)
        assertThat(mgr.messages.value).hasSize(1) // should not have expired
    }
}
