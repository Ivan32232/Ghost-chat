package com.kordar.ghostchat.core.security

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SecurityMonitorTest {

    @Test
    fun `screenshot event is emitted`() = runTest(UnconfinedTestDispatcher()) {
        val monitor = SecurityMonitor()
        val collected = mutableListOf<SecurityMonitor.Event>()
        val job = launch {
            monitor.events.collect { collected += it }
        }
        monitor.notifyScreenshot()
        advanceUntilIdle()
        assertThat(collected).contains(SecurityMonitor.Event.Screenshot)
        job.cancel()
    }

    @Test
    fun `screen recording toggle is carried in event`() = runTest(UnconfinedTestDispatcher()) {
        val monitor = SecurityMonitor()
        val captured = CompletableDeferred<SecurityMonitor.Event>()
        val job = launch {
            captured.complete(monitor.events.first())
        }
        monitor.notifyScreenRecording(true)
        val event = captured.await()
        assertThat(event).isInstanceOf(SecurityMonitor.Event.ScreenRecording::class.java)
        assertThat((event as SecurityMonitor.Event.ScreenRecording).active).isTrue()
        job.cancel()
    }

    @Test
    fun `audio route event carries the output name`() = runTest(UnconfinedTestDispatcher()) {
        val monitor = SecurityMonitor()
        val captured = CompletableDeferred<SecurityMonitor.Event>()
        val job = launch {
            captured.complete(monitor.events.first())
        }
        monitor.notifyAudioRoute("Bluetooth Headset")
        val event = captured.await()
        assertThat(event).isInstanceOf(SecurityMonitor.Event.AudioRouteChanged::class.java)
        assertThat((event as SecurityMonitor.Event.AudioRouteChanged).output)
            .isEqualTo("Bluetooth Headset")
        job.cancel()
    }
}
