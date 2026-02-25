plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.ghost.chat"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.ghost.chat"
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"
    }

    signingConfigs {
        create("release") {
            storeFile = file("ghost-chat.jks")
            storePassword = System.getenv("KEYSTORE_PASSWORD") ?: "ghost-chat-release"
            keyAlias = "ghost-chat"
            keyPassword = System.getenv("KEY_PASSWORD") ?: "ghost-chat-release"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.getByName("release")
        }
        debug {
            isDebuggable = true
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }
}

dependencies {
    // Jetpack Compose
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.navigation:navigation-compose:2.8.5")

    // Core
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")

    // WebRTC (P2P + audio)
    implementation("io.getstream:stream-webrtc-android:1.3.1")

    // BouncyCastle (HKDF — java.security has no HKDF)
    implementation("org.bouncycastle:bcprov-jdk18on:1.79")

    // SQLCipher (encrypted database)
    implementation("net.zetetic:android-database-sqlcipher:4.5.4@aar")
    implementation("androidx.sqlite:sqlite:2.4.0")

    // Biometric auth
    implementation("androidx.biometric:biometric:1.1.0")

    // OkHttp (WebSocket + TURN HTTP)
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // Security (EncryptedSharedPreferences)
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // JSON (built-in org.json)
    // No extra dependency needed

    // Debug
    debugImplementation("androidx.compose.ui:ui-tooling")
}
