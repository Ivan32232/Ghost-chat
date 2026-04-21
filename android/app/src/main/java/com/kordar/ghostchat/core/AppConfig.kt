package com.kordar.ghostchat.core

/**
 * Compile-time configuration constants. Mirrors iOS `AppServices.serverHTTPS / serverWSS`.
 * These URLs are baked in — certificate pinning in [CertificatePinning] (Core/Network)
 * prevents redirection via any network-level attack.
 */
object AppConfig {
    const val SERVER_HTTPS: String = "https://ghostchat.one"
    const val SERVER_WSS: String   = "wss://ghostchat.one/ws"
}
