package com.kordar.ghostchat.core.storage

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.common.truth.Truth.assertThat
import com.kordar.ghostchat.core.security.InMemoryKeystore
import com.kordar.ghostchat.models.Contact
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Real SQLCipher integration tests. Proves on-disk encryption by writing a unique marker
 * label, closing the DB, then hexdump-scanning the raw file for the marker — it must NOT
 * appear (SQLCipher page-level encryption).
 *
 * Runs on device/emulator only.
 */
@RunWith(AndroidJUnit4::class)
class DatabaseServiceAndroidTest {

    private lateinit var ctx: Context
    private lateinit var tempFile: File

    @Before
    fun setUp() {
        ctx = ApplicationProvider.getApplicationContext()
        tempFile = File.createTempFile("ghostchat-test-", ".db", ctx.cacheDir).also {
            it.delete()
        }
    }

    @After
    fun tearDown() {
        val siblings = listOf("", "-wal", "-shm", "-journal").map { File(tempFile.parentFile, "${tempFile.name}$it") }
        siblings.forEach { it.delete() }
    }

    @Test
    fun migration_creates_schema_tables() {
        val svc = DatabaseService.openAt(ctx, InMemoryKeystore(), tempFile)
        svc.db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", arrayOf()).use { c ->
            val names = mutableListOf<String>()
            while (c.moveToNext()) names += c.getString(0)
            assertThat(names).containsAtLeast("contacts", "messages", "skippedKeys")
        }
        svc.close()
    }

    @Test
    fun onDiskFile_isEncrypted_notPlaintext() {
        val keystore = InMemoryKeystore()
        val svc = DatabaseService.openAt(ctx, keystore, tempFile)
        val store = ContactStore(svc)

        // Write a contact whose label contains a unique, long marker that's unlikely to
        // appear in any legitimate SQLite overhead.
        val marker = "GHOSTCHAT-ENCRYPTION-PROOF-${System.nanoTime()}"
        store.save(
            Contact(
                label = marker,
                identityKey = ByteArray(65),
                publicKey = ByteArray(65)
            )
        )

        // Force a WAL checkpoint so all data lands in the main db file.
        svc.db.rawQuery("PRAGMA wal_checkpoint(TRUNCATE);", arrayOf()).use { /* drain */ }
        svc.close()

        // Verify: scan the raw file bytes for the marker. It MUST NOT appear plaintext.
        val raw = tempFile.readBytes()
        val rawText = String(raw, Charsets.ISO_8859_1)
        assertThat(rawText).doesNotContain(marker)
        assertThat(rawText).doesNotContain("SQLite format 3\u0000") // SQLCipher replaces this magic
    }

    @Test
    fun reopenWithDifferentKey_fails() {
        val legit = InMemoryKeystore()
        DatabaseService.openAt(ctx, legit, tempFile).also { it.db.execSQL("CREATE TABLE x(a)"); it.close() }
        val impostor = InMemoryKeystore() // fresh keystore generates a different master key
        val ex = try {
            DatabaseService.openAt(ctx, impostor, tempFile).also { it.close() }
            null
        } catch (t: Throwable) { t }
        assertThat(ex).isNotNull()
    }
}
