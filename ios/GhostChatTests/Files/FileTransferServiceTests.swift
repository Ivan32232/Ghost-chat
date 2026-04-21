import XCTest
import CryptoKit
@testable import GhostChat

final class FileTransferServiceTests: XCTestCase {

    // MARK: - Outbound chunking

    func test_prepareOutbound_splitsExactMultiple() throws {
        let svc = FileTransferService()
        let data = Data(repeating: 0xAB, count: 4096)
        let out = try svc.prepareOutbound(data: data, name: "a.bin", mimeType: "application/zip")
        XCTAssertEqual(out.totalChunks, 2)
        XCTAssertEqual(out.chunkMessages.count, 2)
        XCTAssertEqual(out.size, 4096)
    }

    func test_prepareOutbound_splitsWithRemainder() throws {
        let svc = FileTransferService()
        let data = Data(repeating: 0x01, count: 5000)
        let out = try svc.prepareOutbound(data: data, name: "a.bin", mimeType: "application/zip")
        XCTAssertEqual(out.totalChunks, 3)
        XCTAssertEqual(out.chunkMessages.count, 3)
    }

    func test_prepareOutbound_zeroByteFile() throws {
        let svc = FileTransferService()
        let out = try svc.prepareOutbound(data: Data(), name: "empty.bin", mimeType: "application/zip")
        XCTAssertEqual(out.totalChunks, 0)
        XCTAssertEqual(out.chunkMessages.count, 0)
        XCTAssertEqual(out.size, 0)
        // SHA-256 of empty input
        XCTAssertEqual(out.sha256Hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func test_prepareOutbound_sha256Hex_matchesKnownVector() throws {
        let svc = FileTransferService()
        let out = try svc.prepareOutbound(
            data: "abc".data(using: .utf8)!,
            name: "t.txt",
            mimeType: "text/plain"
        )
        // SHA-256("abc") per FIPS 180-4
        XCTAssertEqual(out.sha256Hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func test_prepareOutbound_rejectsEmptyName() {
        let svc = FileTransferService()
        XCTAssertThrowsError(try svc.prepareOutbound(data: Data(), name: "", mimeType: "text/plain")) { err in
            XCTAssertEqual(err as? FileTransferError, .emptyName)
        }
    }

    func test_prepareOutbound_messageWireShapes() throws {
        let svc = FileTransferService()
        let out = try svc.prepareOutbound(data: Data([0x01, 0x02, 0x03]), name: "a.bin", mimeType: "text/plain")
        guard case .fileStart(let sid, let name, let size, let mime, let total) = out.startMessage else {
            XCTFail("not fileStart"); return
        }
        XCTAssertEqual(sid, out.fileId)
        XCTAssertEqual(name, "a.bin")
        XCTAssertEqual(size, 3)
        XCTAssertEqual(mime, "text/plain")
        XCTAssertEqual(total, 1)
        guard case .fileComplete(let cid, let hex) = out.completeMessage else {
            XCTFail("not fileComplete"); return
        }
        XCTAssertEqual(cid, out.fileId)
        XCTAssertEqual(hex, out.sha256Hex)
    }

    // MARK: - Roundtrip

    private func roundtrip(data: Data, mimeType: String = "application/zip") throws -> Data? {
        let sender = FileTransferService()
        let receiver = FileTransferService()
        let out = try sender.prepareOutbound(data: data, name: "a.bin", mimeType: mimeType)
        _ = receiver.handleStart(
            fileId: out.fileId, name: "a.bin",
            size: data.count, mimeType: mimeType,
            totalChunks: out.totalChunks
        )
        for msg in out.chunkMessages {
            if case .fileChunk(let fid, let idx, let b64) = msg {
                _ = receiver.handleChunk(fileId: fid, index: idx, base64Data: b64)
            }
        }
        let event = receiver.handleComplete(fileId: out.fileId, expectedSha256Hex: out.sha256Hex)
        if case .completed(let file) = event { return file.data }
        return nil
    }

    func test_roundtrip_500bytes_reassemblesIdentical() throws {
        let data = Data((0..<500).map { _ in UInt8.random(in: 0...255) })
        let out = try roundtrip(data: data)
        XCTAssertEqual(out, data)
    }

    func test_roundtrip_1MB_reassemblesIdentical() throws {
        let data = Data((0..<(1024 * 1024)).map { _ in UInt8.random(in: 0...255) })
        let out = try roundtrip(data: data)
        XCTAssertEqual(out, data)
    }

    func test_roundtrip_zeroByteFile() throws {
        let out = try roundtrip(data: Data())
        XCTAssertEqual(out, Data())
    }

    func test_roundtrip_handlesOutOfOrderChunks() throws {
        let sender = FileTransferService()
        let receiver = FileTransferService()
        let src = Data(repeating: 0x42, count: 5000)
        let out = try sender.prepareOutbound(data: src, name: "x.bin", mimeType: "application/zip")
        _ = receiver.handleStart(
            fileId: out.fileId, name: "x.bin",
            size: src.count, mimeType: "application/zip",
            totalChunks: out.totalChunks
        )
        for msg in out.chunkMessages.reversed() {
            if case .fileChunk(let fid, let idx, let b64) = msg {
                _ = receiver.handleChunk(fileId: fid, index: idx, base64Data: b64)
            }
        }
        let event = receiver.handleComplete(fileId: out.fileId, expectedSha256Hex: out.sha256Hex)
        if case .completed(let file) = event {
            XCTAssertEqual(file.data, src)
        } else {
            XCTFail("expected completed, got \(event)")
        }
    }

    // MARK: - Error paths

    func test_handleComplete_missingChunks_returnsMissing() throws {
        let sender = FileTransferService()
        let receiver = FileTransferService()
        let src = Data(repeating: 0x42, count: 5000)
        let out = try sender.prepareOutbound(data: src, name: "x.bin", mimeType: "application/zip")
        _ = receiver.handleStart(
            fileId: out.fileId, name: "x.bin",
            size: src.count, mimeType: "application/zip",
            totalChunks: out.totalChunks
        )
        for (i, msg) in out.chunkMessages.enumerated() where i != 1 {
            if case .fileChunk(let fid, let idx, let b64) = msg {
                _ = receiver.handleChunk(fileId: fid, index: idx, base64Data: b64)
            }
        }
        let event = receiver.handleComplete(fileId: out.fileId, expectedSha256Hex: out.sha256Hex)
        if case .missing(_, let indices) = event {
            XCTAssertEqual(indices, [1])
        } else {
            XCTFail("expected missing, got \(event)")
        }
    }

    func test_handleComplete_integrityFailure_onCorruptedChunk() throws {
        let sender = FileTransferService()
        let receiver = FileTransferService()
        let src = Data(repeating: 0x01, count: 100)
        let out = try sender.prepareOutbound(data: src, name: "x.bin", mimeType: "application/zip")
        _ = receiver.handleStart(
            fileId: out.fileId, name: "x.bin",
            size: src.count, mimeType: "application/zip",
            totalChunks: out.totalChunks
        )
        let corrupt = Data(repeating: 0xFF, count: src.count).base64EncodedString()
        _ = receiver.handleChunk(fileId: out.fileId, index: 0, base64Data: corrupt)
        let event = receiver.handleComplete(fileId: out.fileId, expectedSha256Hex: out.sha256Hex)
        if case .integrityFailure = event {} else {
            XCTFail("expected integrityFailure, got \(event)")
        }
    }

    func test_handleChunk_unknownFileId_returnsUnknown() {
        let svc = FileTransferService()
        let event = svc.handleChunk(fileId: "missing", index: 0, base64Data: "AA==")
        if case .unknown(let fid) = event {
            XCTAssertEqual(fid, "missing")
        } else {
            XCTFail("expected unknown, got \(event)")
        }
    }

    func test_handleChunk_rejectsOutOfRangeIndex() {
        let svc = FileTransferService()
        _ = svc.handleStart(fileId: "f", name: "n", size: 10, mimeType: "x", totalChunks: 1)
        let event = svc.handleChunk(fileId: "f", index: 42, base64Data: "AA==")
        if case .unknown = event {} else { XCTFail("expected unknown for OOB index") }
    }

    func test_handleChunk_rejectsInvalidBase64() {
        let svc = FileTransferService()
        _ = svc.handleStart(fileId: "f", name: "n", size: 10, mimeType: "x", totalChunks: 1)
        let event = svc.handleChunk(fileId: "f", index: 0, base64Data: "%%not-base64%%")
        if case .unknown = event {} else { XCTFail("expected unknown for bad base64") }
    }

    func test_missingChunks_afterStart_returnsAll() {
        let svc = FileTransferService()
        _ = svc.handleStart(fileId: "f", name: "n", size: 4096, mimeType: "x", totalChunks: 2)
        XCTAssertEqual(svc.missingChunks(fileId: "f"), [0, 1])
    }

    func test_missingChunks_afterPartial() {
        let svc = FileTransferService()
        _ = svc.handleStart(fileId: "f", name: "n", size: 4096, mimeType: "x", totalChunks: 3)
        _ = svc.handleChunk(fileId: "f", index: 0, base64Data: "AA==")
        _ = svc.handleChunk(fileId: "f", index: 2, base64Data: "AA==")
        XCTAssertEqual(svc.missingChunks(fileId: "f"), [1])
    }

    func test_cancelInbound_removesState() {
        let svc = FileTransferService()
        _ = svc.handleStart(fileId: "f", name: "n", size: 2048, mimeType: "x", totalChunks: 1)
        svc.cancelInbound(fileId: "f")
        XCTAssertNil(svc.missingChunks(fileId: "f"))
    }

    func test_concurrentFiles_areIndependent() throws {
        let sender = FileTransferService()
        let receiver = FileTransferService()
        let d1 = Data(repeating: 0x11, count: 500)
        let d2 = Data(repeating: 0x22, count: 800)
        let o1 = try sender.prepareOutbound(data: d1, name: "a.bin", mimeType: "application/zip")
        let o2 = try sender.prepareOutbound(data: d2, name: "b.bin", mimeType: "application/zip")

        _ = receiver.handleStart(fileId: o1.fileId, name: "a.bin",
                                 size: d1.count, mimeType: "application/zip",
                                 totalChunks: o1.totalChunks)
        _ = receiver.handleStart(fileId: o2.fileId, name: "b.bin",
                                 size: d2.count, mimeType: "application/zip",
                                 totalChunks: o2.totalChunks)

        for msg in o1.chunkMessages {
            if case .fileChunk(let fid, let idx, let b64) = msg {
                _ = receiver.handleChunk(fileId: fid, index: idx, base64Data: b64)
            }
        }
        for msg in o2.chunkMessages {
            if case .fileChunk(let fid, let idx, let b64) = msg {
                _ = receiver.handleChunk(fileId: fid, index: idx, base64Data: b64)
            }
        }

        guard case .completed(let f1) = receiver.handleComplete(fileId: o1.fileId, expectedSha256Hex: o1.sha256Hex) else {
            XCTFail("f1 not completed"); return
        }
        guard case .completed(let f2) = receiver.handleComplete(fileId: o2.fileId, expectedSha256Hex: o2.sha256Hex) else {
            XCTFail("f2 not completed"); return
        }
        XCTAssertEqual(f1.data, d1)
        XCTAssertEqual(f2.data, d2)
    }

    // MARK: - Retransmit

    func test_retransmitMessages_returnsSameChunksByIndex() throws {
        let svc = FileTransferService()
        let data = Data(repeating: 0x77, count: 5000)
        let out = try svc.prepareOutbound(data: data, name: "x.bin", mimeType: "application/zip")
        let again = svc.retransmitMessages(fileId: out.fileId, indices: [0, 2])
        XCTAssertEqual(again.count, 2)
        if case .fileChunk(_, let i0, _) = again[0] { XCTAssertEqual(i0, 0) } else { XCTFail() }
        if case .fileChunk(_, let i2, _) = again[1] { XCTAssertEqual(i2, 2) } else { XCTFail() }
    }

    func test_retransmitMessages_unknownFile_returnsEmpty() {
        let svc = FileTransferService()
        XCTAssertTrue(svc.retransmitMessages(fileId: "no-such", indices: [0, 1]).isEmpty)
    }

    func test_forgetOutbound_clearsState() throws {
        let svc = FileTransferService()
        let out = try svc.prepareOutbound(data: Data(repeating: 1, count: 100), name: "x", mimeType: "x")
        XCTAssertTrue(svc.hasOutbound(fileId: out.fileId))
        svc.forgetOutbound(fileId: out.fileId)
        XCTAssertFalse(svc.hasOutbound(fileId: out.fileId))
    }

    // MARK: - Cross-platform test vector

    /// The exact sha256 hex below must match the Android test `fileTransferService_crossPlatformVector`.
    func test_crossPlatformVector_deterministicHashForFixedInput() throws {
        let svc = FileTransferService()
        // 4000 bytes, byte i = (i * 31 + 7) mod 256 — deterministic.
        var bytes: [UInt8] = []; bytes.reserveCapacity(4000)
        for i in 0..<4000 { bytes.append(UInt8(((i &* 31) &+ 7) & 0xFF)) }
        let out = try svc.prepareOutbound(data: Data(bytes), name: "vector.bin", mimeType: "application/zip")
        XCTAssertEqual(out.totalChunks, 2) // 4000 / 2048 = 1.95 → 2
        XCTAssertEqual(out.sha256Hex, "2e781e3762b7c315ce53c7e3645f59b2e4c037db30c6bec3a195e0751bd62722")
    }
}

final class FileCatalogTests: XCTestCase {

    func test_imageMimeTypes_areSupported() {
        for mime in ["image/jpeg", "image/png", "image/gif", "image/heic", "image/webp"] {
            XCTAssertTrue(FileCatalog.isSupportedMimeType(mime), "mime \(mime) should be supported")
            XCTAssertEqual(FileCatalog.categoryFor(mimeType: mime), .image)
        }
    }

    func test_videoMimeTypes_areSupported() {
        XCTAssertEqual(FileCatalog.categoryFor(mimeType: "video/mp4"), .video)
        XCTAssertEqual(FileCatalog.categoryFor(mimeType: "video/quicktime"), .video)
    }

    func test_audioMimeTypes_areSupported() {
        XCTAssertEqual(FileCatalog.categoryFor(mimeType: "audio/mpeg"), .audio)
        XCTAssertEqual(FileCatalog.categoryFor(mimeType: "audio/mp4"), .audio)
    }

    func test_documentMimeTypes_areSupported() {
        XCTAssertEqual(FileCatalog.categoryFor(mimeType: "application/pdf"), .document)
        XCTAssertEqual(FileCatalog.categoryFor(mimeType: "application/zip"), .document)
        XCTAssertEqual(FileCatalog.categoryFor(mimeType: "text/plain"), .document)
    }

    func test_unsupportedMimeType_isRejected() {
        XCTAssertFalse(FileCatalog.isSupportedMimeType("application/x-evil"))
        XCTAssertNil(FileCatalog.categoryFor(mimeType: "application/x-evil"))
    }

    func test_extensionResolvesToMime_caseInsensitive() {
        XCTAssertEqual(FileCatalog.mimeType(forFilename: "report.pdf"), "application/pdf")
        XCTAssertEqual(FileCatalog.mimeType(forFilename: "clip.MOV"), "video/quicktime")
        XCTAssertEqual(FileCatalog.mimeType(forFilename: "photo.JPEG"), "image/jpeg")
    }

    func test_m4aVoiceMessageMimeType() {
        XCTAssertEqual(FileCatalog.mimeType(forFilename: "msg.m4a"), "audio/mp4")
    }

    func test_primaryExtensionForMime() {
        XCTAssertEqual(FileCatalog.primaryExtension(forMimeType: "image/jpeg"), "jpg")
        XCTAssertEqual(FileCatalog.primaryExtension(forMimeType: "audio/mp4"), "m4a")
    }
}
