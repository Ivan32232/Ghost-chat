package com.kordar.ghostchat.features.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.kordar.ghostchat.core.managers.CallManager
import com.kordar.ghostchat.core.managers.ConnectionManager
import com.kordar.ghostchat.core.managers.ContactManager
import com.kordar.ghostchat.core.managers.MessageManager
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Thin orchestrator for the chat screen. Holds references to the four managers and
 * exposes the text draft — every business rule lives in a manager.
 *
 * Mirror of iOS ChatViewModel — required to stay ≤ 300 LOC.
 */
@HiltViewModel
class ChatViewModel @Inject constructor(
    val connection: ConnectionManager,
    val messages: MessageManager,
    val calls: CallManager,
    val contacts: ContactManager
) : ViewModel() {

    private val _draft = MutableStateFlow("")
    val draft: StateFlow<String> = _draft.asStateFlow()

    private var incomingJob: Job? = null

    fun start() {
        if (incomingJob != null) return
        incomingJob = viewModelScope.launch {
            connection.incomingText.collect { text -> messages.received(text) }
        }
    }

    fun stop() { incomingJob?.cancel(); incomingJob = null }

    fun updateDraft(value: String) { _draft.value = value }

    fun send() {
        val text = _draft.value.trim()
        if (text.isEmpty()) return
        val local = messages.send(text)
        _draft.value = ""
        viewModelScope.launch {
            runCatching { connection.sendText(text) }
                .onSuccess { messages.markDelivered(local.id) }
            // on failure we leave the message as pending — UI shows the state
        }
    }

    fun leave() {
        stop()
        connection.leave()
    }

    fun peerLabel(): String {
        val peer = connection.peerIdentity.value ?: return connection.roomId.value?.take(8)
            ?.let { "$it…" } ?: "Ghost Chat"
        val contact = contacts.contacts.value.firstOrNull {
            it.identityKey.contentEquals(peer)
        }
        return contact?.label ?: connection.roomId.value?.take(8)?.let { "$it…" } ?: "Ghost Chat"
    }

    fun startCall() {
        viewModelScope.launch { calls.startOutgoing(peerLabel()) }
    }

    override fun onCleared() {
        super.onCleared()
        stop()
    }
}
