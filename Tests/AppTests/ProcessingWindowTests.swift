@testable import App
import Foundation
import Testing

@Suite("ProcessingWindow")
struct ProcessingWindowTests {
    static var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)!
    }

    @Test func parsing() throws {
        #expect(try ProcessingWindow(parsing: "01:00-06:00") == ProcessingWindow(start: 60, end: 360))
        #expect(try ProcessingWindow(parsing: " 23:30 - 05:15 ") == ProcessingWindow(start: 1410, end: 315))
        #expect(try ProcessingWindow(parsing: "") == nil)
        for bad in ["1-6", "01:00", "25:00-06:00", "01:00-06:60", "01:00-01:00", "1:0-6:00", "abc"] {
            #expect(throws: ProcessingWindowError.self, "\(bad)") { try ProcessingWindow(parsing: bad) }
        }
        #expect(try ProcessingWindow(parsing: "01:00-06:00")?.description == "01:00–06:00")
    }

    @Test func containsSameDay() throws {
        let window = try #require(try ProcessingWindow(parsing: "01:00-06:00"))
        let cal = Self.berlin
        #expect(!window.contains(date("2026-10-20T23:59:00+02:00"), calendar: cal))
        #expect(window.contains(date("2026-10-21T01:00:00+02:00"), calendar: cal), "start is inclusive")
        #expect(window.contains(date("2026-10-21T05:59:00+02:00"), calendar: cal))
        #expect(!window.contains(date("2026-10-21T06:00:00+02:00"), calendar: cal), "end is exclusive")
        #expect(!window.contains(date("2026-10-21T12:00:00+02:00"), calendar: cal))
    }

    @Test func containsAcrossMidnight() throws {
        let window = try #require(try ProcessingWindow(parsing: "23:00-06:00"))
        let cal = Self.berlin
        #expect(window.contains(date("2026-10-20T23:30:00+02:00"), calendar: cal))
        #expect(window.contains(date("2026-10-21T00:30:00+02:00"), calendar: cal))
        #expect(!window.contains(date("2026-10-21T06:30:00+02:00"), calendar: cal))
        #expect(!window.contains(date("2026-10-21T22:59:00+02:00"), calendar: cal))
    }

    @Test func nextOpening() throws {
        let window = try #require(try ProcessingWindow(parsing: "01:00-06:00"))
        let cal = Self.berlin
        let noon = date("2026-10-21T12:00:00+02:00")
        #expect(window.nextOpening(after: noon, calendar: cal) == date("2026-10-22T01:00:00+02:00"))
        let inside = date("2026-10-21T02:00:00+02:00")
        #expect(window.nextOpening(after: inside, calendar: cal) == inside)
    }

    @Test func nextOpeningAcrossDSTChanges() throws {
        let cal = Self.berlin
        // Clocks go back on 2026-10-25 (03:00 CEST → 02:00 CET): 01:00 still exists once.
        let window = try #require(try ProcessingWindow(parsing: "01:00-06:00"))
        #expect(window.nextOpening(after: date("2026-10-24T12:00:00+02:00"), calendar: cal)
            == date("2026-10-25T01:00:00+02:00"))
        // Clocks go forward on 2027-03-28 (02:00 CET → 03:00 CEST): 02:30 doesn't exist.
        let skipped = try #require(try ProcessingWindow(parsing: "02:30-05:00"))
        let next = skipped.nextOpening(after: date("2027-03-27T12:00:00+01:00"), calendar: cal)
        #expect(next == date("2027-03-28T03:00:00+02:00"))
        #expect(skipped.contains(next, calendar: cal))
    }
}
