import Foundation

/// Display formatting for the web UI.
enum Format {
    static func bytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "–" }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 10 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }

    /// `1:02:03` or `12:34`.
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "–" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func date(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "–" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    static func dateTime(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "never" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: date)
    }

    /// "just now", "5 min ago", "3 h ago", or a date.
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h ago" }
        return dateTime(date)
    }

    static func speed(_ speed: Double) -> String {
        String(format: "%.2f×", speed)
    }
}
