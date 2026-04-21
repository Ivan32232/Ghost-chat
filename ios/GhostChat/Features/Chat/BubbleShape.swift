import SwiftUI

/// Tapered-corner chat bubble. Matches the Android `bubbleShape(isMe:)` shape point-for-point.
///
/// `tailSide == .trailing` renders a bubble whose lower-right corner lacks a round
/// — visually "pointing" at the sender slot. `tailSide == .leading` mirrors it for the peer.
/// System-centred bubbles use plain rounded rectangles — this shape is not needed.
struct BubbleShape: Shape {
    enum TailSide { case leading, trailing }
    let tailSide: TailSide
    var cornerRadius: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        var path = Path()
        let topLeft     = CGPoint(x: rect.minX, y: rect.minY)
        let topRight    = CGPoint(x: rect.maxX, y: rect.minY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        let bottomLeft  = CGPoint(x: rect.minX, y: rect.maxY)

        // Top-left corner — always round.
        path.move(to: CGPoint(x: topLeft.x + r, y: topLeft.y))
        // Top edge → top-right corner (round).
        path.addLine(to: CGPoint(x: topRight.x - r, y: topRight.y))
        path.addArc(center: CGPoint(x: topRight.x - r, y: topRight.y + r),
                    radius: r, startAngle: .degrees(-90), endAngle: .zero, clockwise: false)
        // Right edge → bottom-right corner.
        if tailSide == .trailing {
            // Sharp corner for the tail.
            path.addLine(to: bottomRight)
        } else {
            path.addLine(to: CGPoint(x: bottomRight.x, y: bottomRight.y - r))
            path.addArc(center: CGPoint(x: bottomRight.x - r, y: bottomRight.y - r),
                        radius: r, startAngle: .zero, endAngle: .degrees(90), clockwise: false)
        }
        // Bottom edge → bottom-left corner.
        if tailSide == .leading {
            path.addLine(to: bottomLeft)
        } else {
            path.addLine(to: CGPoint(x: bottomLeft.x + r, y: bottomLeft.y))
            path.addArc(center: CGPoint(x: bottomLeft.x + r, y: bottomLeft.y - r),
                        radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        }
        // Left edge → back to top-left round.
        path.addLine(to: CGPoint(x: topLeft.x, y: topLeft.y + r))
        path.addArc(center: CGPoint(x: topLeft.x + r, y: topLeft.y + r),
                    radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}
