import Foundation

/// Turns episode description HTML into short plain text for list previews.
/// The result is escaped again by Leaf when rendered.
enum PlainText {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™",
    ]

    static func fromHTML(_ html: String) -> String {
        var text = html
        // Content that is never readable text.
        text = text.replacingOccurrences(of: "<(script|style)[^>]*>.*?</\\1>", with: " ", options: [.regularExpression, .caseInsensitive])
        // Block-level breaks become spaces so words don't run together.
        text = text.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6])[^>]*>", with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmed
    }

    /// At most `maxLength` characters, cut at a word boundary, with "…" if shortened.
    static func excerpt(_ html: String?, maxLength: Int = 280) -> String? {
        guard let html else { return nil }
        let text = fromHTML(html)
        guard !text.isEmpty else { return nil }
        guard text.count > maxLength else { return text }
        let cut = text.prefix(maxLength)
        let wordBoundary = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return wordBoundary.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let afterAmp = rest[rest.index(after: amp)...]
            if let semicolon = afterAmp.prefix(10).firstIndex(of: ";"),
               let decoded = decode(String(afterAmp[..<semicolon])) {
                result += decoded
                rest = afterAmp[afterAmp.index(after: semicolon)...]
            } else {
                result += "&"
                rest = afterAmp
            }
        }
        return result + rest
    }

    private static func decode(_ entity: String) -> String? {
        if entity.hasPrefix("#") {
            let number = entity.dropFirst()
            let value = number.first == "x" || number.first == "X"
                ? UInt32(number.dropFirst(), radix: 16)
                : UInt32(number)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return named[entity.lowercased()]
    }

    /// Whether `subtitle` adds anything beyond the description (many feeds repeat its first sentence).
    static func subtitle(_ subtitle: String?, addsTo description: String?) -> Bool {
        guard let subtitle = subtitle?.trimmed, !subtitle.isEmpty else { return false }
        guard let description, !description.isEmpty else { return true }
        let normalize = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let sub = normalize(subtitle), desc = normalize(description)
        return !(desc.hasPrefix(sub) || sub.hasPrefix(desc))
    }
}
