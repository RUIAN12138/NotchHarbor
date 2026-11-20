//
//  ClipboardHistoryArchive.swift
//  boringNotch
//
//  Local, on-disk persistence for clipboard history. This module owns all
//  serial file IO so the store itself never blocks the main actor on assets.
//  It intentionally has no Defaults, Shelf or UI dependencies.
//

import CryptoKit
import Darwin
import Foundation
import ImageIO

enum ClipboardArchiveLoadOutcome: Sendable {
    case empty
    case entries([ClipboardHistoryEntry])
    case partial([ClipboardHistoryEntry], message: String)
    /// The index exists but cannot be understood. Writes are refused until an
    /// explicit reset so an unknown or corrupt format is never overwritten.
    case unreadable(message: String)
}

struct ClipboardArchiveSaveOutcome: Equatable, Sendable {
    let savedCount: Int
    let skippedFileEntries: Int
    let failed: Bool
    let blocked: Bool

    static let failure = ClipboardArchiveSaveOutcome(
        savedCount: 0,
        skippedFileEntries: 0,
        failed: true,
        blocked: false
    )

    static let blockedWrite = ClipboardArchiveSaveOutcome(
        savedCount: 0,
        skippedFileEntries: 0,
        failed: false,
        blocked: true
    )
}

/// One serial, versioned archive directory:
///
///     ClipboardHistory/
///       index.json         0600, atomic replace, metadata only
///       assets/<sha256>.blob  0600, content-addressed payloads
///
/// Text bodies, RTF/HTML, full PNGs and thumbnails all live in `assets`.
/// File entries store bookmarks and display names only; source files are never
/// copied into this directory.
final class ClipboardHistoryArchive: @unchecked Sendable {
    static let indexFileName = "index.json"
    static let assetsDirectoryName = "assets"

    private static let formatVersion = 1
    private static let maximumIndexBytes = 8 * 1024 * 1024
    private static let maximumBookmarkBytes = 1024 * 1024
    private static let maximumFileReferences = 64
    private static let maximumThumbnailBytes = 4 * 1024 * 1024
    private static let assetNameLength = 64 + ".blob".utf8.count

    let directory: URL

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let maxItems: Int
    private let maxTotalBytes: Int
    private let maxImageBytes: Int
    private let maxReadBytes: Int

    // All mutable state below is confined to `queue`.
    private var loaded = false
    private var blocked = false
    private var cachedOutcome: ClipboardArchiveLoadOutcome?

    init(
        directory: URL,
        queue: DispatchQueue? = nil,
        maxItems: Int = 50,
        maxTotalBytes: Int = 64 * 1024 * 1024,
        maxImageBytes: Int = 16 * 1024 * 1024,
        maxReadBytes: Int = 64 * 1024 * 1024
    ) {
        self.directory = directory.standardizedFileURL
        self.queue = queue ?? DispatchQueue(label: "boringNotch.clipboard.history.archive")
        self.maxItems = max(1, maxItems)
        self.maxTotalBytes = max(1, maxTotalBytes)
        self.maxImageBytes = max(1, maxImageBytes)
        self.maxReadBytes = max(1, maxReadBytes)
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    private var indexURL: URL {
        directory.appendingPathComponent(Self.indexFileName, isDirectory: false)
    }

    private var assetsDirectoryURL: URL {
        directory.appendingPathComponent(Self.assetsDirectoryName, isDirectory: true)
    }

    // MARK: - Public entry points

    func load() async -> ClipboardArchiveLoadOutcome {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.loadLocked())
            }
        }
    }

    func save(_ entries: [ClipboardHistoryEntry]) async -> ClipboardArchiveSaveOutcome {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.saveLocked(entries))
            }
        }
    }

    /// Explicit user reset (clear history). Unlike a normal save this is also
    /// allowed when the previous index was unreadable: the user asked to start
    /// over. Only paths inside this dedicated directory are removed.
    func reset(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            let succeeded = self.resetLocked()
            DispatchQueue.main.async {
                completion(succeeded)
            }
        }
    }

    // MARK: - Termination-only synchronous entry points

    func loadSynchronously() -> ClipboardArchiveLoadOutcome {
        guard DispatchQueue.getSpecific(key: queueKey) == nil else {
            return .unreadable(message: "本机历史无法读取")
        }
        return queue.sync { loadLocked() }
    }

    func saveSynchronously(_ entries: [ClipboardHistoryEntry]) -> ClipboardArchiveSaveOutcome {
        guard DispatchQueue.getSpecific(key: queueKey) == nil else {
            return .failure
        }
        return queue.sync { saveLocked(entries) }
    }

    // MARK: - Load

    private func loadLocked() -> ClipboardArchiveLoadOutcome {
        if let cachedOutcome {
            return cachedOutcome
        }

        do {
            try prepareDirectoriesLocked()
        } catch {
            blocked = true
            loaded = true
            let outcome = ClipboardArchiveLoadOutcome.unreadable(message: "无法访问本机存储")
            cachedOutcome = outcome
            return outcome
        }

        guard let indexInfo = lstatInfo(indexURL) else {
            loaded = true
            cachedOutcome = .empty
            return .empty
        }

        guard (indexInfo.mode & S_IFMT) == S_IFREG,
              indexInfo.size <= Self.maximumIndexBytes,
              let data = try? Data(contentsOf: indexURL),
              data.count <= Self.maximumIndexBytes
        else {
            return blockLocked()
        }

        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(StoredHeader.self, from: data),
              header.formatVersion == Self.formatVersion
        else {
            return blockLocked()
        }

        guard let stored = try? decoder.decode(StoredIndex.self, from: data) else {
            return blockLocked()
        }

        var restored: [ClipboardHistoryEntry] = []
        var skipped = 0
        var totalBytes = 0
        let candidates = stored.entries.prefix(maxItems)
        skipped += max(0, stored.entries.count - maxItems)

        for item in candidates {
            guard let entry = restoreEntry(item),
                  totalBytes + entry.byteCount <= maxTotalBytes
            else {
                skipped += 1
                continue
            }
            restored.append(entry)
            totalBytes += entry.byteCount
        }

        loaded = true
        let outcome: ClipboardArchiveLoadOutcome
        if skipped > 0 {
            outcome = .partial(restored, message: "部分历史未能恢复")
        } else if restored.isEmpty {
            outcome = .empty
        } else {
            outcome = .entries(restored)
        }
        cachedOutcome = outcome
        return outcome
    }

    private func blockLocked() -> ClipboardArchiveLoadOutcome {
        blocked = true
        loaded = true
        let outcome = ClipboardArchiveLoadOutcome.unreadable(message: "本机历史文件无法读取")
        cachedOutcome = outcome
        return outcome
    }

    private func restoreEntry(_ stored: StoredEntry) -> ClipboardHistoryEntry? {
        if let text = stored.text {
            guard let bodyData = readAssetLocked(named: text.bodyAsset, maxBytes: maxReadBytes),
                  let body = String(data: bodyData, encoding: .utf8),
                  !body.isEmpty
            else { return nil }

            let rtf = text.rtfAsset.flatMap {
                readAssetLocked(named: $0, maxBytes: maxReadBytes)
            }
            let html = text.htmlAsset.flatMap {
                readAssetLocked(named: $0, maxBytes: maxReadBytes)
            }
            let url = text.urlString.flatMap { value -> URL? in
                guard value.utf8.count <= 8 * 1024 else { return nil }
                return URL(string: value)
            }
            let content = ClipboardTextContent(
                text: body,
                rtf: rtf,
                html: html,
                url: url
            )
            let kind = ClipboardHistoryEntry.Kind.text(content)
            return makeEntry(
                id: stored.id,
                capturedAt: stored.capturedAt,
                isPinned: stored.isPinned == true,
                kind: kind,
                fileReferences: nil
            )
        }

        if let image = stored.image {
            guard image.pixelWidth > 0,
                  image.pixelHeight > 0,
                  let pngData = readAssetLocked(named: image.pngAsset, maxBytes: maxImageBytes),
                  let size = pixelSize(of: pngData),
                  size.width > 0,
                  size.height > 0
            else { return nil }

            var thumbnail = image.thumbnailAsset.flatMap {
                readAssetLocked(named: $0, maxBytes: Self.maximumThumbnailBytes)
            }
            if let data = thumbnail, !isDecodableImage(data) {
                thumbnail = nil
            }
            if thumbnail == nil {
                thumbnail = makeThumbnail(from: pngData)
            }

            let content = ClipboardImageContent(
                pngData: pngData,
                thumbnailData: thumbnail,
                pixelWidth: size.width,
                pixelHeight: size.height
            )
            let kind = ClipboardHistoryEntry.Kind.image(content)
            return makeEntry(
                id: stored.id,
                capturedAt: stored.capturedAt,
                isPinned: stored.isPinned == true,
                kind: kind,
                fileReferences: nil
            )
        }

        if let files = stored.files {
            guard !files.isEmpty, files.count <= Self.maximumFileReferences else {
                return nil
            }

            var references: [ClipboardFileReference] = []
            var urls: [URL] = []
            for file in files {
                let bookmark: Data? = {
                    guard !file.bookmark.isEmpty,
                          file.bookmark.count <= Self.maximumBookmarkBytes
                    else { return nil }
                    return file.bookmark
                }()

                guard let bookmark else {
                    references.append(ClipboardFileReference(
                        displayName: file.displayName,
                        bookmarkData: nil,
                        isSecurityScoped: file.securityScoped,
                        resolvedURL: nil
                    ))
                    continue
                }

                let options: URL.BookmarkResolutionOptions = file.securityScoped
                    ? [.withSecurityScope]
                    : []
                var stale = false
                guard let resolved = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: options,
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ) else {
                    references.append(ClipboardFileReference(
                        displayName: file.displayName,
                        bookmarkData: bookmark,
                        isSecurityScoped: file.securityScoped,
                        resolvedURL: nil
                    ))
                    continue
                }

                var refreshed = bookmark
                if stale {
                    let started = resolved.startAccessingSecurityScopedResource()
                    let creationOptions: URL.BookmarkCreationOptions = file.securityScoped
                        ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
                        : []
                    if let data = try? resolved.bookmarkData(
                        options: creationOptions,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        refreshed = data
                    }
                    if started {
                        resolved.stopAccessingSecurityScopedResource()
                    }
                }

                references.append(ClipboardFileReference(
                    displayName: file.displayName,
                    bookmarkData: refreshed,
                    isSecurityScoped: file.securityScoped,
                    resolvedURL: resolved
                ))
                urls.append(resolved)
            }

            guard !references.isEmpty else { return nil }
            let kind = ClipboardHistoryEntry.Kind.files(urls)
            return makeEntry(
                id: stored.id,
                capturedAt: stored.capturedAt,
                isPinned: stored.isPinned == true,
                kind: kind,
                fileReferences: references
            )
        }

        return nil
    }

    private func makeEntry(
        id: UUID,
        capturedAt: Date,
        isPinned: Bool,
        kind: ClipboardHistoryEntry.Kind,
        fileReferences: [ClipboardFileReference]?
    ) -> ClipboardHistoryEntry {
        ClipboardHistoryEntry(
            id: id,
            fingerprint: ClipboardHistoryStore.fingerprint(for: kind, fileReferences: fileReferences),
            kind: kind,
            capturedAt: capturedAt,
            byteCount: ClipboardHistoryStore.approximateByteCount(for: kind),
            fileReferences: fileReferences,
            isPinned: isPinned
        )
    }

    // MARK: - Save

    private func saveLocked(_ entries: [ClipboardHistoryEntry]) -> ClipboardArchiveSaveOutcome {
        guard !blocked else { return .blockedWrite }
        guard loaded else { return .failure }
        do {
            try prepareDirectoriesLocked()
        } catch {
            return .failure
        }

        var storedEntries: [StoredEntry] = []
        var assetPayloads: [(name: String, data: Data)] = []
        var skippedFileEntries = 0
        var totalBytes = 0

        for entry in entries.prefix(maxItems) {
            guard totalBytes + max(0, entry.byteCount) <= maxTotalBytes,
                  let converted = makeStoredEntry(from: entry)
            else {
                if case .files = entry.kind {
                    skippedFileEntries += 1
                }
                continue
            }
            storedEntries.append(converted.entry)
            assetPayloads.append(contentsOf: converted.assets)
            totalBytes += max(0, entry.byteCount)
        }

        for payload in assetPayloads {
            guard writeAssetLocked(named: payload.name, data: payload.data) else {
                return .failure
            }
        }

        let index = StoredIndex(formatVersion: Self.formatVersion, entries: storedEntries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(index),
              data.count <= Self.maximumIndexBytes,
              atomicWriteLocked(data, to: indexURL)
        else {
            return .failure
        }

        pruneAssetsLocked(referenced: Set(assetPayloads.map(\.name)))

        return ClipboardArchiveSaveOutcome(
            savedCount: storedEntries.count,
            skippedFileEntries: skippedFileEntries,
            failed: false,
            blocked: false
        )
    }

    private func makeStoredEntry(
        from entry: ClipboardHistoryEntry
    ) -> (entry: StoredEntry, assets: [(name: String, data: Data)])? {
        switch entry.kind {
        case .text(let content):
            guard !content.text.isEmpty else { return nil }
            let body = Data(content.text.utf8)
            guard body.count <= maxReadBytes else { return nil }

            var assets: [(String, Data)] = [(Self.assetName(for: body), body)]
            var rtfAsset: String?
            var htmlAsset: String?

            if let rtf = content.rtf, !rtf.isEmpty, rtf.count <= maxReadBytes {
                let name = Self.assetName(for: rtf)
                rtfAsset = name
                assets.append((name, rtf))
            }
            if let html = content.html, !html.isEmpty, html.count <= maxReadBytes {
                let name = Self.assetName(for: html)
                htmlAsset = name
                assets.append((name, html))
            }

            let urlString = content.url.flatMap { url -> String? in
                let value = url.absoluteString
                return value.utf8.count <= 8 * 1024 ? value : nil
            }
            return (
                StoredEntry(
                    id: entry.id,
                    capturedAt: entry.capturedAt,
                    isPinned: entry.isPinned ? true : nil,
                    text: StoredText(
                        bodyAsset: Self.assetName(for: body),
                        rtfAsset: rtfAsset,
                        htmlAsset: htmlAsset,
                        urlString: urlString
                    ),
                    image: nil,
                    files: nil
                ),
                assets
            )

        case .image(let content):
            guard !content.pngData.isEmpty,
                  content.pngData.count <= maxImageBytes,
                  content.pixelWidth > 0,
                  content.pixelHeight > 0
            else { return nil }

            let pngName = Self.assetName(for: content.pngData)
            var assets: [(String, Data)] = [(pngName, content.pngData)]

            var thumbnailAsset: String?
            if let thumbnail = content.thumbnailData,
               !thumbnail.isEmpty,
               thumbnail.count <= Self.maximumThumbnailBytes
            {
                let name = Self.assetName(for: thumbnail)
                thumbnailAsset = name
                assets.append((name, thumbnail))
            }

            return (
                StoredEntry(
                    id: entry.id,
                    capturedAt: entry.capturedAt,
                    isPinned: entry.isPinned ? true : nil,
                    text: nil,
                    image: StoredImage(
                        pngAsset: pngName,
                        thumbnailAsset: thumbnailAsset,
                        pixelWidth: content.pixelWidth,
                        pixelHeight: content.pixelHeight
                    ),
                    files: nil
                ),
                assets
            )

        case .files(let urls):
            let references: [ClipboardFileReference]
            if let existing = entry.fileReferences, !existing.isEmpty {
                references = existing
            } else if let created = makeFileReferencesLocked(for: urls) {
                references = created
            } else {
                return nil
            }

            guard !references.isEmpty,
                  references.count <= Self.maximumFileReferences
            else { return nil }

            var storedFiles: [StoredFile] = []
            for reference in references {
                guard let bookmark = reference.bookmarkData,
                      !bookmark.isEmpty,
                      bookmark.count <= Self.maximumBookmarkBytes
                else { return nil }
                let displayName = reference.displayName.count > 1024
                    ? String(reference.displayName.prefix(1024))
                    : reference.displayName
                storedFiles.append(StoredFile(
                    displayName: displayName,
                    bookmark: bookmark,
                    securityScoped: reference.isSecurityScoped
                ))
            }

            return (
                StoredEntry(
                    id: entry.id,
                    capturedAt: entry.capturedAt,
                    isPinned: entry.isPinned ? true : nil,
                    text: nil,
                    image: nil,
                    files: storedFiles
                ),
                []
            )
        }
    }

    private func makeFileReferencesLocked(for urls: [URL]) -> [ClipboardFileReference]? {
        var references: [ClipboardFileReference] = []
        for url in urls {
            let started = url.startAccessingSecurityScopedResource()
            defer {
                if started {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            if let bookmark = try? url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                references.append(ClipboardFileReference(
                    displayName: url.lastPathComponent,
                    bookmarkData: bookmark,
                    isSecurityScoped: true,
                    resolvedURL: url
                ))
            } else if !clipboardRunsInsideAppSandbox,
                      let bookmark = try? url.bookmarkData(
                          options: [],
                          includingResourceValuesForKeys: nil,
                          relativeTo: nil
                      )
            {
                references.append(ClipboardFileReference(
                    displayName: url.lastPathComponent,
                    bookmarkData: bookmark,
                    isSecurityScoped: false,
                    resolvedURL: url
                ))
            } else {
                return nil
            }
        }
        return references
    }

    // MARK: - Directory and asset IO

    private struct ArchiveIOError: Error {}

    private func prepareDirectoriesLocked() throws {
        let fileManager = FileManager.default

        if let info = lstatInfo(directory) {
            guard (info.mode & S_IFMT) == S_IFDIR else { throw ArchiveIOError() }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        _ = chmod(directory.path, 0o700)

        let assets = assetsDirectoryURL
        if let info = lstatInfo(assets) {
            guard (info.mode & S_IFMT) == S_IFDIR else { throw ArchiveIOError() }
        } else {
            try fileManager.createDirectory(
                at: assets,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        _ = chmod(assets.path, 0o700)
    }

    private func resetLocked() -> Bool {
        // Never operate through a symlinked root directory: that could delete
        // files outside the dedicated clipboard archive.
        if let info = lstatInfo(directory) {
            guard (info.mode & S_IFMT) == S_IFDIR else { return false }
        } else {
            do {
                try prepareDirectoriesLocked()
                blocked = false
                loaded = true
                cachedOutcome = .empty
                return true
            } catch {
                return false
            }
        }

        guard removeOwnedItemLocked(indexURL),
              removeOwnedItemLocked(assetsDirectoryURL)
        else { return false }

        do {
            try prepareDirectoriesLocked()
        } catch {
            return false
        }

        blocked = false
        loaded = true
        cachedOutcome = .empty
        return true
    }

    /// Removes an entry we own. Symlinks are unlinked themselves, never
    /// followed; only a real directory (the flat assets folder) is removed
    /// recursively.
    private func removeOwnedItemLocked(_ url: URL) -> Bool {
        guard let info = lstatInfo(url) else { return true }
        if (info.mode & S_IFMT) == S_IFDIR {
            do {
                try FileManager.default.removeItem(at: url)
                return true
            } catch {
                return false
            }
        } else {
            return unlink(url.path) == 0 || errno == ENOENT
        }
    }

    private static func assetName(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".blob"
    }

    private static func isValidAssetName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == assetNameLength,
              name.hasSuffix(".blob")
        else { return false }
        return bytes.prefix(64).allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private func readAssetLocked(named name: String, maxBytes: Int) -> Data? {
        guard Self.isValidAssetName(name) else { return nil }
        let url = assetsDirectoryURL.appendingPathComponent(name, isDirectory: false)
        guard let info = lstatInfo(url),
              (info.mode & S_IFMT) == S_IFREG,
              info.size > 0,
              info.size <= Int64(maxBytes)
        else { return nil }
        return try? Data(contentsOf: url)
    }

    private func writeAssetLocked(named name: String, data: Data) -> Bool {
        guard Self.isValidAssetName(name) else { return false }
        let url = assetsDirectoryURL.appendingPathComponent(name, isDirectory: false)

        // Content-addressed dedupe: a regular file of the expected size already
        // has this content. Symlinks are never followed or trusted.
        if let info = lstatInfo(url),
           (info.mode & S_IFMT) == S_IFREG,
           info.size == Int64(data.count)
        {
            return true
        }

        return atomicWriteLocked(data, to: url)
    }

    private func atomicWriteLocked(_ data: Data, to url: URL) -> Bool {
        let fileManager = FileManager.default
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: false)

        // The temp name is unique and the directory is 0700. Refuse to write
        // through a pre-existing path so a planted symlink is never followed.
        guard lstatInfo(temporary) == nil else { return false }
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { return false }

        guard let info = lstatInfo(temporary),
              (info.mode & S_IFMT) == S_IFREG,
              info.size == Int64(data.count)
        else {
            unlink(temporary.path)
            return false
        }

        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try? handle.close()
        } catch {
            unlink(temporary.path)
            return false
        }

        _ = chmod(temporary.path, 0o600)
        let renamed = rename(temporary.path, url.path) == 0
        if renamed {
            _ = chmod(url.path, 0o600)
        } else {
            unlink(temporary.path)
        }
        return renamed
    }

    private func pruneAssetsLocked(referenced: Set<String>) {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: assetsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }

        for child in children {
            let name = child.lastPathComponent
            guard Self.isValidAssetName(name), !referenced.contains(name) else {
                continue
            }
            guard let info = lstatInfo(child) else { continue }
            let type = info.mode & S_IFMT
            // Delete our own files and symlinks only. Never recurse into or
            // follow an unexpected directory.
            if type == S_IFREG || type == S_IFLNK {
                unlink(child.path)
            }
        }
    }

    private func lstatInfo(_ url: URL) -> (mode: mode_t, size: Int64)? {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &status)
        }
        guard result == 0 else { return nil }
        return (status.st_mode, Int64(status.st_size))
    }

    // MARK: - Image helpers (archive queue only)

    private func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0
        else { return nil }
        return (width, height)
    }

    private func isDecodableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        return CGImageSourceGetCount(source) > 0
    }

    private func makeThumbnail(from pngData: Data, maxPixelSize: Int = 192) -> Data? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Stored format

    private struct StoredHeader: Decodable {
        let formatVersion: Int
    }

    private struct StoredIndex: Codable {
        let formatVersion: Int
        let entries: [StoredEntry]
    }

    private struct StoredEntry: Codable {
        let id: UUID
        let capturedAt: Date
        let isPinned: Bool?
        let text: StoredText?
        let image: StoredImage?
        let files: [StoredFile]?
    }

    private struct StoredText: Codable {
        let bodyAsset: String
        let rtfAsset: String?
        let htmlAsset: String?
        let urlString: String?
    }

    private struct StoredImage: Codable {
        let pngAsset: String
        let thumbnailAsset: String?
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private struct StoredFile: Codable {
        let displayName: String
        let bookmark: Data
        let securityScoped: Bool
    }
}
