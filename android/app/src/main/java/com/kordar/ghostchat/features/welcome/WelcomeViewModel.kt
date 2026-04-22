package com.kordar.ghostchat.features.welcome

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.kordar.ghostchat.core.managers.ConnectionManager
import com.kordar.ghostchat.core.managers.ContactManager
import com.kordar.ghostchat.core.managers.DeepLinkRouter
import com.kordar.ghostchat.models.Room
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.delay
import javax.inject.Inject
import java.net.URI

@HiltViewModel
class WelcomeViewModel @Inject constructor(
    val connection: ConnectionManager,
    val contacts: ContactManager,
    val deepLink: DeepLinkRouter
) : ViewModel() {

    /** What navigation target, if any, the UI should jump to. */
    sealed interface Target {
        data class Waiting(val roomId: String) : Target
        data object Connecting : Target
    }

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _target = MutableStateFlow<Target?>(null)
    val target: StateFlow<Target?> = _target.asStateFlow()

    private val _isBusy = MutableStateFlow(false)
    val isBusy: StateFlow<Boolean> = _isBusy.asStateFlow()

    init {
        contacts.refresh()
    }

    fun createRoom() {
        if (_isBusy.value) return
        _isBusy.value = true
        viewModelScope.launch {
            val outcome = runCatching { connection.createRoom() }
            if (outcome.isFailure) {
                _isBusy.value = false
                _error.value = outcome.exceptionOrNull()?.localizedMessage ?: "Failed to create room"
                return@launch
            }
            // Wait for the server's roomCreated event to populate connection.roomId.
            val roomId = withTimeoutOrNull(ROOM_ID_TIMEOUT_MS) {
                while (connection.roomId.value == null) delay(50)
                connection.roomId.value
            }
            _isBusy.value = false
            if (roomId != null) {
                _target.value = Target.Waiting(roomId)
            } else {
                connection.leave()
                _error.value = "Room creation timed out"
            }
        }
    }

    fun joinRoom(rawInput: String) {
        if (_isBusy.value) return
        val id = extractRoomId(rawInput)
        if (!Room.isValidId(id)) {
            _error.value = "Invalid room link"
            return
        }
        startJoin(id)
    }

    /**
     * Triggered by the user confirming the deep-link alert. Behaves the same
     * as a manual join — push ConnectingScreen, kick off the network.
     */
    fun confirmDeepLink(roomId: String) {
        deepLink.clear()
        if (!Room.isValidId(roomId)) {
            _error.value = "Invalid room link"
            return
        }
        startJoin(roomId)
    }

    fun cancelDeepLink() {
        deepLink.clear()
    }

    private fun startJoin(id: String) {
        _isBusy.value = true
        _target.value = Target.Connecting
        viewModelScope.launch {
            runCatching { connection.joinRoom(id) }
                .onFailure {
                    _target.value = null
                    _error.value = it.localizedMessage ?: "Failed to join room"
                }
            _isBusy.value = false
        }
    }

    fun clearError() { _error.value = null }
    fun clearTarget() { _target.value = null }

    /**
     * Accepts: raw id, `ghostchat://room/<id>`, `ghostchat://?room=<id>`,
     * `https://ghostchat.one/?room=<id>`.
     */
    internal fun extractRoomId(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.startsWith("ghostchat://room/")) {
            return trimmed.removePrefix("ghostchat://room/")
        }
        return runCatching {
            val uri = URI(trimmed)
            val query = uri.rawQuery ?: return@runCatching trimmed
            query.split("&")
                .firstOrNull { it.startsWith("room=") }
                ?.removePrefix("room=")
                ?: trimmed
        }.getOrDefault(trimmed)
    }

    companion object {
        private const val ROOM_ID_TIMEOUT_MS = 10_000L
    }
}
