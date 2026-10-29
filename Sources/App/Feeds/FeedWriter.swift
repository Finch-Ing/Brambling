import Foundation

struct FeedChannel: Sendable {
    var title: String
    var link: URL
    /// The feed's own URL, for `<atom:link rel="self">`.
    var selfURL: URL?
    var description: String
    var author: String?
    var artworkURL: URL?
    var language: String?
    var explicit: Bool = false
    /// `itunes:type serial`: items are written in the given order (oldest first).
    var serial: Bool = false
}

struct FeedItem: Sendable {
    var guid: String
    var title: String
    var pubDate: Date
    var descriptionHTML: String?
    var enclosureURL: URL
    var length: Int
    var duration: Double
    var episodeNumber: Int? = nil
    var seasonNumber: Int? = nil
}

/// Renders RSS 2.0 + iTunes podcast feeds. Pure string building.
enum FeedWriter {
    static func render(channel: FeedChannel, items: [FeedItem]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:atom="http://www.w3.org/2005/Atom">
        <channel>

        """
        xml += element("title", channel.title)
        xml += element("link", channel.link.absoluteString)
        if let selfURL = channel.selfURL {
            xml += "  <atom:link href=\"\(escape(selfURL.absoluteString))\" rel=\"self\" type=\"application/rss+xml\"/>\n"
        }
        xml += element("description", channel.description)
        if let language = channel.language, !language.isEmpty {
            xml += element("language", language)
        }
        if let author = channel.author, !author.isEmpty {
            xml += element("itunes:author", author)
        }
        if let artwork = channel.artworkURL {
            xml += "  <itunes:image href=\"\(escape(artwork.absoluteString))\"/>\n"
        }
        xml += element("itunes:explicit", channel.explicit ? "true" : "false")
        xml += element("itunes:type", channel.serial ? "serial" : "episodic")
        // Keep these private feeds out of Apple's public directory.
        xml += element("itunes:block", "yes")

        for item in channel.serial ? items : items.sorted(by: { $0.pubDate > $1.pubDate }) {
            xml += "  <item>\n"
            xml += "    <guid isPermaLink=\"false\">\(escape(item.guid))</guid>\n"
            xml += "  " + element("title", item.title)
            xml += "  " + element("pubDate", rfc822(item.pubDate))
            if let description = item.descriptionHTML, !description.isEmpty {
                xml += "    <description>\(cdata(description))</description>\n"
            }
            xml += "    <enclosure url=\"\(escape(item.enclosureURL.absoluteString))\" length=\"\(item.length)\" type=\"audio/mpeg\"/>\n"
            xml += "  " + element("itunes:duration", formatDuration(item.duration))
            if let season = item.seasonNumber { xml += "  " + element("itunes:season", String(season)) }
            if let episode = item.episodeNumber { xml += "  " + element("itunes:episode", String(episode)) }
            xml += "  " + element("itunes:episodeType", "full")
            xml += "  </item>\n"
        }

        xml += "</channel>\n</rss>\n"
        return xml
    }

    /// Builds the feed for a show from its `ready` episodes.
    static func render(show: Show, episodes: [Episode], baseURL: URL, hasArtwork: Bool) -> String {
        let channel = FeedChannel(
            title: show.displayTitle,
            link: show.siteURL.flatMap(URL.init(string:)) ?? baseURL,
            selfURL: feedURL(slug: show.slug, baseURL: baseURL),
            description: show.summary ?? show.displayTitle,
            author: show.author,
            artworkURL: hasArtwork ? artworkURL(slug: show.slug, baseURL: baseURL) : nil,
            language: show.language,
            serial: show.seriesOrder
        )
        var items = episodes.compactMap { episode -> FeedItem? in
            guard episode.status == .ready,
                  let fileName = episode.fileName,
                  let fileSize = episode.fileSize,
                  let duration = episode.duration
            else { return nil }
            return FeedItem(
                guid: "\(episode.sourceGUID)-\(episode.settingsHash)",
                title: episode.title,
                pubDate: episode.pubDate,
                descriptionHTML: episode.descriptionHTML,
                enclosureURL: mediaURL(slug: show.slug, fileName: fileName, baseURL: baseURL),
                length: fileSize,
                duration: duration,
                episodeNumber: episode.episodeNumber,
                seasonNumber: episode.seasonNumber
            )
        }
        if show.seriesOrder {
            items = seriesOrdered(items)
        }
        return render(channel: channel, items: items)
    }

    /// Series order for listening from the start (plan §7.1):
    /// - oldest first, by season and episode number when every episode has one, otherwise by date;
    /// - release dates rewritten so the *first* episode is the newest: the iPod classic (and Finder)
    ///   ignore `itunes:type serial` and always list by date, newest on top. Dates stay stable
    ///   between fetches (anchored to the newest real date) and step one minute per episode.
    /// - the real date goes into the description, since the shown one is synthetic.
    static func seriesOrdered(_ items: [FeedItem]) -> [FeedItem] {
        guard let anchor = items.map(\.pubDate).max() else { return items }
        let ordered = SeriesOrder.sorted(items, episode: \.episodeNumber, season: \.seasonNumber, date: \.pubDate)
        return ordered.enumerated().map { index, item in
            var item = item
            let note = "<p>Originally published \(Format.date(item.pubDate)).</p>"
            item.descriptionHTML = note + (item.descriptionHTML ?? "")
            item.pubDate = anchor.addingTimeInterval(-Double(index) * 60)
            return item
        }
    }

    static func feedURL(slug: String, baseURL: URL) -> URL {
        baseURL.appendingPathComponent("feeds").appendingPathComponent("\(slug).xml")
    }

    static func mediaURL(slug: String, fileName: String, baseURL: URL) -> URL {
        baseURL.appendingPathComponent("media").appendingPathComponent(slug).appendingPathComponent(fileName)
    }

    static func artworkURL(slug: String, baseURL: URL) -> URL {
        baseURL.appendingPathComponent("art").appendingPathComponent("\(slug).jpg")
    }

    // MARK: - Formatting helpers

    private static func element(_ name: String, _ value: String) -> String {
        "  <\(name)>\(escape(value))</\(name)>\n"
    }

    /// Escapes text for XML element content and attribute values, dropping characters XML 1.0 forbids.
    static func escape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.utf8.count)
        for scalar in string.unicodeScalars where isValidXMLScalar(scalar) {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Wraps HTML in CDATA, splitting any `]]>` so it can't terminate the section early.
    static func cdata(_ string: String) -> String {
        let cleaned = String(String.UnicodeScalarView(string.unicodeScalars.filter(isValidXMLScalar)))
        return "<![CDATA[" + cleaned.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>") + "]]>"
    }

    private static func isValidXMLScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: true
        default: false
        }
    }

    static func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    /// `HH:MM:SS`, rounded to whole seconds.
    static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
