import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct ParsedFeed: Sendable, Equatable {
    var title: String
    var link: String?
    var description: String?
    var author: String?
    var language: String?
    var artworkURL: String?
    var items: [ParsedItem]
}

struct ParsedItem: Sendable, Equatable {
    var guid: String
    var title: String
    var subtitle: String? = nil
    var descriptionHTML: String?
    var pubDate: Date?
    var enclosureURL: String
    var enclosureType: String?
    var enclosureLength: Int?
    var duration: Double?
    var episodeNumber: Int?
    var seasonNumber: Int?
}

enum FeedParserError: Error, CustomStringConvertible {
    case invalidXML(String)
    case notAPodcastFeed

    var description: String {
        switch self {
        case let .invalidXML(message): "Feed is not valid XML: \(message)"
        case .notAPodcastFeed: "Not an RSS podcast feed (no <channel> found)"
        }
    }
}

/// Minimal RSS 2.0 + iTunes parser: only channel fields and items with an enclosure.
enum FeedParser {
    static func parse(_ data: Data) throws -> ParsedFeed {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw FeedParserError.invalidXML(parser.parserError.map { "\($0.localizedDescription)" } ?? "unknown error")
        }
        guard delegate.sawChannel else { throw FeedParserError.notAPodcastFeed }

        let channel = delegate.channel
        return ParsedFeed(
            title: channel.title?.trimmed ?? "Untitled",
            link: channel.link?.trimmed.nilIfEmpty,
            description: (channel.description ?? channel.itunesSummary)?.trimmed.nilIfEmpty,
            author: channel.itunesAuthor?.trimmed.nilIfEmpty,
            language: channel.language?.trimmed.nilIfEmpty,
            artworkURL: (channel.itunesImage ?? channel.imageURL)?.trimmed.nilIfEmpty,
            items: delegate.items.compactMap(\.parsed)
        )
    }

    // MARK: - Value parsing

    private static let dateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm zzz",
        "EEE, dd MMM yyyy HH:mm Z",
        "dd MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
    ]

    /// RFC 822 dates as found in the wild (with/without weekday, seconds, named or numeric zones).
    static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmed
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// `itunes:duration` as `HH:MM:SS`, `MM:SS` or plain seconds.
    static func parseDuration(_ string: String) -> Double? {
        let parts = string.trimmed.split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    // MARK: - XML delegate

    private struct ChannelFields {
        var title: String?
        var link: String?
        var description: String?
        var itunesSummary: String?
        var itunesAuthor: String?
        var language: String?
        var itunesImage: String?
        var imageURL: String?
    }

    private struct ItemFields {
        var guid: String?
        var title: String?
        var subtitle: String?
        var description: String?
        var contentEncoded: String?
        var itunesSummary: String?
        var pubDate: String?
        var enclosureURL: String?
        var enclosureType: String?
        var enclosureLength: String?
        var duration: String?
        var episodeNumber: String?
        var seasonNumber: String?

        var parsed: ParsedItem? {
            guard let url = enclosureURL?.trimmed.nilIfEmpty else { return nil }
            let date = pubDate.flatMap(FeedParser.parseDate)
            let title = title?.trimmed.nilIfEmpty ?? "Untitled episode"
            return ParsedItem(
                // Feeds without a GUID are common enough; the enclosure URL is the usual fallback.
                guid: guid?.trimmed.nilIfEmpty ?? url,
                title: title,
                subtitle: subtitle?.trimmed.nilIfEmpty,
                descriptionHTML: (contentEncoded ?? description ?? itunesSummary)?.trimmed.nilIfEmpty,
                pubDate: date,
                enclosureURL: url,
                enclosureType: enclosureType?.trimmed.nilIfEmpty,
                enclosureLength: enclosureLength.flatMap { Int($0.trimmed) }.flatMap { $0 > 0 ? $0 : nil },
                duration: duration.flatMap(FeedParser.parseDuration),
                episodeNumber: episodeNumber.flatMap { Int($0.trimmed) },
                seasonNumber: seasonNumber.flatMap { Int($0.trimmed) }
            )
        }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var sawChannel = false
        var channel = ChannelFields()
        var items: [ItemFields] = []

        private var stack: [String] = []
        private var text = ""
        private var currentItem: ItemFields?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes: [String: String] = [:]
        ) {
            stack.append(elementName)
            text = ""
            switch elementName {
            case "channel":
                sawChannel = true
            case "item":
                currentItem = ItemFields()
            case "enclosure" where currentItem != nil:
                // Some feeds have several enclosures; the first one wins.
                if currentItem?.enclosureURL == nil {
                    currentItem?.enclosureURL = attributes["url"]
                    currentItem?.enclosureType = attributes["type"]
                    currentItem?.enclosureLength = attributes["length"]
                }
            case "itunes:image":
                if currentItem == nil, channel.itunesImage == nil {
                    channel.itunesImage = attributes["href"]
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            defer {
                stack.removeLast()
                text = ""
            }
            let parent = stack.dropLast().last

            if elementName == "item", let item = currentItem {
                items.append(item)
                currentItem = nil
                return
            }

            if currentItem != nil, parent == "item" {
                switch elementName {
                case "guid": currentItem?.guid = text
                case "title": currentItem?.title = text
                case "itunes:subtitle": currentItem?.subtitle = text
                case "description": currentItem?.description = text
                case "content:encoded": currentItem?.contentEncoded = text
                case "itunes:summary": currentItem?.itunesSummary = text
                case "pubDate": currentItem?.pubDate = text
                case "itunes:duration": currentItem?.duration = text
                case "itunes:episode": currentItem?.episodeNumber = text
                case "itunes:season": currentItem?.seasonNumber = text
                default: break
                }
                return
            }

            if parent == "channel" {
                switch elementName {
                case "title": channel.title = channel.title ?? text
                case "link": channel.link = channel.link ?? text
                case "description": channel.description = channel.description ?? text
                case "itunes:summary": channel.itunesSummary = channel.itunesSummary ?? text
                case "itunes:author": channel.itunesAuthor = channel.itunesAuthor ?? text
                case "language": channel.language = channel.language ?? text
                default: break
                }
            } else if parent == "image", elementName == "url", stack.dropLast(2).last == "channel" {
                channel.imageURL = channel.imageURL ?? text
            }
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
