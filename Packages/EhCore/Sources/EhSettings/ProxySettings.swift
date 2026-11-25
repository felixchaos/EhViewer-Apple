import Foundation

/// A snapshot is passed to each new session; editing a copy does not change routing.
public struct ProxySettings: Equatable, Sendable {
    public var mode: Int
    public var host: String
    public var port: Int

    public init(mode: Int = 0, host: String = "", port: Int = 0) {
        self.mode = mode
        self.host = host
        self.port = port
    }

    public enum ValidationError: Error {
        case invalidMode, invalidEndpoint
    }

    public func validated() throws -> Self {
        guard mode == 0 || mode == 1 else { throw ValidationError.invalidMode }
        var normalized = self
        normalized.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == 1 {
            let separators = CharacterSet.whitespacesAndNewlines
                .union(.controlCharacters).union(CharacterSet(charactersIn: "/?#@"))
            guard !normalized.host.isEmpty,
                  normalized.host.rangeOfCharacter(from: separators) == nil,
                  (1...65535).contains(port)
            else { throw ValidationError.invalidEndpoint }
        }
        return normalized
    }

    public var connectionProxyDictionary: [AnyHashable: Any]? {
        guard mode == 1, let endpoint = try? validated() else { return nil }
        return [
            "HTTPEnable": 1, "HTTPProxy": endpoint.host, "HTTPPort": endpoint.port,
            "HTTPSEnable": 1, "HTTPSProxy": endpoint.host, "HTTPSPort": endpoint.port,
        ]
    }
}
