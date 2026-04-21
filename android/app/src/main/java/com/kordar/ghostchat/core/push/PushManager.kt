package com.kordar.ghostchat.core.push

import com.kordar.ghostchat.core.network.CertificatePinning
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Coordinates FCM token registration + push-relay HTTP posts. Mirror of iOS PushManager.
 *
 * FCM on Android covers both VoIP and regular push in one channel: a data message with
 * `roomId` wakes the app via [GhostFirebaseService], which then signals [CallManager]
 * to surface the call UI. Registering is graceful — if google-services.json isn't
 * present in the build, [registerForFCM] fails silently and push is simply unavailable.
 */
class PushManager(
    private val baseUrl: String,
    private val client: OkHttpClient = defaultClient()
) {

    sealed class Error(message: String) : RuntimeException(message) {
        data class HttpStatus(val code: Int) : Error("HTTP $code")
    }

    private val _fcmTokens = MutableSharedFlow<String>(
        replay = 1,
        extraBufferCapacity = 4,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val fcmTokens: SharedFlow<String> = _fcmTokens.asSharedFlow()

    var fcmToken: String? = null
        private set
    var pushAuth: String? = null

    /** Ask FCM for the current token. Returns null if Firebase isn't initialised. */
    suspend fun registerForFCM(): String? {
        return try {
            val token = suspendCancellableCoroutine<String> { cont ->
                FirebaseMessaging.getInstance().token
                    .addOnSuccessListener { t -> if (cont.isActive) cont.resume(t) }
                    .addOnFailureListener { e -> if (cont.isActive) cont.resumeWithException(e) }
            }
            onNewFCMToken(token)
            token
        } catch (_: Throwable) {
            null
        }
    }

    /** Called by [GhostFirebaseService] when FCM rotates the token. */
    fun onNewFCMToken(token: String) {
        fcmToken = token
        _fcmTokens.tryEmit(token)
    }

    // MARK: - Outgoing push posts (relay to server)

    suspend fun sendFCMCall(token: String, roomId: String, callerName: String) = post(
        path = "api/send-push-android",
        body = buildJsonObject {
            put("token", JsonPrimitive(token))
            put("payload", buildJsonObject {
                put("roomId", JsonPrimitive(roomId))
                put("callerName", JsonPrimitive(callerName))
            })
            pushAuth?.let { put("auth", JsonPrimitive(it)) }
        }
    )

    suspend fun sendInvite(
        token: String,
        platform: String,
        roomId: String,
        inviterName: String
    ) = post(
        path = "api/send-invite",
        body = buildJsonObject {
            put("token", JsonPrimitive(token))
            put("platform", JsonPrimitive(platform))
            put("payload", buildJsonObject {
                put("roomId", JsonPrimitive(roomId))
                put("inviterName", JsonPrimitive(inviterName))
            })
            pushAuth?.let { put("auth", JsonPrimitive(it)) }
        }
    )

    suspend fun sendNotify(
        token: String,
        platform: String,
        senderName: String,
        type: String
    ) = post(
        path = "api/push/notify",
        body = buildJsonObject {
            put("token", JsonPrimitive(token))
            put("platform", JsonPrimitive(platform))
            put("senderName", JsonPrimitive(senderName))
            put("type", JsonPrimitive(type))
            pushAuth?.let { put("auth", JsonPrimitive(it)) }
        }
    )

    private suspend fun post(path: String, body: JsonElement) = withContext(Dispatchers.IO) {
        val url = baseUrl.trimEnd('/') + "/" + path
        val bodyStr = json.encodeToString(JsonElement.serializer(), body)
        val request = Request.Builder()
            .url(url)
            .post(bodyStr.toRequestBody(JSON))
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw Error.HttpStatus(response.code)
        }
    }

    companion object {
        private val json = Json { encodeDefaults = false }
        private val JSON = "application/json; charset=utf-8".toMediaType()

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .certificatePinner(CertificatePinning.pinner())
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
    }
}
