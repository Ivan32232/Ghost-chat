import Foundation

struct TURNCredentials: Codable, Equatable {
    let username: String
    let credential: String
    let urls: [String]
    let ttl: Int
    let fetchedAt: Date

    init(username: String, credential: String, urls: [String], ttl: Int, fetchedAt: Date = Date()) {
        self.username = username
        self.credential = credential
        self.urls = urls
        self.ttl = ttl
        self.fetchedAt = fetchedAt
    }

    /// True once ≥ 5 minutes remain below the `ttl` boundary.
    func isExpired(now: Date = Date(), skew: TimeInterval = 300) -> Bool {
        now.timeIntervalSince(fetchedAt) + skew >= TimeInterval(ttl)
    }
}

final class TURNService {

    enum Error: Swift.Error {
        case httpStatus(Int)
        case malformedResponse
    }

    private let endpoint: URL
    private let session: URLSession

    init(baseURL: URL, pinning: CertificatePinning = CertificatePinning()) {
        self.endpoint = baseURL.appendingPathComponent("api/turn-credentials")
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: pinning, delegateQueue: nil)
    }

    func fetchCredentials() async throws -> TURNCredentials {
        let (data, response) = try await session.data(from: endpoint)
        guard let http = response as? HTTPURLResponse else { throw Error.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.httpStatus(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let username = json["username"] as? String,
              let credential = json["credential"] as? String,
              let urls = json["urls"] as? [String],
              let ttl = json["ttl"] as? Int else {
            throw Error.malformedResponse
        }
        return TURNCredentials(username: username, credential: credential, urls: urls, ttl: ttl)
    }
}
