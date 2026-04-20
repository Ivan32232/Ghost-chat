import SwiftUI

@main
struct GhostChatApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Ghost Chat")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("Phase 3 scaffolding")
                    .foregroundStyle(.gray)
            }
        }
    }
}
