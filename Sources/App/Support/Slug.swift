import Foundation

enum Slug {
    static let maxLength = 60

    /// "Tom & Jérôme's Show!" → "tom-jeromes-show"
    static func make(from title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "ß", with: "ss")
            .lowercased()
        var slug = ""
        var lastWasDash = false
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if scalar == "'" || scalar == "’" {
                continue
            } else if !lastWasDash, !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        slug = String(slug.prefix(maxLength))
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "show" : slug
    }

    /// Whether a user-entered slug is acceptable as-is.
    static func isValid(_ slug: String) -> Bool {
        !slug.isEmpty && slug.count <= maxLength && make(from: slug) == slug
    }

    /// Appends `-2`, `-3`, … until `isTaken` returns false.
    static func unique(_ base: String, isTaken: (String) async throws -> Bool) async rethrows -> String {
        var candidate = base
        var counter = 2
        while try await isTaken(candidate) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }
}
