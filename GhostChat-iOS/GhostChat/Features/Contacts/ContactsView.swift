import SwiftUI

/// Полный список контактов — навигация, поиск, удаление
struct ContactsView: View {
    @StateObject private var viewModel = ContactsViewModel()
    let onStartChat: (Contact) -> Void
    let onCallContact: ((Contact) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    init(onStartChat: @escaping (Contact) -> Void, onCallContact: ((Contact) -> Void)? = nil) {
        self.onStartChat = onStartChat
        self.onCallContact = onCallContact
    }

    private var filteredContacts: [Contact] {
        guard !searchText.isEmpty else { return viewModel.contacts }
        return viewModel.contacts.filter { $0.label.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.contacts.isEmpty {
                    emptyState
                } else {
                    contactList
                }
            }
            .navigationTitle("contacts.title")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: Text("settings.language.search"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("settings.done")
                            .fontWeight(.semibold)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(white: 0.07))
        }
        .task {
            viewModel.loadContacts()
        }
        .refreshable {
            viewModel.loadContacts()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.2.slash")
                .font(.system(size: 56))
                .foregroundStyle(.gray.opacity(0.5))
            Text("contacts.empty")
                .font(.title3)
                .foregroundStyle(.gray)
            Text("contacts.emptyHint")
                .font(.caption)
                .foregroundStyle(.gray.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Contact List

    private var contactList: some View {
        List {
            ForEach(filteredContacts) { contact in
                NavigationLink {
                    ContactDetailView(
                        contact: contact,
                        viewModel: viewModel,
                        onStartChat: { saved in
                            onStartChat(saved)
                            dismiss()
                        },
                        onCallContact: onCallContact.map { callback in
                            { saved in
                                callback(saved)
                                dismiss()
                            }
                        }
                    )
                } label: {
                    ContactRow(contact: contact)
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
            .onDelete { indexSet in
                for index in indexSet {
                    let contact = filteredContacts[index]
                    viewModel.deleteContact(contact)
                }
            }
        }
    }
}

// MARK: - Contact Row

struct ContactRow: View {
    let contact: Contact

    var body: some View {
        HStack(spacing: 14) {
            // Аватар с уникальным цветом
            Circle()
                .fill(avatarColor(for: contact))
                .frame(width: 44, height: 44)
                .overlay {
                    Text(String(contact.label.prefix(1)).uppercased())
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }

            // Имя + последняя сессия
            VStack(alignment: .leading, spacing: 3) {
                Text(contact.label)
                    .foregroundStyle(.white)
                    .font(.body)

            }

            Spacer()

            // Кол-во сессий
            if contact.sessionCount > 0 {
                Text("\(contact.sessionCount)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.1), in: Capsule())
            }

            // Индикатор ключей
            if contact.ratchetState != nil {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.green.opacity(0.7))
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Avatar Color

/// Детерминистичный цвет аватара по identity key
func avatarColor(for contact: Contact) -> Color {
    let hash = contact.identityKey.hashValue
    let colors: [Color] = [
        .red.opacity(0.4), .orange.opacity(0.4), .yellow.opacity(0.4),
        .green.opacity(0.4), .mint.opacity(0.4), .teal.opacity(0.4),
        .cyan.opacity(0.4), .blue.opacity(0.4), .indigo.opacity(0.4),
        .purple.opacity(0.4), .pink.opacity(0.4)
    ]
    return colors[abs(hash) % colors.count]
}
