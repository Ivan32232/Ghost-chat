import SwiftUI

/// Ghost Threads home screen — contacts with chat previews + new/join room
struct WelcomeView: View {
    @EnvironmentObject var biometricAuth: BiometricAuthService
    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var contactsVM = ContactsViewModel()
    @State private var joinRoomId = ""
    @State private var isCreating = false
    @State private var isJoining = false
    @State private var showSettings = false
    @State private var showContacts = false
    @State private var showJoinField = false

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            topBar

            if contactsVM.contacts.isEmpty && !viewModel.savedMessagesEnabled {
                // No contacts — show classic welcome
                classicWelcome
            } else {
                // Ghost Threads — contact list with previews
                threadsList
            }

            // Bottom actions
            bottomBar
        }
        .background(Color(white: 0.04))
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showContacts) {
            ContactsView(
                onStartChat: { contact in
                    showContacts = false
                    Task { await viewModel.startChatWithContact(contact) }
                },
                onCallContact: { contact in
                    showContacts = false
                    Task { await viewModel.callOfflineContact(contact) }
                }
            )
        }
        .task {
            contactsVM.loadContacts()
        }
        .onChange(of: viewModel.screen) { newScreen in
            if newScreen == .welcome {
                contactsVM.loadContacts()
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Text("Ghost")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color(white: 0.94))

            Spacer()

            // New anonymous chat
            Button {
                guard !isCreating else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                isCreating = true
                viewModel.screen = .waiting
                Task { await viewModel.createRoom() }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .foregroundStyle(Color(white: 0.94))
                    .padding(8)
            }
            .disabled(isCreating)

            // Settings
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(Color(white: 0.47)) // #777
                    .padding(8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(white: 0.04))
    }

    // MARK: - Classic Welcome (no contacts)

    private var classicWelcome: some View {
        VStack(spacing: 0) {
            Spacer()

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

            // Create room — web style: white button, dark text, rounded
            Button {
                guard !isCreating else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                isCreating = true
                viewModel.screen = .waiting
                Task { await viewModel.createRoom() }
            } label: {
                HStack(spacing: 8) {
                    Text("welcome.newChat")
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(white: 0.04))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color(white: 0.94))
                .cornerRadius(14)
            }
            .disabled(isCreating)
            .opacity(isCreating ? 0.4 : 1)
            .padding(.horizontal, 24)
            .accessibilityIdentifier("newChatButton")

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
                    .background(Color(red: 0.086, green: 0.086, blue: 0.086)) // #161616
                    .accessibilityIdentifier("roomCodeField")
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color(red: 0.18, green: 0.18, blue: 0.18), lineWidth: 1) // #2e2e2e
                    )
                    .cornerRadius(12)
                    .foregroundStyle(Color(white: 0.94))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    isJoining = true
                    Task {
                        await viewModel.joinRoom(joinRoomId)
                        isJoining = false
                    }
                } label: {
                    Text(LocalizedStringKey(isJoining ? "welcome.joining" : "welcome.join"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(white: 0.94))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(red: 0.086, green: 0.086, blue: 0.086)) // #161616
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color(red: 0.18, green: 0.18, blue: 0.18), lineWidth: 1) // #2e2e2e
                        )
                        .cornerRadius(12)
                }
                .disabled(joinRoomId.isEmpty || isJoining)
                .opacity(joinRoomId.isEmpty || isJoining ? 0.4 : 1)
                .accessibilityIdentifier("joinButton")
            }
            .padding(.horizontal, 24)

            Spacer()
        }
    }

    // MARK: - Ghost Threads List

    private var threadsList: some View {
        List {
            // Saved Messages (pinned at top, only when enabled)
            if viewModel.savedMessagesEnabled {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    viewModel.openSavedMessages()
                } label: {
                    savedMessagesRowContent
                }
                .listRowBackground(Color.white.opacity(0.03))
            }

            ForEach(contactsVM.contacts) { contact in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await viewModel.startChatWithContact(contact) }
                } label: {
                    ThreadRow(
                        contact: contact,
                        lastMessage: contactsVM.lastMessages[contact.id.uuidString],
                        unreadCount: contactsVM.unreadCounts[contact.id.uuidString] ?? 0
                    )
                }
                .listRowBackground(Color.white.opacity(0.03))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        contactsVM.deleteContact(contact)
                    } label: {
                        Label("delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var savedMessagesRowContent: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color.purple.opacity(0.4))
                .frame(width: 50, height: 50)
                .overlay {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text("saved.title")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                let lastMsg = contactsVM.lastMessages[ChatViewModel.savedMessagesContactId]
                if let msg = lastMsg {
                    Text(msg.text)
                        .font(.system(size: 14))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                } else {
                    Text("saved.hint")
                        .font(.system(size: 14))
                        .foregroundStyle(.gray.opacity(0.5))
                        .lineLimit(1)
                }
            }

            Spacer()

            let lastMsg = contactsVM.lastMessages[ChatViewModel.savedMessagesContactId]
            if let msg = lastMsg {
                Text(msg.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
        }
        .padding(.vertical, 4)
    }

    private var savedMessagesRow: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            viewModel.openSavedMessages()
        } label: {
            HStack(spacing: 14) {
                // Bookmark avatar
                Circle()
                    .fill(Color.purple.opacity(0.4))
                    .frame(width: 50, height: 50)
                    .overlay {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text("saved.title")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    let lastMsg = contactsVM.lastMessages[ChatViewModel.savedMessagesContactId]
                    if let msg = lastMsg {
                        Text(msg.text)
                            .font(.system(size: 14))
                            .foregroundStyle(.gray)
                            .lineLimit(1)
                    } else {
                        Text("saved.hint")
                            .font(.system(size: 14))
                            .foregroundStyle(.gray.opacity(0.5))
                            .lineLimit(1)
                    }
                }

                Spacer()

                let lastMsg = contactsVM.lastMessages[ChatViewModel.savedMessagesContactId]
                if let msg = lastMsg {
                    Text(msg.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            // Join room field (toggle)
            if showJoinField {
                HStack(spacing: 8) {
                    TextField(String(localized: "welcome.roomCode"), text: $joinRoomId)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(10)
                        .foregroundStyle(.white)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        isJoining = true
                        Task {
                            await viewModel.joinRoom(joinRoomId)
                            isJoining = false
                        }
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title2)
                            .foregroundStyle(joinRoomId.isEmpty ? .gray : .white)
                    }
                    .disabled(joinRoomId.isEmpty || isJoining)
                }
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack {
                // Join by code
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showJoinField.toggle()
                    }
                } label: {
                    Image(systemName: "number")
                        .font(.body)
                        .foregroundStyle(.gray)
                        .padding(10)
                }

                Spacer()

                // Contacts management
                Button {
                    showContacts = true
                } label: {
                    Image(systemName: "person.2.fill")
                        .font(.body)
                        .foregroundStyle(.gray)
                        .padding(10)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(Color(white: 0.04))
    }
}

// MARK: - Thread Row

struct ThreadRow: View {
    let contact: Contact
    let lastMessage: ChatMessage?
    let unreadCount: Int

    var body: some View {
        HStack(spacing: 14) {
            // Avatar
            Circle()
                .fill(avatarColor(for: contact))
                .frame(width: 50, height: 50)
                .overlay {
                    Text(String(contact.label.prefix(1)).uppercased())
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }

            // Name + preview
            VStack(alignment: .leading, spacing: 4) {
                Text(contact.label)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let msg = lastMessage {
                    Text(msg.text)
                        .font(.system(size: 14))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                } else {
                    Text("contacts.noMessages")
                        .font(.system(size: 14))
                        .foregroundStyle(.gray.opacity(0.5))
                        .lineLimit(1)
                }
            }

            Spacer()

            // Time + badge
            VStack(alignment: .trailing, spacing: 6) {
                if let msg = lastMessage {
                    Text(msg.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }

                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.green, in: Capsule())
                }
            }

            // Lock indicator
            if contact.ratchetState != nil {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.green.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
