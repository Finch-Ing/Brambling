import AsyncHTTPClient
import Foundation
import NIOCore
import Vapor

protocol EpisodeDownloading: Sendable {
    /// Streams `url` to `file` and returns the number of bytes written.
    func download(from url: String, to file: URL, timeout: Duration) async throws -> Int64
}

enum DownloadError: Error, CustomStringConvertible {
    case httpStatus(UInt)
    case empty

    var description: String {
        switch self {
        case let .httpStatus(code): "Download failed with HTTP \(code)"
        case .empty: "Download returned no data"
        }
    }
}

/// Streams to disk with AsyncHTTPClient, so a 200 MB episode never sits in memory.
struct HTTPEpisodeDownloader: EpisodeDownloading {
    let client: HTTPClient

    func download(from url: String, to file: URL, timeout: Duration) async throws -> Int64 {
        var request = HTTPClientRequest(url: url)
        request.headers.add(name: "User-Agent", value: FeedFetcher.userAgent)
        let seconds = Int64(timeout.components.seconds)
        let response = try await client.execute(request, deadline: .now() + .seconds(seconds))
        guard (200..<300).contains(response.status.code) else {
            throw DownloadError.httpStatus(response.status.code)
        }

        try? FileManager.default.removeItem(at: file)
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        var written: Int64 = 0
        for try await buffer in response.body {
            try handle.write(contentsOf: buffer.readableBytesView)
            written += Int64(buffer.readableBytes)
        }
        guard written > 0 else { throw DownloadError.empty }
        return written
    }
}
