package com.kordar.ghostchat.core.security

import android.content.Context
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import org.mockito.kotlin.mock

class RootDetectorTest {

    private val context: Context = mock()

    @Test
    fun `rootbeer clean and no paths means safe`() {
        val detector = RootDetector(
            rootBeer = { _ -> false },
            pathsExist = { _ -> emptyList() }
        )
        val r = detector.detect(context)
        assertThat(r.status).isEqualTo(RootStatus.SAFE)
        assertThat(r.markers).isEmpty()
    }

    @Test
    fun `rootbeer hit alone flags suspicious`() {
        val detector = RootDetector(
            rootBeer = { _ -> true },
            pathsExist = { _ -> emptyList() }
        )
        val r = detector.detect(context)
        assertThat(r.status).isEqualTo(RootStatus.SUSPICIOUS)
        assertThat(r.markers).contains("rootbeer")
    }

    @Test
    fun `any suspicious path flags suspicious with path marker`() {
        val detector = RootDetector(
            rootBeer = { _ -> false },
            pathsExist = { paths -> paths.filter { it == "/system/xbin/su" } }
        )
        val r = detector.detect(context)
        assertThat(r.status).isEqualTo(RootStatus.SUSPICIOUS)
        assertThat(r.markers).containsExactly("path:/system/xbin/su")
    }

    @Test
    fun `rootbeer throw is caught and does not propagate`() {
        val detector = RootDetector(
            rootBeer = { _ -> throw RuntimeException("JNI failed") },
            pathsExist = { _ -> emptyList() }
        )
        // Must not bubble up; gracefully degrade to "safe" from RootBeer perspective.
        val r = detector.detect(context)
        assertThat(r.status).isEqualTo(RootStatus.SAFE)
    }

    @Test
    fun `multiple markers all collected`() {
        val detector = RootDetector(
            rootBeer = { _ -> true },
            pathsExist = { paths -> paths.filter { it.startsWith("/system") } }
        )
        val r = detector.detect(context)
        assertThat(r.status).isEqualTo(RootStatus.SUSPICIOUS)
        assertThat(r.markers).contains("rootbeer")
        assertThat(r.markers.any { it.startsWith("path:/system") }).isTrue()
    }

    @Test
    fun `extraPaths merged into default list`() {
        val marker = "/data/local/tmp/injected-marker"
        val detector = RootDetector(
            rootBeer = { _ -> false },
            pathsExist = { paths -> paths.filter { it == marker } }
        )
        val r = detector.detect(context, extraPaths = listOf(marker))
        assertThat(r.status).isEqualTo(RootStatus.SUSPICIOUS)
        assertThat(r.markers).containsExactly("path:$marker")
    }

    @Test
    fun `default suspicious paths cover spec candidates`() {
        assertThat(RootDetector.DEFAULT_SUSPICIOUS_PATHS).contains("/system/xbin/su")
        assertThat(RootDetector.DEFAULT_SUSPICIOUS_PATHS).contains("/system/app/Superuser.apk")
        assertThat(RootDetector.DEFAULT_SUSPICIOUS_PATHS.any { it.contains("magisk") }).isTrue()
    }
}
