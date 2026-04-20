package com.kordar.ghostchat.core.security

import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * Publishes security-relevant events to any observer.
 *
 * Mirror of iOS `SecurityMonitor` — identical enum shape so the receiving code can be
 * written once. On Android, FLAG_SECURE is applied at the Activity level (see
 * `MainActivity.kt`) which prevents screenshots entirely; we still emit explicit
 * events so the peer can be warned of audio route changes and screen recording
 * starts (Android 14+).
 */
class SecurityMonitor {

    sealed class Event {
        data object Screenshot : Event()
        data class ScreenRecording(val active: Boolean) : Event()
        data class AudioRouteChanged(val output: String) : Event()
    }

    private val _events = MutableSharedFlow<Event>(
        extraBufferCapacity = 16,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val events: SharedFlow<Event> = _events.asSharedFlow()

    fun notifyScreenshot() { _events.tryEmit(Event.Screenshot) }
    fun notifyScreenRecording(active: Boolean) { _events.tryEmit(Event.ScreenRecording(active)) }
    fun notifyAudioRoute(output: String) { _events.tryEmit(Event.AudioRouteChanged(output)) }
}
