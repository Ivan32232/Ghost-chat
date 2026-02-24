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
                    // Пробуем восстановить сохранённую сессию
                    await viewModel.restoreSession()
                }
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

            Text("Ожидание собеседника")
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
                                Text("Скопировать")
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
                            message: Text("Присоединяйся к приватному чату")
                        ) {
                            VStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.title3)
                                Text("Поделиться")
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
                Text("Отмена")
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

            Text("Подключение...")
                .font(.title3)
                .foregroundStyle(.white)

            Text("Устанавливаем P2P соединение")
                .font(.caption)
                .foregroundStyle(.gray)

            Spacer()

            Button {
                viewModel.leave()
            } label: {
                Text("Отмена")
                    .foregroundStyle(.red)
            }
            .padding(.bottom, 24)
        }
        .background(Color.black)
    }
}
