//
//  ShelfStateViewModel.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-09.

import Foundation
import AppKit

@MainActor
final class ShelfStateViewModel: ObservableObject {
    static let shared = ShelfStateViewModel()

    @Published private(set) var items: [ShelfItem] = [] {
        didSet {
            ShelfPersistenceService.shared.save(items)
            // The file-focus prompt only lives while the shelf still holds a
            // file. Text/link items do not keep it alive.
            if !hasFileItems {
                if filePriorityActive { emptyShelfFallbackPending = true }
                filePriorityActive = false
            }
        }
    }

    @Published private(set) var isLoading: Bool = false
    private var pendingLoads = 0

    /// Process-local hint set when a newly dropped file is actually appended.
    /// ContentView reads it on open so a fresh file opens the shelf ahead of
    /// the usual agent/timer/music routes. It is never persisted and clears as
    /// soon as the shelf has no file left.
    @Published private(set) var filePriorityActive: Bool = false

    /// Set when the last file that held the shelf priority is removed. The next
    /// open can leave an empty remembered shelf without disturbing a shelf the
    /// user selected on their own.
    @Published private(set) var emptyShelfFallbackPending: Bool = false

    var isEmpty: Bool { items.isEmpty }

    /// Reads and clears the one-shot empty-shelf fallback.
    func consumeEmptyShelfFallback() -> Bool {
        guard emptyShelfFallbackPending else { return false }
        emptyShelfFallbackPending = false
        return true
    }

    var hasFileItems: Bool {
        items.contains {
            if case .file = $0.kind { return true }
            return false
        }
    }

    // Queue for deferred bookmark updates to avoid publishing during view updates
    private var pendingBookmarkUpdates: [ShelfItem.ID: Data] = [:]
    private var updateTask: Task<Void, Never>?

    private init() {
        items = ShelfPersistenceService.shared.load()
    }


    func add(_ newItems: [ShelfItem]) {
        guard !newItems.isEmpty else { return }
        var merged = items
        // Deduplicate by identityKey while preserving order (existing first)
        var seen: Set<String> = Set(merged.map { $0.identityKey })
        var appendedFile = false
        for it in newItems {
            let key = it.identityKey
            if !seen.contains(key) {
                merged.append(it)
                seen.insert(key)
                if case .file = it.kind { appendedFile = true }
            }
        }
        items = merged
        // Duplicates, text, links and failed drops never raise this flag.
        if appendedFile && hasFileItems {
            filePriorityActive = true
            emptyShelfFallbackPending = false
        }
    }

    func remove(_ item: ShelfItem) {
        item.cleanupStoredData()
        items.removeAll { $0.id == item.id }
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if case .file = items[idx].kind {
            items[idx].kind = .file(bookmark: bookmark)
        }
    }

    private func scheduleDeferredBookmarkUpdate(for item: ShelfItem, bookmark: Data) {
        pendingBookmarkUpdates[item.id] = bookmark
        
        // Cancel existing task and schedule a new one
        updateTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            await Task.yield()
            
            guard let self = self else { return }
            
            for (itemID, bookmarkData) in self.pendingBookmarkUpdates {
                if let idx = self.items.firstIndex(where: { $0.id == itemID }),
                   case .file = self.items[idx].kind {
                    self.items[idx].kind = .file(bookmark: bookmarkData)
                }
            }
            
            self.pendingBookmarkUpdates.removeAll()
        }
    }


    func load(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        beginLoading()
        Task { [weak self] in
            let dropped = await ShelfDropService.items(from: providers)
            guard let self else { return }
            self.add(dropped)
            self.endLoading()
        }
    }

    func beginLoading() {
        pendingLoads += 1
        if !isLoading { isLoading = true }
    }

    func endLoading() {
        guard pendingLoads > 0 else { return }
        pendingLoads -= 1
        if pendingLoads == 0 { isLoading = false }
    }

    func cleanupInvalidItems() {
        Task { [weak self] in
            guard let self else { return }
            var invalid: [ShelfItem.ID: Data] = [:]
            for item in self.items {
                guard case .file(let data) = item.kind else { continue }
                if !(await Bookmark(data: data).validate()) { invalid[item.id] = data }
            }
            // Validation can suspend while the user adds a file or refreshes a
            // bookmark. Only remove the exact item version we validated.
            let removed = self.items.filter { item in
                guard case .file(let data) = item.kind else { return false }
                return invalid[item.id] == data
            }
            guard !removed.isEmpty else { return }
            let removedIDs = Set(removed.map(\.id))
            removed.forEach { $0.cleanupStoredData() }
            self.items.removeAll { removedIDs.contains($0.id) }
        }
    }


    func resolveFileURL(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            scheduleDeferredBookmarkUpdate(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveAndUpdateBookmark(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            updateBookmark(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveFileURLs(for items: [ShelfItem]) -> [URL] {
        var urls: [URL] = []
        for it in items {
            if let u = resolveFileURL(for: it) { urls.append(u) }
        }
        return urls
    }
}
