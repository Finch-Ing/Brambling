@testable import App
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing

@Suite("FeedWriter")
struct FeedWriterTests {
    let baseURL = URL(string: "https://brambling.example.com")!

    @Test func escapesSpecialCharactersAndKeepsEmoji() {
        #expect(FeedWriter.escape("Tom & Jerry <live> \"quoted\" 'single' 🎙️")
            == "Tom &amp; Jerry &lt;live&gt; &quot;quoted&quot; &apos;single&apos; 🎙️")
        #expect(FeedWriter.escape("bad\u{0B}char\u{0}") == "badchar")
    }

    @Test func cdataCannotBeTerminatedEarly() {
        #expect(FeedWriter.cdata("<p>a]]>b</p>") == "<![CDATA[<p>a]]]]><![CDATA[>b</p>]]>")
    }

    @Test func formatsDurationAndDate() {
        #expect(FeedWriter.formatDuration(0) == "00:00:00")
        #expect(FeedWriter.formatDuration(3725.6) == "01:02:06")
        #expect(FeedWriter.rfc822(Date(timeIntervalSince1970: 1_709_294_400)) == "Fri, 01 Mar 2024 12:00:00 GMT")
    }

    @Test func rendersOnlyReadyEpisodesWithAbsoluteURLs() throws {
        let show = Show(slug: "my-show", title: "Source Title", sourceURL: "https://secret.example.com/feed?token=abc")
        show.titleOverride = "Tom & Jerry 🎙️"
        show.author = "Jane <Doe>"
        show.summary = "About things"
        show.language = "en"

        let showID = UUID()
        func episode(_ guid: String, _ status: EpisodeStatus, daysAgo: Double) -> Episode {
            let e = Episode(
                showID: showID, sourceGUID: guid, title: "Ep \(guid) & more",
                pubDate: Date(timeIntervalSince1970: 1_709_294_400 - daysAgo * 86400),
                enclosureURL: "https://secret.example.com/\(guid).mp3?token=abc", settingsHash: "deadbeef", status: status
            )
            if status == .ready {
                e.fileName = "\(guid)-deadbeef.mp3"
                e.fileSize = 1234
                e.duration = 61
                e.descriptionHTML = "<p>Hello</p>"
            }
            return e
        }
        let episodes = [
            episode("old", .ready, daysAgo: 2),
            episode("new", .ready, daysAgo: 0),
            episode("pending", .pending, daysAgo: 1),
            episode("failed", .failed, daysAgo: 1),
        ]

        let xml = FeedWriter.render(show: show, episodes: episodes, baseURL: baseURL, hasArtwork: true)

        #expect(xml.contains("<title>Tom &amp; Jerry 🎙️</title>"))
        #expect(xml.contains("<itunes:author>Jane &lt;Doe&gt;</itunes:author>"))
        #expect(xml.contains("<itunes:image href=\"https://brambling.example.com/art/my-show.jpg\"/>"))
        #expect(xml.contains("<itunes:block>yes</itunes:block>"))
        #expect(xml.contains("<atom:link href=\"https://brambling.example.com/feeds/my-show.xml\" rel=\"self\" type=\"application/rss+xml\"/>"))
        #expect(xml.contains("<language>en</language>"))
        #expect(xml.contains("<guid isPermaLink=\"false\">new-deadbeef</guid>"))
        #expect(xml.contains(
            "<enclosure url=\"https://brambling.example.com/media/my-show/new-deadbeef.mp3\" length=\"1234\" type=\"audio/mpeg\"/>"
        ))
        #expect(xml.contains("<itunes:duration>00:01:01</itunes:duration>"))
        #expect(xml.contains("<description><![CDATA[<p>Hello</p>]]></description>"))
        #expect(!xml.contains("pending"))
        #expect(!xml.contains("failed"))
        #expect(!xml.contains("secret.example.com"), "source URLs must never leak into the feed")

        let newIndex = try #require(xml.range(of: "new-deadbeef</guid>"))
        let oldIndex = try #require(xml.range(of: "old-deadbeef</guid>"))
        #expect(newIndex.lowerBound < oldIndex.lowerBound, "newest first")

        // Must be well-formed XML.
        let parser = XMLParser(data: Data(xml.utf8))
        #expect(parser.parse(), "\(String(describing: parser.parserError))")
    }
}
