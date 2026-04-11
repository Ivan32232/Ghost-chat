import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import AVFoundation

/// Экран чата — сообщения + ввод
struct ChatView: View {
    @EnvironmentObject var biometricAuth: BiometricAuthService
    @ObservedObject var viewModel: ChatViewModel
    @State private var messageText = ""
    @State private var showVerifyPanel = false
    @State private var showSettings = false
    @State private var showContactDetail = false
    @StateObject private var contactsVM = ContactsViewModel()
    @State private var lastMessageCount = 0
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showAttachPanel = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            chatHeader

            // Messages
            messageList

            // Peer disconnected banner
            if viewModel.showPeerDisconnectedBanner {
                peerDisconnectedBanner
            }

            // Typing indicator
            if viewModel.peerIsTyping {
                typingIndicator
            }

            // Input
            if viewModel.callState != .ringing {
                messageInput
            }

            // Incoming call
            if viewModel.callState == .ringing {
                IncomingCallView(viewModel: viewModel)
            }
        }
        .background(Color(white: 0.04))
        .overlay {
            // Call overlay
            if viewModel.callState == .calling || viewModel.callState == .active {
                CallView(viewModel: viewModel)
            }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            DebugLogOverlay(viewModel: viewModel)
        }
        #endif
        .sheet(isPresented: $showVerifyPanel) {
            verifySheet
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .alert(
            String(localized: "contacts.savePrompt.title"),
            isPresented: $viewModel.showSaveContactPrompt
        ) {
            TextField(String(localized: "contacts.savePrompt.name"), text: $viewModel.pendingContactName)
            Button(String(localized: "contacts.save")) {
                ghostLog("[UI] Save contact button tapped, name='\(viewModel.pendingContactName)'")
                viewModel.saveNewContact(name: viewModel.pendingContactName)
            }
            Button(String(localized: "contacts.skip"), role: .cancel) {
                ghostLog("[UI] Skip save contact button tapped")
                viewModel.skipSaveContact()
            }
        } message: {
            Text("contacts.savePrompt.message")
        }
        .onChange(of: viewModel.messages.count) { newCount in
            ghostLog("[UI] onChange messages.count, new=\(newCount), prev=\(lastMessageCount)")
            // Haptic на получение сообщения
            if newCount > lastMessageCount, let last = viewModel.messages.last, last.type == .received {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            lastMessageCount = newCount
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack(spacing: 8) {
            // Back button — navigate back without disconnecting
            Button {
                ghostLog("[UI] Back button tapped, isConnected=\(viewModel.isConnected), screen=\(viewModel.screen)")
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                if viewModel.isConnected || viewModel.currentPeerContact != nil {
                    viewModel.navigateBack()
                } else {
                    viewModel.leave()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(8)
            }

            // Contact name — tappable to open detail
            if viewModel.isSavedMessagesMode {
                HStack(spacing: 6) {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(.purple)
                    Text("saved.title")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            } else {
                Button {
                    ghostLog("[UI] Contact name tapped, contact=\(viewModel.currentPeerContact?.label ?? "nil")")
                    if viewModel.currentPeerContact != nil {
                        showContactDetail = true
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(viewModel.currentPeerContact?.label ?? (viewModel.fingerprint.isEmpty ? "" : String(viewModel.fingerprint.prefix(19)) + "..."))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if viewModel.peerIsTyping {
                                TypingDots()
                                Text("chat.typing")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.gray)
                            } else {
                                Circle()
                                    .fill(peerStatusColor)
                                    .frame(width: 6, height: 6)
                                Text(viewModel.peerStatus.localizedName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(peerStatusColor)
                            }
                        }
                    }
                }
            }

            Spacer()

            // Right: shield + call
            if !viewModel.isSavedMessagesMode {
                Button {
                    ghostLog("[UI] Verify shield tapped")
                    showVerifyPanel = true
                } label: {
                    Image(systemName: viewModel.isVerified ? "checkmark.shield.fill" : "shield.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(viewModel.isVerified ? .green : (viewModel.isConnected ? .white : .red))
                }

                Button {
                    ghostLog("[UI] Call button tapped, isConnected=\(viewModel.isConnected), callState=\(viewModel.callState)")
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    Task { await viewModel.startCall() }
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(8)
                        .background(Color.green.opacity(0.15), in: Circle())
                }
                .disabled(viewModel.callState != .idle)
                .opacity(viewModel.callState != .idle ? 0.4 : 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(white: 0.04))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(red: 0.18, green: 0.18, blue: 0.18)).frame(height: 0.5) // #2e2e2e border
        }
        .sheet(isPresented: $showContactDetail) {
            if let contact = viewModel.currentPeerContact {
                NavigationStack {
                    ContactDetailView(
                        contact: contact,
                        viewModel: contactsVM,
                        onStartChat: { _ in },
                        onCallContact: nil
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(String(localized: "settings.done")) {
                                ghostLog("[UI] Contact detail done tapped")
                                showContactDetail = false
                            }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: - Peer Disconnected Banner

    private var peerDisconnectedBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 16))
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 2) {
                Text("system.peerDisconnected")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                Text("system.waitingReconnect")
                    .font(.system(size: 12))
                    .foregroundStyle(.gray)
            }

            Spacer()

            Button {
                ghostLog("[UI] Leave/disconnect banner button tapped")
                viewModel.leave()
            } label: {
                Text("chat.leave")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.red.opacity(0.15))
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.08))
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.3), value: viewModel.showPeerDisconnectedBanner)
    }

    // MARK: - Typing Indicator

    private var typingIndicator: some View {
        HStack(spacing: 6) {
            TypingDots()
            Text("chat.typing")
                .font(.caption)
                .foregroundStyle(.gray)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .animation(.easeInOut(duration: 0.2), value: viewModel.peerIsTyping)
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.messages) { message in
                        SwipeToReplyWrapper(message: message, onReply: {
                            ghostLog("[UI] Swipe to reply triggered, msgId=\(message.id)")
                            viewModel.replyingTo = message
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }) {
                            MessageBubble(message: message, viewModel: viewModel)
                        }
                        .id(message.id)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.9).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.messages.count)
            }
            .onChange(of: viewModel.messages.count) { newCount in
                ghostLog("[UI] onChange messages.count (scroll), count=\(newCount)")
                if let lastMessage = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input

    private var canAttachFiles: Bool {
        viewModel.isSavedMessagesMode || viewModel.isConnected
    }

    private var messageInput: some View {
        VStack(spacing: 0) {
            // Reply preview bar (Telegram-style)
            if let reply = viewModel.replyingTo {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.blue)
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reply.type == .sent ? String(localized: "chat.you") : (viewModel.currentPeerContact?.label ?? ""))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.blue)
                        Text(reply.text)
                            .font(.system(size: 13))
                            .foregroundStyle(.gray)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        ghostLog("[UI] Cancel reply tapped")
                        withAnimation(.easeInOut(duration: 0.15)) { viewModel.replyingTo = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.gray)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.05))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Attach panel (expandable)
            if showAttachPanel && canAttachFiles {
                attachPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Main input row
            HStack(spacing: 8) {
                // Attach button (paperclip)
                if canAttachFiles {
                    Button {
                        ghostLog("[UI] Attach button tapped, showAttachPanel=\(!showAttachPanel)")
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showAttachPanel.toggle()
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(showAttachPanel ? .white : .gray)
                            .rotationEffect(.degrees(showAttachPanel ? 45 : 0))
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showAttachPanel)
                            .frame(width: 36, height: 36)
                    }
                }

                // Text field — web style: surface bg + border, pill shape
                TextField(String(localized: viewModel.isSavedMessagesMode ? "saved.placeholder" : "chat.message"), text: $messageText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.086, green: 0.086, blue: 0.086)) // #161616
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color(red: 0.18, green: 0.18, blue: 0.18), lineWidth: 1) // #2e2e2e
                            )
                    )
                    .foregroundStyle(Color(white: 0.94))
                    .disabled(!viewModel.isConnected && !viewModel.isSavedMessagesMode && viewModel.currentPeerContact == nil)
                    .onSubmit {
                        ghostLog("[UI] TextField onSubmit, len=\(messageText.count)")
                        sendMessage()
                    }
                    .onChange(of: messageText) { newValue in
                        ghostLog("[UI] onChange messageText, len=\(newValue.count), empty=\(newValue.isEmpty)")
                        if !viewModel.isSavedMessagesMode {
                            if !newValue.isEmpty {
                                viewModel.userIsTyping()
                            } else {
                                viewModel.stopTyping()
                            }
                        }
                        // Hide attach panel when typing
                        if !newValue.isEmpty && showAttachPanel {
                            withAnimation(.spring(response: 0.2)) {
                                showAttachPanel = false
                            }
                        }
                    }

                // Send button — web style: light gray circle with dark icon
                Button {
                    ghostLog("[UI] Send button tapped, text='\(messageText.prefix(20))', isConnected=\(viewModel.isConnected)")
                    sendMessage()
                } label: {
                    Circle()
                        .fill(canSend ? Color(white: 0.88) : Color.gray.opacity(0.2))
                        .frame(width: 32, height: 32)
                        .overlay {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(canSend ? Color(white: 0.04) : .gray.opacity(0.4))
                        }
                }
                .disabled(!canSend)
                .scaleEffect(canSend ? 1.0 : 0.85)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: canSend)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color(white: 0.04))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showAttachPanel)
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .any(of: [.images, .videos]))
        .onChange(of: selectedPhotoItem) { item in
            ghostLog("[UI] onChange selectedPhotoItem, hasItem=\(item != nil)")
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    ghostLog("[UI] Photo picker loaded data, bytes=\(data.count)")
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
                    try? data.write(to: tmpURL)
                    viewModel.sendFile(url: tmpURL)
                    try? FileManager.default.removeItem(at: tmpURL)
                } else {
                    ghostLog("[UI] Photo picker loadTransferable FAILED")
                }
                selectedPhotoItem = nil
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            ghostLog("[UI] fileImporter result received")
            if case .success(let urls) = result, let url = urls.first {
                ghostLog("[UI] fileImporter success, url=\(url.lastPathComponent)")
                if url.startAccessingSecurityScopedResource() {
                    viewModel.sendFile(url: url)
                    url.stopAccessingSecurityScopedResource()
                } else {
                    ghostLog("[UI] fileImporter startAccessingSecurityScopedResource FAILED")
                }
            } else if case .failure(let err) = result {
                ghostLog("[UI] fileImporter FAILED: \(err.localizedDescription)")
            }
        }
    }

    private var peerStatusColor: Color {
        switch viewModel.peerStatus {
        case .online:         return .green
        case .connecting:     return .yellow
        case .searching:      return .orange
        case .recentlyOnline: return .blue
        case .offline:        return .gray
        }
    }

    private var canSend: Bool {
        // Can always send — messages queue offline and deliver when peer connects
        !messageText.isEmpty && (viewModel.currentPeerContact != nil || viewModel.isConnected || viewModel.isSavedMessagesMode)
    }

    // MARK: - Attach Panel

    private var attachPanel: some View {
        HStack(spacing: 20) {
            attachButton(icon: "photo.on.rectangle.angled", label: String(localized: "file.photoVideo"), color: .purple) {
                ghostLog("[UI] Photo/Video picker tapped")
                showPhotoPicker = true
                withAnimation { showAttachPanel = false }
            }

            attachButton(icon: "doc", label: String(localized: "file.document"), color: .blue) {
                ghostLog("[UI] Document picker tapped")
                showFilePicker = true
                withAnimation { showAttachPanel = false }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.04))
    }

    private func attachButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(color.opacity(0.15))
                        .frame(width: 52, height: 52)
                    Image(systemName: icon)
                        .font(.system(size: 22))
                        .foregroundStyle(color)
                }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Verify Sheet

    private var verifySheet: some View {
        VStack(spacing: 24) {
            Text("chat.securityCode")
                .font(.headline)
                .foregroundStyle(.white)

            Text(viewModel.fingerprint)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.green)
                .multilineTextAlignment(.center)
                .padding()
                .background(Color.white.opacity(0.05))
                .cornerRadius(12)

            Text("chat.compareCode")
                .font(.caption)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button {
                    ghostLog("[UI] Verify YES tapped")
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    viewModel.markAsVerified(true)
                    showVerifyPanel = false
                } label: {
                    Text("chat.matches")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    ghostLog("[UI] Verify NO tapped")
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    viewModel.markAsVerified(false)
                    showVerifyPanel = false
                } label: {
                    Text("chat.doesNotMatch")
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
        viewModel.stopTyping()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            await viewModel.sendMessage(text)
        }
    }
}

// MARK: - Typing Dots Animation

struct TypingDots: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.gray)
                    .frame(width: 6, height: 6)
                    .opacity(phase == index ? 1.0 : 0.3)
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    phase = (phase + 1) % 3
                }
            }
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage
    var viewModel: ChatViewModel? = nil
    @State private var remainingTime = ""
    @State private var showPreview = false
    @State private var previewURL: URL?
    @State private var showEditSheet = false
    @State private var editText = ""
    @State private var showFullScreenImage = false
    @State private var fullScreenImage: UIImage?

    var body: some View {
        HStack {
            if message.type == .sent { Spacer(minLength: 60) }

            VStack(alignment: message.type == .sent ? .trailing : .leading, spacing: 4) {
                if message.isFileMessage {
                    fileBubble
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        // Inline reply quote (Telegram-style)
                        if let replyText = message.replyToText {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(.blue.opacity(0.6))
                                    .frame(width: 2.5)
                                Text(replyText)
                                    .font(.system(size: 12))
                                    .foregroundStyle(message.type == .sent ? Color(white: 0.3) : .gray)
                                    .lineLimit(2)
                            }
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                        }

                        Text(message.text)
                            .font(.body)
                            .foregroundStyle(message.type == .sent ? Color(white: 0.04) : .white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, message.replyToText != nil ? 6 : 10)
                            .padding(.top, message.replyToText != nil ? 0 : 0)
                    }
                    .background(backgroundColor)
                    .cornerRadius(18)
                    .contextMenu {
                        Button {
                            ghostLog("[UI] Copy message tapped")
                            UIPasteboard.general.string = message.text
                        } label: {
                            Label(String(localized: "chat.copy"), systemImage: "doc.on.doc")
                        }
                        // Edit (own messages only)
                        if message.type == .sent, viewModel != nil {
                            Button {
                                ghostLog("[UI] Edit message tapped")
                                editText = message.text
                                showEditSheet = true
                            } label: {
                                Label(String(localized: "chat.edit"), systemImage: "pencil")
                            }
                        }
                        // Delete for everyone (own messages only)
                        if message.type == .sent, message.senderMessageId != nil, viewModel != nil {
                            Button(role: .destructive) {
                                ghostLog("[UI] Delete message tapped, id=\(message.id)")
                                Task { await viewModel?.deleteMessageForEveryone(message) }
                            } label: {
                                Label(String(localized: "chat.deleteForEveryone"), systemImage: "trash")
                            }
                        }
                    }
                    .sheet(isPresented: $showEditSheet) {
                        EditMessageSheet(text: $editText) { newText in
                            Task { await viewModel?.editMessage(message, newText: newText) }
                        }
                        .presentationDetents([.height(200)])
                    }
                }

                if message.type != .system {
                    HStack(spacing: 4) {
                        if message.isEdited {
                            Text(String(localized: "chat.edited"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.gray.opacity(0.6))
                        }
                        Text(message.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.gray)

                        if message.type == .sent {
                            if message.isRead {
                                Text("✓✓")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            } else if message.isDelivered {
                                Text("✓✓")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            } else if message.isPending {
                                Image(systemName: "clock")
                                    .font(.caption2)
                                    .foregroundStyle(.gray.opacity(0.6))
                            } else {
                                Text("✓")
                                    .font(.caption2)
                                    .foregroundStyle(.gray)
                            }
                        }

                        if message.type != .system, message.expiresAt != nil {
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

    @ViewBuilder
    private var fileBubble: some View {
        let isTransferring = message.fileTransferProgress != nil
        let hasLocalFile = message.fileLocalPath != nil
        let mime = message.fileMimeType
        let isImage = mime != nil && FileTransferService.isImage(mime!)
        let isVideo = mime != nil && FileTransferService.isVideo(mime!)

        VStack(alignment: .leading, spacing: 4) {
            // Image / Video preview
            if let localPath = message.fileLocalPath, (isImage || isVideo) {
                let url = FileTransferService.localURL(for: localPath)
                let thumbnail: UIImage? = isVideo
                    ? Self.videoThumbnail(url: url)
                    : Self.loadImage(url: url)
                if let thumbnail {
                    ZStack {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 250, maxHeight: 300)
                            .cornerRadius(12)
                        if isVideo {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.white.opacity(0.85))
                                .shadow(radius: 4)
                        }
                    }
                    .onTapGesture {
                        ghostLog("[UI] Media thumbnail tapped, isVideo=\(isVideo)")
                        if isVideo {
                            showPreview = true
                        } else {
                            fullScreenImage = thumbnail
                            showFullScreenImage = true
                        }
                    }

                    // Caption: filename + size below image
                    HStack(spacing: 4) {
                        Text(message.fileName ?? "")
                            .font(.caption2)
                            .foregroundStyle(textColor.opacity(0.6))
                            .lineLimit(1)
                        if let size = message.fileSize {
                            Text("· \(FileTransferService.formatSize(size))")
                                .font(.caption2)
                                .foregroundStyle(textColor.opacity(0.4))
                        }
                    }
                } else {
                    // Image/video but failed to load thumbnail — show filename fallback
                    fileIconRow
                }
            } else {
                // Non-image file icon + name
                fileIconRow
            }

            // Progress bar
            if isTransferring, let progress = message.fileTransferProgress {
                ProgressView(value: progress)
                    .tint(.white)
                    .frame(maxWidth: 200)
            }
        }
        .padding(10)
        .background(backgroundColor)
        .cornerRadius(16)
        .onTapGesture {
            ghostLog("[UI] File bubble tapped, hasLocalFile=\(hasLocalFile), isTransferring=\(isTransferring), isImage=\(isImage)")
            if hasLocalFile, !isTransferring {
                if isImage {
                    // Open full screen for images
                    if let localPath = message.fileLocalPath {
                        let url = FileTransferService.localURL(for: localPath)
                        fullScreenImage = Self.loadImage(url: url)
                        showFullScreenImage = true
                    }
                } else {
                    showPreview = true
                }
            }
        }
        .fullScreenCover(isPresented: $showFullScreenImage) {
            FullScreenImageView(image: fullScreenImage, isPresented: $showFullScreenImage)
        }
        .quickLookPreview($previewURL)
        .onChange(of: showPreview) { show in
            ghostLog("[UI] onChange showPreview=\(show)")
            if show, let path = message.fileLocalPath {
                previewURL = FileTransferService.localURL(for: path)
            } else {
                previewURL = nil
            }
        }
    }

    private var fileIconRow: some View {
        HStack(spacing: 8) {
            Image(systemName: fileIcon)
                .font(.title2)
                .foregroundStyle(textColor.opacity(0.8))
            VStack(alignment: .leading, spacing: 2) {
                Text(message.fileName ?? "File")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(textColor)
                    .lineLimit(2)
                if let size = message.fileSize {
                    Text(FileTransferService.formatSize(size))
                        .font(.caption2)
                        .foregroundStyle(textColor.opacity(0.6))
                }
            }
        }
    }

    /// Load image with fallback for various formats
    private static func loadImage(url: URL) -> UIImage? {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        ghostLog("[ChatView] loadImage: path=\(url.lastPathComponent), exists=\(exists), size=\(size)")
        // Try direct file path first (fastest)
        if let img = UIImage(contentsOfFile: url.path) {
            ghostLog("[ChatView] loadImage: UIImage OK, size=\(img.size)")
            return img
        }
        // Fallback: load via Data (handles more formats like HEIC)
        if let data = try? Data(contentsOf: url) {
            ghostLog("[ChatView] loadImage: loaded \(data.count) bytes via Data")
            if let img = UIImage(data: data) {
                ghostLog("[ChatView] loadImage: UIImage from Data OK, size=\(img.size)")
                return img
            }
            ghostLog("[ChatView] loadImage: UIImage from Data FAILED")
        }
        ghostLog("[ChatView] loadImage: FAILED completely")
        return nil
    }

    private var fileIcon: String {
        guard let mime = message.fileMimeType else { return "doc" }
        if FileTransferService.isImage(mime) { return "photo" }
        if FileTransferService.isVideo(mime) { return "film" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime == "application/pdf" { return "doc.text" }
        return "doc"
    }

    private static func videoThumbnail(url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 440, height: 440)
        if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
            return UIImage(cgImage: cgImage)
        }
        return nil
    }

    private var backgroundColor: Color {
        switch message.type {
        case .sent: return Color(red: 0.816, green: 0.816, blue: 0.816) // #d0d0d0
        case .received: return Color(red: 0.133, green: 0.133, blue: 0.133) // #222222
        case .system: return .clear
        }
    }

    private var textColor: Color {
        switch message.type {
        case .sent: return Color(white: 0.04)
        case .received: return .white
        case .system: return .gray
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

// MARK: - Swipe To Reply Wrapper

struct SwipeToReplyWrapper<Content: View>: View {
    let message: ChatMessage
    let onReply: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var offset: CGFloat = 0

    var body: some View {
        content()
            .offset(x: offset)
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        // Only allow right swipe, max 80pt
                        if value.translation.width > 0 {
                            offset = min(80, value.translation.width * 0.6)
                        }
                    }
                    .onEnded { value in
                        if offset > 50 {
                            onReply()
                        }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            offset = 0
                        }
                    }
            )
            .overlay(alignment: .leading) {
                if offset > 10 {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.gray.opacity(Double(offset) / 80.0))
                        .offset(x: -24)
                }
            }
    }
}

// MARK: - Edit Message Sheet

struct EditMessageSheet: View {
    @Binding var text: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("chat.edit")
                .font(.headline)
                .foregroundStyle(.white)

            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Color.white.opacity(0.08))
                .cornerRadius(12)
                .foregroundStyle(.white)
                .lineLimit(1...6)

            HStack(spacing: 16) {
                Button {
                    ghostLog("[UI] Edit message cancel tapped")
                    dismiss()
                } label: {
                    Text("connecting.cancel")
                        .foregroundStyle(.gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }

                Button {
                    ghostLog("[UI] Edit message save tapped, len=\(text.count)")
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSave(trimmed)
                    dismiss()
                } label: {
                    Text("chat.save")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.blue)
                        .cornerRadius(10)
                }
            }
        }
        .padding(20)
        .background(Color(white: 0.1))
    }
}

// MARK: - Full Screen Image Viewer

struct FullScreenImageView: View {
    let image: UIImage?
    @Binding var isPresented: Bool
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = lastScale * value
                            }
                            .onEnded { value in
                                lastScale = scale
                                if scale < 1.0 {
                                    withAnimation(.spring(response: 0.3)) {
                                        scale = 1.0
                                        lastScale = 1.0
                                        offset = .zero
                                        lastOffset = .zero
                                    }
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                if scale > 1.0 {
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) {
                        ghostLog("[UI] FullScreenImage double tap, currentScale=\(scale)")
                        withAnimation(.spring(response: 0.3)) {
                            if scale > 1.0 {
                                scale = 1.0
                                lastScale = 1.0
                                offset = .zero
                                lastOffset = .zero
                            } else {
                                scale = 3.0
                                lastScale = 3.0
                            }
                        }
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                ghostLog("[UI] FullScreenImage close tapped")
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(16)
            }
        }
        .statusBar(hidden: true)
    }
}

// MARK: - Debug Log Overlay (DEBUG only)

#if DEBUG
struct DebugLogOverlay: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                ghostLog("[UI] Debug overlay toggle, expanded=\(!expanded)")
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "ant.fill")
                        .font(.caption2)
                    Text("DEBUG")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.7))
                .cornerRadius(4)
            }

            if expanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(viewModel.debugLog.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.green.opacity(0.8))
                        }
                    }
                    .padding(4)
                }
                .frame(maxWidth: 300, maxHeight: 200)
                .background(.black.opacity(0.85))
                .cornerRadius(6)
            }
        }
        .padding(.top, 50)
        .padding(.leading, 4)
    }
}
#endif
