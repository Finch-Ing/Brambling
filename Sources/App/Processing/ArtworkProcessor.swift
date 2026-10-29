import Foundation
import Logging

/// Downloads show artwork and stores it as `art/<slug>.jpg` (plan §5.1 step 6).
struct ArtworkProcessor: Sendable {
    let downloader: any EpisodeDownloading
    let processor: any AudioProcessing
    let artDirectory: URL
    let tmpDirectory: URL

    func artworkFile(slug: String) -> URL {
        artDirectory.appendingPathComponent("\(slug).jpg")
    }

    /// Re-fetches only if the source URL changed or the file is missing.
    func needsUpdate(for show: Show) -> Bool {
        guard show.artworkSourceURL != nil else { return false }
        return show.artworkSourceURL != show.artworkFetchedURL
            || !FileManager.default.fileExists(atPath: artworkFile(slug: show.slug).path)
    }

    func update(_ show: Show) async throws {
        guard let url = show.artworkSourceURL else { return }
        let source = tmpDirectory.appendingPathComponent("art-\(show.slug).src")
        let converted = tmpDirectory.appendingPathComponent("art-\(show.slug).jpg")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: converted)
        }
        _ = try await downloader.download(from: url, to: source, timeout: .seconds(120))
        try await processor.convertArtwork(source: source, output: converted)
        let destination = artworkFile(slug: show.slug)
        _ = try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: converted, to: destination)
        show.artworkFetchedURL = url
    }
}
