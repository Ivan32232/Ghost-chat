import Foundation

/// ViewModel for contacts list — fetches from ContactStore (SQLCipher)
@MainActor
final class ContactsViewModel: ObservableObject {

    @Published var contacts: [Contact] = []
    @Published var errorMessage: String?

    private let store = ContactStore()

    func loadContacts() {
        do {
            contacts = try store.fetchAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteContact(_ contact: Contact) {
        do {
            try store.delete(id: contact.id)
            contacts.removeAll { $0.id == contact.id }
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

    func deleteAllContacts() {
        do {
            try store.deleteAll()
            contacts.removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
