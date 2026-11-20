#!/usr/bin/env python3
"""Exercise production clipboard persistence against private pasteboards.

The real ClipboardHistoryStore and ClipboardHistoryArchive sources are
compiled with swiftc. Every pasteboard is a unique private NSPasteboard and
every byte of content is generated under the process temporary directory.

Exit codes:
  0  all checks passed
  1  a production assertion failed
  2  the environment or sources are missing
"""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
STORE_SOURCE = ROOT / "boringNotch/components/Clipboard/ClipboardHistoryStore.swift"
ARCHIVE_SOURCE = ROOT / "boringNotch/components/Clipboard/ClipboardHistoryArchive.swift"

SWIFT_TEST = r'''
import AppKit
import Dispatch
import Foundation
import ImageIO

var failures: [String] = []

func check(_ condition: Bool, _ name: String) {
    print((condition ? "PASS " : "FAIL ") + name)
    if !condition { failures.append(name) }
}

@MainActor
func waitUntil(
    _ name: String,
    timeout: TimeInterval = 3,
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    let result = condition()
    check(result, name)
    return result
}

func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("boringnotch.clipboard.persist.\(UUID().uuidString)"))
}

func writeString(_ text: String, to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

func makeRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("boringnotch-clipboard-persist-\(UUID().uuidString)", isDirectory: true)
}

@MainActor
func makeStore(
    directory: URL,
    maxItems: Int = 50,
    queue: DispatchQueue? = nil,
    pasteboard: NSPasteboard = makePasteboard()
) -> ClipboardHistoryStore {
    ClipboardHistoryStore(
        pasteboard: pasteboard,
        maxItems: maxItems,
        persistenceDirectory: directory,
        persistenceQueue: queue
    )
}

func makeImage(width: Int, height: Int) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.2, green: 0.55, blue: 0.85, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

func encode(_ image: CGImage, as type: String) -> Data {
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        output as CFMutableData,
        type as CFString,
        1,
        nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    return output as Data
}

func imageSize(_ data: Data) -> (Int, Int) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return (0, 0) }
    return (image.width, image.height)
}

func textContent(of entry: ClipboardHistoryEntry?) -> ClipboardTextContent? {
    guard let entry, case .text(let content) = entry.kind else { return nil }
    return content
}

func imageContent(of entry: ClipboardHistoryEntry?) -> ClipboardImageContent? {
    guard let entry, case .image(let content) = entry.kind else { return nil }
    return content
}

func files(of entry: ClipboardHistoryEntry?) -> [URL]? {
    guard let entry, case .files(let urls) = entry.kind else { return nil }
    return urls
}

func blobNames(in directory: URL) -> [String] {
    let assets = directory.appendingPathComponent("assets", isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: assets.path)) ?? []
    return names.filter { $0.hasSuffix(".blob") }.sorted()
}

func posixPermissions(_ url: URL) -> Int? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let number = attributes[.posixPermissions] as? NSNumber
    else { return nil }
    return number.intValue
}

@MainActor
func captureText(
    _ text: String,
    store: ClipboardHistoryStore,
    pasteboard: NSPasteboard,
    name: String
) async -> Bool {
    writeString(text, to: pasteboard)
    store.checkForChanges()
    return await waitUntil(name) {
        textContent(of: store.items.first)?.text == text
    }
}

@MainActor
func captureImage(
    _ png: Data,
    store: ClipboardHistoryStore,
    pasteboard: NSPasteboard,
    name: String
) async -> Bool {
    pasteboard.clearContents()
    pasteboard.setData(png, forType: .png)
    store.checkForChanges()
    return await waitUntil(name) {
        imageContent(of: store.items.first)?.pngData == png
    }
}

@MainActor
func captureFiles(
    _ urls: [URL],
    store: ClipboardHistoryStore,
    pasteboard: NSPasteboard,
    name: String
) async -> Bool {
    pasteboard.clearContents()
    let items = urls.map { url -> NSPasteboardItem in
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        return item
    }
    _ = pasteboard.writeObjects(items)
    store.checkForChanges()
    return await waitUntil(name) {
        files(of: store.items.first)?.map(\.lastPathComponent) == urls.map(\.lastPathComponent)
    }
}

@MainActor
func restoredStore(
    directory: URL,
    maxItems: Int = 50,
    queue: DispatchQueue? = nil,
    pasteboard: NSPasteboard = makePasteboard()
) async -> ClipboardHistoryStore {
    let store = makeStore(
        directory: directory,
        maxItems: maxItems,
        queue: queue,
        pasteboard: pasteboard
    )
    await store.restorePersistedHistory()
    return store
}

@main
struct ClipboardPersistenceTests {
    @MainActor
    static func main() async {
        let root = makeRoot()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // MARK: Text + RTF survives a full store rebuild
        do {
            let directory = root.appendingPathComponent("text", isDirectory: true)
            let pasteboard = makePasteboard()
            let store = makeStore(directory: directory, pasteboard: pasteboard)
            let original = String(repeating: "完整正文一二三四五 ", count: 120) + "END"
            let attributed = NSAttributedString(
                string: original,
                attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
            )
            let rtf = try? attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            let item = NSPasteboardItem()
            item.setString(original, forType: .string)
            if let rtf { item.setData(rtf, forType: .rtf) }
            pasteboard.clearContents()
            _ = pasteboard.writeObjects([item])
            store.checkForChanges()
            let captured = await waitUntil("persist text: captured") {
                textContent(of: store.items.first)?.text == original
            }
            if captured {
                check(textContent(of: store.items[0])?.rtf != nil, "persist text: RTF captured")
            }

            let flushed = await store.flushPersistence()
            check(flushed?.savedCount == 1, "persist text: flushed one entry")
            check(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("index.json").path
                ),
                "persist text: index written"
            )
            check(posixPermissions(directory) == 0o700, "persist text: directory is 0700")
            check(
                posixPermissions(directory.appendingPathComponent("index.json")) == 0o600,
                "persist text: index is 0600"
            )

            let target = makePasteboard()
            let rebuilt = await restoredStore(directory: directory, pasteboard: target)
            check(rebuilt.items.count == 1, "persist text: one entry restored")
            if let content = textContent(of: rebuilt.items.first) {
                check(content.text == original, "persist text: full body restored exactly")
                check(content.text.utf8.count > 420, "persist text: body is longer than a preview")
                check(content.rtf == textContent(of: store.items.first)?.rtf,
                      "persist text: RTF restored")
                let succeeded = rebuilt.copy(rebuilt.items[0])
                check(succeeded, "persist text: restored entry copies")
                check(target.string(forType: .string) == original,
                      "persist text: restored copy writes the exact body")
            }
        }

        // MARK: Reusing an old entry updates recency without duplicating it
        do {
            let directory = root.appendingPathComponent("recency", isDirectory: true)
            let pasteboard = makePasteboard()
            let store = await restoredStore(directory: directory, pasteboard: pasteboard)
            let a = await captureText("earlier", store: store, pasteboard: pasteboard, name: "recency: first item")
            let earlier = store.items.first
            let b = await captureText("later", store: store, pasteboard: pasteboard, name: "recency: second item")
            if a, b, let earlier {
                check(store.copyFromCard(earlier) && pasteboard.string(forType: .string) == "earlier",
                      "selection: unselected card copies full text")
                let before = pasteboard.changeCount
                let oldOrder = store.items.map(\.id)
                let ear = NSRange(location: 0, length: 3)
                let er = NSRange(location: 5, length: 2)
                store.selectText(from: earlier, range: ear, toggles: true)
                store.selectText(from: earlier, range: er, toggles: true)
                check(pasteboard.changeCount == before && store.items.map(\.id) == oldOrder,
                      "selection: preview never writes to clipboard or changes recency")
                check(store.hasSelectedText(earlier), "selection: collapsed card remembers selection")
                let selectedDrag = store.dragPayload(for: earlier, whole: false)
                let wholeDrag = store.dragPayload(for: earlier, whole: true)
                check(selectedDrag?.items.first?.string(forType: .string) == "ear er" &&
                      wholeDrag?.items.first?.string(forType: .string) == "earlier",
                      "drag: selected text and full-item override")
                check(pasteboard.changeCount == before && store.items.map(\.id) == oldOrder,
                      "drag: preparing or cancelling does not write to clipboard or reorder")
                if let later = store.items.last {
                    store.markUsed(later)
                    check(store.items.first?.id == later.id && pasteboard.changeCount == before,
                          "drag: successful drop updates recency without changing the clipboard")
                }
                check(store.copyFromCard(earlier) && pasteboard.string(forType: .string) == "ear er",
                      "selection: collapsed card copies disjoint words in reading order")
                store.selectText(from: earlier, range: er, toggles: true)
                check(store.copyFromCard(earlier) && pasteboard.string(forType: .string) == "ear",
                      "selection: a second click deselects a word")
                let beforeCancel = pasteboard.changeCount
                store.clearTextSelections()
                check(!store.copySelectedText(id: earlier.id) && pasteboard.changeCount == beforeCancel,
                      "selection: blank-space cancel cannot overwrite the clipboard on exit")
                store.selectText(from: earlier, range: er, toggles: true)
                check(store.copySelectedText(id: earlier.id) && pasteboard.string(forType: .string) == "er",
                      "selection: exit commits the exact pending text")
                check(store.copyFromCard(earlier, whole: true) && pasteboard.string(forType: .string) == "earlier",
                      "selection: whole-copy override leaves the original intact")
                store.checkForChanges()
                check(store.items.count == 2 && store.items.first?.id == earlier.id,
                      "recency: move to front without duplicate")
                check((store.items.first?.capturedAt ?? .distantPast) >= earlier.capturedAt,
                      "recency: copy refreshes last-use timestamp")
                _ = await store.flushPersistence()
                let next = await restoredStore(directory: directory, pasteboard: makePasteboard())
                check(next.items.map(\.id) == store.items.map(\.id), "recency: order survives restart")
            }
        }

        // MARK: PNG (and thumbnail) survives a rebuild
        do {
            let directory = root.appendingPathComponent("image", isDirectory: true)
            let pasteboard = makePasteboard()
            let store = makeStore(directory: directory, pasteboard: pasteboard)
            let png = encode(makeImage(width: 96, height: 48), as: "public.png")
            let captured = await captureImage(
                png,
                store: store,
                pasteboard: pasteboard,
                name: "persist png: captured"
            )
            if captured {
                check(imageContent(of: store.items.first)?.thumbnailData != nil,
                      "persist png: thumbnail generated")
            }
            _ = await store.flushPersistence()

            let target = makePasteboard()
            let rebuilt = await restoredStore(directory: directory, pasteboard: target)
            check(rebuilt.items.count == 1, "persist png: one entry restored")
            if let content = imageContent(of: rebuilt.items.first) {
                check(content.pixelWidth == 96 && content.pixelHeight == 48,
                      "persist png: dimensions restored")
                check(imageSize(content.pngData) == (96, 48),
                      "persist png: PNG payload decodes at original size")
                check(content.thumbnailData != nil, "persist png: thumbnail restored")
                let payload = rebuilt.dragPayload(for: rebuilt.items[0], whole: false)
                check(payload?.items.count == 1 && payload?.items.first?.data(forType: .png) == content.pngData,
                      "drag: image writer contains original PNG")
                check(rebuilt.copy(rebuilt.items[0]), "persist png: restored entry copies")
                check(imageSize(target.data(forType: .png) ?? Data()) == (96, 48),
                      "persist png: restored copy decodes at original size")
            } else {
                check(false, "persist png: restored kind is image")
            }
        }

        // MARK: Multi-file group keeps order, references only, and copies
        do {
            let directory = root.appendingPathComponent("files", isDirectory: true)
            let sources = root.appendingPathComponent("file-sources", isDirectory: true)
            try? FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            let first = sources.appendingPathComponent("first.txt")
            let second = sources.appendingPathComponent("second.txt")
            try? "first-content".write(to: first, atomically: true, encoding: .utf8)
            try? "second-content".write(to: second, atomically: true, encoding: .utf8)

            let sourceListing = (try? FileManager.default.contentsOfDirectory(atPath: sources.path)) ?? []
            let originalFirst = try? Data(contentsOf: first)
            let originalSecond = try? Data(contentsOf: second)

            let pasteboard = makePasteboard()
            let store = makeStore(directory: directory, pasteboard: pasteboard)
            let captured = await captureFiles(
                [first, second],
                store: store,
                pasteboard: pasteboard,
                name: "persist files: group captured"
            )
            if captured {
                check(files(of: store.items.first)?.map(\.lastPathComponent)
                        == ["first.txt", "second.txt"],
                      "persist files: order captured")
                check(store.items.first?.fileReferences?.count == 2,
                      "persist files: bookmarks created")
            }
            _ = await store.flushPersistence()
            check(blobNames(in: directory).isEmpty,
                  "persist files: no file contents copied into history")

            let target = makePasteboard()
            let rebuilt = await restoredStore(directory: directory, pasteboard: target)
            check(rebuilt.items.count == 1, "persist files: group restored")
            if let entry = rebuilt.items.first {
                check(files(of: entry)?.map(\.lastPathComponent)
                        == ["first.txt", "second.txt"],
                      "persist files: order restored")
                check(entry.hasCompleteFileGroup, "persist files: every bookmark resolved")
                check(rebuilt.itemProviders(for: entry).count == 2,
                      "persist files: shelf providers for the whole group")
                check(rebuilt.fileAccessLease(for: entry) != nil,
                      "persist files: security-scope lease available")
                let lease = rebuilt.fileAccessLease(for: entry)
                lease?.release()

                let payload = rebuilt.dragPayload(for: entry, whole: false)
                let dragFiles = payload?.items.compactMap { item in
                    item.string(forType: .fileURL).flatMap { URL(string: $0)?.lastPathComponent }
                }
                check(dragFiles == ["first.txt", "second.txt"] && payload?.lease != nil,
                      "drag: all files keep their order and scope for the session")
                payload?.lease?.release()
                check(rebuilt.copy(entry), "persist files: restored group copies")
                let pasted = (target.pasteboardItems ?? []).compactMap { item -> String? in
                    guard let raw = item.string(forType: .fileURL),
                          let url = URL(string: raw)
                    else { return nil }
                    return url.lastPathComponent
                }
                check(pasted == ["first.txt", "second.txt"],
                      "persist files: pasteboard order preserved")
            }

            check(
                ((try? FileManager.default.contentsOfDirectory(atPath: sources.path)) ?? []) == sourceListing,
                "persist files: source directory count unchanged"
            )
            check((try? Data(contentsOf: first)) == originalFirst,
                  "persist files: first source content unchanged")
            check((try? Data(contentsOf: second)) == originalSecond,
                  "persist files: second source content unchanged")
        }

        // MARK: Pins survive history trimming, duplicate captures and a restart
        do {
            let directory = root.appendingPathComponent("pins", isDirectory: true)
            let pasteboard = makePasteboard()
            let store = await restoredStore(directory: directory, maxItems: 3, pasteboard: pasteboard)
            _ = await captureText("kept", store: store, pasteboard: pasteboard, name: "pins: initial capture")
            if let entry = store.items.first { store.togglePin(entry) }
            for text in ["first", "second", "third"] {
                _ = await captureText(text, store: store, pasteboard: pasteboard, name: "pins: capture \(text)")
            }
            check(store.items.map(\.title) == ["third", "second", "kept"], "pins: trimming evicts the oldest unpinned item")
            _ = await captureText("kept", store: store, pasteboard: pasteboard, name: "pins: duplicate capture")
            check(store.items.first?.isPinned == true, "pins: duplicate stays pinned and moves to the front")
            _ = await store.flushPersistence()

            let rebuilt = await restoredStore(directory: directory, maxItems: 3, pasteboard: pasteboard)
            check(rebuilt.items.map(\.isPinned) == [true, false, false], "pins: old-style entries and pins decode together")
            let changeCount = pasteboard.changeCount
            rebuilt.clearUnpinned()
            _ = await rebuilt.flushPersistence()
            check(pasteboard.changeCount == changeCount, "pins: clearing unpinned leaves the pasteboard alone")
            let cleared = await restoredStore(directory: directory, maxItems: 3)
            check(cleared.items.map(\.title) == ["kept"], "pins: clearing unpinned persists")
            if let entry = cleared.items.first { cleared.togglePin(entry) }
            _ = await cleared.flushPersistence()
            let unpinned = await restoredStore(directory: directory, maxItems: 3)
            check(unpinned.items.first?.isPinned == false, "pins: unpinning survives restart")
        }

        // MARK: Clear removes disk history but never the system/private board
        do {
            let directory = root.appendingPathComponent("clear", isDirectory: true)
            let pasteboard = makePasteboard()
            let store = makeStore(directory: directory, pasteboard: pasteboard)
            _ = await captureText("clear-text", store: store, pasteboard: pasteboard,
                                  name: "persist clear: text captured")
            _ = await store.flushPersistence()

            let boardChangeCount = pasteboard.changeCount
            let boardText = pasteboard.string(forType: .string)
            store.clear()
            let outcome = await store.flushPersistence()
            check(store.items.isEmpty, "persist clear: memory emptied")
            check(outcome?.savedCount == 0, "persist clear: empty index saved")
            check(blobNames(in: directory).isEmpty, "persist clear: assets removed")
            check(pasteboard.changeCount == boardChangeCount,
                  "persist clear: private pasteboard not cleared")
            check(pasteboard.string(forType: .string) == boardText,
                  "persist clear: pasteboard content preserved")

            let rebuilt = await restoredStore(directory: directory)
            check(rebuilt.items.isEmpty, "persist clear: rebuild stays empty")
        }

        // MARK: Removing one entry keeps the other entry's assets
        do {
            let directory = root.appendingPathComponent("remove", isDirectory: true)
            let pasteboard = makePasteboard()
            let store = makeStore(directory: directory, pasteboard: pasteboard)
            _ = await captureText("remove-me-unique", store: store, pasteboard: pasteboard,
                                  name: "persist remove: text captured")
            let png = encode(makeImage(width: 40, height: 24), as: "public.png")
            _ = await captureImage(png, store: store, pasteboard: pasteboard,
                                   name: "persist remove: image captured")
            _ = await store.flushPersistence()
            let before = blobNames(in: directory)
            check(before.count >= 3, "persist remove: text and image assets written")

            guard let textEntry = store.items.first(where: {
                textContent(of: $0)?.text == "remove-me-unique"
            }) else {
                check(false, "persist remove: text entry present")
                return finish()
            }
            store.remove(textEntry)
            _ = await store.flushPersistence()
            let after = blobNames(in: directory)
            check(after.count < before.count, "persist remove: orphaned text asset pruned")

            let rebuilt = await restoredStore(directory: directory)
            check(rebuilt.items.count == 1, "persist remove: one entry remains")
            if let content = imageContent(of: rebuilt.items.first) {
                check(imageSize(content.pngData) == (40, 24),
                      "persist remove: remaining image intact")
            } else {
                check(false, "persist remove: remaining entry is the image")
            }
        }

        // An IO failure while clearing must not report successful deletion.
        do {
            let directory = root.appendingPathComponent("failed-reset", isDirectory: true)
            let pasteboard = makePasteboard()
            let store = makeStore(directory: directory, pasteboard: pasteboard)
            _ = await captureText("preserve-on-failed-clear", store: store,
                                  pasteboard: pasteboard, name: "persist reset failure: captured")
            _ = await store.flushPersistence()
            store.stop()
            let archive = ClipboardHistoryArchive(directory: directory)
            _ = await archive.load()
            let index = directory.appendingPathComponent("index.json")
            let before = try? Data(contentsOf: index)
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                                      ofItemAtPath: directory.path)
                defer {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                          ofItemAtPath: directory.path)
                }
                let reset: Bool = await withCheckedContinuation { continuation in
                    archive.reset { continuation.resume(returning: $0) }
                }
                check(!reset, "persist reset failure: deletion failure is reported")
                check((try? Data(contentsOf: index)) == before,
                      "persist reset failure: locked index was not falsely cleared")
            } catch {
                check(false, "persist reset failure: could not prepare isolated IO fixture")
            }
        }

        // MARK: Entry limit is enforced on disk and after restore
        do {
            let directory = root.appendingPathComponent("limit", isDirectory: true)
            let pasteboard = makePasteboard()
            let store = makeStore(directory: directory, maxItems: 2, pasteboard: pasteboard)
            for text in ["one", "two", "three"] {
                _ = await captureText(text, store: store, pasteboard: pasteboard,
                                      name: "persist limit: captured \(text)")
            }
            _ = await store.flushPersistence()
            let rebuilt = await restoredStore(directory: directory, maxItems: 2)
            check(rebuilt.items.count == 2, "persist limit: count capped on restore")
            check(rebuilt.items.compactMap { textContent(of: $0)?.text } == ["three", "two"],
                  "persist limit: newest two restored in order")
        }

        // MARK: Bad/illegal asset names degrade safely and never escape
        do {
            let directory = root.appendingPathComponent("bad-index", isDirectory: true)
            let pasteboard = makePasteboard()
            let store = makeStore(directory: directory, pasteboard: pasteboard)
            _ = await captureText("valid-survivor", store: store, pasteboard: pasteboard,
                                  name: "persist bad: valid text captured")
            _ = await store.flushPersistence()

            let sentinel = root.appendingPathComponent("outside-sentinel.blob")
            try? "outside-data".write(to: sentinel, atomically: true, encoding: .utf8)

            let indexURL = directory.appendingPathComponent("index.json")
            guard let data = try? Data(contentsOf: indexURL),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var entries = object["entries"] as? [[String: Any]]
            else {
                check(false, "persist bad: index readable for mutation")
                return finish()
            }
            let symlinkTarget = root.appendingPathComponent("symlink-target.txt")
            try? "symlink-target-data".write(to: symlinkTarget, atomically: true, encoding: .utf8)
            let symlinkName = String(repeating: "b", count: 64) + ".blob"
            let symlinkURL = directory
                .appendingPathComponent("assets", isDirectory: true)
                .appendingPathComponent(symlinkName, isDirectory: false)
            try? FileManager.default.createSymbolicLink(
                at: symlinkURL,
                withDestinationURL: symlinkTarget
            )

            entries.append([
                "id": UUID().uuidString,
                "capturedAt": 0.0,
                "text": ["bodyAsset": "../../outside-sentinel.blob"],
            ])
            entries.append([
                "id": UUID().uuidString,
                "capturedAt": 0.0,
                "text": ["bodyAsset": String(repeating: "a", count: 64) + ".blob"],
            ])
            entries.append([
                "id": UUID().uuidString,
                "capturedAt": 0.0,
                "text": ["bodyAsset": symlinkName],
            ])
            object["entries"] = entries
            if let mutated = try? JSONSerialization.data(withJSONObject: object) {
                try? mutated.write(to: indexURL)
            }

            let rebuilt = await restoredStore(directory: directory)
            check(rebuilt.items.count == 1, "persist bad: valid entry survives")
            check(textContent(of: rebuilt.items.first)?.text == "valid-survivor",
                  "persist bad: text payload intact")
            check(rebuilt.persistenceStatus != .ready,
                  "persist bad: partial restore is reported")
            check(FileManager.default.fileExists(atPath: sentinel.path),
                  "persist bad: traversal asset name cannot delete outside file")
            check((try? Data(contentsOf: sentinel)) == Data("outside-data".utf8),
                  "persist bad: outside file unchanged")
            check((try? Data(contentsOf: symlinkTarget)) == Data("symlink-target-data".utf8),
                  "persist bad: symlinked asset is never followed on load")

            rebuilt.clear()
            _ = await rebuilt.flushPersistence()
            check(!FileManager.default.fileExists(atPath: symlinkURL.path),
                  "persist bad: reset unlinks the symlink itself")
            check((try? Data(contentsOf: symlinkTarget)) == Data("symlink-target-data".utf8),
                  "persist bad: reset never deletes the symlink target")
        }

        // MARK: Unknown version and malformed indexes are never overwritten
        for (name, payload) in [
            ("unknown-version", "{\"formatVersion\":999,\"entries\":[]}"),
            ("malformed", "this is not json"),
        ] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let indexURL = directory.appendingPathComponent("index.json")
            let original = Data(payload.utf8)
            try? original.write(to: indexURL)

            let store = await restoredStore(directory: directory)
            check(store.items.isEmpty, "persist \(name): no entries recovered")
            check(store.persistenceStatus != .ready, "persist \(name): failure reported")
            let flushOutcome = await store.flushPersistence()
            check(flushOutcome == nil, "persist \(name): save refused while unreadable")
            check((try? Data(contentsOf: indexURL)) == original,
                  "persist \(name): unknown index not overwritten")

            store.clear()
            _ = await store.flushPersistence()
            let rebuilt = await restoredStore(directory: directory)
            check(rebuilt.items.isEmpty, "persist \(name): explicit clear resets archive")
        }

        // MARK: A new copy during background restore is kept and wins
        do {
            let directory = root.appendingPathComponent("restore-race", isDirectory: true)
            let seedBoard = makePasteboard()
            let seed = makeStore(directory: directory, pasteboard: seedBoard)
            _ = await captureText("disk-old", store: seed, pasteboard: seedBoard,
                                  name: "persist race: disk entry seeded")
            _ = await seed.flushPersistence()

            let queue = DispatchQueue(label: "boringnotch.clipboard.persist.restore-race")
            queue.suspend()
            let pasteboard = makePasteboard()
            let store = makeStore(directory: directory, queue: queue, pasteboard: pasteboard)
            let restore = Task { @MainActor in
                await store.restorePersistedHistory()
            }
            try? await Task.sleep(nanoseconds: 60_000_000)

            _ = await captureText("memory-new", store: store, pasteboard: pasteboard,
                                  name: "persist race: new copy captured during restore")
            queue.resume()
            await restore.value

            check(store.items.count == 2, "persist race: both entries retained")
            check(textContent(of: store.items.first)?.text == "memory-new",
                  "persist race: new entry stays in front")
            check(store.items.contains { textContent(of: $0)?.text == "disk-old" },
                  "persist race: disk entry merged")

            await store.flushPersistence()
            let rebuilt = await restoredStore(directory: directory)
            check(rebuilt.items.compactMap { textContent(of: $0)?.text } == ["memory-new", "disk-old"],
                  "persist race: merged order persisted")
        }

        // MARK: A late restore cannot resurrect a cleared history
        do {
            let directory = root.appendingPathComponent("restore-clear", isDirectory: true)
            let seedBoard = makePasteboard()
            let seed = makeStore(directory: directory, pasteboard: seedBoard)
            _ = await captureText("disk-old", store: seed, pasteboard: seedBoard,
                                  name: "persist late-clear: disk entry seeded")
            _ = await seed.flushPersistence()

            let queue = DispatchQueue(label: "boringnotch.clipboard.persist.restore-clear")
            queue.suspend()
            let pasteboard = makePasteboard()
            let store = makeStore(directory: directory, queue: queue, pasteboard: pasteboard)
            let restore = Task { @MainActor in
                await store.restorePersistedHistory()
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
            store.clear()
            queue.resume()
            await restore.value
            await store.flushPersistence()

            check(store.items.isEmpty, "persist late-clear: clear wins over late restore")
            let rebuilt = await restoredStore(directory: directory)
            check(rebuilt.items.isEmpty, "persist late-clear: rebuild stays empty")
        }

        // MARK: Pending writes from before a clear cannot reappear
        do {
            let directory = root.appendingPathComponent("stale-write", isDirectory: true)
            let queue = DispatchQueue(label: "boringnotch.clipboard.persist.stale-write")
            queue.suspend()
            let pasteboard = makePasteboard()
            let store = makeStore(directory: directory, queue: queue, pasteboard: pasteboard)

            _ = await captureText("before-clear", store: store, pasteboard: pasteboard,
                                  name: "persist stale-write: first copy captured")
            store.clear()
            _ = await captureText("after-clear", store: store, pasteboard: pasteboard,
                                  name: "persist stale-write: post-clear copy captured")
            queue.resume()
            await store.flushPersistence()

            let rebuilt = await restoredStore(directory: directory)
            check(rebuilt.items.compactMap { textContent(of: $0)?.text } == ["after-clear"],
                  "persist stale-write: only post-clear entry survives")
        }

        // MARK: Normal stop flushes the last visible entry
        do {
            let directory = root.appendingPathComponent("stop", isDirectory: true)
            let pasteboard = makePasteboard()
            let store = makeStore(directory: directory, pasteboard: pasteboard)
            _ = await captureText("last-visible", store: store, pasteboard: pasteboard,
                                  name: "persist stop: entry captured")
            store.stop()

            let rebuilt = await restoredStore(directory: directory)
            check(rebuilt.items.compactMap { textContent(of: $0)?.text } == ["last-visible"],
                  "persist stop: final flush persisted the entry")
        }

        // MARK: A missing source file fails only that file group
        do {
            let directory = root.appendingPathComponent("missing-file", isDirectory: true)
            let sources = root.appendingPathComponent("missing-sources", isDirectory: true)
            try? FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            let file = sources.appendingPathComponent("gone.txt")
            try? "gone".write(to: file, atomically: true, encoding: .utf8)

            let pasteboard = makePasteboard()
            let store = makeStore(directory: directory, pasteboard: pasteboard)
            _ = await captureText("text-survives", store: store, pasteboard: pasteboard,
                                  name: "persist missing: text captured")
            _ = await captureFiles([file], store: store, pasteboard: pasteboard,
                                   name: "persist missing: file captured")
            _ = await store.flushPersistence()
            try? FileManager.default.removeItem(at: file)

            let rebuilt = await restoredStore(directory: directory, pasteboard: pasteboard)
            check(rebuilt.items.count == 2, "persist missing: text and file records kept")
            check(rebuilt.items.contains { textContent(of: $0)?.text == "text-survives" },
                  "persist missing: text history not lost")
            guard let broken = rebuilt.items.first(where: {
                if case .files = $0.kind { return !$0.fileDisplayNames.isEmpty }
                return false
            }) else {
                check(false, "persist missing: file record restored with its name")
                return finish()
            }
            check(broken.fileDisplayNames == ["gone.txt"],
                  "persist missing: display name kept")
            let before = pasteboard.changeCount
            check(rebuilt.dragPayload(for: broken, whole: false) == nil,
                  "drag: missing file rejects the complete payload")
            check(!rebuilt.copy(broken), "persist missing: copy fails accurately")
            check(pasteboard.changeCount == before, "persist missing: pasteboard untouched")
            check(rebuilt.notice?.style == .error, "persist missing: error notice exposed")
        }

        finish()
    }

    @MainActor
    static func finish() {
        if failures.isEmpty {
            print("PASS: clipboard history persistence")
            exit(0)
        } else {
            print("FAIL: \(failures.count) check(s) failed")
            for failure in failures { print("  - \(failure)") }
            exit(1)
        }
    }
}
'''


def main() -> int:
    if not STORE_SOURCE.is_file() or not ARCHIVE_SOURCE.is_file():
        print(f"missing production source: {STORE_SOURCE} / {ARCHIVE_SOURCE}", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="boring-clipboard-persist-test-") as directory:
        folder = pathlib.Path(directory)
        main_source = folder / "main.swift"
        main_source.write_text(SWIFT_TEST)
        binary = folder / "clipboard-persistence-check"

        compile_result = subprocess.run(
            [
                "xcrun",
                "swiftc",
                "-parse-as-library",
                str(STORE_SOURCE),
                str(ARCHIVE_SOURCE),
                str(main_source),
                "-o",
                str(binary),
            ],
            capture_output=True,
            text=True,
        )
        if compile_result.returncode != 0:
            print(compile_result.stdout)
            print(compile_result.stderr, file=sys.stderr)
            return 1

        run_result = subprocess.run([str(binary)])
        return run_result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
