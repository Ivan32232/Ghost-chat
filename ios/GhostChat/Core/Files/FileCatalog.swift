import Foundation

/// Static registry of MIME types Ghost Chat accepts as attachments. Used to
/// reject unsupported payloads at the UI layer and to guess a MIME type from a
/// filename when the OS picker didn't provide one.
///
/// Mirror of Android `core/files/FileCatalog.kt`. Keep the table in sync.
enum FileCatalog {

    enum Category: String, Equatable {
        case image
        case video
        case audio
        case document
    }

    struct Entry: Equatable {
        let mimeType: String
        let ext: String
        let category: Category
    }

    static let entries: [Entry] = [
        // Images
        .init(mimeType: "image/jpeg", ext: "jpg",  category: .image),
        .init(mimeType: "image/jpeg", ext: "jpeg", category: .image),
        .init(mimeType: "image/png",  ext: "png",  category: .image),
        .init(mimeType: "image/gif",  ext: "gif",  category: .image),
        .init(mimeType: "image/heic", ext: "heic", category: .image),
        .init(mimeType: "image/webp", ext: "webp", category: .image),
        // Video
        .init(mimeType: "video/mp4",       ext: "mp4", category: .video),
        .init(mimeType: "video/quicktime", ext: "mov", category: .video),
        // Audio
        .init(mimeType: "audio/mpeg", ext: "mp3", category: .audio),
        .init(mimeType: "audio/mp4",  ext: "m4a", category: .audio),
        .init(mimeType: "audio/aac",  ext: "aac", category: .audio),
        .init(mimeType: "audio/wav",  ext: "wav", category: .audio),
        // Documents
        .init(mimeType: "application/pdf",   ext: "pdf",  category: .document),
        .init(mimeType: "application/msword", ext: "doc", category: .document),
        .init(
            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            ext: "docx", category: .document
        ),
        .init(mimeType: "text/plain",      ext: "txt", category: .document),
        .init(mimeType: "application/zip", ext: "zip", category: .document)
    ]

    static func isSupportedMimeType(_ mime: String) -> Bool {
        entries.contains { $0.mimeType == mime }
    }

    static func categoryFor(mimeType: String) -> Category? {
        entries.first { $0.mimeType == mimeType }?.category
    }

    static func mimeType(forFilename filename: String) -> String? {
        let ext = (filename as NSString).pathExtension.lowercased()
        return entries.first { $0.ext == ext }?.mimeType
    }

    /// Primary (first-listed) extension for a MIME type. `.jpg` wins over `.jpeg`.
    static func primaryExtension(forMimeType mime: String) -> String? {
        entries.first { $0.mimeType == mime }?.ext
    }
}
