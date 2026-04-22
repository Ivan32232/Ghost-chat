package com.kordar.ghostchat.features.welcome

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.kordar.ghostchat.core.managers.ConnectionManager
import com.kordar.ghostchat.core.managers.ContactManager
import com.kordar.ghostchat.models.Room
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject
import java.net.URI

@HiltViewModel
class WelcomeViewModel @Inject constructor(
    val connection: ConnectionManager,
    val contacts: ContactManager
) : ViewModel() {

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _navigateToChat = MutableStateFlow(false)
    val navigateToChat: StateFlow<Boolean> = _navigateToChat.asStateFlow()

    /** True while a create / join request is in-flight — gate for the Welcome button. */
    private val _isBusy = MutableStateFlow(false)
    val isBusy: StateFlow<Boolean> = _isBusy.asStateFlow()

    init {
        contacts.refresh()
    }

    fun createRoom() {
        if (_isBusy.value) return
        _isBusy.value = true
        // Navigate immediately — ChatScreen's StatusBanner handles the "waiting" visual.
        _navigateToChat.value = true
        viewModelScope.launch {
            runCatching { connection.createRoom() }
                .onFailure {
                    _navigateToChat.value = false
                    _error.value = it.localizedMessage ?: "Failed to create room"
                }
            _isBusy.value = false
        }
    }

    fun joinRoom(rawInput: String) {
        if (_isBusy.value) return
        val id = extractRoomId(rawInput)
        if (!Room.isValidId(id)) {
            _error.value = "Invalid room link"
            return
        }
        _isBusy.value = true
        _navigateToChat.value = true
        viewModelScope.launch {
            runCatching { connection.joinRoom(id) }
                .onFailure {
                    _navigateToChat.value = false
                    _error.value = it.localizedMessage ?: "Failed to join room"
                }
            _isBusy.value = false
        }
    }

    fun clearError() { _error.value = null }
    fun clearNavigation() { _navigateToChat.value = false }

    /**
     * Mirror of iOS extractRoomID: accept raw room ID, `ghostchat://room/XXX`,
     * or `https://ghostchat.one/?room=XXX`.
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
}
