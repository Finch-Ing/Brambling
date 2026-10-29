@testable import App
import Foundation
import Testing

@Suite("DiskGuard")
struct DiskGuardTests {
    static let gb: Int64 = 1_073_741_824
    let limits = DiskGuard.Limits(minFreeBytes: 5 * gb, maxMediaBytes: nil)

    @Test func allowsWithEnoughSpace() {
        let usage = DiskGuard.Usage(freeBytes: 20 * Self.gb, mediaBytes: 0, tmpBytes: 0)
        #expect(DiskGuard.check(need: Self.gb, usage: usage, limits: limits) == .allowed)
    }

    @Test func blocksAtMinimumFree() {
        let usage = DiskGuard.Usage(freeBytes: 5 * Self.gb + 100, mediaBytes: 0, tmpBytes: 0)
        guard case let .blocked(reason) = DiskGuard.check(need: 200, usage: usage, limits: limits) else {
            Issue.record("expected blocked"); return
        }
        #expect(reason.contains("5.0 GB minimum"))
        #expect(DiskGuard.check(need: 100, usage: usage, limits: limits) == .allowed, "exactly at the limit is fine")
    }

    @Test func maxMediaCountsMediaTmpAndNeed() {
        let capped = DiskGuard.Limits(minFreeBytes: 0, maxMediaBytes: 10 * Self.gb)
        let usage = DiskGuard.Usage(freeBytes: 100 * Self.gb, mediaBytes: 8 * Self.gb, tmpBytes: Self.gb)
        #expect(DiskGuard.check(need: Self.gb, usage: usage, limits: capped) == .allowed)
        guard case let .blocked(reason) = DiskGuard.check(need: Self.gb + 1, usage: usage, limits: capped) else {
            Issue.record("expected blocked"); return
        }
        #expect(reason.contains("of 10.0 GB"))
        #expect(DiskGuard.check(need: 50 * Self.gb, usage: usage, limits: limits) == .allowed, "no cap when unset")
    }

    @Test func downloadNeedEstimate() {
        #expect(DiskGuard.downloadNeed(enclosureLength: 1000) == 2000)
        #expect(DiskGuard.downloadNeed(enclosureLength: nil) == 2 * DiskGuard.unknownSourceSize)
    }

    @Test func recognisesOutOfSpaceErrors() {
        #expect(DiskGuard.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        #expect(DiskGuard.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        #expect(DiskGuard.isOutOfSpace(AudioProcessorError.ffmpegFailed(code: 1, stderr: "out.mp3: No space left on device")))
        #expect(!DiskGuard.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }
}
