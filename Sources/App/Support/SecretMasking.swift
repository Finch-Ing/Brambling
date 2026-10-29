import Foundation

/// Masks tokens in private feed / enclosure URLs before they reach the UI or logs.
enum SecretMasking {
    static let mask = "••••"

    /// `https://user:pw@feeds.example.com/p/abc123def456ghi789/rss?token=xyz`
    /// → `https://••••@feeds.example.com/p/••••/rss?token=••••`
    static func mask(url string: String) -> String {
        guard var components = URLComponents(string: string), components.host != nil else {
            // Not a parseable URL: show nothing that could be a secret.
            return string.isEmpty ? string : mask
        }
        let hadUserInfo = components.user != nil || components.password != nil
        components.user = nil
        components.password = nil
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: false)
        components.path = segments.map { looksLikeToken($0) ? mask : String($0) }.joined(separator: "/")
        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = nil
            components.query = items.map { "\($0.name)=\(mask)" }.joined(separator: "&")
        }
        components.fragment = nil
        // URLComponents would percent-encode the bullets; rebuild the string without re-encoding them.
        var result = (components.string ?? mask)
            .replacingOccurrences(of: mask.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? mask, with: mask)
        if hadUserInfo, let schemeEnd = result.range(of: "://") {
            result.insert(contentsOf: "\(mask)@", at: schemeEnd.upperBound)
        }
        return result
    }

    /// Replaces every occurrence of the given secrets in free text (e.g. error messages) with their masked form.
    static func redact(_ text: String, secrets: [String]) -> String {
        secrets
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .reduce(text) { result, secret in
                result.replacingOccurrences(of: secret, with: mask(url: secret))
            }
    }

    /// A path segment is treated as a token if it's long and mixes letters and digits
    /// (Patreon/Supercast style), or is a long hex/base64-ish blob.
    static func looksLikeToken(_ segment: Substring) -> Bool {
        let name = segment.split(separator: ".").first ?? segment
        guard name.count >= 16 else { return false }
        let hasDigit = name.contains(where: \.isNumber)
        let hasLetter = name.contains(where: \.isLetter)
        let isTokenAlphabet = name.allSatisfy { $0.isLetter || $0.isNumber || "-_=+".contains($0) }
        return hasDigit && hasLetter && isTokenAlphabet
    }
}
