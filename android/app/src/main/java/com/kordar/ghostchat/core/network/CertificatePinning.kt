package com.kordar.ghostchat.core.network

import okhttp3.CertificatePinner

/**
 * SPKI-SHA256 certificate pinning for `ghostchat.one`.
 *
 * NO FALLBACK: if neither pin matches, OkHttp throws `SSLPeerUnverifiedException` and the
 * connection dies. Pins are rotated via app update (both `PRIMARY_PIN` and `BACKUP_PIN`
 * live in this file and are baked into the APK).
 *
 * Pin values MUST stay byte-identical to iOS [`CertificatePinning.swift`] —
 * cross-platform builds MUST pin the same SubjectPublicKeyInfo.
 */
object CertificatePinning {

    /** base64(SHA256(SubjectPublicKeyInfo)) — Let's Encrypt leaf, valid through 2026-06-29. */
    const val PRIMARY_PIN = "u+rYBkrJDJtDcMZuuZxvgrwKAiaN/8Ppuk7pwdxjGbg="

    /** Backup pin derived from our controlled ECDSA P-256 keypair. */
    const val BACKUP_PIN  = "/AdS6h9evKtyk7J9aoy+0isfcARe0dv7/C+BOUabNeo="

    const val HOST = "ghostchat.one"

    fun pinner(host: String = HOST): CertificatePinner =
        CertificatePinner.Builder()
            .add(host, "sha256/$PRIMARY_PIN")
            .add(host, "sha256/$BACKUP_PIN")
            .build()

    /** Exactly the two pins, in fixed order. Useful for verification scripts and dashboards. */
    val pins: List<String> = listOf(PRIMARY_PIN, BACKUP_PIN)
}
