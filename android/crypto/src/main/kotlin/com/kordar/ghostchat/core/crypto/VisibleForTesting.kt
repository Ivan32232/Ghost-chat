package com.kordar.ghostchat.core.crypto

/**
 * Marker for APIs exposed only for testing. Combine with `internal` visibility —
 * this annotation documents intent; `internal` enforces module-boundary access at compile time.
 *
 * When the crypto module is later consumed from the main Android app (Phase 4),
 * swap to `androidx.annotation.VisibleForTesting` if lint enforcement is desired.
 */
@Retention(AnnotationRetention.BINARY)
@Target(
    AnnotationTarget.CLASS,
    AnnotationTarget.FUNCTION,
    AnnotationTarget.PROPERTY,
    AnnotationTarget.FIELD,
    AnnotationTarget.CONSTRUCTOR
)
annotation class VisibleForTesting
