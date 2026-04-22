import Foundation

/// Parses incoming deep links (`ghostchat://…`, `https://ghostchat.one/?room=…`)
/// and surfaces a pending room id that the UI layer confirms with the user
/// before any network action. Never auto-joins — confirmation is mandatory.
@MainActor
final class DeepLinkRouter: ObservableObject {
    @Published var pendingRoomId: String?

    /// Accepts any form we advertise to users:
    ///   - `ghostchat://?room=<id>`             (query)
    ///   - `ghostchat://room/<id>`              (path, shipped in earlier builds)
    ///   - `https://ghostchat.one/?room=<id>`   (universal link, query)
    ///   - `https://ghostchat.one/room/<id>`    (universal link, path)
    /// Returns the parsed room id if the URL looks like an invite and the id
    /// passes `Room.isValidID`; `nil` otherwise. Pure — no side effects.
    static func parse(_ url: URL) -> String? {
        let scheme = url.scheme?.lowercased()
        let candidate: String?

        if scheme == "ghostchat" {
            // Prefer query parameter (current shipping shape).
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let room = comps.queryItems?.first(where: { $0.name == "room" })?.value,
               !room.isEmpty {
                candidate = room
            } else if url.host?.lowercased() == "room" {
                // Legacy `ghostchat://room/<id>` path form.
                candidate = url.pathComponents.last
            } else {
                candidate = nil
            }
        } else if scheme == "https" || scheme == "http" {
            guard let host = url.host?.lowercased(),
                  host == "ghostchat.one" || host == "www.ghostchat.one" else {
                return nil
            }
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let q = comps?.queryItems?.first(where: { $0.name == "room" })?.value, !q.isEmpty {
                candidate = q
            } else {
                // Universal-link path form: /room/<id>
                let parts = url.pathComponents.filter { $0 != "/" }
                if parts.count == 2, parts.first?.lowercased() == "room" {
                    candidate = parts.last
                } else {
                    candidate = nil
                }
            }
        } else {
            candidate = nil
        }

        guard let id = candidate, !id.isEmpty, Room.isValidID(id) else { return nil }
        return id
    }

    /// Called from the `SwiftUI.onOpenURL` modifier. Stores the id so the
    /// view layer can show a confirmation dialog.
    func submit(_ url: URL) {
        if let id = Self.parse(url) {
            pendingRoomId = id
        }
    }

    func clear() {
        pendingRoomId = nil
    }
}
