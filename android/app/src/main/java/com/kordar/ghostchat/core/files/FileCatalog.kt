package com.kordar.ghostchat.core.files

/**
 * Static registry of MIME types Ghost Chat accepts as attachments. Used to
 * reject unsupported payloads at the UI layer and to guess a MIME type from a
 * filename when the OS picker didn't provide one.
 *
 * Mirror of iOS `Core/Files/FileCatalog.swift`. Keep the table in sync.
 */
object FileCatalog {

    enum class Category { IMAGE, VIDEO, AUDIO, DOCUMENT }

    data class Entry(val mimeType: String, val ext: String, val category: Category)

    val entries: List<Entry> = listOf(
        // Images
        Entry("image/jpeg", "jpg",  Category.IMAGE),
        Entry("image/jpeg", "jpeg", Category.IMAGE),
        Entry("image/png",  "png",  Category.IMAGE),
        Entry("image/gif",  "gif",  Category.IMAGE),
        Entry("image/heic", "heic", Category.IMAGE),
        Entry("image/webp", "webp", Category.IMAGE),
        // Video
        Entry("video/mp4",       "mp4", Category.VIDEO),
        Entry("video/quicktime", "mov", Category.VIDEO),
        // Audio
        Entry("audio/mpeg", "mp3", Category.AUDIO),
        Entry("audio/mp4",  "m4a", Category.AUDIO),
        Entry("audio/aac",  "aac", Category.AUDIO),
        Entry("audio/wav",  "wav", Category.AUDIO),
        // Documents
        Entry("application/pdf",   "pdf",  Category.DOCUMENT),
        Entry("application/msword", "doc", Category.DOCUMENT),
        Entry(
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "docx", Category.DOCUMENT
        ),
        Entry("text/plain",      "txt", Category.DOCUMENT),
        Entry("application/zip", "zip", Category.DOCUMENT)
    )

    fun isSupportedMimeType(mime: String): Boolean =
        entries.any { it.mimeType == mime }

    fun categoryFor(mimeType: String): Category? =
        entries.firstOrNull { it.mimeType == mimeType }?.category

    fun mimeType(filename: String): String? {
        val ext = filename.substringAfterLast('.', "").lowercase()
        if (ext.isEmpty()) return null
        return entries.firstOrNull { it.ext == ext }?.mimeType
    }

    /** Primary (first-listed) extension for a MIME type. `.jpg` wins over `.jpeg`. */
    fun primaryExtension(mime: String): String? =
        entries.firstOrNull { it.mimeType == mime }?.ext
}
