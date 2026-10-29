import Foundation

/// Keeps the data volume from filling up (plan §5.4). The decision logic is pure;
/// `DiskGuard.usage` does the I/O.
enum DiskGuard {
    struct Limits: Sendable, Equatable {
        var minFreeBytes: Int64
        var maxMediaBytes: Int64?
    }

    struct Usage: Sendable, Equatable {
        var freeBytes: Int64
        var mediaBytes: Int64
        var tmpBytes: Int64
    }

    enum Decision: Sendable, Equatable {
        case allowed
        case blocked(reason: String)
    }

    /// Assumed source size when the feed doesn't say.
    static let unknownSourceSize: Int64 = 300 * 1024 * 1024

    /// Source plus output; the output is about the source size because quality is kept.
    static func downloadNeed(enclosureLength: Int?) -> Int64 {
        2 * (enclosureLength.map(Int64.init) ?? unknownSourceSize)
    }

    static func check(need: Int64, usage: Usage, limits: Limits) -> Decision {
        if usage.freeBytes - need < limits.minFreeBytes {
            return .blocked(reason: "\(format(usage.freeBytes)) free, need \(format(need)) plus the \(format(limits.minFreeBytes)) minimum")
        }
        if let maxMedia = limits.maxMediaBytes, usage.mediaBytes + usage.tmpBytes + need > maxMedia {
            return .blocked(reason: "media uses \(format(usage.mediaBytes + usage.tmpBytes)) of \(format(maxMedia)), need \(format(need)) more")
        }
        return .allowed
    }

    static func format(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    // MARK: - I/O

    static func freeBytes(at url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// Total size of the regular files directly inside `directory` (used for `tmp/`).
    static func directorySize(_ directory: URL) -> Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        )) ?? []
        return urls.reduce(0) { total, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return total + Int64(values?.isRegularFile == true ? values?.fileSize ?? 0 : 0)
        }
    }

    /// Whether an error means the disk is full (ENOSPC), from Foundation or from ffmpeg's stderr.
    static func isOutOfSpace(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) { return true }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error, isOutOfSpace(underlying) { return true }
        return String(describing: error).contains("No space left on device")
    }
}
