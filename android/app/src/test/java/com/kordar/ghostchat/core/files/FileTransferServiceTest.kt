package com.kordar.ghostchat.core.files

import com.google.common.truth.Truth.assertThat
import com.kordar.ghostchat.models.ControlMessage
import org.junit.Assert.assertThrows
import org.junit.Test
import kotlin.random.Random

class FileTransferServiceTest {

    // MARK: - Outbound chunking

    @Test
    fun `prepareOutbound splits exact multiple`() {
        val svc = FileTransferService()
        val data = ByteArray(4096) { 0xAB.toByte() }
        val out = svc.prepareOutbound(data, "a.bin", "application/zip")
        assertThat(out.totalChunks).isEqualTo(2)
        assertThat(out.chunkMessages).hasSize(2)
        assertThat(out.size).isEqualTo(4096)
    }

    @Test
    fun `prepareOutbound splits with remainder`() {
        val svc = FileTransferService()
        val data = ByteArray(5000) { 0x01.toByte() }
        val out = svc.prepareOutbound(data, "a.bin", "application/zip")
        assertThat(out.totalChunks).isEqualTo(3)
        assertThat(out.chunkMessages).hasSize(3)
    }

    @Test
    fun `prepareOutbound zero byte file`() {
        val svc = FileTransferService()
        val out = svc.prepareOutbound(ByteArray(0), "empty.bin", "application/zip")
        assertThat(out.totalChunks).isEqualTo(0)
        assertThat(out.chunkMessages).isEmpty()
        assertThat(out.size).isEqualTo(0)
        // SHA-256 of empty input (FIPS 180-4).
        assertThat(out.sha256Hex)
            .isEqualTo("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test
    fun `prepareOutbound sha256 matches known vector for abc`() {
        val svc = FileTransferService()
        val out = svc.prepareOutbound("abc".toByteArray(Charsets.UTF_8), "t.txt", "text/plain")
        assertThat(out.sha256Hex)
            .isEqualTo("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test
    fun `prepareOutbound rejects empty name`() {
        val svc = FileTransferService()
        assertThrows(IllegalArgumentException::class.java) {
            svc.prepareOutbound(ByteArray(0), "", "text/plain")
        }
    }

    @Test
    fun `prepareOutbound produces expected control-message shapes`() {
        val svc = FileTransferService()
        val out = svc.prepareOutbound(byteArrayOf(1, 2, 3), "a.bin", "text/plain")
        val start = out.startMessage as ControlMessage.FileStart
        assertThat(start.fileId).isEqualTo(out.fileId)
        assertThat(start.name).isEqualTo("a.bin")
        assertThat(start.size).isEqualTo(3)
        assertThat(start.mimeType).isEqualTo("text/plain")
        assertThat(start.totalChunks).isEqualTo(1)
        val complete = out.completeMessage as ControlMessage.FileComplete
        assertThat(complete.fileId).isEqualTo(out.fileId)
        assertThat(complete.sha256).isEqualTo(out.sha256Hex)
    }

    // MARK: - Roundtrip

    private fun roundtrip(data: ByteArray, mimeType: String = "application/zip"): ByteArray? {
        val sender = FileTransferService()
        val receiver = FileTransferService()
        val out = sender.prepareOutbound(data, "a.bin", mimeType)
        receiver.handleStart(out.fileId, "a.bin", data.size, mimeType, out.totalChunks)
        for (msg in out.chunkMessages) {
            val chunk = msg as ControlMessage.FileChunk
            receiver.handleChunk(chunk.fileId, chunk.index, chunk.data)
        }
        val event = receiver.handleComplete(out.fileId, out.sha256Hex)
        return (event as? FileTransferService.Event.Completed)?.file?.data
    }

    @Test
    fun `roundtrip 500 bytes matches source`() {
        val data = Random.nextBytes(500)
        assertThat(roundtrip(data)).isEqualTo(data)
    }

    @Test
    fun `roundtrip 1MB matches source`() {
        val data = Random.nextBytes(1024 * 1024)
        assertThat(roundtrip(data)).isEqualTo(data)
    }

    @Test
    fun `roundtrip zero byte file`() {
        assertThat(roundtrip(ByteArray(0))).isEqualTo(ByteArray(0))
    }

    @Test
    fun `roundtrip handles out-of-order chunks`() {
        val sender = FileTransferService()
        val receiver = FileTransferService()
        val src = ByteArray(5000) { 0x42.toByte() }
        val out = sender.prepareOutbound(src, "x.bin", "application/zip")
        receiver.handleStart(out.fileId, "x.bin", src.size, "application/zip", out.totalChunks)
        for (msg in out.chunkMessages.reversed()) {
            val chunk = msg as ControlMessage.FileChunk
            receiver.handleChunk(chunk.fileId, chunk.index, chunk.data)
        }
        val ev = receiver.handleComplete(out.fileId, out.sha256Hex)
        val file = (ev as FileTransferService.Event.Completed).file
        assertThat(file.data).isEqualTo(src)
    }

    // MARK: - Error paths

    @Test
    fun `handleComplete missing chunks returns missing list`() {
        val sender = FileTransferService()
        val receiver = FileTransferService()
        val src = ByteArray(5000) { 0x42.toByte() }
        val out = sender.prepareOutbound(src, "x.bin", "application/zip")
        receiver.handleStart(out.fileId, "x.bin", src.size, "application/zip", out.totalChunks)
        for ((i, msg) in out.chunkMessages.withIndex()) {
            if (i == 1) continue
            val chunk = msg as ControlMessage.FileChunk
            receiver.handleChunk(chunk.fileId, chunk.index, chunk.data)
        }
        val ev = receiver.handleComplete(out.fileId, out.sha256Hex) as FileTransferService.Event.Missing
        assertThat(ev.indices).containsExactly(1)
    }

    @Test
    fun `handleComplete returns integrity failure on corrupted chunk`() {
        val sender = FileTransferService()
        val receiver = FileTransferService()
        val src = ByteArray(100) { 0x01.toByte() }
        val out = sender.prepareOutbound(src, "x.bin", "application/zip")
        receiver.handleStart(out.fileId, "x.bin", src.size, "application/zip", out.totalChunks)
        val corrupt = java.util.Base64.getEncoder()
            .encodeToString(ByteArray(src.size) { 0xFF.toByte() })
        receiver.handleChunk(out.fileId, 0, corrupt)
        val ev = receiver.handleComplete(out.fileId, out.sha256Hex)
        assertThat(ev).isInstanceOf(FileTransferService.Event.IntegrityFailure::class.java)
    }

    @Test
    fun `handleChunk unknown fileId returns unknown`() {
        val svc = FileTransferService()
        val ev = svc.handleChunk("missing", 0, "AA==")
        assertThat(ev).isInstanceOf(FileTransferService.Event.Unknown::class.java)
    }

    @Test
    fun `handleChunk rejects out-of-range index`() {
        val svc = FileTransferService()
        svc.handleStart("f", "n", 10, "x", 1)
        val ev = svc.handleChunk("f", 42, "AA==")
        assertThat(ev).isInstanceOf(FileTransferService.Event.Unknown::class.java)
    }

    @Test
    fun `handleChunk rejects invalid base64`() {
        val svc = FileTransferService()
        svc.handleStart("f", "n", 10, "x", 1)
        val ev = svc.handleChunk("f", 0, "%%not-base64%%")
        assertThat(ev).isInstanceOf(FileTransferService.Event.Unknown::class.java)
    }

    @Test
    fun `missingChunks after start returns all indices`() {
        val svc = FileTransferService()
        svc.handleStart("f", "n", 4096, "x", 2)
        assertThat(svc.missingChunks("f")).isEqualTo(listOf(0, 1))
    }

    @Test
    fun `missingChunks after partial receives`() {
        val svc = FileTransferService()
        svc.handleStart("f", "n", 4096, "x", 3)
        svc.handleChunk("f", 0, "AA==")
        svc.handleChunk("f", 2, "AA==")
        assertThat(svc.missingChunks("f")).isEqualTo(listOf(1))
    }

    @Test
    fun `cancelInbound removes state`() {
        val svc = FileTransferService()
        svc.handleStart("f", "n", 2048, "x", 1)
        svc.cancelInbound("f")
        assertThat(svc.missingChunks("f")).isNull()
    }

    @Test
    fun `two concurrent files are independent`() {
        val sender = FileTransferService()
        val receiver = FileTransferService()
        val d1 = ByteArray(500) { 0x11.toByte() }
        val d2 = ByteArray(800) { 0x22.toByte() }
        val o1 = sender.prepareOutbound(d1, "a.bin", "application/zip")
        val o2 = sender.prepareOutbound(d2, "b.bin", "application/zip")

        receiver.handleStart(o1.fileId, "a.bin", d1.size, "application/zip", o1.totalChunks)
        receiver.handleStart(o2.fileId, "b.bin", d2.size, "application/zip", o2.totalChunks)

        for (msg in o1.chunkMessages) {
            val c = msg as ControlMessage.FileChunk
            receiver.handleChunk(c.fileId, c.index, c.data)
        }
        for (msg in o2.chunkMessages) {
            val c = msg as ControlMessage.FileChunk
            receiver.handleChunk(c.fileId, c.index, c.data)
        }
        val e1 = receiver.handleComplete(o1.fileId, o1.sha256Hex) as FileTransferService.Event.Completed
        val e2 = receiver.handleComplete(o2.fileId, o2.sha256Hex) as FileTransferService.Event.Completed
        assertThat(e1.file.data).isEqualTo(d1)
        assertThat(e2.file.data).isEqualTo(d2)
    }

    // MARK: - Retransmit

    @Test
    fun `retransmit returns same chunks by index`() {
        val svc = FileTransferService()
        val data = ByteArray(5000) { 0x77.toByte() }
        val out = svc.prepareOutbound(data, "x.bin", "application/zip")
        val again = svc.retransmitMessages(out.fileId, listOf(0, 2))
        assertThat(again).hasSize(2)
        assertThat((again[0] as ControlMessage.FileChunk).index).isEqualTo(0)
        assertThat((again[1] as ControlMessage.FileChunk).index).isEqualTo(2)
    }

    @Test
    fun `retransmit for unknown file returns empty`() {
        val svc = FileTransferService()
        assertThat(svc.retransmitMessages("missing", listOf(0, 1))).isEmpty()
    }

    @Test
    fun `forgetOutbound clears state`() {
        val svc = FileTransferService()
        val out = svc.prepareOutbound(ByteArray(100) { 1 }, "x", "x")
        assertThat(svc.hasOutbound(out.fileId)).isTrue()
        svc.forgetOutbound(out.fileId)
        assertThat(svc.hasOutbound(out.fileId)).isFalse()
    }

    // MARK: - Cross-platform vector

    @Test
    fun `cross-platform vector sha256 matches iOS`() {
        val svc = FileTransferService()
        val bytes = ByteArray(4000) { i -> ((i * 31 + 7) and 0xFF).toByte() }
        val out = svc.prepareOutbound(bytes, "vector.bin", "application/zip")
        assertThat(out.totalChunks).isEqualTo(2)
        // This hash must match the exact string in FileTransferServiceTests.swift
        assertThat(out.sha256Hex)
            .isEqualTo("2e781e3762b7c315ce53c7e3645f59b2e4c037db30c6bec3a195e0751bd62722")
    }
}

class FileCatalogTest {

    @Test
    fun `image mime types are supported`() {
        listOf("image/jpeg", "image/png", "image/gif", "image/heic", "image/webp").forEach { mime ->
            assertThat(FileCatalog.isSupportedMimeType(mime)).isTrue()
            assertThat(FileCatalog.categoryFor(mime)).isEqualTo(FileCatalog.Category.IMAGE)
        }
    }

    @Test
    fun `video mime types are supported`() {
        assertThat(FileCatalog.categoryFor("video/mp4")).isEqualTo(FileCatalog.Category.VIDEO)
        assertThat(FileCatalog.categoryFor("video/quicktime")).isEqualTo(FileCatalog.Category.VIDEO)
    }

    @Test
    fun `audio mime types are supported`() {
        assertThat(FileCatalog.categoryFor("audio/mpeg")).isEqualTo(FileCatalog.Category.AUDIO)
        assertThat(FileCatalog.categoryFor("audio/mp4")).isEqualTo(FileCatalog.Category.AUDIO)
    }

    @Test
    fun `document mime types are supported`() {
        assertThat(FileCatalog.categoryFor("application/pdf")).isEqualTo(FileCatalog.Category.DOCUMENT)
        assertThat(FileCatalog.categoryFor("application/zip")).isEqualTo(FileCatalog.Category.DOCUMENT)
        assertThat(FileCatalog.categoryFor("text/plain")).isEqualTo(FileCatalog.Category.DOCUMENT)
    }

    @Test
    fun `unsupported mime type is rejected`() {
        assertThat(FileCatalog.isSupportedMimeType("application/x-evil")).isFalse()
        assertThat(FileCatalog.categoryFor("application/x-evil")).isNull()
    }

    @Test
    fun `extension resolves to mime case-insensitively`() {
        assertThat(FileCatalog.mimeType("report.pdf")).isEqualTo("application/pdf")
        assertThat(FileCatalog.mimeType("clip.MOV")).isEqualTo("video/quicktime")
        assertThat(FileCatalog.mimeType("photo.JPEG")).isEqualTo("image/jpeg")
    }

    @Test
    fun `m4a resolves to audio mp4`() {
        assertThat(FileCatalog.mimeType("msg.m4a")).isEqualTo("audio/mp4")
    }

    @Test
    fun `primary extension for mime`() {
        assertThat(FileCatalog.primaryExtension("image/jpeg")).isEqualTo("jpg")
        assertThat(FileCatalog.primaryExtension("audio/mp4")).isEqualTo("m4a")
    }
}
