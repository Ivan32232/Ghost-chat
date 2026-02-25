package com.ghost.chat.core.network

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/// TURN credentials from server — port of TURNService.swift
/// Response format: { username, credential, ttl, urls: [...] }
data class TURNCredentials(
    val username: String,
    val credential: String,
    val ttl: Int,
    val urls: List<String>
)

class TURNService(private val baseURL: String) {

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    /** Fetch temporary TURN credentials from server */
    suspend fun fetchCredentials(): TURNCredentials = withContext(Dispatchers.IO) {
        val url = "${baseURL.trimEnd('/')}/api/turn-credentials"
        val request = Request.Builder().url(url).get().build()

        val response = client.newCall(request).execute()
        if (!response.isSuccessful) throw TURNError.FetchFailed()

        val body = response.body?.string() ?: throw TURNError.FetchFailed()
        val json = JSONObject(body)

        val urlsArray = json.getJSONArray("urls")
        val urls = mutableListOf<String>()
        for (i in 0 until urlsArray.length()) {
            urls.add(urlsArray.getString(i))
        }

        TURNCredentials(
            username = json.getString("username"),
            credential = json.getString("credential"),
            ttl = json.getInt("ttl"),
            urls = urls
        )
    }
}

sealed class TURNError : Exception() {
    class FetchFailed : TURNError() {
        override val message = "Failed to fetch TURN credentials"
    }
}
