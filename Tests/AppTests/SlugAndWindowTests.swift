@testable import App
import Foundation
import Testing

@Suite("Slug")
struct SlugTests {
    @Test(arguments: [
        ("Tom & Jérôme's Show!", "tom-jeromes-show"),
        ("  Hello   World  ", "hello-world"),
        ("Straße der Lieder", "strasse-der-lieder"),
        ("🎙️🎙️", "show"),
        ("ATP: Accidental Tech Podcast", "atp-accidental-tech-podcast"),
    ])
    func makesSlugs(title: String, expected: String) {
        #expect(Slug.make(from: title) == expected)
    }

    @Test func limitsLength() {
        let slug = Slug.make(from: String(repeating: "word ", count: 40))
        #expect(slug.count <= Slug.maxLength)
        #expect(!slug.hasSuffix("-"))
    }

    @Test func validation() {
        #expect(Slug.isValid("my-show-2"))
        #expect(!Slug.isValid("My Show"))
        #expect(!Slug.isValid("-show"))
        #expect(!Slug.isValid(""))
    }
}

@Suite("Episode window")
struct EpisodeWindowTests {
    func item(_ guid: String, _ date: Date?) -> ParsedItem {
        ParsedItem(guid: guid, title: guid, pubDate: date, enclosureURL: "https://x/\(guid).mp3")
    }

    @Test func newestKeepCountByDate() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [item("old", base), item("new", base.addingTimeInterval(200)), item("mid", base.addingTimeInterval(100))]
        let window = ShowRefresher.window(of: items, keepCount: 2, now: base)
        #expect(window.map(\.0.guid) == ["new", "mid"])
    }

    @Test func duplicatesAndMissingDates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [item("first", nil), item("second", nil), item("first", nil)]
        let window = ShowRefresher.window(of: items, keepCount: 10, now: now)
        #expect(window.map(\.0.guid) == ["first", "second"], "feed order kept, duplicates dropped")
    }
}
