# Ghost Chat — R8 / ProGuard keep rules.
#
# minifyEnabled stays `false` in Phase 7 (no release keystore checked in, and we haven't
# validated minified release builds on real devices yet). These rules are shipped so the
# user can flip `release { isMinifyEnabled = true }` in one line once a keystore exists.
#
# Keep everything that reflection, JNI, or native interop depends on.

# --------- BouncyCastle (ECDH, HKDF, ML-KEM768) ---------
-keep class org.bouncycastle.** { *; }
-keep interface org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# --------- SQLCipher (JNI + Cursor native classes) ---------
-keep class net.sqlcipher.** { *; }
-keep class net.zetetic.database.** { *; }
-keep class net.zetetic.database.sqlcipher.** { *; }
-dontwarn net.sqlcipher.**
-dontwarn net.zetetic.**

# --------- WebRTC (JNI peer connection, data channel, audio track) ---------
-keep class io.getstream.webrtc.** { *; }
-keep class org.webrtc.** { *; }
-keepclassmembers class org.webrtc.** {
    native <methods>;
}
-dontwarn org.webrtc.**

# --------- Firebase / FCM ---------
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**

# --------- Sentry (instrumentation APIs + reflection) ---------
-keep class io.sentry.** { *; }
-dontwarn io.sentry.**

# --------- Our own serializable wire models (kotlinx.serialization) ---------
-keep @kotlinx.serialization.Serializable class * { *; }
-keepclassmembers class ** {
    @kotlinx.serialization.SerialName <fields>;
}
-keepattributes *Annotation*, Signature, Exceptions, InnerClasses, EnclosingMethod

# --------- Kotlin metadata (used by reflection / coroutines debug) ---------
-keep class kotlin.Metadata { *; }
-keepclassmembers class kotlin.coroutines.jvm.internal.** { *; }

# --------- Hilt / Dagger generated code ---------
-keep class dagger.hilt.** { *; }
-keep class * extends dagger.hilt.android.lifecycle.HiltViewModel { *; }
-keep @dagger.hilt.android.AndroidEntryPoint class * { *; }

# --------- Ghost Chat own code (models are parcelable-ish and reflected in tests) ---------
-keep class com.kordar.ghostchat.models.** { *; }
-keep class com.kordar.ghostchat.core.crypto.KeyExchangePacket { *; }
-keep class com.kordar.ghostchat.core.crypto.PqExchangePacket { *; }
-keep class com.kordar.ghostchat.core.crypto.MessageEnvelope { *; }
-keep class com.kordar.ghostchat.core.crypto.GhostCryptoExport { *; }

# --------- Native libraries (strip-proofing) ---------
-keepclasseswithmembernames class * {
    native <methods>;
}
