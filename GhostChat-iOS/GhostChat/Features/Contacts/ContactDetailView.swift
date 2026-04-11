import SwiftUI

/// Детальный экран контакта — имя, отпечаток, ключи, действия
struct ContactDetailView: View {
    @State var contact: Contact
    @ObservedObject var viewModel: ContactsViewModel
    let onStartChat: (Contact) -> Void
    let onCallContact: ((Contact) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var editedName: String = ""
    @State private var isEditing = false
    @State private var showDeleteConfirmation = false
    @State private var notesText: String = ""

    init(contact: Contact, viewModel: ContactsViewModel, onStartChat: @escaping (Contact) -> Void, onCallContact: ((Contact) -> Void)? = nil) {
        self._contact = State(initialValue: contact)
        self.viewModel = viewModel
        self.onStartChat = onStartChat
        self.onCallContact = onCallContact
        self._notesText = State(initialValue: contact.notes ?? "")
    }

    var body: some View {
        List {
            // MARK: - Avatar + Name
            Section {
                VStack(spacing: 12) {
                    Circle()
                        .fill(avatarColor(for: contact))
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

                // Кнопка звонка (доступна если есть push token)
                if let onCallContact, contact.pushToken != nil {
                    Button {
                        onCallContact(contact)
                        dismiss()
                    } label: {
                        Label("contacts.call", systemImage: "phone.fill")
                            .foregroundStyle(.green)
                    }
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

            // MARK: - Notes
            Section {
                TextEditor(text: $notesText)
                    .frame(minHeight: 60)
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .onChange(of: notesText) { newValue in
                        let limited = String(newValue.prefix(999))
                        if newValue.count > 999 { notesText = limited }
                        viewModel.updateContactNotes(contact, notes: limited)
                    }
            } header: {
                Text("contacts.notes")
            }
            .listRowBackground(Color.white.opacity(0.05))

            // MARK: - Message TTL
            Section {
                Picker(selection: Binding(
                    get: { contact.messageTTL ?? 0 },
                    set: { newValue in
                        let ttl: Int? = newValue == 0 ? nil : newValue
                        contact.messageTTL = ttl
                        viewModel.updateMessageTTL(contact, ttl: ttl)
                    }
                )) {
                    Text("contacts.ttl.off").tag(0)
                    Text("contacts.ttl.1h").tag(3600)
                    Text("contacts.ttl.1d").tag(86400)
                    Text("contacts.ttl.7d").tag(604800)
                    Text("contacts.ttl.30d").tag(2592000)
                } label: {
                    Label("contacts.ttl", systemImage: "timer")
                        .foregroundStyle(.white)
                }
            } header: {
                Text("contacts.ttl.header")
            } footer: {
                Text("contacts.ttl.footer")
            }
            .listRowBackground(Color.white.opacity(0.05))

            // MARK: - Info
            Section {
                HStack {
                    Label("contacts.created", systemImage: "calendar")
                        .foregroundStyle(.white)
                    Spacer()
                    Text(contact.createdAt, style: .date)
                        .foregroundStyle(.gray)
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

}
