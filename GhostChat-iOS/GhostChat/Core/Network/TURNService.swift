import Foundation

/// TURN credentials от сервера — порт fetchTurnCredentials()
/// Формат ответа: { username, credential, ttl, urls: [...] }
struct TURNCredentials: Decodable {
    let username: String
    let credential: String
    let ttl: Int
    let urls: [String]
}

final class TURNService: NSObject {

    private let baseURL: URL
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    init(baseURL: URL) {
        self.baseURL = baseURL
        super.init()
    }

    /// Загрузка временных TURN credentials с сервера
    func fetchCredentials() async throws -> TURNCredentials {
        let url = baseURL.appendingPathComponent("api/turn-credentials")
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TURNError.fetchFailed
        }

        return try JSONDecoder().decode(TURNCredentials.self, from: data)
    }
}

// MARK: - Certificate Pinning (M1)

extension TURNService: URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        CertificatePinning.handleChallenge(challenge, completionHandler: completionHandler)
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
