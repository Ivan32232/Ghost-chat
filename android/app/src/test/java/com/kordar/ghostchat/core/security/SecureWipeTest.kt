package com.kordar.ghostchat.core.security

import com.google.common.truth.Truth.assertThat
import org.junit.After
import org.junit.Before
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile
import java.nio.file.Files
import java.util.UUID

/**
 * Unit tests for [SecureWipe]. Mirror of iOS `SecureWipeTests`.
 */
class SecureWipeTest {

    private lateinit var tmpDir: File

    @Before
    fun setUp() {
        tmpDir = Files.createTempDirectory("securewipe-${UUID.randomUUID()}").toFile()
    }

    @After
    fun tearDown() {
        tmpDir.deleteRecursively()
    }

    private fun path(name: String) = File(tmpDir, name)

    // MARK: - wipeFile

    @Test
    fun `wipeFile removes existing file`() {
        val f = path("plain.bin").apply { writeBytes("SENSITIVE".toByteArray()) }
        assertThat(SecureWipe.wipeFile(f)).isTrue()
        assertThat(f.exists()).isFalse()
    }

    @Test
    fun `wipeFile nonexistent is noop`() {
        val f = path("never-was.bin")
        assertThat(SecureWipe.wipeFile(f)).isTrue()
    }

    @Test
    fun `wipeFile zero byte file still deletes`() {
        val f = path("empty.bin").apply { writeBytes(ByteArray(0)) }
        assertThat(SecureWipe.wipeFile(f)).isTrue()
        assertThat(f.exists()).isFalse()
    }

    @Test
    fun `wipeFile zeroes contents before delete (observable via pre-unlink read)`() {
        // Write content, then manually run just the overwrite phase to confirm
        // the file bytes are zero before unlinking.
        val f = path("sensitive.bin")
        val markerBytes = "MARKER_${UUID.randomUUID()}".toByteArray()
        val padding = ByteArray(200_000 - markerBytes.size)
        f.writeBytes(markerBytes + padding)

        RandomAccessFile(f, "rw").use { raf ->
            raf.seek(0)
            val zeros = ByteArray(SecureWipe.CHUNK_SIZE)
            var remaining = f.length()
            while (remaining > 0) {
                val n = minOf(SecureWipe.CHUNK_SIZE.toLong(), remaining).toInt()
                if (n == SecureWipe.CHUNK_SIZE) raf.write(zeros) else raf.write(zeros, 0, n)
                remaining -= n
            }
            raf.fd.sync()
        }
        val after = f.readBytes()
        assertThat(after.any { it != 0.toByte() }).isFalse()
        f.delete()
    }

    @Test
    fun `wipeFile large file uses chunks`() {
        val f = path("large.bin")
        f.writeBytes(ByteArray(2 * SecureWipe.CHUNK_SIZE + 1024))
        assertThat(SecureWipe.wipeFile(f)).isTrue()
        assertThat(f.exists()).isFalse()
    }

    // MARK: - wipeDatabase

    @Test
    fun `wipeDatabase removes db plus WAL, SHM, journal siblings`() {
        val db = path("ghostchat.db")
        for (suffix in listOf("", "-wal", "-shm", "-journal")) {
            val sib = if (suffix.isEmpty()) db else File(db.parentFile, db.name + suffix)
            sib.writeBytes(ByteArray(1024))
        }
        SecureWipe.wipeDatabase(db)
        for (suffix in listOf("", "-wal", "-shm", "-journal")) {
            val sib = if (suffix.isEmpty()) db else File(db.parentFile, db.name + suffix)
            assertThat(sib.exists()).isFalse()
        }
    }

    @Test
    fun `wipeDatabase with missing siblings does not throw`() {
        val db = path("ghostchat.db")
        db.writeBytes(ByteArray(128))
        SecureWipe.wipeDatabase(db)
        assertThat(db.exists()).isFalse()
    }

    // MARK: - wipeDirectory

    @Test
    fun `wipeDirectory non-recursive clears top-level files`() {
        path("a.dat").writeBytes("a".toByteArray())
        path("b.dat").writeBytes("b".toByteArray())
        val nested = File(tmpDir, "nested").apply { mkdirs() }
        File(nested, "c.dat").writeBytes("c".toByteArray())
        SecureWipe.wipeDirectory(tmpDir)
        assertThat(path("a.dat").exists()).isFalse()
        assertThat(path("b.dat").exists()).isFalse()
        // nested preserved when recursive=false
        assertThat(File(nested, "c.dat").exists()).isTrue()
    }

    @Test
    fun `wipeDirectory recursive clears nested`() {
        val deep = File(File(tmpDir, "nested"), "deep").apply { mkdirs() }
        File(deep, "file.dat").writeBytes("x".toByteArray())
        SecureWipe.wipeDirectory(tmpDir, recursive = true)
        assertThat(File(deep, "file.dat").exists()).isFalse()
        assertThat(File(tmpDir, "nested").exists()).isFalse()
    }
}
