import SwiftUI

@main
struct GhostChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = ChatViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .preferredColorScheme(.dark)
                .task {
                    await viewModel.restoreSession()
                }
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
    }

    /// Обработка deep link: https://gbskgs.xyz/?room=ROOM_ID или ghostchat://join?room=ROOM_ID
    private func handleIncomingURL(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        guard let roomId = components?.queryItems?.first(where: { $0.name == "room" })?.value,
              !roomId.isEmpty else { return }

        // Если уже в чате — игнорируем
        guard viewModel.screen == .welcome else { return }

        Task {
            await viewModel.joinRoom(roomId)
        }
    }
}

/// Root view — маршрутизация экранов
struct ContentView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.screen {
            case .welcome:
                WelcomeView(viewModel: viewModel)

            case .waiting:
                WaitingView(viewModel: viewModel)

            case .connecting:
                ConnectingView(viewModel: viewModel)

            case .chat:
                ChatView(viewModel: viewModel)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.screen)
    }
}

// MARK: - Waiting Screen

struct WaitingView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.2)
                .tint(.white)

            Text("waiting.title")
                .font(.title3)
                .foregroundStyle(.white)

            // Room ID
            if let roomId = viewModel.roomId {
                VStack(spacing: 12) {
                    Text(roomId)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.gray)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    HStack(spacing: 12) {
                        // Copy link
                        Button {
                            if let link = viewModel.getInviteLink() {
                                UIPasteboard.general.string = link
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "doc.on.doc")
                                    .font(.title3)
                                Text("waiting.copy")
                                    .font(.caption)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                        }

                        // Share
                        ShareLink(
                            item: viewModel.getInviteLink() ?? "",
                            subject: Text("Ghost Chat"),
                            message: Text("waiting.shareMessage")
                        ) {
                            VStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.title3)
                                Text("waiting.share")
                                    .font(.caption)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }

            Spacer()

            Button {
                viewModel.leave()
            } label: {
                Text("waiting.cancel")
                    .foregroundStyle(.red)
            }
            .padding(.bottom, 24)
        }
        .background(Color.black)
    }
}

// MARK: - Connecting Screen

struct ConnectingView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.2)
                .tint(.white)

            Text("connecting.title")
                .font(.title3)
                .foregroundStyle(.white)

            Text("connecting.subtitle")
                .font(.caption)
                .foregroundStyle(.gray)

            Spacer()

            Button {
                viewModel.leave()
            } label: {
                Text("connecting.cancel")
                    .foregroundStyle(.red)
            }
            .padding(.bottom, 24)
        }
        .background(Color.black)
    }
}
