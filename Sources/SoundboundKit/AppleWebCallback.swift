import Foundation

/// Accept only the callback for this attempt. Never show server-supplied text,
/// authorization codes, or tokens in an error message.
enum AppleWebCallback {
    enum Failure: Error, Equatable {
        case invalidResponse, cancelled, exchange, verification, configuration

        var message: String {
            switch self {
            case .cancelled: return "Apple sign-in was cancelled."
            case .exchange: return "Apple could not complete the sign-in exchange. Please try again. (AUTH-EXCHANGE)"
            case .verification: return "Soundbound could not verify Apple’s response. Please try again. (AUTH-VERIFY)"
            case .configuration: return "Apple web sign-in needs a server configuration fix. (AUTH-CONFIG)"
            case .invalidResponse: return "Apple sign-in returned an incomplete response. Please try again. (AUTH-CALLBACK)"
            }
        }
    }

    static func parse(_ url: URL?, expectedState: String) -> Result<String, Failure> {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "soundbound", components.host == "auth",
              components.path.isEmpty, components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil else { return .failure(.invalidResponse) }
        let items = components.queryItems ?? []
        func values(_ key: String) -> [String] { items.filter { $0.name == key }.compactMap(\.value) }
        guard values("state") == [expectedState] else { return .failure(.invalidResponse) }
        let errors = values("error"), codes = values("code")
        if errors.count == 1, codes.isEmpty {
            switch errors[0] {
            case "cancelled": return .failure(.cancelled)
            case "exchange_failed": return .failure(.exchange)
            case "verification_failed": return .failure(.verification)
            case "configuration_failed": return .failure(.configuration)
            default: return .failure(.invalidResponse)
            }
        }
        guard errors.isEmpty, codes.count == 1, (16...128).contains(codes[0].utf8.count),
              codes[0].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 })
        else { return .failure(.invalidResponse) }
        return .success(codes[0])
    }
}
