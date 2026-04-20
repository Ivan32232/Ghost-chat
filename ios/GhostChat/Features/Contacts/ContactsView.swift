import SwiftUI

struct ContactsView: View {
    @EnvironmentObject var contacts: ContactManager
    @EnvironmentObject var localization: LocalizationManager

    @State private var query: String = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                searchField
                if filteredContacts.isEmpty {
                    empty
                } else {
                    list
                }
            }
        }
        .navigationTitle(localization.localized("contacts.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { contacts.refresh() }
    }

    private var searchField: some View {
        TextField(localization.localized("contacts.search"), text: $query)
            .padding(12)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    private var empty: some View {
        VStack {
            Spacer()
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 48)).foregroundStyle(.gray)
            Text(localization.localized("contacts.empty"))
                .foregroundStyle(.gray).padding(.top, 12)
            Spacer()
        }
    }

    private var list: some View {
        List {
            ForEach(filteredContacts) { contact in
                NavigationLink(destination: ContactDetailView(contact: contact)) {
                    row(contact)
                }
                .listRowBackground(Color.white.opacity(0.03))
            }
            .onDelete(perform: delete)
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
    }

    private func row(_ contact: Contact) -> some View {
        HStack {
            Circle().fill(Color.white.opacity(0.08)).frame(width: 40, height: 40)
                .overlay(Text(String(contact.label.prefix(1)).uppercased()).foregroundStyle(.white))
            VStack(alignment: .leading) {
                Text(contact.label).foregroundStyle(.white)
                if let last = contact.lastSessionAt {
                    Text(relative(from: last)).font(.caption).foregroundStyle(.gray)
                }
            }
        }
    }

    private var filteredContacts: [Contact] {
        let all = contacts.contacts
        if query.isEmpty { return all }
        return all.filter { $0.label.localizedCaseInsensitiveContains(query) }
    }

    private func delete(at offsets: IndexSet) {
        for idx in offsets {
            let contact = filteredContacts[idx]
            try? contacts.delete(id: contact.id)
        }
    }

    private func relative(from date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

struct ContactDetailView: View {
    @EnvironmentObject var contacts: ContactManager
    @EnvironmentObject var localization: LocalizationManager
    @Environment(\.dismiss) private var dismiss

    let contact: Contact
    @State private var label: String
    @State private var notes: String
    @State private var ttl: MessageTTL

    init(contact: Contact) {
        self.contact = contact
        _label = State(initialValue: contact.label)
        _notes = State(initialValue: contact.notes ?? "")
        _ttl = State(initialValue: MessageTTL(rawValue: contact.messageTTL) ?? .fiveMinutes)
    }

    var body: some View {
        Form {
            Section(localization.localized("contacts.rename")) {
                TextField("", text: $label)
            }
            Section(localization.localized("contacts.notes")) {
                TextField("", text: $notes, axis: .vertical)
                    .lineLimit(4, reservesSpace: true)
            }
            Section(localization.localized("settings.message_ttl")) {
                Picker("", selection: $ttl) {
                    ForEach(MessageTTL.allCases) { value in
                        Text(localization.localized(value.localizedKey)).tag(value)
                    }
                }
                .pickerStyle(.navigationLink)
            }
            Section {
                Button(role: .destructive) {
                    try? contacts.delete(id: contact.id)
                    dismiss()
                } label: {
                    Text(localization.localized("contacts.delete"))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle(contact.label)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(localization.localized("action.save")) {
                    var updated = contact
                    updated.label = label
                    updated.notes = notes.isEmpty ? nil : notes
                    updated.messageTTL = ttl.rawValue
                    try? contacts.save(updated)
                    dismiss()
                }
            }
        }
    }
}
