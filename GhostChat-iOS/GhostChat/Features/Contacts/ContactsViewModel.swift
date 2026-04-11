import Foundation

/// ViewModel for contacts list — fetches from ContactStore (SQLCipher)
@MainActor
final class ContactsViewModel: ObservableObject {

    @Published var contacts: [Contact] = []
    @Published var errorMessage: String?
    @Published var lastMessages: [String: ChatMessage] = [:]   // contactId -> last message
    @Published var unreadCounts: [String: Int] = [:]           // contactId -> unread count

    private let store = ContactStore()
    private let messageStore = MessageStore()

    func loadContacts() {
        do {
            contacts = try store.fetchAll()
            loadMessagePreviews()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMessagePreviews() {
        var previews: [String: ChatMessage] = [:]
        var counts: [String: Int] = [:]
        for contact in contacts {
            let cId = contact.id.uuidString
            if let last = try? messageStore.fetchLastMessage(for: cId) {
                previews[cId] = last
            }
            if let count = try? messageStore.countUnread(for: cId), count > 0 {
                counts[cId] = count
            }
        }
        // Also load Saved Messages preview
        let savedId = ChatViewModel.savedMessagesContactId
        if let last = try? messageStore.fetchLastMessage(for: savedId) {
            previews[savedId] = last
        }
        lastMessages = previews
        unreadCounts = counts
    }

    func deleteContact(_ contact: Contact) {
        do {
            try store.delete(id: contact.id)
            try? messageStore.deleteForContact(contact.id.uuidString)
            contacts.removeAll { $0.id == contact.id }
            lastMessages.removeValue(forKey: contact.id.uuidString)
            unreadCounts.removeValue(forKey: contact.id.uuidString)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateContactLabel(_ contact: Contact, newLabel: String) {
        do {
            try store.updateLabel(contactId: contact.id, label: newLabel)
            if let idx = contacts.firstIndex(where: { $0.id == contact.id }) {
                contacts[idx].label = newLabel
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateContactNotes(_ contact: Contact, notes: String) {
        do {
            let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.updateNotes(contactId: contact.id, notes: trimmed.isEmpty ? nil : trimmed)
            if let idx = contacts.firstIndex(where: { $0.id == contact.id }) {
                contacts[idx].notes = trimmed.isEmpty ? nil : trimmed
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateMessageTTL(_ contact: Contact, ttl: Int?) {
        do {
            try store.updateMessageTTL(contactId: contact.id, ttl: ttl)
            if let idx = contacts.firstIndex(where: { $0.id == contact.id }) {
                contacts[idx].messageTTL = ttl
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAllContacts() {
        do {
            try messageStore.deleteAll()
            try store.deleteAll()
            contacts.removeAll()
            lastMessages.removeAll()
            unreadCounts.removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteHistory(for contact: Contact) {
        try? messageStore.deleteForContact(contact.id.uuidString)
        lastMessages.removeValue(forKey: contact.id.uuidString)
        unreadCounts.removeValue(forKey: contact.id.uuidString)
    }
}
