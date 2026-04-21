package com.kordar.ghostchat.core.security

import java.io.File
import java.io.RandomAccessFile

/**
 * Overwrite-then-unlink helpers used by panic wipe and secure file cleanup.
 *
 * Filesystem `delete()` does not erase the underlying blocks — on flash it's
 * mostly moot because of FTL wear-levelling, but we still want an explicit
 * zero pass to shorten the recoverability window on encrypted overlays and
 * older spinning disks. 64 KiB chunks keep peak memory small even for
 * multi-GB database files.
 *
 * Mirror of iOS `SecureWipe` — identical chunk size, identical semantics.
 */
object SecureWipe {

    /** Bytes per write. 64 KiB is the spec-mandated chunk. */
    const val CHUNK_SIZE: Int = 64 * 1024

    /**
     * Overwrite [file] with zeros then delete it. No-op if the file is absent.
     * Returns `true` if the file existed and was wiped+deleted (or was absent).
     * `false` only on I/O errors that the caller should notice.
     */
    fun wipeFile(file: File): Boolean {
        if (!file.exists()) return true
        return try {
            if (file.length() > 0) {
                RandomAccessFile(file, "rw").use { raf ->
                    raf.seek(0)
                    val zeros = ByteArray(CHUNK_SIZE)
                    var remaining = file.length()
                    while (remaining > 0) {
                        val n = minOf(CHUNK_SIZE.toLong(), remaining).toInt()
                        if (n == CHUNK_SIZE) raf.write(zeros) else raf.write(zeros, 0, n)
                        remaining -= n
                    }
                    raf.fd.sync()
                }
            }
            file.delete()
            !file.exists()
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Wipe a SQLCipher/SQLite DB plus every sibling WAL/SHM/journal file.
     * Used by panic wipe and by tests that need to prove the DB is zeroed
     * before deletion.
     */
    fun wipeDatabase(dbFile: File) {
        for (suffix in listOf("", "-wal", "-shm", "-journal")) {
            val f = if (suffix.isEmpty()) dbFile else File(dbFile.parentFile, dbFile.name + suffix)
            wipeFile(f)
        }
    }

    /** Wipe every regular file under [directory]. Recurses when [recursive] is true. */
    fun wipeDirectory(directory: File, recursive: Boolean = false) {
        val children = directory.listFiles() ?: return
        for (child in children) {
            when {
                child.isDirectory && recursive -> {
                    wipeDirectory(child, recursive = true)
                    child.delete()
                }
                child.isFile -> wipeFile(child)
                else -> Unit
            }
        }
    }
}
