import SwiftUI
import UIKit

struct ChatBubble: View {
    let message: ChatMessage
    var onPreviewImage: ((URL) -> Void)? = nil

    var body: some View {
        HStack {
            if message.sender == .me { Spacer(minLength: 48) }
            if message.sender == .system {
                systemRow
            } else {
                contentRow
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: alignment)
            }
            if message.sender == .peer { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    @ViewBuilder private var contentRow: some View {
        switch message.type {
        case .text, .system:
            textContent
        case .voice:
            voiceContent
        case .file:
            if let mime = message.fileMimeType,
               FileCatalog.categoryFor(mimeType: mime) == .image {
                imageContent
            } else {
                fileCardContent
            }
        }
    }

    private var textContent: some View {
        Text(message.text)
            .font(GhostType.bubbleBody)
            .foregroundStyle(foreground)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(background, in: bubbleShape)
    }

    private var voiceContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.circle.fill")
                .foregroundStyle(foreground)
                .font(.title2)
            Text(durationLabel)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(foreground.opacity(0.8))
            if let size = message.fileSize {
                Text(ChatBubble.formatBytes(size))
                    .font(.caption)
                    .foregroundStyle(foreground.opacity(0.6))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(background, in: bubbleShape)
    }

    private var imageContent: some View {
        Group {
            if let path = message.fileLocalPath,
               let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .onTapGesture {
                        onPreviewImage?(URL(fileURLWithPath: path))
                    }
            } else {
                fileCardContent
            }
        }
    }

    private var fileCardContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .foregroundStyle(foreground)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.fileName ?? "file")
                    .lineLimit(1)
                    .foregroundStyle(foreground)
                    .font(.subheadline)
                if let size = message.fileSize {
                    Text(ChatBubble.formatBytes(size))
                        .font(.caption)
                        .foregroundStyle(foreground.opacity(0.6))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(background, in: bubbleShape)
    }

    private var systemRow: some View {
        HStack {
            Spacer(minLength: 0)
            Text(message.text)
                .font(GhostType.systemNote)
                .foregroundStyle(.gray)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.white.opacity(0.05), in: Capsule())
            Spacer(minLength: 0)
        }
    }

    // MARK: - Styling

    private var foreground: Color { message.sender == .me ? .black : .white }
    private var background: Color { message.sender == .me ? .white : .white.opacity(0.1) }

    /// The tapered bubble — tail points at `me` on the right, `peer` on the left.
    private var bubbleShape: BubbleShape {
        BubbleShape(tailSide: message.sender == .me ? .trailing : .leading)
    }

    private var alignment: Alignment {
        switch message.sender {
        case .me:     return .trailing
        case .peer:   return .leading
        case .system: return .center
        }
    }

    private var durationLabel: String {
        guard let size = message.fileSize, size > 0 else { return "voice" }
        // Rough estimate: 64 kbps = 8 KiB/sec.
        let seconds = max(1, Int(Double(size) / 8192))
        let m = seconds / 60, s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    static func formatBytes(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }
}
