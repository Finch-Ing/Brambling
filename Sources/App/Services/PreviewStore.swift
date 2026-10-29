import Foundation
import Vapor

/// Holds feed URLs between "Preview" and "Add show", so the secret URL never has to be
/// put into the page's HTML. Entries expire after 30 minutes.
actor PreviewStore {
    static let lifetime: TimeInterval = 30 * 60
    private var entries: [String: (url: String, expires: Date)] = [:]

    func put(_ url: String, now: Date = Date()) -> String {
        entries = entries.filter { $0.value.expires > now }
        let id = UUID().uuidString.lowercased()
        entries[id] = (url, now.addingTimeInterval(Self.lifetime))
        return id
    }

    func get(_ id: String, now: Date = Date()) -> String? {
        guard let entry = entries[id], entry.expires > now else { return nil }
        return entry.url
    }

    func remove(_ id: String) {
        entries[id] = nil
    }
}

extension Application {
    private struct PreviewStoreKey: StorageKey {
        typealias Value = PreviewStore
    }

    var previewStore: PreviewStore {
        if let store = storage[PreviewStoreKey.self] { return store }
        let store = PreviewStore()
        storage[PreviewStoreKey.self] = store
        return store
    }
}
