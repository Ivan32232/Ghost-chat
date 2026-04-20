import SwiftUI

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.sender == .me { Spacer(minLength: 48) }
            if message.sender == .system {
                Spacer(minLength: 0)
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.white.opacity(0.05), in: Capsule())
                Spacer(minLength: 0)
            } else {
                Text(message.text)
                    .foregroundStyle(foreground)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(background, in: RoundedRectangle(cornerRadius: 14))
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: alignment)
            }
            if message.sender == .peer { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var foreground: Color {
        message.sender == .me ? .black : .white
    }
    private var background: Color {
        message.sender == .me ? .white : .white.opacity(0.1)
    }
    private var alignment: Alignment {
        switch message.sender {
        case .me:     return .trailing
        case .peer:   return .leading
        case .system: return .center
        }
    }
}
