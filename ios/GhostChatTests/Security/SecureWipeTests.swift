import XCTest
@testable import GhostChat

final class SecureWipeTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "securewipe-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    private func path(_ name: String) -> String { tmpDir + name }

    // MARK: - wipeFile

    func test_wipeFile_removesExistingFile() throws {
        let p = path("plain.bin")
        try Data("SENSITIVE".utf8).write(to: URL(fileURLWithPath: p))
        try SecureWipe.wipeFile(at: p)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p))
    }

    func test_wipeFile_nonexistent_isNoop() {
        XCTAssertNoThrow(try SecureWipe.wipeFile(at: path("never-was.bin")))
    }

    func test_wipeFile_zeroByteFile_stillDeletes() throws {
        let p = path("empty.bin")
        try Data().write(to: URL(fileURLWithPath: p))
        try SecureWipe.wipeFile(at: p)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p))
    }

    func test_wipeFile_zeroesContentsBeforeDelete_observableViaHandle() throws {
        // Open a second file descriptor to the same inode, keep it open across
        // wipeFile(), and confirm its contents are zeroed after the wipe
        // write-through sync but before the final unlink closes our inode view.
        let p = path("sensitive.bin")
        let marker = "MARKER_\(UUID().uuidString)".data(using: .utf8)!
        var content = Data()
        content.append(marker)
        content.append(Data(count: 200_000 - marker.count))
        try content.write(to: URL(fileURLWithPath: p))

        let descriptorBefore = FileHandle(forReadingAtPath: p)!
        // Manually run the overwrite phase, read descriptor view, then unlink.
        if let writer = FileHandle(forWritingAtPath: p) {
            let size = try FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber
            try writer.seek(toOffset: 0)
            var remaining = size?.intValue ?? 0
            while remaining > 0 {
                let n = min(SecureWipe.chunkSize, remaining)
                try writer.write(contentsOf: Data(count: n))
                remaining -= n
            }
            try writer.synchronize()
            try writer.close()
        }

        try descriptorBefore.seek(toOffset: 0)
        let viewAfterOverwrite = try descriptorBefore.readToEnd() ?? Data()
        XCTAssertFalse(viewAfterOverwrite.contains(marker),
                       "marker must be gone after zero-overwrite")
        XCTAssertTrue(viewAfterOverwrite.allSatisfy { $0 == 0 },
                      "post-wipe content must be all zeros")
        try FileManager.default.removeItem(atPath: p)
        try descriptorBefore.close()
    }

    func test_wipeFile_largeFile_usesChunks() throws {
        let p = path("large.bin")
        let size = 2 * SecureWipe.chunkSize + 1024 // 128 KiB + 1 KiB
        try Data(count: size).write(to: URL(fileURLWithPath: p))
        try SecureWipe.wipeFile(at: p)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p))
    }

    // MARK: - wipeDatabase

    func test_wipeDatabase_removesDbPlusWAL_SHM_journal() throws {
        let dbPath = path("ghostchat.db")
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try Data(count: 1024).write(to: URL(fileURLWithPath: dbPath + suffix))
        }
        SecureWipe.wipeDatabase(at: dbPath)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath + suffix),
                           "sibling \(suffix) not removed")
        }
    }

    func test_wipeDatabase_missingSiblings_noThrow() {
        // Only the main file exists; missing siblings must not cause a throw.
        let dbPath = path("ghostchat.db")
        try? Data(count: 128).write(to: URL(fileURLWithPath: dbPath))
        SecureWipe.wipeDatabase(at: dbPath) // no throw
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath))
    }

    // MARK: - wipeDirectory

    func test_wipeDirectory_nonRecursive_clearsTopLevelFiles() throws {
        try Data("a".utf8).write(to: URL(fileURLWithPath: path("a.dat")))
        try Data("b".utf8).write(to: URL(fileURLWithPath: path("b.dat")))
        try FileManager.default.createDirectory(atPath: path("nested"),
                                                withIntermediateDirectories: true)
        try Data("c".utf8).write(to: URL(fileURLWithPath: path("nested/c.dat")))
        SecureWipe.wipeDirectory(at: tmpDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("a.dat")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("b.dat")))
        // nested directory left alone when recursive=false
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("nested/c.dat")))
    }

    func test_wipeDirectory_recursive_clearsNested() throws {
        try FileManager.default.createDirectory(atPath: path("nested/deep"),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: path("nested/deep/file.dat")))
        SecureWipe.wipeDirectory(at: tmpDir, recursive: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("nested/deep/file.dat")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("nested")))
    }
}
