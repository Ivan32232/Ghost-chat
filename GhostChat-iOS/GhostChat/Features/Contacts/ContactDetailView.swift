import SwiftUI
import CryptoKit

/// Детальный экран контакта — имя, отпечаток, ключи, действия
struct ContactDetailView: View {
    @State var contact: Contact
    @ObservedObject var viewModel: ContactsViewModel
    let onStartChat: (Contact) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var editedName: String = ""
    @State private var isEditing = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        List {
            // MARK: - Avatar + Name
            Section {
                VStack(spacing: 12) {
                    Circle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 80, height: 80)
                        .overlay {
                            Text(String(contact.label.prefix(1)).uppercased())
                                .font(.system(size: 32, weight: .bold))
                                .foregroundStyle(.white)
                        }

                    if isEditing {
                        TextField(String(localized: "contacts.name"), text: $editedName)
                            .multilineTextAlignment(.center)
                            .textFieldStyle(.plain)
                            .font(.title2)
                            .foregroundStyle(.white)
                            .onSubmit { saveName() }
                    } else {
                        Text(contact.label)
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            // MARK: - Actions
            Section {
                Button {
                    onStartChat(contact)
                    dismiss()
                } label: {
                    Label("contacts.startChat", systemImage: "bubble.left.and.bubble.right.fill")
                }

                Button {
                    if isEditing {
                        saveName()
                    } else {
                        editedName = contact.label
                        isEditing = true
                    }
                } label: {
                    Label(
                        isEditing ? "contacts.save" : "contacts.editName",
                        systemImage: isEditing ? "checkmark" : "pencil"
                    )
                }
            }
            .listRowBackground(Color.white.opacity(0.05))

            // MARK: - Info
            Section {
                HStack {
                    Label("contacts.fingerprint", systemImage: "key.fill")
                        .foregroundStyle(.white)
                    Spacer()
                    Text(formatFingerprint(contact.identityKey))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.green)
                }

                HStack {
                    Label("contacts.created", systemImage: "calendar")
                        .foregroundStyle(.white)
                    Spacer()
                    Text(contact.createdAt, style: .date)
                        .foregroundStyle(.gray)
                }

                if let lastSession = contact.lastSessionAt {
                    HStack {
                        Label("contacts.lastSession", systemImage: "clock")
                            .foregroundStyle(.white)
                        Spacer()
                        Text(lastSession, style: .relative)
                            .foregroundStyle(.gray)
                    }
                }

                HStack {
                    Label("contacts.sessions", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(contact.sessionCount)")
                        .foregroundStyle(.gray)
                }

                HStack {
                    Label("contacts.keyState", systemImage: "lock.shield")
                        .foregroundStyle(.white)
                    Spacer()
                    Text(contact.ratchetState != nil ? "contacts.keyState.saved" : "contacts.keyState.none")
                        .foregroundStyle(contact.ratchetState != nil ? .green : .gray)
                }
            } header: {
                Text("contacts.details")
            }
            .listRowBackground(Color.white.opacity(0.05))

            // MARK: - Danger Zone
            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("contacts.delete", systemImage: "trash")
                }
            }
            .listRowBackground(Color.white.opacity(0.05))
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(white: 0.07))
        .navigationBarTitleDisplayMode(.inline)
        .alert("contacts.deleteConfirm", isPresented: $showDeleteConfirmation) {
            Button("settings.delete", role: .destructive) {
                viewModel.deleteContact(contact)
                dismiss()
            }
            Button("settings.cancel", role: .cancel) {}
        }
    }

    private func saveName() {
        guard !editedName.isEmpty else { return }
        viewModel.updateContactLabel(contact, newLabel: editedName)
        contact.label = editedName
        isEditing = false
    }

    private func formatFingerprint(_ keyData: Data) -> String {
        let hash = SHA256.hash(data: keyData)
        let bytes = Array(hash).prefix(8)
        return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
