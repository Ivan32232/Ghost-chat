package com.kordar.ghostchat.core.security

import android.content.Context
import com.scottyab.rootbeer.RootBeer
import java.io.File

enum class RootStatus { SAFE, SUSPICIOUS }

data class RootReport(
    val status: RootStatus,
    /**
     * Specific heuristic hits (`rootbeer`, `path:/system/xbin/su`, …). Used by
     * the SecurityDashboard and never sent to the peer beyond a boolean
     * "rooted-device" security-alert.
     */
    val markers: List<String>
)

/**
 * Best-effort root detection. Mirror of iOS `JailbreakDetector`.
 *
 * Per spec ("Warn user but don't block"), we surface a boolean + marker list
 * but never refuse to run. Some legitimate users run rooted devices.
 *
 * Heuristics:
 * 1. RootBeer — library-level check: su binary presence, busybox, dangerous apps,
 *    writable /system, test-keys, Magisk paths, etc.
 * 2. Explicit fallback filesystem paths that indicate root (su binaries / Magisk
 *    data dir / Superuser.apk). Covers cases where RootBeer missed something or
 *    the device model isn't in its list.
 */
class RootDetector(
    /** Injectable RootBeer call for tests. */
    private val rootBeer: (Context) -> Boolean = { ctx -> RootBeer(ctx).isRooted },
    /**
     * Injectable filesystem check — takes a list of candidate paths and returns
     * those that exist. Tests pass a mock that returns an arbitrary subset.
     */
    private val pathsExist: (List<String>) -> List<String> = { paths ->
        paths.filter { File(it).exists() }
    }
) {

    companion object {
        val DEFAULT_SUSPICIOUS_PATHS = listOf(
            "/system/xbin/su",
            "/system/bin/su",
            "/sbin/su",
            "/system/bin/.ext/.su",
            "/system/app/Superuser.apk",
            "/data/local/xbin/su",
            "/data/local/bin/su",
            "/system/bin/magisk",
            "/sbin/magisk",
            "/data/adb/magisk",
            "/data/data/com.topjohnwu.magisk"
        )
    }

    fun detect(context: Context, extraPaths: List<String> = emptyList()): RootReport {
        val markers = mutableListOf<String>()
        if (runCatching { rootBeer(context) }.getOrElse { false }) {
            markers += "rootbeer"
        }
        val found = runCatching { pathsExist(DEFAULT_SUSPICIOUS_PATHS + extraPaths) }
            .getOrElse { emptyList() }
        for (p in found) markers += "path:$p"
        return RootReport(
            status = if (markers.isEmpty()) RootStatus.SAFE else RootStatus.SUSPICIOUS,
            markers = markers
        )
    }
}
