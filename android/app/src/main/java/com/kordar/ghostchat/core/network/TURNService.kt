package com.kordar.ghostchat.core.network

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.util.concurrent.TimeUnit

data class TURNCredentials(
    val username: String,
    val credential: String,
    val urls: List<String>,
    val ttl: Int,
    val pushAuth: String?,
    val fetchedAtEpochMs: Long = System.currentTimeMillis()
) {
    /** True once ≥ `skewSeconds` remain below the `ttl` boundary. */
    fun isExpired(
        nowEpochMs: Long = System.currentTimeMillis(),
        skewSeconds: Int = 300
    ): Boolean {
        val ageSeconds = (nowEpochMs - fetchedAtEpochMs) / 1000
        return ageSeconds + skewSeconds >= ttl
    }
}

/**
 * Thin HTTP client for `/api/turn-credentials`. Uses a pinned [OkHttpClient] so MitM via
 * a network proxy fails hard (no fallback; see [CertificatePinning]).
 */
class TURNService(
    private val baseUrl: String,
    private val client: OkHttpClient = defaultClient()
) {

    sealed class Error(message: String) : RuntimeException(message) {
        data class HttpStatus(val code: Int) : Error("HTTP $code")
        data object MalformedResponse : Error("malformed TURN response")
    }

    suspend fun fetchCredentials(): TURNCredentials = withContext(Dispatchers.IO) {
        val url = baseUrl.trimEnd('/') + "/api/turn-credentials"
        val request = Request.Builder().url(url).get().build()
        val response = client.newCall(request).execute()
        response.use { resp ->
            if (!resp.isSuccessful) throw Error.HttpStatus(resp.code)
            val body = resp.body?.string() ?: throw Error.MalformedResponse
            parse(body)
        }
    }

    private fun parse(raw: String): TURNCredentials {
        val obj: JsonObject = try {
            json.parseToJsonElement(raw).jsonObject
        } catch (_: Throwable) { throw Error.MalformedResponse }
        val username    = obj["username"]?.jsonPrimitive?.content ?: throw Error.MalformedResponse
        val credential  = obj["credential"]?.jsonPrimitive?.content ?: throw Error.MalformedResponse
        val urlsElement = obj["urls"] as? JsonArray ?: throw Error.MalformedResponse
        val urls        = urlsElement.map { it.jsonPrimitive.content }
        val ttl         = obj["ttl"]?.jsonPrimitive?.intOrNull ?: throw Error.MalformedResponse
        val pushAuth    = obj["pushAuth"]?.jsonPrimitive?.content
        return TURNCredentials(username, credential, urls, ttl, pushAuth)
    }

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .certificatePinner(CertificatePinning.pinner())
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
    }
}
