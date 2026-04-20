import SwiftUI

struct ChatView: View {
    var body: some View {
        Text("Chat — implemented in Stage 13")
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
    }
}
