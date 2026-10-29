@testable import App
import Testing

@Suite("SecretMasking")
struct SecretMaskingTests {
    @Test func masksQueryValues() {
        #expect(SecretMasking.mask(url: "https://feeds.example.com/rss?token=abc123&format=mp3")
            == "https://feeds.example.com/rss?token=••••&format=••••")
    }

    @Test func masksTokenPathSegments() {
        #expect(SecretMasking.mask(url: "https://www.patreon.com/rss/someshow?auth=Xy12Zq&show=123")
            == "https://www.patreon.com/rss/someshow?auth=••••&show=••••")
        #expect(SecretMasking.mask(url: "https://feeds.supercast.com/episodes/a1b2c3d4e5f6g7h8i9j0.rss")
            == "https://feeds.supercast.com/episodes/••••")
        #expect(SecretMasking.mask(url: "https://example.com/podcast/my-really-long-show-name/feed")
            == "https://example.com/podcast/my-really-long-show-name/feed", "plain words aren't tokens")
    }

    @Test func masksUserInfo() {
        #expect(SecretMasking.mask(url: "https://user:hunter2@feeds.example.com/feed")
            == "https://••••@feeds.example.com/feed")
    }

    @Test func unparseableInputRevealsNothing() {
        #expect(SecretMasking.mask(url: "not a url with token 123") == "••••")
    }

    @Test func redactsSecretsInText() {
        let secret = "https://feeds.example.com/rss?token=abc123"
        #expect(SecretMasking.redact("GET \(secret) failed: 403", secrets: [secret])
            == "GET https://feeds.example.com/rss?token=•••• failed: 403")
    }
}
