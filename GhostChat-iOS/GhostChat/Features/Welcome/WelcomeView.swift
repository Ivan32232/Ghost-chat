import SwiftUI

/// Экран приветствия — создать/войти в комнату
struct WelcomeView: View {
    @EnvironmentObject var biometricAuth: BiometricAuthService
    @ObservedObject var viewModel: ChatViewModel
    @State private var joinRoomId = ""
    @State private var isCreating = false
    @State private var isJoining = false
    @State private var showSettings = false
    @State private var showContacts = false

    var body: some View {
        VStack(spacing: 0) {
            // Top bar — Contacts left, Settings right
            HStack {
                Button {
                    showContacts = true
                } label: {
                    Image(systemName: "person.2.fill")
                        .font(.title3)
                        .foregroundStyle(.gray)
                        .padding(12)
                }
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                        .foregroundStyle(.gray)
                        .padding(12)
                }
            }
            .padding(.horizontal, 8)

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

            // Create room — мгновенный переход
            Button {
                guard !isCreating else { return }
                isCreating = true
                viewModel.screen = .waiting
                Task { await viewModel.createRoom() }
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("welcome.newChat")
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
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showContacts) {
            ContactsView(onStartChat: { contact in
                showContacts = false
                Task { await viewModel.startChatWithContact(contact) }
            })
        }
    }
}
