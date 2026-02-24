import Foundation

/// TURN credentials от сервера — порт fetchTurnCredentials()
/// Формат ответа: { username, credential, ttl, urls: [...] }
struct TURNCredentials: Decodable {
    let username: String
    let credential: String
    let ttl: Int
    let urls: [String]
}

final class TURNService {

    private let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Загрузка временных TURN credentials с сервера
    func fetchCredentials() async throws -> TURNCredentials {
        let url = baseURL.appendingPathComponent("api/turn-credentials")
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TURNError.fetchFailed
        }

        return try JSONDecoder().decode(TURNCredentials.self, from: data)
    }
}

enum TURNError: LocalizedError {
    case fetchFailed

    var errorDescription: String? {
        switch self {
        case .fetchFailed: return "Failed to fetch TURN credentials"
        }
    }
}
