import SwiftUI

/// Экран приветствия — создать/войти в комнату
struct WelcomeView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var joinRoomId = ""
    @State private var isCreating = false
    @State private var isJoining = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Logo
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white)

                Text("Ghost")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)

                Text("welcome.subtitle")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
            }
            .padding(.bottom, 48)

            // Create room
            Button {
                isCreating = true
                Task {
                    await viewModel.createRoom()
                    isCreating = false
                }
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text(LocalizedStringKey(isCreating ? "welcome.creating" : "welcome.newChat"))
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
            .disabled(isCreating)
            .padding(.horizontal, 24)

            // Divider
            HStack {
                Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
                Text("welcome.or").foregroundStyle(.gray).font(.footnote)
                Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            // Join room
            VStack(spacing: 12) {
                TextField(String(localized: "welcome.roomCode"), text: $joinRoomId)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(12)
                    .foregroundStyle(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button {
                    isJoining = true
                    Task {
                        await viewModel.joinRoom(joinRoomId)
                        isJoining = false
                    }
                } label: {
                    Text(LocalizedStringKey(isJoining ? "welcome.joining" : "welcome.join"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(joinRoomId.isEmpty || isJoining)
            }
            .padding(.horizontal, 24)

            Spacer()

            // Privacy toggle
            Toggle(isOn: $viewModel.privacyMode) {
                HStack(spacing: 8) {
                    Image(systemName: "shield.checkered")
                    Text("welcome.hideIP")
                        .font(.footnote)
                }
                .foregroundStyle(.gray)
            }
            .toggleStyle(.switch)
            .tint(.green)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            // Footer
            Text("welcome.footer")
                .font(.caption2)
                .foregroundStyle(.gray.opacity(0.5))
                .padding(.bottom, 8)
        }
        .background(Color.black)
    }
}
