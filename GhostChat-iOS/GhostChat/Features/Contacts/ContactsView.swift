import SwiftUI

/// Полный список контактов — навигация, поиск, удаление
struct ContactsView: View {
    @StateObject private var viewModel = ContactsViewModel()
    let onStartChat: (Contact) -> Void
    @Environment(\.dismiss) private var dismiss

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
            ForEach(viewModel.contacts) { contact in
                NavigationLink {
                    ContactDetailView(
                        contact: contact,
                        viewModel: viewModel,
                        onStartChat: { saved in
                            onStartChat(saved)
                            dismiss()
                        }
                    )
                } label: {
                    ContactRow(contact: contact)
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
            .onDelete { indexSet in
                for index in indexSet {
                    viewModel.deleteContact(viewModel.contacts[index])
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
            // Аватар
            Circle()
                .fill(Color.white.opacity(0.1))
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

                if let lastSession = contact.lastSessionAt {
                    Text(lastSession, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
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
