import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var connection: ConnectionManager
    @EnvironmentObject var contacts: ContactManager
    @EnvironmentObject var localization: LocalizationManager

    @State private var joinInput: String = ""
    @State private var showContacts = false
    @State private var showSettings = false
    @State private var showChat = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 32) {
                    header
                    Spacer(minLength: 0)
                    title
                    createButton
                    joinField
                    Spacer()
                    contactsEntry
                }
                .padding(24)
            }
            .preferredColorScheme(.dark)
            .navigationDestination(isPresented: $showChat) {
                ChatView()
            }
            .navigationDestination(isPresented: $showContacts) {
                ContactsView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .alert("Error", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button(localization.localized("action.done")) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Components

    private var header: some View {
        HStack {
            Text(localization.localized("app.name"))
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(localization.localized("welcome.settings"))
        }
    }

    private var title: some View {
        VStack(spacing: 8) {
            Text(localization.localized("app.name"))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("End-to-end encrypted. Zero-identity.")
                .font(.footnote)
                .foregroundStyle(.gray)
        }
    }

    private var createButton: some View {
        Button {
            Task {
                do {
                    try await connection.createRoom()
                    showChat = true
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } label: {
            Text(localization.localized("welcome.create"))
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var joinField: some View {
        HStack(spacing: 12) {
            TextField(localization.localized("welcome.join_placeholder"), text: $joinInput)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .padding(14)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            Button(localization.localized("welcome.join")) {
                Task { await join() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.2))
            .foregroundStyle(.white)
        }
    }

    private var contactsEntry: some View {
        Button {
            showContacts = true
        } label: {
            HStack {
                Image(systemName: "person.2.fill")
                Text(localization.localized("welcome.contacts"))
                Spacer()
                Text("\(contacts.contacts.count)")
                    .foregroundStyle(.gray)
            }
            .foregroundStyle(.white)
            .padding(14)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Actions

    private func join() async {
        let id = extractRoomID(from: joinInput)
        guard Room.isValidID(id) else {
            errorMessage = localization.localized("error.invalid_room")
            return
        }
        do {
            try await connection.joinRoom(id)
            showChat = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func extractRoomID(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let room = comps.queryItems?.first(where: { $0.name == "room" })?.value {
            return room
        }
        if trimmed.hasPrefix("ghostchat://room/") {
            return String(trimmed.dropFirst("ghostchat://room/".count))
        }
        return trimmed
    }
}
