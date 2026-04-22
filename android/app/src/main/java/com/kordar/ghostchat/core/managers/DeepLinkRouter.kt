package com.kordar.ghostchat.core.managers

import android.net.Uri
import com.kordar.ghostchat.models.Room
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Parses incoming deep-link intents and surfaces a pending room id the UI layer
 * must confirm with the user before any join happens.
 *
 * Singleton by design — [MainActivity.onNewIntent] and the WelcomeScreen
 * composable both observe the same instance so the confirmation alert is the
 * single gate for auto-joins.
 *
 * Never joins on its own: parse + stash is the only side effect. Mirrors the
 * iOS `DeepLinkRouter`.
 */
@Singleton
class DeepLinkRouter @Inject constructor() {

    private val _pendingRoomId = MutableStateFlow<String?>(null)
    val pendingRoomId: StateFlow<String?> = _pendingRoomId.asStateFlow()

    fun submit(uri: Uri?) {
        val id = parse(uri) ?: return
        _pendingRoomId.value = id
    }

    fun clear() {
        _pendingRoomId.value = null
    }

    companion object {
        /**
         * Returns a valid room id parsed from any of the shapes we advertise:
         *   - `ghostchat://?room=<id>`            (query form; current builds)
         *   - `ghostchat://room/<id>`             (legacy path form)
         *   - `https://ghostchat.one/?room=<id>`  (universal app link, query)
         *   - `https://ghostchat.one/room/<id>`   (universal app link, path)
         * Null if the URI doesn't match any shape or the id fails
         * [Room.isValidId] (64-char base64url).
         */
        fun parse(uri: Uri?): String? {
            uri ?: return null
            val scheme = uri.scheme?.lowercase() ?: return null
            val candidate: String? = when (scheme) {
                "ghostchat" -> {
                    // Prefer query; fall back to legacy host=room + last segment.
                    uri.getQueryParameter("room")?.takeIf { it.isNotEmpty() }
                        ?: (if (uri.host?.lowercase() == "room") uri.pathSegments.lastOrNull() else null)
                }
                "http", "https" -> {
                    val host = uri.host?.lowercase()
                    if (host == "ghostchat.one" || host == "www.ghostchat.one") {
                        uri.getQueryParameter("room")?.takeIf { it.isNotEmpty() }
                            ?: run {
                                // Universal-link path form: /room/<id>
                                val segments = uri.pathSegments
                                if (segments.size == 2 && segments[0].lowercase() == "room") {
                                    segments[1]
                                } else null
                            }
                    } else null
                }
                else -> null
            }
            return candidate?.takeIf { Room.isValidId(it) }
        }
    }
}
