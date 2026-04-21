package com.kordar.ghostchat.core.storage

import android.content.Context
import com.kordar.ghostchat.core.security.KeystoreServicing
import net.zetetic.database.sqlcipher.SQLiteConnection
import net.zetetic.database.sqlcipher.SQLiteDatabase
import net.zetetic.database.sqlcipher.SQLiteDatabaseHook
import java.io.File
import java.security.SecureRandom

/**
 * Encrypted persistent storage for saved contacts, messages, and Double Ratchet state.
 *
 * **Encryption:** SQLCipher with a 32-byte per-install master key stored in Keystore.
 * PRAGMAs applied identically to iOS DatabaseService:
 *   - `cipher_page_size = 4096`, `kdf_iter = 256000`
 *   - `cipher_memory_security = ON` (zeros page buffers on free)
 *   - `secure_delete = ON` (zeros freed pages before reuse)
 *   - `journal_mode = WAL`, `foreign_keys = ON`
 *
 * Cipher parameters MUST be set BEFORE the key (preKey hook). The hook hands us a
 * raw [SQLiteConnection]; `executeRaw` is the correct call to run PRAGMAs from inside
 * the open sequence.
 */
class DatabaseService private constructor(
    private val keystore: KeystoreServicing,
    val db: SQLiteDatabase,
    internal val path: File?
) {

    fun close() { if (db.isOpen) db.close() }

    companion object {
        const val DB_FILE_NAME = "ghostchat.db"

        object Keys {
            const val DB_MASTER_KEY = "db.master.key"
        }

        private val Hook = object : SQLiteDatabaseHook {
            override fun preKey(connection: SQLiteConnection) {
                connection.executeRaw("PRAGMA cipher_page_size = 4096;", arrayOf(), null)
                connection.executeRaw("PRAGMA kdf_iter = 256000;", arrayOf(), null)
            }
            override fun postKey(connection: SQLiteConnection) {
                connection.executeRaw("PRAGMA cipher_memory_security = ON;", arrayOf(), null)
                connection.executeRaw("PRAGMA secure_delete = ON;", arrayOf(), null)
                connection.executeRaw("PRAGMA journal_mode = WAL;", arrayOf(), null)
                connection.executeRaw("PRAGMA foreign_keys = ON;", arrayOf(), null)
            }
        }

        /**
         * Opens (or creates) the on-disk encrypted DB in the app's files directory.
         * The master key is generated on first access and persisted in Keystore.
         */
        fun onDisk(context: Context, keystore: KeystoreServicing): DatabaseService {
            val target = File(context.filesDir, DB_FILE_NAME)
            return openAt(context = context, keystore = keystore, file = target)
        }

        /** Opens (or creates) an encrypted DB at an explicit path. Intended for tests. */
        fun openAt(context: Context, keystore: KeystoreServicing, file: File): DatabaseService {
            ensureLibraryLoaded(context)
            val passphrase = ensureMasterKey(keystore)
            file.parentFile?.mkdirs()
            val db = SQLiteDatabase.openOrCreateDatabase(file, passphrase, null, null, Hook)
            val service = DatabaseService(keystore, db, file)
            Schema.migrate(db)
            return service
        }

        /** Opens an in-memory DB still going through SQLCipher (key + PRAGMAs applied). */
        fun inMemory(context: Context, keystore: KeystoreServicing): DatabaseService {
            ensureLibraryLoaded(context)
            val passphrase = ensureMasterKey(keystore)
            val db = SQLiteDatabase.openOrCreateDatabase(":memory:", passphrase, null, null, Hook)
            val service = DatabaseService(keystore, db, null)
            Schema.migrate(db)
            return service
        }

        @JvmStatic
        fun ensureMasterKey(keystore: KeystoreServicing): ByteArray {
            keystore.get(Keys.DB_MASTER_KEY)?.let { return it }
            val fresh = ByteArray(32).also { SecureRandom().nextBytes(it) }
            keystore.set(Keys.DB_MASTER_KEY, fresh)
            return fresh
        }

        /**
         * Irrecoverably deletes the DB file and its WAL/SHM/journal siblings. Used by
         * panic wipe — overwrites each file with zeros in 64 KiB chunks before
         * unlinking (via [com.kordar.ghostchat.core.security.SecureWipe.wipeDatabase]) so
         * the file blocks are no longer on disk as plaintext of the encrypted DB pages.
         */
        fun deleteFile(context: Context) {
            val base = context.filesDir
            com.kordar.ghostchat.core.security.SecureWipe.wipeDatabase(File(base, DB_FILE_NAME))
        }

        private var loaded = false
        @Synchronized
        private fun ensureLibraryLoaded(@Suppress("UNUSED_PARAMETER") context: Context) {
            if (loaded) return
            System.loadLibrary("sqlcipher")
            loaded = true
        }
    }
}
