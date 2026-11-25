//
//  ClipboardHistoryStore.swift
//  boringNotch
//
//  In-memory clipboard history. Kept independent of Shelf and Defaults so the
//  production store can be compiled against a private NSPasteboard in tests.
//

import AppKit
import Combine
import CryptoKit
import Foundation
import ImageIO

struct ClipboardTextContent: Equatable, Sendable {
    let text: String
    let rtf: Data?
    let html: Data?
    let url: URL?
}

struct ClipboardImageContent: Equatable, Sendable {
    let pngData: Data
    let thumbnailData: Data?
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Persisted reference to a source file. The history never stores file
/// contents; `bookmarkData` is the sandbox-resolvable reference and
/// `resolvedURL` is only valid while the security scope is held.
struct ClipboardFileReference: Equatable, Sendable {
    let displayName: String
    let bookmarkData: Data?
    let isSecurityScoped: Bool
    let resolvedURL: URL?
}

/// Small RAII bridge for security-scoped URLs. Callers must hold the lease
/// across pasteboard writes or async shelf reads and release it afterwards.
final class ClipboardFileAccessLease: @unchecked Sendable {
    private let lock = NSLock()
    private var activeURLs: [URL]

    init(urls: [URL]) {
        var active: [URL] = []
        for url in urls where url.startAccessingSecurityScopedResource() {
            active.append(url)
        }
        self.activeURLs = active
    }

    func release() {
        lock.lock()
        let urls = activeURLs
        activeURLs = []
        lock.unlock()
        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
    }

    deinit {
        release()
    }
}

enum ClipboardPersistenceStatus: Equatable {
    case unavailable
    case ready
    case degraded(String)
}

struct ClipboardHistoryEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case text(ClipboardTextContent)
        case image(ClipboardImageContent)
        case files([URL])
    }

    let id: UUID
    let fingerprint: String
    var kind: Kind
    /// Last successful copy, whether detected externally or copied from history.
    var capturedAt: Date
    /// Approximate resident cost, used only for the in-memory budget.
    var byteCount: Int
    /// Bookmarks for file groups. Persisted entries keep display names even
    /// when a bookmark can no longer be resolved.
    var fileReferences: [ClipboardFileReference]? = nil
    var isPinned = false

    var fileDisplayNames: [String] {
        if let fileReferences, !fileReferences.isEmpty {
            return fileReferences.map(\.displayName)
        }
        if case .files(let urls) = kind {
            return urls.map(\.lastPathComponent)
        }
        return []
    }

    var resolvedFileURLs: [URL] {
        if let fileReferences, !fileReferences.isEmpty {
            return fileReferences.compactMap(\.resolvedURL)
        }
        if case .files(let urls) = kind {
            return urls
        }
        return []
    }

    var hasCompleteFileGroup: Bool {
        guard case .files(let urls) = kind else { return false }
        guard let fileReferences else { return !urls.isEmpty }
        return !fileReferences.isEmpty
            && fileReferences.count == urls.count
            && fileReferences.allSatisfy { $0.resolvedURL != nil }
    }

    var kindLabel: String {
        switch kind {
        case .text: return "文字"
        case .image: return "图片"
        case .files(let urls):
            let count = max(fileDisplayNames.count, urls.count)
            return count > 1 ? "\(count) 个文件" : "文件"
        }
    }

    var title: String {
        switch kind {
        case .text(let content):
            let prefix = content.text.prefix(81)
            let title = String(prefix.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
            return title + (prefix.count > 80 ? "…" : "")
        case .image(let content):
            return "\(content.pixelWidth) × \(content.pixelHeight)"
        case .files:
            let names = fileDisplayNames
            guard let first = names.first else { return "文件" }
            return names.count > 1 ? "\(first) 等 \(names.count) 项" : first
        }
    }

    /// Bounded preview. The full text stays in `kind` for exact write-back.
    var previewText: String {
        guard case .text(let content) = kind else { return "" }
        let prefix = content.text.prefix(421)
        let preview = String(prefix.prefix(420)).trimmingCharacters(in: .whitespacesAndNewlines)
        return preview + (prefix.count > 420 ? "…" : "")
    }

    var thumbnailData: Data? {
        guard case .image(let content) = kind else { return nil }
        return content.thumbnailData
    }
}

struct ClipboardNotice: Identifiable {
    enum Style: Equatable {
        case info
        case error
    }

    let id = UUID()
    let text: String
    let style: Style
}

private struct ClipboardSnapshotContent {
    let kind: ClipboardHistoryEntry.Kind
    let fileReferences: [ClipboardFileReference]?
}

/// One serialized, generation-checked read of a pasteboard snapshot.
private enum ClipboardSnapshot {
    case ignored
    case empty
    case tooLarge
    case content(ClipboardSnapshotContent)
}

private enum ClipboardImageReadResult {
    case content(ClipboardImageContent)
    case unsupported
    case tooLarge
}

private struct ClipboardLimits {
    let maxItems: Int
    let maxTotalBytes: Int
    let maxImageBytes: Int
    let maxReadBytes: Int
}

/// NSPasteboard is documented as usable from any thread, but it is not marked
/// Sendable. The store only ever performs one read at a time and validates the
/// change count around it, so handing the instance to the serial queue is safe.
private final class ClipboardPasteboardBox: @unchecked Sendable {
    let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }
}

/// Security-scoped bookmarks are the only restorable file references inside
/// the app sandbox. Outside it (test binaries compiled with swiftc) a plain
/// bookmark is still useful, so the fallback is limited to that environment.
let clipboardRunsInsideAppSandbox =
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    || NSHomeDirectory().contains("/Library/Containers/")

private let clipboardIgnoredPasteboardTypes: Set<NSPasteboard.PasteboardType> = [
    NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
    NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    NSPasteboard.PasteboardType("com.agilebits.onepassword"),
    NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType"),
    NSPasteboard.PasteboardType("com.typeit4me.clipping"),
    NSPasteboard.PasteboardType("Pasteboard generator type"),
]

private let clipboardImageTypesInPriorityOrder: [NSPasteboard.PasteboardType] = [
    .png,
    .tiff,
    NSPasteboard.PasteboardType("public.jpeg"),
    NSPasteboard.PasteboardType("public.heic"),
    NSPasteboard.PasteboardType("public.heif"),
]

/// Monotonic history change counter. Save tasks from older snapshots check it
/// before writing so a late write cannot overwrite a newer clear/remove state.
private final class ClipboardPersistenceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    @discardableResult
    func advance() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }

    func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        current() == candidate
    }
}

private enum ClipboardRestoreState {
    case idle
    case running
    case finished
}

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    static let shared: ClipboardHistoryStore = {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ClipboardHistory", isDirectory: true)
        return ClipboardHistoryStore(persistenceDirectory: directory)
    }()

    @Published private(set) var items: [ClipboardHistoryEntry] = []
    @Published private(set) var isPaused = false
    @Published private(set) var isRecordingEnabled = true
    @Published private(set) var notice: ClipboardNotice?
    @Published private(set) var persistenceStatus: ClipboardPersistenceStatus

    // The clipboard page is recreated each time the notch closes.
    var carouselFilter = "all"
    var carouselPositions: [String: (entryID: UUID, inset: CGFloat, offset: CGFloat)] = [:]

    let maxItems: Int
    let maxTotalBytes: Int
    let maxImageBytes: Int
    let maxReadBytes: Int

    private let pasteboard: NSPasteboard
    private let workQueue: DispatchQueue
    private let archive: ClipboardHistoryArchive?
    private let persistenceGate = ClipboardPersistenceGate()
    private var restoreState: ClipboardRestoreState = .idle
    private var restoreTask: Task<Void, Never>?
    private var persistenceReady = false
    private var persistenceBlocked = false
    private var pendingSaveAfterRestore = false
    private var clearEpoch: UInt64 = 0
    private var didStop = false
    private var removedFingerprints: Set<String> = []
    @Published private var selectedTextRanges: [UUID: [NSRange]] = [:]
    private var resetInFlight = false
    private var resetWaiters: [CheckedContinuation<Void, Never>] = []
    private let pollInterval: TimeInterval

    private var timer: Timer?
    private var isRunning = false
    private var isReading = false
    private var generation: UInt64 = 0
    private var lastChangeCount: Int
    private var manualPause = false
    private var lockPause = false

    init(
        pasteboard: NSPasteboard = .general,
        maxItems: Int = 50,
        maxTotalBytes: Int = 64 * 1024 * 1024,
        maxImageBytes: Int = 16 * 1024 * 1024,
        maxReadBytes: Int = 64 * 1024 * 1024,
        pollInterval: TimeInterval = 0.45,
        workQueue: DispatchQueue = DispatchQueue(label: "boringNotch.clipboard.history.read"),
        persistenceDirectory: URL? = nil,
        persistenceQueue: DispatchQueue? = nil
    ) {
        self.pasteboard = pasteboard
        self.maxItems = max(1, maxItems)
        self.maxTotalBytes = max(1, maxTotalBytes)
        self.maxImageBytes = max(1, maxImageBytes)
        self.maxReadBytes = max(1, maxReadBytes)
        self.pollInterval = pollInterval
        self.workQueue = workQueue

        if let persistenceDirectory {
            self.archive = ClipboardHistoryArchive(
                directory: persistenceDirectory,
                queue: persistenceQueue,
                maxItems: max(1, maxItems),
                maxTotalBytes: max(1, maxTotalBytes),
                maxImageBytes: max(1, maxImageBytes),
                maxReadBytes: max(1, maxReadBytes)
            )
            self.persistenceStatus = .ready
        } else {
            // Tests and previews get an isolated, entirely in-memory store.
            self.archive = nil
            self.persistenceStatus = .unavailable
        }

        // Align with whatever was already on the pasteboard so app launch does
        // not import content copied before the observer existed.
        self.lastChangeCount = pasteboard.changeCount
    }

    // MARK: - Lifecycle

    func start() {
        isRunning = true
        beginRestoreIfNeeded()
        guard isRecordingEnabled, !isPaused else { return }
        lastChangeCount = pasteboard.changeCount
        startTimer()
    }

    func stop() {
        isRunning = false
        stopTimer()
        generation &+= 1
        didStop = true

        guard let archive else { return }
        if !persistenceReady {
            // The app can quit before the background restore finishes. Merge
            // the disk history with the visible new entries before the final
            // flush so neither side is lost. Once the user has explicitly
            // cleared this session, disk content must not be merged back.
            let mayMergeDiskHistory = clearEpoch == 0
            switch archive.loadSynchronously() {
            case .entries(let restored):
                if mayMergeDiskHistory { mergeRestored(restored) }
            case .partial(let restored, _):
                if mayMergeDiskHistory { mergeRestored(restored) }
            case .unreadable:
                persistenceBlocked = true
            case .empty:
                break
            }
        }
        guard !persistenceBlocked else { return }
        _ = archive.saveSynchronously(items)
    }

    func setRecordingEnabled(_ enabled: Bool) {
        guard isRecordingEnabled != enabled else { return }
        isRecordingEnabled = enabled
        generation &+= 1

        if enabled {
            lastChangeCount = pasteboard.changeCount
            if isRunning, !isPaused { startTimer() }
        } else {
            stopTimer()
        }
    }

    /// User-initiated pause/resume from the clipboard page.
    func pause() {
        guard !manualPause else { return }
        manualPause = true
        updatePausedState()
        stopTimer()
        generation &+= 1
    }

    func resume() {
        guard manualPause else { return }
        manualPause = false
        updatePausedState()
        guard !isPaused, isRecordingEnabled else { return }
        // Resume without backfilling anything copied while paused.
        lastChangeCount = pasteboard.changeCount
        generation &+= 1
        if isRunning { startTimer() }
    }

    /// Screen lock is a separate pause reason so unlocking never overrides a
    /// pause the user chose in the clipboard page.
    func pauseForScreenLock() {
        guard !lockPause else { return }
        lockPause = true
        updatePausedState()
        stopTimer()
        generation &+= 1
    }

    func resumeFromScreenLock() {
        guard lockPause else { return }
        lockPause = false
        updatePausedState()
        guard !isPaused, isRecordingEnabled else { return }
        lastChangeCount = pasteboard.changeCount
        generation &+= 1
        if isRunning { startTimer() }
    }

    private func updatePausedState() {
        let paused = manualPause || lockPause
        if isPaused != paused {
            isPaused = paused
        }
    }

    // MARK: - Restore

    /// Loads the on-disk history once. `start()` also calls this in the
    /// background; tests can await it directly.
    func restorePersistedHistory() async {
        beginRestoreIfNeeded()
        if let restoreTask {
            await restoreTask.value
        }
    }

    private func beginRestoreIfNeeded() {
        guard archive != nil, restoreState == .idle else { return }
        restoreState = .running
        restoreTask = Task { @MainActor [weak self] in
            await self?.performRestore()
        }
    }

    private func performRestore() async {
        defer {
            restoreState = .finished
            restoreTask = nil
        }

        guard let archive else { return }
        let epoch = clearEpoch
        let outcome = await archive.load()
        guard !didStop else { return }

        persistenceReady = true

        // A clear that happened while the disk was being read owns the disk
        // state now; do not merge resurrected entries.
        guard epoch == clearEpoch else { return }

        switch outcome {
        case .empty:
            break
        case .entries(let restored):
            mergeRestored(restored)
        case .partial(let restored, let message):
            mergeRestored(restored)
            setPersistenceStatus(.degraded(message))
        case .unreadable(let message):
            persistenceBlocked = true
            setPersistenceStatus(.degraded(message))
            return
        }

        if pendingSaveAfterRestore {
            pendingSaveAfterRestore = false
            scheduleSave()
        }
    }

    /// Current in-memory entries always win and stay in front. Entries the
    /// user removed during restore are not resurrected.
    private func mergeRestored(_ restored: [ClipboardHistoryEntry]) {
        guard !restored.isEmpty else { return }

        var seenFingerprints = Set(items.map(\.fingerprint))
        var seenIdentifiers = Set(items.map(\.id))
        var merged = items

        for entry in restored {
            guard !removedFingerprints.contains(entry.fingerprint) else { continue }
            if seenFingerprints.contains(entry.fingerprint) {
                if entry.isPinned, let index = merged.firstIndex(where: { $0.fingerprint == entry.fingerprint }) {
                    merged[index].isPinned = true
                }
                continue
            }
            guard !seenIdentifiers.contains(entry.id) else { continue }
            merged.append(entry)
            seenFingerprints.insert(entry.fingerprint)
            seenIdentifiers.insert(entry.id)
        }

        if merged != items {
            items = merged
            trimToLimits()
        }
    }

    private func setPersistenceStatus(_ status: ClipboardPersistenceStatus) {
        if persistenceStatus != status {
            persistenceStatus = status
        }
    }

    // MARK: - Persistence scheduling

    private func historyDidChange() {
        let epoch = persistenceGate.advance()
        guard archive != nil else { return }
        guard persistenceReady else {
            // Never write before the existing index was read: an empty or
            // partial in-memory list must not replace the old history.
            pendingSaveAfterRestore = true
            return
        }
        guard !persistenceBlocked, !didStop else { return }

        let snapshot = items
        Task { @MainActor [weak self] in
            guard let self,
                  !self.didStop,
                  self.persistenceGate.isCurrent(epoch),
                  let archive = self.archive
            else { return }

            let outcome = await archive.save(snapshot)
            guard self.persistenceGate.isCurrent(epoch) else { return }
            self.applySaveOutcome(outcome)
        }
    }

    private func scheduleSave() {
        guard archive != nil, persistenceReady, !persistenceBlocked, !didStop else {
            return
        }
        let epoch = persistenceGate.advance()
        let snapshot = items
        Task { @MainActor [weak self] in
            guard let self,
                  !self.didStop,
                  self.persistenceGate.isCurrent(epoch),
                  let archive = self.archive
            else { return }
            let outcome = await archive.save(snapshot)
            guard self.persistenceGate.isCurrent(epoch) else { return }
            self.applySaveOutcome(outcome)
        }
    }

    private func applySaveOutcome(_ outcome: ClipboardArchiveSaveOutcome) {
        if outcome.blocked {
            persistenceBlocked = true
            setPersistenceStatus(.degraded("本机历史无法读取，清空可重置"))
        } else if outcome.failed {
            setPersistenceStatus(.degraded("无法保存到本机"))
        } else if outcome.skippedFileEntries > 0 {
            setPersistenceStatus(.degraded("部分文件未能保存到本机"))
        } else {
            setPersistenceStatus(.ready)
        }
    }

    /// Produces a deterministic point for tests (and for callers that need to
    /// know the current list is on disk) without blocking the main actor.
    @discardableResult
    func flushPersistence() async -> ClipboardArchiveSaveOutcome? {
        guard let archive else { return nil }

        if !persistenceReady {
            await restorePersistedHistory()
        }
        if resetInFlight {
            await withCheckedContinuation { continuation in
                resetWaiters.append(continuation)
            }
        }
        guard persistenceReady, !persistenceBlocked else { return nil }

        let epoch = persistenceGate.current()
        let outcome = await archive.save(items)
        if persistenceGate.isCurrent(epoch) {
            applySaveOutcome(outcome)
        }
        return outcome
    }

    // MARK: - History actions

    var canManagePins: Bool { archive == nil || (persistenceReady && !persistenceBlocked && !resetInFlight) }

    func togglePin(_ entry: ClipboardHistoryEntry) {
        guard canManagePins, let index = items.firstIndex(where: { $0.id == entry.id }) else { return }
        items[index].isPinned.toggle()
        historyDidChange()
    }

    func clearUnpinned() {
        guard canManagePins else { return }
        let removed = items.filter { !$0.isPinned }
        guard !removed.isEmpty else { return }
        for entry in removed {
            removedFingerprints.insert(entry.fingerprint)
            selectedTextRanges[entry.id] = nil
        }
        items.removeAll { !$0.isPinned }
        lastChangeCount = pasteboard.changeCount
        generation &+= 1
        notice = ClipboardNotice(text: "已清理未固定项", style: .info)
        historyDidChange()
    }

    func remove(_ entry: ClipboardHistoryEntry) {
        guard items.contains(where: { $0.id == entry.id }) else { return }
        selectedTextRanges[entry.id] = nil
        items.removeAll { $0.id == entry.id }
        removedFingerprints.insert(entry.fingerprint)
        historyDidChange()
    }

    /// Clears history only. The system pasteboard and user files are untouched.
    func clear() {
        selectedTextRanges.removeAll()
        items.removeAll()
        // Mark the current pasteboard as seen so an in-flight snapshot cannot
        // resurrect the history and the next poll does not re-import it.
        lastChangeCount = pasteboard.changeCount
        generation &+= 1
        clearEpoch &+= 1
        removedFingerprints.removeAll()
        pendingSaveAfterRestore = false
        persistenceGate.advance()
        notice = ClipboardNotice(text: "已清空记录", style: .info)

        guard let archive else { return }
        resetInFlight = true
        archive.reset { [weak self] succeeded in
            Task { @MainActor [weak self] in
                self?.handleReset(succeeded)
            }
        }
    }

    private func handleReset(_ succeeded: Bool) {
        resetInFlight = false
        let waiters = resetWaiters
        resetWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        if succeeded {
            persistenceBlocked = false
            persistenceReady = true
            setPersistenceStatus(.ready)
        } else {
            setPersistenceStatus(.degraded("无法清除本机历史"))
        }
    }

    /// Security scope for file copy or async shelf reads. Returns nil for
    /// non-file entries.
    func fileAccessLease(for entry: ClipboardHistoryEntry) -> ClipboardFileAccessLease? {
        guard case .files = entry.kind else { return nil }
        let urls = entry.resolvedFileURLs
        guard !urls.isEmpty else { return nil }
        return ClipboardFileAccessLease(urls: urls)
    }

    /// Writes the entry back to the pasteboard. Returns false without touching
    /// the pasteboard when the entry can no longer be reproduced faithfully.
    @discardableResult
    func copy(_ entry: ClipboardHistoryEntry) -> Bool {
        let lease = fileAccessLease(for: entry)
        defer { lease?.release() }

        guard let plan = Self.makePasteboardPlan(for: entry) else {
            notice = ClipboardNotice(text: "复制失败：文件已移动、删除或无法访问", style: .error)
            return false
        }

        pasteboard.clearContents()
        return finishCopy(pasteboard.writeObjects(Self.pasteboardItems(for: plan)), entry: entry)
    }

    func textSelection(for entry: ClipboardHistoryEntry) -> [NSRange] {
        selectedTextRanges[entry.id] ?? []
    }

    func hasSelectedText(_ entry: ClipboardHistoryEntry) -> Bool {
        !textSelection(for: entry).isEmpty
    }

    func clearTextSelection(id: UUID) {
        if selectedTextRanges[id] != nil { selectedTextRanges[id] = nil }
    }

    func clearTextSelections() {
        if !selectedTextRanges.isEmpty { selectedTextRanges.removeAll() }
    }

    @discardableResult
    func copySelectedText(id: UUID) -> Bool {
        guard let entry = items.first(where: { $0.id == id }), hasSelectedText(entry) else { return false }
        return copyFromCard(entry)
    }

    /// Selecting alone does not change the pasteboard or history order.
    func selectText(from entry: ClipboardHistoryEntry, range: NSRange, toggles: Bool) {
        guard let text = storedText(entry), let safe = safeRange(range, in: text) else { return }
        let old = textSelection(for: entry)
        var updated = old
        if toggles, let selected = old.first(where: { NSIntersectionRange($0, safe) == safe }) {
            updated.removeAll { $0 == selected }
            if selected.location < safe.location {
                updated.append(NSRange(location: selected.location, length: safe.location - selected.location))
            }
            if NSMaxRange(selected) > NSMaxRange(safe) {
                updated.append(NSRange(location: NSMaxRange(safe), length: NSMaxRange(selected) - NSMaxRange(safe)))
            }
        } else {
            updated.append(safe)
        }
        var merged: [NSRange] = []
        for part in updated.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, NSMaxRange(last) >= part.location {
                merged[merged.count - 1] = NSUnionRange(last, part)
            } else {
                merged.append(part)
            }
        }
        if old != merged { selectedTextRanges[entry.id] = merged.isEmpty ? nil : merged }
    }

    @discardableResult
    func copyFromCard(_ entry: ClipboardHistoryEntry, whole: Bool = false) -> Bool {
        guard !whole, let value = selectedSubstring(for: entry) else { return copy(entry) }
        guard !value.isEmpty else { return false }
        pasteboard.clearContents()
        return finishCopy(pasteboard.setString(value, forType: .string), entry: entry)
    }

    private func selectedSubstring(for entry: ClipboardHistoryEntry) -> String? {
        let ranges = textSelection(for: entry)
        guard !ranges.isEmpty, let text = storedText(entry) else { return nil }
        let parts = ranges.compactMap { safeRange($0, in: text) }
        guard parts.count == ranges.count else { return nil }
        if parts.count == 1 {
            return parts[0].length == text.length ? nil : text.substring(with: parts[0])
        }
        return parts.map {
            text.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func storedText(_ entry: ClipboardHistoryEntry) -> NSString? {
        guard items.contains(where: { $0.id == entry.id && $0.fingerprint == entry.fingerprint }),
              case .text(let content) = entry.kind else { return nil }
        return content.text as NSString
    }

    private func safeRange(_ range: NSRange, in text: NSString) -> NSRange? {
        guard range.length > 0, range.location >= 0, range.location < text.length,
              range.length <= text.length - range.location else { return nil }
        return text.rangeOfComposedCharacterSequences(for: range)
    }

    private func finishCopy(_ succeeded: Bool, entry: ClipboardHistoryEntry) -> Bool {
        // Own writes must not loop back into the history.
        lastChangeCount = pasteboard.changeCount
        generation &+= 1
        if succeeded { markUsed(entry) }
        notice = succeeded
            ? ClipboardNotice(text: "已复制", style: .info)
            : ClipboardNotice(text: "复制失败：无法写入剪贴板", style: .error)
        return succeeded
    }

    func markUsed(_ entry: ClipboardHistoryEntry) {
        guard let index = items.firstIndex(where: { $0.id == entry.id }) else { return }
        var reordered = items
        var used = reordered.remove(at: index)
        used.capturedAt = Date()
        reordered.insert(used, at: 0)
        items = reordered
        historyDidChange()
    }

    /// AppKit writes these objects to the drag pasteboard. Each file has its
    /// own writer so the receiving app can read the entire group.
    func dragPayload(for entry: ClipboardHistoryEntry, whole: Bool) -> (items: [NSPasteboardItem], lease: ClipboardFileAccessLease?)? {
        if !whole, let text = selectedSubstring(for: entry) {
            guard !text.isEmpty else { return nil }
            let item = NSPasteboardItem()
            guard item.setString(text, forType: .string) else { return nil }
            return ([item], nil)
        }
        let lease = fileAccessLease(for: entry)
        guard let plan = Self.makePasteboardPlan(for: entry) else { return nil }
        return (Self.pasteboardItems(for: plan), lease)
    }

    /// Providers for the existing shelf drop pipeline. Files are supplied one
    /// provider per URL, text as NSString, and images as PNG data with a name.
    func itemProviders(for entry: ClipboardHistoryEntry) -> [NSItemProvider] {
        switch entry.kind {
        case .text(let content):
            let provider = NSItemProvider(object: content.text as NSString)
            provider.suggestedName = "剪贴板文字.txt"
            return [provider]

        case .image(let content):
            let provider = NSItemProvider()
            provider.suggestedName = "剪贴板图片.png"
            let pngData = content.pngData
            provider.registerDataRepresentation(
                forTypeIdentifier: "public.png",
                visibility: .all
            ) { completion in
                completion(pngData, nil)
                return nil
            }
            provider.registerDataRepresentation(
                forTypeIdentifier: "public.data",
                visibility: .all
            ) { completion in
                completion(pngData, nil)
                return nil
            }
            return [provider]

        case .files:
            // An unresolved bookmark must not turn into a partial or fake
            // group in the shelf.
            guard entry.hasCompleteFileGroup else { return [] }
            let urls = entry.resolvedFileURLs
            guard !urls.isEmpty else { return [] }
            return urls.map { NSItemProvider(object: $0 as NSURL) }
        }
    }

    func report(_ text: String, isError: Bool = false) {
        notice = ClipboardNotice(text: text, style: isError ? .error : .info)
    }

    /// Auto-expires informational status text. Errors stay until the next
    /// action so a failed copy or an ignored oversize item is not missed.
    func dismissInfoNotice(after seconds: TimeInterval) async {
        guard let notice, notice.style == .info else { return }
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled, self.notice?.id == notice.id else { return }
        self.notice = nil
    }

    // MARK: - Polling

    /// Production timer entry point. Exposed so tests can drive the same path
    /// deterministically without starting a timer.
    func checkForChanges() {
        guard isRecordingEnabled, !isPaused, !isReading else { return }

        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else { return }

        isReading = true
        let generationAtStart = generation
        let pasteboardBox = ClipboardPasteboardBox(self.pasteboard)
        let limits = ClipboardLimits(
            maxItems: maxItems,
            maxTotalBytes: maxTotalBytes,
            maxImageBytes: maxImageBytes,
            maxReadBytes: maxReadBytes
        )

        workQueue.async { [weak self] in
            let snapshot = Self.readSnapshot(
                from: pasteboardBox.pasteboard,
                expectedChangeCount: currentChangeCount,
                limits: limits
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isReading = false

                // pause/clear/copy/stop all bump the generation and invalidate
                // an in-flight read. Do not align the change count either.
                guard self.generation == generationAtStart,
                      self.isRecordingEnabled,
                      !self.isPaused,
                      let snapshot
                else { return }

                self.lastChangeCount = currentChangeCount
                self.publish(snapshot)
            }
        }
    }

    private func publish(_ snapshot: ClipboardSnapshot) {
        switch snapshot {
        case .ignored, .empty:
            return
        case .tooLarge:
            notice = ClipboardNotice(text: "内容较大，未记录", style: .info)
        case .content(let content):
            insert(content.kind, fileReferences: content.fileReferences)
        }
    }

    private func insert(
        _ kind: ClipboardHistoryEntry.Kind,
        fileReferences: [ClipboardFileReference]? = nil
    ) {
        let fingerprint = Self.fingerprint(for: kind, fileReferences: fileReferences)
        let byteCount = Self.approximateByteCount(for: kind)
        let now = Date()

        guard byteCount <= maxTotalBytes else {
            notice = ClipboardNotice(text: "内容较大，未记录", style: .info)
            return
        }

        let existingIndex = items.firstIndex { $0.fingerprint == fingerprint }
        let otherPins = items.filter { $0.isPinned && $0.fingerprint != fingerprint }
        let pinnedBytes = otherPins.reduce(0) { $0 + $1.byteCount }
        guard otherPins.count < maxItems, byteCount <= maxTotalBytes - pinnedBytes else {
            notice = ClipboardNotice(text: "固定项已占用可用空间", style: .info)
            return
        }

        if let index = existingIndex {
            var existing = items.remove(at: index)
            existing.kind = kind
            existing.fileReferences = fileReferences
            existing.capturedAt = now
            existing.byteCount = byteCount
            items.insert(existing, at: 0)
        } else {
            let entry = ClipboardHistoryEntry(
                id: UUID(),
                fingerprint: fingerprint,
                kind: kind,
                capturedAt: now,
                byteCount: byteCount,
                fileReferences: fileReferences
            )
            items.insert(entry, at: 0)
        }

        removedFingerprints.remove(fingerprint)
        trimToLimits()
        historyDidChange()
    }

    private func trimToLimits() {
        while items.count > maxItems {
            items.remove(at: items.lastIndex(where: { !$0.isPinned }) ?? items.index(before: items.endIndex))
        }

        var total = items.reduce(0) { $0 + $1.byteCount }
        while total > maxTotalBytes && !items.isEmpty {
            let index = items.lastIndex(where: { !$0.isPinned }) ?? items.index(before: items.endIndex)
            total -= items.remove(at: index).byteCount
        }
        let retained = Set(items.map(\.id))
        selectedTextRanges = selectedTextRanges.filter { retained.contains($0.key) }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkForChanges()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Snapshot reading (serial work queue)

    nonisolated private static func readSnapshot(
        from pasteboard: NSPasteboard,
        expectedChangeCount: Int,
        limits: ClipboardLimits
    ) -> ClipboardSnapshot? {
        let before = pasteboard.changeCount
        guard before == expectedChangeCount else { return nil }

        let pasteboardTypes = Set(pasteboard.types ?? [])
        if !pasteboardTypes.isDisjoint(with: clipboardIgnoredPasteboardTypes) {
            return pasteboard.changeCount == before ? .ignored : nil
        }

        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else {
            return pasteboard.changeCount == before ? .empty : nil
        }

        // File groups win over any image or text that travelled with them.
        var fileURLs: [URL] = []
        for item in pasteboardItems {
            let types = Set(item.types)
            guard types.isDisjoint(with: clipboardIgnoredPasteboardTypes) else { continue }
            guard types.contains(.fileURL),
                  let rawValue = item.string(forType: .fileURL),
                  let url = parseFileURL(rawValue)
            else { continue }
            fileURLs.append(url)
        }

        if !fileURLs.isEmpty {
            guard pasteboard.changeCount == before else { return nil }
            let references = fileURLs.map { makeFileReference(for: $0) }
            return .content(ClipboardSnapshotContent(
                kind: .files(fileURLs),
                fileReferences: references
            ))
        }

        // Images, in the same priority order used by Maccy.
        for type in clipboardImageTypesInPriorityOrder {
            for item in pasteboardItems {
                let types = Set(item.types)
                guard types.isDisjoint(with: clipboardIgnoredPasteboardTypes) else { continue }
                guard types.contains(type), let data = item.data(forType: type) else { continue }

                guard data.count <= limits.maxReadBytes else { return .tooLarge }
                switch normalizedImage(data: data, sourceType: type, limits: limits) {
                case .content(let image):
                    guard pasteboard.changeCount == before else { return nil }
                    return .content(ClipboardSnapshotContent(
                        kind: .image(image),
                        fileReferences: nil
                    ))
                case .tooLarge:
                    return .tooLarge
                case .unsupported:
                    continue
                }
            }
        }

        // Text: string > RTF (extracted, never rendered from HTML) > URL.
        for item in pasteboardItems {
            let types = Set(item.types)
            guard types.isDisjoint(with: clipboardIgnoredPasteboardTypes) else { continue }

            let rtf = item.data(forType: .rtf)
            let html = item.data(forType: .html)
            let plain = item.string(forType: .string)
            let urlString = item.string(forType: .URL)

            var text = plain
            if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               let rtf,
               let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil),
               !attributed.string.isEmpty
            {
                text = attributed.string
            }
            if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                text = urlString
            }

            guard let finalText = text,
                  !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }

            guard finalText.utf8.count <= limits.maxReadBytes else { return .tooLarge }

            // RTF/HTML are kept only as optional write-back formats. HTML is
            // never imported into an attributed string here.
            let rtfData = (rtf?.count ?? 0) <= limits.maxReadBytes ? rtf : nil
            let htmlData = (html?.count ?? 0) <= limits.maxReadBytes ? html : nil
            let url = urlString.flatMap { URL(string: $0) }
            let content = ClipboardTextContent(text: finalText, rtf: rtfData, html: htmlData, url: url)

            let cost = approximateByteCount(for: .text(content))
            guard cost <= limits.maxTotalBytes else { return .tooLarge }
            guard pasteboard.changeCount == before else { return nil }
            return .content(ClipboardSnapshotContent(kind: .text(content), fileReferences: nil))
        }

        return pasteboard.changeCount == before ? .empty : nil
    }

    nonisolated private static func parseFileURL(_ rawValue: String) -> URL? {
        if let url = URL(string: rawValue), url.isFileURL {
            return url
        }
        if rawValue.hasPrefix("/") {
            return URL(fileURLWithPath: rawValue)
        }
        return nil
    }

    /// Creates a sandbox-resolvable reference while the pasteboard read is
    /// already on the serial background queue. The security-scoped form is
    /// preferred; the plain form only keeps unsandboxed tests working.
    nonisolated private static func makeFileReference(for url: URL) -> ClipboardFileReference {
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
            return ClipboardFileReference(
                displayName: url.lastPathComponent,
                bookmarkData: bookmark,
                isSecurityScoped: true,
                resolvedURL: url
            )
        }

        // Plain bookmarks do not carry a sandbox extension. Keep the entry
        // usable in this session, but let persistence report it as unsaved
        // instead of promising a restart-safe reference.
        let plain: Data? = clipboardRunsInsideAppSandbox
            ? nil
            : (try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ))
        return ClipboardFileReference(
            displayName: url.lastPathComponent,
            bookmarkData: plain,
            isSecurityScoped: false,
            resolvedURL: url
        )
    }

    // MARK: - Image normalization

    nonisolated private static func normalizedImage(
        data: Data,
        sourceType: NSPasteboard.PasteboardType,
        limits: ClipboardLimits
    ) -> ClipboardImageReadResult {
        if sourceType == .png {
            // PNG is already the write-back format. Reuse it verbatim when it
            // fits; only ImageIO reads it to build the small thumbnail.
            guard data.count <= limits.maxImageBytes else { return .tooLarge }
            let size = pixelSize(of: data)
            guard size.width > 0, size.height > 0 else { return .unsupported }
            let thumbnail = pngThumbnail(from: data)
            return .content(ClipboardImageContent(
                pngData: data,
                thumbnailData: thumbnail,
                pixelWidth: size.width,
                pixelHeight: size.height
            ))
        }

        // TIFF/JPEG/HEIC are decoded and re-encoded as PNG off the main thread.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return .unsupported }

        // Decoded pixels are much larger than encoded bytes. Reject images that
        // would need an unreasonable bitmap before asking ImageIO to decode one.
        guard Double(width) * Double(height) <= 32_000_000 else { return .tooLarge }

        guard let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) else { return .unsupported }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            "public.png" as CFString,
            1,
            nil
        ) else { return .unsupported }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return .unsupported }
        guard output.length <= limits.maxImageBytes else { return .tooLarge }

        let pngData = output as Data
        return .content(ClipboardImageContent(
            pngData: pngData,
            thumbnailData: pngThumbnail(from: pngData),
            pixelWidth: image.width,
            pixelHeight: image.height
        ))
    }

    nonisolated private static func pixelSize(of data: Data) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return (0, 0) }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (width, height)
    }

    nonisolated private static func pngThumbnail(from data: Data, maxPixelSize: Int = 192) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

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

    // MARK: - Fingerprint / budget

    nonisolated static func fingerprint(
        for kind: ClipboardHistoryEntry.Kind,
        fileReferences: [ClipboardFileReference]? = nil
    ) -> String {
        var hasher = SHA256()

        func append(_ tag: UInt8, _ data: Data) {
            hasher.update(data: Data([tag]))
            var length = UInt64(data.count).bigEndian
            let lengthData = withUnsafeBytes(of: &length) { Data($0) }
            hasher.update(data: lengthData)
            hasher.update(data: data)
        }

        switch kind {
        case .text(let content):
            append(1, Data(content.text.utf8))
        case .image(let content):
            append(2, content.pngData)
        case .files(let urls):
            if let fileReferences, !fileReferences.isEmpty {
                append(3, Data("count:\(fileReferences.count)".utf8))
                for reference in fileReferences {
                    if let resolved = reference.resolvedURL {
                        append(4, Data(resolved.standardizedFileURL.path.utf8))
                    } else if let bookmark = reference.bookmarkData {
                        append(5, bookmark)
                    } else {
                        append(6, Data(reference.displayName.utf8))
                    }
                }
            } else {
                append(3, Data("count:\(urls.count)".utf8))
                for url in urls {
                    append(4, Data(url.standardizedFileURL.path.utf8))
                }
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func approximateByteCount(for kind: ClipboardHistoryEntry.Kind) -> Int {
        switch kind {
        case .text(let content):
            return content.text.utf8.count
                + (content.rtf?.count ?? 0)
                + (content.html?.count ?? 0)
                + 128
        case .image(let content):
            return content.pngData.count + (content.thumbnailData?.count ?? 0) + 128
        case .files(let urls):
            return urls.reduce(128) { $0 + $1.path.utf8.count }
        }
    }

    // MARK: - Write-back plans

    private enum PasteboardPlan {
        case text(ClipboardTextContent)
        case image(Data)
        case files([URL])
    }

    private static func makePasteboardPlan(for entry: ClipboardHistoryEntry) -> PasteboardPlan? {
        switch entry.kind {
        case .text(let content):
            return .text(content)
        case .image(let content):
            guard !content.pngData.isEmpty else { return nil }
            return .image(content.pngData)
        case .files:
            // Every bookmark in the group must have resolved and every source
            // file must still be present and readable. A partial group must
            // never masquerade as a successful copy.
            guard entry.hasCompleteFileGroup else { return nil }
            let urls = entry.resolvedFileURLs
            guard !urls.isEmpty else { return nil }
            let fileManager = FileManager.default
            guard urls.allSatisfy({
                $0.isFileURL
                    && fileManager.fileExists(atPath: $0.path)
                    && fileManager.isReadableFile(atPath: $0.path)
            }) else {
                return nil
            }
            return .files(urls)
        }
    }

    private static func pasteboardItems(for plan: PasteboardPlan) -> [NSPasteboardItem] {
        switch plan {
        case .text(let content):
            let item = NSPasteboardItem()
            item.setString(content.text, forType: .string)
            if let rtf = content.rtf {
                item.setData(rtf, forType: .rtf)
            }
            if let html = content.html {
                item.setData(html, forType: .html)
            }
            if let url = content.url, content.text == url.absoluteString {
                item.setString(url.absoluteString, forType: .URL)
            }
            return [item]

        case .image(let pngData):
            let item = NSPasteboardItem()
            item.setData(pngData, forType: .png)
            return [item]

        case .files(let urls):
            return urls.map { url -> NSPasteboardItem in
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                return item
            }
        }
    }
}
