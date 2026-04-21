package com.kordar.ghostchat.core.managers

import com.kordar.ghostchat.core.audio.SoundLibrary
import com.kordar.ghostchat.core.storage.MessageStore
import com.kordar.ghostchat.models.ChatMessage
import com.kordar.ghostchat.models.MessageTTL
import com.kordar.ghostchat.models.MessageType
import com.kordar.ghostchat.models.Sender
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Sole owner of the in-memory message list. Auto-delete per-message TTL. Persistence
 * (saved contacts) goes through the injected [MessageStore]. Mirror of iOS `MessageManager`.
 */
class MessageManager(
    private val store: MessageStore?,
    defaultTtlSeconds: Long = MessageTTL.FIVE_MINUTES.seconds.toLong(),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
) {

    /** Optional sound-cue dispatcher. Wired through CoreModule; nil in headless test fixtures. */
    var sounds: SoundLibrary? = null

    private val _messages = MutableStateFlow<List<ChatMessage>>(emptyList())
    val messages: StateFlow<List<ChatMessage>> = _messages.asStateFlow()

    private var defaultTtl: Long = defaultTtlSeconds
    private val deleteJobs = mutableMapOf<String, Job>()
    var activeContactId: String? = null
        set(value) {
            field = value
            reloadForActiveContact()
        }

    fun send(text: String): ChatMessage {
        val m = ChatMessage(
            contactId = activeContactId ?: "",
            sender = Sender.ME,
            text = text,
            isDelivered = false,
            isPending = true
        )
        val final = finalize(m, defaultTtl)
        sounds?.play(SoundLibrary.Sound.Sent)
        return final
    }

    fun received(text: String, senderMessageId: String? = null): ChatMessage {
        val m = ChatMessage(
            contactId = activeContactId ?: "",
            sender = Sender.PEER,
            text = text,
            isDelivered = true,
            isPending = false,
            senderMessageId = senderMessageId
        )
        val final = finalize(m, defaultTtl)
        sounds?.play(SoundLibrary.Sound.IncomingMessage)
        return final
    }

    /** Create a local "sending…" bubble for an outgoing attachment. */
    fun sendFile(
        fileId: String,
        name: String,
        size: Int,
        mimeType: String,
        localPath: String?
    ): ChatMessage {
        val type = if (mimeType == "audio/mp4" && name.startsWith("voice-"))
            MessageType.VOICE else MessageType.FILE
        val m = ChatMessage(
            contactId = activeContactId ?: "",
            sender = Sender.ME,
            text = "",
            type = type,
            isDelivered = false,
            isPending = true,
            fileName = name,
            fileSize = size,
            fileMimeType = mimeType,
            fileLocalPath = localPath,
            fileId = fileId
        )
        return finalize(m, defaultTtl)
    }

    /** Record an incoming attachment once the chunked transfer assembles. */
    fun receivedFile(
        fileId: String,
        name: String,
        size: Int,
        mimeType: String,
        localPath: String?
    ): ChatMessage {
        val type = if (mimeType == "audio/mp4" && name.startsWith("voice-"))
            MessageType.VOICE else MessageType.FILE
        val m = ChatMessage(
            contactId = activeContactId ?: "",
            sender = Sender.PEER,
            text = "",
            type = type,
            isDelivered = true,
            isPending = false,
            fileName = name,
            fileSize = size,
            fileMimeType = mimeType,
            fileLocalPath = localPath,
            fileId = fileId
        )
        return finalize(m, defaultTtl)
    }

    fun system(text: String) {
        finalize(
            ChatMessage(
                contactId = activeContactId ?: "",
                sender = Sender.SYSTEM,
                text = text,
                type = MessageType.SYSTEM
            ),
            defaultTtl
        )
    }

    fun markDelivered(id: String) = update(id) { it.copy(isDelivered = true, isPending = false) }
    fun markPinned(id: String, pinned: Boolean) = update(id) { it.copy(isPinned = pinned) }

    fun remove(id: String) {
        deleteJobs.remove(id)?.cancel()
        _messages.value = _messages.value.filterNot { it.id == id }
        val contactId = activeContactId
        if (!contactId.isNullOrEmpty()) store?.deleteMessage(id)
    }

    fun setTtl(ttl: MessageTTL) { defaultTtl = ttl.seconds.toLong() }

    // MARK: - Private

    private fun finalize(message: ChatMessage, ttlSeconds: Long): ChatMessage {
        _messages.value = _messages.value + message
        val contactId = activeContactId
        if (!contactId.isNullOrEmpty() && message.contactId == contactId) {
            store?.append(message)
        }
        scheduleDelete(message.id, ttlSeconds)
        return message
    }

    private fun scheduleDelete(id: String, ttlSeconds: Long) {
        deleteJobs[id] = scope.launch {
            delay(ttlSeconds * 1000)
            remove(id)
        }
    }

    private fun update(id: String, mutator: (ChatMessage) -> ChatMessage) {
        _messages.value = _messages.value.map { if (it.id == id) mutator(it) else it }
    }

    private fun reloadForActiveContact() {
        deleteJobs.values.forEach { it.cancel() }
        deleteJobs.clear()
        val contactId = activeContactId
        _messages.value = if (contactId.isNullOrEmpty()) emptyList()
                          else runCatching { store?.fetch(contactId) ?: emptyList() }
                              .getOrDefault(emptyList())
    }
}
