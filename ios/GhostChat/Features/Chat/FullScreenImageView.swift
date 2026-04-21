import SwiftUI
import UIKit

/// Full-screen image viewer with pinch-to-zoom and drag-to-pan. The bitmap is
/// down-sampled to `maxDimension` on decode so gigantic attachments don't blow
/// the process heap.
struct FullScreenImageView: View {

    let url: URL
    let onClose: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    private static let maxDimension: CGFloat = 2048

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = FullScreenImageView.sampledImage(at: url, maxDimension: Self.maxDimension) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnification)
                    .simultaneousGesture(drag)
                    .onTapGesture(count: 2) { withAnimation { resetZoom() } }
            } else {
                Text("Cannot display image").foregroundStyle(.white)
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                    }
                    .padding(16)
                }
                Spacer()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in scale = max(1.0, baseScale * value) }
            .onEnded { _ in baseScale = scale }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width:  baseOffset.width  + value.translation.width,
                    height: baseOffset.height + value.translation.height
                )
            }
            .onEnded { _ in baseOffset = offset }
    }

    private func resetZoom() {
        scale = 1; baseScale = 1
        offset = .zero; baseOffset = .zero
    }

    /// Decode a bitmap to at most `maxDimension` on the longer side using
    /// ImageIO's thumbnail pipeline — avoids loading the full bitmap into RAM.
    static func sampledImage(at url: URL, maxDimension: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}
