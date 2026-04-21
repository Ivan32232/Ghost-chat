import Foundation

/// Overwrite-then-unlink helpers used by panic-wipe and secure file cleanup.
///
/// Filesystem `unlink()` does not erase the underlying blocks — on flash storage
/// that's mostly moot (the FTL handles wear-levelling and zero-fill garbage
/// collection), but on HFS+ / APFS over spinning disks or encrypted overlays
/// we want an explicit zero pass to reduce the recoverability window. 64 KiB
/// chunks keep peak memory small even for multi-GB databases.
///
/// Mirror of Android `SecureWipe` — identical chunk size + matching semantics.
enum SecureWipe {

    /// Bytes per write. 64 KiB is the spec-mandated chunk.
    static let chunkSize: Int = 64 * 1024

    /// Overwrite `path` with zeros then delete it. No-op if the file is absent.
    /// Throws only on I/O errors — missing files are considered success.
    static func wipeFile(at path: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }
        let attrs = try fm.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size > 0, let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            try handle.seek(toOffset: 0)
            var remaining = size
            let fullChunk = Data(count: chunkSize)
            while remaining > 0 {
                let write = min(chunkSize, remaining)
                if write == chunkSize {
                    try handle.write(contentsOf: fullChunk)
                } else {
                    try handle.write(contentsOf: Data(count: write))
                }
                remaining -= write
            }
            try handle.synchronize()
        }
        try fm.removeItem(atPath: path)
    }

    /// Wipe a SQLCipher/SQLite database and every sibling WAL/SHM/journal file.
    /// Called from panic wipe and from tests that need to prove the DB file is
    /// zeroed before deletion.
    static func wipeDatabase(at path: String) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? wipeFile(at: path + suffix)
        }
    }

    /// Wipe every regular file under `directory` (non-recursive by default).
    /// Used to clear the attachments cache during panic wipe.
    static func wipeDirectory(at directory: String, recursive: Bool = false) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: directory) else { return }
        for name in items {
            let full = (directory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if recursive {
                    wipeDirectory(at: full, recursive: true)
                    try? fm.removeItem(atPath: full)
                }
            } else {
                try? wipeFile(at: full)
            }
        }
    }
}
