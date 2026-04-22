package com.kordar.ghostchat.features.waiting

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Thin view model for [WaitingScreen]. Mirrors iOS `WaitingViewModel`:
 * formats the invite URL, truncates the display id, and bridges a flash
 * "copied" flag for the UI.
 */
@HiltViewModel
class WaitingViewModel @Inject constructor(
    @ApplicationContext private val context: Context
) : ViewModel() {

    private val _copiedFeedbackVisible = MutableStateFlow(false)
    val copiedFeedbackVisible: StateFlow<Boolean> = _copiedFeedbackVisible.asStateFlow()

    fun shareUrl(roomId: String): String = "$INVITE_BASE_URL?room=$roomId"

    /**
     * Short, scanable label: first 8 chars + "…" + last 4. Ids of 12 chars or
     * shorter are shown in full — no value in eliding.
     */
    fun displayId(roomId: String): String {
        if (roomId.length <= 12) return roomId
        return "${roomId.take(8)}…${roomId.takeLast(4)}"
    }

    fun copy(roomId: String) {
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
        cm.setPrimaryClip(ClipData.newPlainText("Ghost Chat invite", shareUrl(roomId)))
        _copiedFeedbackVisible.value = true
        viewModelScope.launch {
            delay(COPIED_FLASH_MS)
            _copiedFeedbackVisible.value = false
        }
    }

    /** Test hook: set the flag without the viewModelScope delay. */
    internal fun _test_markCopied() { _copiedFeedbackVisible.value = true }

    companion object {
        const val INVITE_BASE_URL = "https://ghostchat.one/"
        private const val COPIED_FLASH_MS = 2_000L
    }
}
