import SwiftUI

/// Экран чата — сообщения + ввод
struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var messageText = ""
    @State private var showVerifyPanel = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            chatHeader

            // Messages
            messageList

            // Input
            if viewModel.callState != .ringing {
                messageInput
            }

            // Incoming call
            if viewModel.callState == .ringing {
                IncomingCallView(viewModel: viewModel)
            }
        }
        .background(Color.black)
        .overlay {
            // Call overlay
            if viewModel.callState == .calling || viewModel.callState == .active {
                CallView(viewModel: viewModel)
            }
        }
        .sheet(isPresented: $showVerifyPanel) {
            verifySheet
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack {
            // Connection status
            Button {
                showVerifyPanel = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.isVerified ? "checkmark.shield.fill" : "shield.fill")
                        .foregroundStyle(viewModel.isVerified ? .green : (viewModel.isConnected ? .white : .red))

                    Text(viewModel.fingerprint.isEmpty ? "" : String(viewModel.fingerprint.prefix(19)) + "...")
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Call button
            Button {
                Task { await viewModel.startCall() }
            } label: {
                Image(systemName: "phone.fill")
                    .foregroundStyle(viewModel.callState == .idle ? .white : .gray)
            }
            .disabled(viewModel.callState != .idle || !viewModel.isConnected)

            // Leave button
            Button {
                viewModel.leave()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.95))
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.messages.count) { _ in
                if let lastMessage = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input

    private var messageInput: some View {
        HStack(spacing: 8) {
            TextField("Сообщение", text: $messageText)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Color.white.opacity(0.08))
                .cornerRadius(20)
                .foregroundStyle(.white)
                .disabled(!viewModel.isConnected)
                .onSubmit {
                    sendMessage()
                }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(messageText.isEmpty || !viewModel.isConnected ? .gray : .white)
            }
            .disabled(messageText.isEmpty || !viewModel.isConnected)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.95))
    }

    // MARK: - Verify Sheet

    private var verifySheet: some View {
        VStack(spacing: 24) {
            Text("Код безопасности")
                .font(.headline)
                .foregroundStyle(.white)

            Text(viewModel.fingerprint)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.green)
                .multilineTextAlignment(.center)
                .padding()
                .background(Color.white.opacity(0.05))
                .cornerRadius(12)

            Text("Сравните этот код с собеседником через другой канал связи")
                .font(.caption)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button {
                    viewModel.markAsVerified(true)
                    showVerifyPanel = false
                } label: {
                    Text("Совпадает")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    viewModel.markAsVerified(false)
                    showVerifyPanel = false
                } label: {
                    Text("Не совпадает")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding(24)
        .presentationDetents([.medium])
        .background(Color(white: 0.1))
    }

    // MARK: - Helpers

    private func sendMessage() {
        let text = messageText
        messageText = ""
        Task {
            await viewModel.sendMessage(text)
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage
    @State private var remainingTime = ""

    var body: some View {
        HStack {
            if message.type == .sent { Spacer(minLength: 60) }

            VStack(alignment: message.type == .sent ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(backgroundColor)
                    .cornerRadius(18)

                if message.type != .system {
                    HStack(spacing: 4) {
                        Text(message.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.gray)

                        if message.type == .sent && message.isDelivered {
                            Text("✓")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }

                        if message.type != .system {
                            Text("⏱ \(message.remainingTimeFormatted)")
                                .font(.caption2)
                                .foregroundStyle(.gray.opacity(0.6))
                        }
                    }
                }
            }

            if message.type == .received { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var backgroundColor: Color {
        switch message.type {
        case .sent: return .blue.opacity(0.5)
        case .received: return Color.white.opacity(0.1)
        case .system: return .clear
        }
    }

    private var alignment: Alignment {
        switch message.type {
        case .sent: return .trailing
        case .received: return .leading
        case .system: return .center
        }
    }
}
