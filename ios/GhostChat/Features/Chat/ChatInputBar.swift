import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Chat input row: attachment button, text field, voice mic button.
/// Presents its own pickers; hands resolved data back to the view model.
struct ChatInputBar: View {

    @ObservedObject var vm: ChatViewModel
    let placeholder: String
    let canSend: Bool

    @State private var showAttachMenu = false
    @State private var showPhotosPicker = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var showFilePicker = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            attachButton
            if vm.isRecordingVoice {
                recordingIndicator
            } else {
                textField
            }
            trailingButton
        }
        .padding(12)
        .confirmationDialog("attach", isPresented: $showAttachMenu, titleVisibility: .hidden) {
            Button("Photo") { showPhotosPicker = true }
            Button("File")  { showFilePicker = true }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $photoSelection,
            matching: .images
        )
        .onChange(of: photoSelection) { newItem in
            guard let item = newItem else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let name = "image-\(Int(Date().timeIntervalSince1970)).jpg"
                let mime = FileCatalog.mimeType(forFilename: name) ?? "image/jpeg"
                await vm.sendAttachment(data: data, name: name, mimeType: mime)
                photoSelection = nil
            }
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerSheet(onPicked: { url in
                Task {
                    guard let data = try? Data(contentsOf: url) else { return }
                    let name = url.lastPathComponent
                    let mime = FileCatalog.mimeType(forFilename: name) ?? "application/octet-stream"
                    guard FileCatalog.isSupportedMimeType(mime) else { return }
                    await vm.sendAttachment(data: data, name: name, mimeType: mime)
                }
            })
        }
    }

    // MARK: - Subviews

    private var attachButton: some View {
        Button {
            showAttachMenu = true
        } label: {
            Image(systemName: "paperclip")
                .resizable().frame(width: 22, height: 22)
                .foregroundStyle(.white)
        }
        .disabled(!canSend || vm.isRecordingVoice)
    }

    private var textField: some View {
        TextField(placeholder, text: $vm.draft)
            .padding(12)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(.white)
            .disabled(!canSend)
    }

    private var recordingIndicator: some View {
        HStack(spacing: 10) {
            Circle().fill(.red).frame(width: 10, height: 10)
            Text("Recording…").foregroundStyle(.white).font(.footnote)
            Spacer()
        }
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder private var trailingButton: some View {
        if !vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sendButton
        } else {
            micButton
        }
    }

    private var sendButton: some View {
        Button {
            // Light haptic pulse on send — mirrors the sonic "sent" cue from SoundLibrary.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { await vm.send() }
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .resizable().frame(width: 36, height: 36)
                .foregroundStyle(.white)
        }
        .disabled(!canSend)
    }

    private var micButton: some View {
        Image(systemName: vm.isRecordingVoice ? "stop.circle.fill" : "mic.circle.fill")
            .resizable().frame(width: 36, height: 36)
            .foregroundStyle(vm.isRecordingVoice ? .red : .white)
            .gesture(
                LongPressGesture(minimumDuration: 0.2)
                    .onEnded { _ in
                        if canSend { vm.startVoiceRecording() }
                    }
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onEnded { _ in
                        Task { await vm.stopVoiceRecordingAndSend() }
                    }
            )
            .opacity(canSend ? 1 : 0.3)
    }
}

// MARK: - DocumentPicker

struct DocumentPickerSheet: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [
            .pdf, .plainText, .zip,
            UTType("com.microsoft.word.doc")  ?? .data,
            UTType("org.openxmlformats.wordprocessingml.document") ?? .data,
            .mp3, .mpeg4Audio, .mpeg4Movie, .quickTimeMovie, .aiff, .wav,
            .jpeg, .png, .gif, .heic, .webP
        ]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL) -> Void
        init(onPicked: @escaping (URL) -> Void) { self.onPicked = onPicked }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPicked(url) }
        }
    }
}
