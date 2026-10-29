import Foundation

/// Daily time window in which ffmpeg jobs may start, e.g. `01:00-06:00` (plan §5.5).
/// May cross midnight (`23:00-06:00`). Interpreted in the given calendar's time zone.
struct ProcessingWindow: Sendable, Equatable, CustomStringConvertible {
    /// Minutes since midnight.
    var start: Int
    var end: Int

    init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    /// Parses `HH:MM-HH:MM`. Returns `nil` for an empty string (= always open).
    init?(parsing string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = Self.minutes(parts[0]),
              let end = Self.minutes(parts[1]),
              start != end
        else {
            throw ProcessingWindowError.invalid(string)
        }
        self.init(start: start, end: end)
    }

    private static func minutes(_ text: Substring) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        return hour * 60 + minute
    }

    var description: String {
        String(format: "%02d:%02d–%02d:%02d", start / 60, start % 60, end / 60, end % 60)
    }

    func contains(_ date: Date, calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if start < end {
            return minute >= start && minute < end
        }
        return minute >= start || minute < end
    }

    /// `date` itself if the window is open, otherwise the next time it opens.
    /// On a DST change where the start time doesn't exist, the next valid time is used.
    func nextOpening(after date: Date, calendar: Calendar) -> Date {
        if contains(date, calendar: calendar) { return date }
        let components = DateComponents(hour: start / 60, minute: start % 60, second: 0)
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime) ?? date
    }
}

enum ProcessingWindowError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case let .invalid(value): "Invalid processing window \"\(value)\"; expected HH:MM-HH:MM, e.g. 01:00-06:00"
        }
    }
}
