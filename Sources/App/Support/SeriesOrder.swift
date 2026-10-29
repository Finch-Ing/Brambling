import Foundation

/// The one rule for "oldest first" (plan §7.1), used by the feed and the web UI alike:
/// 1. every item has a season and a number → by season, then number (works for numbering that
///    restarts each season and for continuous numbering);
/// 2. every item has a number and the numbers are unique → by number alone (continuous numbering,
///    e.g. specials without a season in between);
/// 3. otherwise by date.
enum SeriesOrder {
    static func sorted<T>(
        _ items: [T], episode: (T) -> Int?, season: (T) -> Int?, date: (T) -> Date
    ) -> [T] {
        let numbers = items.compactMap(episode)
        let allNumbered = numbers.count == items.count
        let bySeason = allNumbered && items.allSatisfy { season($0) != nil }
        let byNumber = allNumbered && Set(numbers).count == numbers.count
        return items.sorted { a, b in
            if bySeason, season(a)! != season(b)! { return season(a)! < season(b)! }
            if bySeason || byNumber, episode(a)! != episode(b)! { return episode(a)! < episode(b)! }
            return date(a) < date(b)
        }
    }

    static func sorted(_ episodes: [Episode]) -> [Episode] {
        sorted(episodes, episode: \.episodeNumber, season: \.seasonNumber, date: \.pubDate)
    }
}
