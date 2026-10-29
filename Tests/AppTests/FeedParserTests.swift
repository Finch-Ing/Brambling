@testable import App
import Foundation
import Testing

@Suite("FeedParser")
struct FeedParserTests {
    static let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
         xmlns:content="http://purl.org/rss/1.0/modules/content/">
    <channel>
      <title>Tom &amp; Jerry Show 🎙️</title>
      <link>https://example.com/show</link>
      <description><![CDATA[A show about <b>things</b>.]]></description>
      <language>de-de</language>
      <itunes:author>Jane Doe</itunes:author>
      <itunes:image href="https://cdn.example.com/art.jpg"/>
      <image><url>https://cdn.example.com/small.jpg</url><title>ignored</title></image>
      <item>
        <title>Episode 2</title>
        <itunes:subtitle>The one with the dragon</itunes:subtitle>
        <guid isPermaLink="false">ep-2</guid>
        <pubDate>Fri, 01 Mar 2024 12:00:00 GMT</pubDate>
        <description>Plain description</description>
        <content:encoded><![CDATA[<p>Rich <i>notes</i> &amp; more</p>]]></content:encoded>
        <enclosure url="https://cdn.example.com/ep2.mp3?token=abc" length="12345678" type="audio/mpeg"/>
        <itunes:duration>1:02:03</itunes:duration>
        <itunes:image href="https://cdn.example.com/ep2.jpg"/>
      </item>
      <item>
        <title>Episode 1</title>
        <pubDate>Thu, 1 Feb 2024 08:30:00 +0100</pubDate>
        <enclosure url="https://cdn.example.com/ep1.m4a" length="0" type="audio/x-m4a"/>
        <itunes:duration>754</itunes:duration>
      </item>
      <item>
        <title>Blog post without audio</title>
        <guid>post-1</guid>
      </item>
    </channel>
    </rss>
    """

    @Test func parsesChannel() throws {
        let feed = try FeedParser.parse(Data(Self.feed.utf8))
        #expect(feed.title == "Tom & Jerry Show 🎙️")
        #expect(feed.link == "https://example.com/show")
        #expect(feed.description == "A show about <b>things</b>.")
        #expect(feed.language == "de-de")
        #expect(feed.author == "Jane Doe")
        #expect(feed.artworkURL == "https://cdn.example.com/art.jpg", "itunes:image wins over <image>")
    }

    @Test func parsesItemsWithEnclosuresOnly() throws {
        let feed = try FeedParser.parse(Data(Self.feed.utf8))
        #expect(feed.items.count == 2)

        let ep2 = feed.items[0]
        #expect(ep2.guid == "ep-2")
        #expect(ep2.title == "Episode 2")
        #expect(ep2.subtitle == "The one with the dragon")
        #expect(feed.items[1].subtitle == nil)
        #expect(ep2.descriptionHTML == "<p>Rich <i>notes</i> &amp; more</p>", "content:encoded preferred, CDATA kept verbatim")
        #expect(ep2.pubDate == Date(timeIntervalSince1970: 1_709_294_400))
        #expect(ep2.enclosureURL == "https://cdn.example.com/ep2.mp3?token=abc")
        #expect(ep2.enclosureType == "audio/mpeg")
        #expect(ep2.enclosureLength == 12_345_678)
        #expect(ep2.duration == 3723)

        let ep1 = feed.items[1]
        #expect(ep1.guid == "https://cdn.example.com/ep1.m4a", "falls back to the enclosure URL")
        #expect(ep1.pubDate == Date(timeIntervalSince1970: 1_706_772_600))
        #expect(ep1.enclosureLength == nil, "length 0 means unknown")
        #expect(ep1.duration == 754)
        #expect(ep1.descriptionHTML == nil)
    }

    @Test func rejectsNonFeeds() {
        #expect(throws: FeedParserError.self) { try FeedParser.parse(Data("<html><body>hi</body></html>".utf8)) }
        #expect(throws: FeedParserError.self) { try FeedParser.parse(Data("not xml at all <".utf8)) }
    }

    @Test(arguments: [
        ("Fri, 01 Mar 2024 12:00:00 GMT", 1_709_294_400.0),
        ("Fri, 01 Mar 2024 13:00:00 +0100", 1_709_294_400.0),
        ("Fri, 1 Mar 2024 12:00:00 GMT", 1_709_294_400.0),
        ("Fri, 01 Mar 2024 12:00 GMT", 1_709_294_400.0),
        ("01 Mar 2024 12:00:00 GMT", 1_709_294_400.0),
        ("2024-03-01T12:00:00Z", 1_709_294_400.0),
        ("Fri, 01 Mar 2024 07:00:00 EST", 1_709_294_400.0),
    ])
    func parsesDateVariants(input: String, expected: Double) {
        #expect(FeedParser.parseDate(input) == Date(timeIntervalSince1970: expected))
    }

    @Test func parsesDurations() {
        #expect(FeedParser.parseDuration("1:02:03") == 3723)
        #expect(FeedParser.parseDuration("02:03") == 123)
        #expect(FeedParser.parseDuration("754") == 754)
        #expect(FeedParser.parseDuration("12.5") == 12.5)
        #expect(FeedParser.parseDuration("abc") == nil)
        #expect(FeedParser.parseDuration("") == nil)
    }
}
