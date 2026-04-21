package com.kordar.ghostchat.features.chat

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.kordar.ghostchat.core.audio.VoiceRecorder
import com.kordar.ghostchat.core.files.FileCatalog
import com.kordar.ghostchat.core.files.FileTransferService
import com.kordar.ghostchat.core.managers.CallManager
import com.kordar.ghostchat.core.managers.ConnectionManager
import com.kordar.ghostchat.core.managers.ContactManager
import com.kordar.ghostchat.core.managers.MessageManager
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.util.UUID
import javax.inject.Inject

/**
 * Thin orchestrator for the chat screen. Mirror of iOS ChatViewModel — ≤ 300 LOC.
 */
@HiltViewModel
class ChatViewModel @Inject constructor(
    @ApplicationContext private val appContext: Context,
    val connection: ConnectionManager,
    val messages: MessageManager,
    val calls: CallManager,
    val contacts: ContactManager
) : ViewModel() {

    private val _draft = MutableStateFlow("")
    val draft: StateFlow<String> = _draft.asStateFlow()

    private val _isRecordingVoice = MutableStateFlow(false)
    val isRecordingVoice: StateFlow<Boolean> = _isRecordingVoice.asStateFlow()

    private val voiceRecorder = VoiceRecorder(appContext)
    private var incomingJob: Job? = null
    private var incomingFileJob: Job? = null

    fun start() {
        if (incomingJob == null) {
            incomingJob = viewModelScope.launch {
                connection.incomingText.collect { text -> messages.received(text) }
            }
        }
        if (incomingFileJob == null) {
            incomingFileJob = viewModelScope.launch {
                connection.incomingFile.collect { file -> onIncomingFile(file) }
            }
        }
    }

    fun stop() {
        incomingJob?.cancel(); incomingJob = null
        incomingFileJob?.cancel(); incomingFileJob = null
        if (_isRecordingVoice.value) voiceRecorder.cancel()
        _isRecordingVoice.value = false
    }

    fun updateDraft(value: String) { _draft.value = value }

    fun send() {
        val text = _draft.value.trim()
        if (text.isEmpty()) return
        val local = messages.send(text)
        _draft.value = ""
        viewModelScope.launch {
            runCatching { connection.sendText(text) }
                .onSuccess { messages.markDelivered(local.id) }
        }
    }

    // MARK: - Attachments

    fun sendAttachment(data: ByteArray, name: String, mimeType: String) {
        val localPath = writeTempCopy(data, name)
        val local = messages.sendFile(
            fileId = "", name = name, size = data.size,
            mimeType = mimeType, localPath = localPath
        )
        viewModelScope.launch {
            runCatching { connection.sendFile(data, name, mimeType) }
                .onSuccess { messages.markDelivered(local.id) }
        }
    }

    fun startVoiceRecording() {
        if (_isRecordingVoice.value) return
        runCatching { voiceRecorder.start() }
            .onSuccess { _isRecordingVoice.value = true }
    }

    fun stopVoiceRecordingAndSend() {
        if (!_isRecordingVoice.value) return
        _isRecordingVoice.value = false
        val result = runCatching { voiceRecorder.stop() }.getOrNull() ?: return
        val name = "voice-${System.currentTimeMillis() / 1000}.m4a"
        sendAttachment(result.data, name, "audio/mp4")
    }

    fun cancelVoiceRecording() {
        if (!_isRecordingVoice.value) return
        voiceRecorder.cancel()
        _isRecordingVoice.value = false
    }

    private fun onIncomingFile(file: FileTransferService.IncomingFile) {
        val localPath = writeTempCopy(file.data, file.name)
        messages.receivedFile(
            fileId = file.fileId, name = file.name,
            size = file.data.size, mimeType = file.mimeType,
            localPath = localPath
        )
    }

    private fun writeTempCopy(data: ByteArray, preferredName: String): String? {
        val safe = preferredName.replace('/', '_')
        val out = File(appContext.cacheDir, "ghost-${UUID.randomUUID()}-$safe")
        return try {
            out.writeBytes(data)
            out.absolutePath
        } catch (_: Throwable) { null }
    }

    // MARK: - Existing

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

    /** Used by the picker Composable to validate a user-picked MIME before send. */
    fun isSupportedMime(mime: String): Boolean = FileCatalog.isSupportedMimeType(mime)

    override fun onCleared() {
        super.onCleared()
        stop()
    }
}
