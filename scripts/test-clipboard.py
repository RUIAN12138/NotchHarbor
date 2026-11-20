#!/usr/bin/env python3
"""Exercise the production ClipboardHistoryStore against a private pasteboard.

The real production source file is compiled with swiftc and driven through a
unique NSPasteboard. The system pasteboard (.general) is never touched, and all
file/image samples live under the process temporary directory.

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

func expect(_ condition: Bool, _ name: String) -> Bool {
    check(condition, name)
    return condition
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
    NSPasteboard(name: NSPasteboard.Name("boringnotch.clipboard.test.\(UUID().uuidString)"))
}

func writeString(_ text: String, to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

func writeItems(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    _ = pasteboard.writeObjects(items)
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
    context.setFillColor(CGColor(red: 0.9, green: 0.35, blue: 0.2, alpha: 1))
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

func textContent(of entry: ClipboardHistoryEntry) -> ClipboardTextContent? {
    guard case .text(let content) = entry.kind else { return nil }
    return content
}

func files(of entry: ClipboardHistoryEntry) -> [URL]? {
    guard case .files(let urls) = entry.kind else { return nil }
    return urls
}

func image(of entry: ClipboardHistoryEntry) -> ClipboardImageContent? {
    guard case .image(let content) = entry.kind else { return nil }
    return content
}

@main
struct ClipboardTests {
    @MainActor
    static func main() async {
        // MARK: Text round-trip, self-copy, stable single entry
        do {
            let pasteboard = makePasteboard()
            let store = ClipboardHistoryStore(pasteboard: pasteboard)
            let original = "第一行原文\nSecond line 123"
            writeString(original, to: pasteboard)
            store.checkForChanges()
            let captured = await waitUntil("text: entry captured") { store.items.count == 1 }
            if captured {
                let entry = store.items[0]
                check(textContent(of: entry)?.text == original, "text: original preserved")
                check(store.copy(entry), "text: copy reported success")
                check(pasteboard.string(forType: .string) == original, "text: exact pasteboard round-trip")
                store.checkForChanges()
                try? await Task.sleep(nanoseconds: 250_000_000)
                check(store.items.count == 1, "text: own copy did not add history")
            }
        }

        // Malformed image representations must not become an unpasteable
        // image record when a usable text representation is present.
        do {
            let queue = DispatchQueue(label: "boringnotch.clipboard.test.invalid-image")
            let pasteboard = makePasteboard()
            let store = ClipboardHistoryStore(pasteboard: pasteboard, workQueue: queue)
            let item = NSPasteboardItem()
            item.setData(Data("not a PNG".utf8), forType: .png)
            item.setString("usable text fallback", forType: .string)
            writeItems([item], to: pasteboard)
            store.checkForChanges()
            await withCheckedContinuation { continuation in
                queue.async {
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
            check(store.items.count == 1, "invalid image: usable fallback recorded")
            if let entry = store.items.first {
                check(textContent(of: entry)?.text == "usable text fallback",
                      "invalid image: never stores a corrupt zero-size PNG")
            }
        }

        // MARK: PNG and TIFF round-trip
        do {
            let pasteboard = makePasteboard()
            let store = ClipboardHistoryStore(pasteboard: pasteboard)
            let png = encode(makeImage(width: 80, height: 40), as: "public.png")
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            store.checkForChanges()
            let captured = await waitUntil("png: entry captured") { store.items.count == 1 }
            if captured {
                let entry = store.items[0]
                if let content = image(of: entry) {
                    check(content.pixelWidth == 80 && content.pixelHeight == 40, "png: dimensions kept")
                    check(content.thumbnailData != nil, "png: thumbnail generated")
                    check(content.pngData == png, "png: source reused verbatim")
                    check(store.copy(entry), "png: copy reported success")
                    let copied = pasteboard.data(forType: .png) ?? Data()
                    check(imageSize(copied) == (80, 40), "png: pasted image decodes at original size")
                } else {
                    check(false, "png: captured as image")
                }
            }
        }

        do {
            let pasteboard = makePasteboard()
            let store = ClipboardHistoryStore(pasteboard: pasteboard)
            let tiff = encode(makeImage(width: 64, height: 32), as: "public.tiff")
            pasteboard.clearContents()
            pasteboard.setData(tiff, forType: .tiff)
            store.checkForChanges()
            let captured = await waitUntil("tiff: entry captured") { store.items.count == 1 }
            if captured {
                let entry = store.items[0]
                if let content = image(of: entry) {
                    check(content.pngData.count > 0, "tiff: converted to PNG in the store")
                    check(content.thumbnailData != nil, "tiff: thumbnail generated")
                    check(content.pixelWidth == 64 && content.pixelHeight == 32, "tiff: dimensions kept")
                    check(store.copy(entry), "tiff: copy reported success")
                    let copied = pasteboard.data(forType: .png) ?? Data()
                    check(imageSize(copied) == (64, 32), "tiff: copied PNG decodes at original size")
                } else {
                    check(false, "tiff: captured as image")
                }
            }
        }

        // MARK: Multi-file group, order, missing file, clear safety
        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("boringnotch-clipboard-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            let first = folder.appendingPathComponent("first.txt")
            let second = folder.appendingPathComponent("second.txt")
            try? "first".write(to: first, atomically: true, encoding: .utf8)
            try? "second".write(to: second, atomically: true, encoding: .utf8)

            let pasteboard = makePasteboard()
            let store = ClipboardHistoryStore(pasteboard: pasteboard)
            let firstItem = NSPasteboardItem()
            firstItem.setString(first.absoluteString, forType: .fileURL)
            let secondItem = NSPasteboardItem()
            secondItem.setString(second.absoluteString, forType: .fileURL)
            writeItems([firstItem, secondItem], to: pasteboard)

            store.checkForChanges()
            let captured = await waitUntil("files: group captured as one entry") {
                store.items.count == 1
            }
            if captured {
                let entry = store.items[0]
                let urls = files(of: entry) ?? []
                check(urls.map(\.lastPathComponent) == ["first.txt", "second.txt"], "files: order preserved")
                check(store.copy(entry), "files: copy reported success")
                let pasted = pasteboard.pasteboardItems ?? []
                let pastedNames = pasted.compactMap { item -> String? in
                    guard let raw = item.string(forType: .fileURL),
                          let url = URL(string: raw)
                    else { return nil }
                    return url.lastPathComponent
                }
                check(pasted.count == 2, "files: two pasteboard items written")
                check(pastedNames == ["first.txt", "second.txt"], "files: multi-item order preserved")

                let changeCount = pasteboard.changeCount
                store.clear()
                check(store.items.isEmpty, "clear: history emptied")
                check(pasteboard.changeCount == changeCount, "clear: pasteboard untouched")
                check((pasteboard.pasteboardItems ?? []).count == 2, "clear: pasteboard contents preserved")
                check(FileManager.default.fileExists(atPath: first.path), "clear: user file still exists")

                try? FileManager.default.removeItem(at: second)
                let beforeFailedCopy = pasteboard.changeCount
                check(!store.copy(entry), "missing file: copy reports failure")
                check(pasteboard.changeCount == beforeFailedCopy, "missing file: pasteboard untouched")
                check(store.notice?.style == .error, "missing file: error state exposed")
            }
        }

        // MARK: File group wins over attached text
        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("boringnotch-clipboard-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("priority.txt")
            try? "priority".write(to: file, atomically: true, encoding: .utf8)

            let pasteboard = makePasteboard()
            let store = ClipboardHistoryStore(pasteboard: pasteboard)
            let fileItem = NSPasteboardItem()
            fileItem.setString(file.absoluteString, forType: .fileURL)
            fileItem.setString("attached text", forType: .string)
            let textItem = NSPasteboardItem()
            textItem.setString("second text", forType: .string)
            writeItems([fileItem, textItem], to: pasteboard)

            store.checkForChanges()
            let captured = await waitUntil("priority: file group captured") { store.items.count == 1 }
            if captured {
                check(files(of: store.items[0])?.count == 1, "priority: fileURL group beats text")
                check(textContent(of: store.items[0]) == nil, "priority: attached text not recorded")
            }
        }

        // MARK: Duplicate moves to front and keeps its id
        do {
            let pasteboard = makePasteboard()
            let store = ClipboardHistoryStore(pasteboard: pasteboard)

            writeString("alpha", to: pasteboard)
            store.checkForChanges()
            _ = await waitUntil("duplicate: alpha captured") { store.items.count == 1 }
            let alphaID = store.items.first?.id

            writeString("beta", to: pasteboard)
            store.checkForChanges()
            _ = await waitUntil("duplicate: beta captured") {
                store.items.first.flatMap { textContent(of: $0)?.text } == "beta"
            }

            writeString("alpha", to: pasteboard)
            store.checkForChanges()
            let moved = await waitUntil("duplicate: alpha moved to front") {
                store.items.first.flatMap { textContent(of: $0)?.text } == "alpha"
            }
            check(moved, "duplicate: most recent copy leads")
            check(store.items.count == 2, "duplicate: logical copy not duplicated")
            check(store.items.first?.id == alphaID, "duplicate: existing id kept")
        }

        // MARK: Pause/resume does not backfill
        do {
            let pasteboard = makePasteboard()
            let store = ClipboardHistoryStore(pasteboard: pasteboard)

            writeString("one", to: pasteboard)
            store.checkForChanges()
            _ = await waitUntil("pause: first entry captured") { store.items.count == 1 }

            store.pause()
            writeString("two", to: pasteboard)
            store.checkForChanges()
            try? await Task.sleep(nanoseconds: 250_000_000)
            check(store.items.count == 1, "pause: new copy ignored")

            store.resume()
            store.checkForChanges()
            try? await Task.sleep(nanoseconds: 250_000_000)
            check(store.items.count == 1, "resume: paused content not backfilled")

            writeString("three", to: pasteboard)
            store.checkForChanges()
            let captured = await waitUntil("resume: new copy captured") { store.items.count == 2 }
            if captured {
                check(store.items.first.flatMap { textContent(of: $0)?.text } == "three", "resume: new copy leads")
            }
        }

        // MARK: Concealed / transient / auto-generated markers
        for marker in [
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType",
        ] {
            let pasteboard = makePasteboard()
            let store = ClipboardHistoryStore(pasteboard: pasteboard)
            let item = NSPasteboardItem()
            item.setString("sensitive", forType: .string)
            item.setString("", forType: NSPasteboard.PasteboardType(marker))
            writeItems([item], to: pasteboard)
            store.checkForChanges()
            try? await Task.sleep(nanoseconds: 250_000_000)
            check(store.items.isEmpty, "ignored marker: \(marker)")
        }

        // MARK: Count and memory budgets
        do {
            let pasteboard = makePasteboard()
            let store = ClipboardHistoryStore(pasteboard: pasteboard, maxItems: 2)
            for text in ["one", "two", "three"] {
                writeString(text, to: pasteboard)
                store.checkForChanges()
                _ = await waitUntil("limit: \(text) processed") {
                    store.items.first.flatMap { textContent(of: $0)?.text } == text
                }
            }
            check(store.items.count == 2, "limit: entry count capped")
            check(store.items.map { textContent(of: $0)?.text } == ["three", "two"], "limit: oldest trimmed")
        }

        do {
            let pasteboard = makePasteboard()
            let store = ClipboardHistoryStore(pasteboard: pasteboard, maxTotalBytes: 512)
            writeString(String(repeating: "x", count: 2_000), to: pasteboard)
            store.checkForChanges()
            let noticed = await waitUntil("memory: oversize notice") { store.notice != nil }
            check(noticed, "memory: oversize text reported")
            check(store.items.isEmpty, "memory: oversize text not stored")
            check(store.notice?.text.contains("内容较大") == true, "memory: short oversize status")
        }

        do {
            let pasteboard = makePasteboard()
            let store = ClipboardHistoryStore(pasteboard: pasteboard, maxImageBytes: 32)
            let png = encode(makeImage(width: 200, height: 200), as: "public.png")
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            store.checkForChanges()
            let noticed = await waitUntil("image budget: oversize notice") { store.notice != nil }
            check(noticed, "image budget: oversize image reported")
            check(store.items.isEmpty, "image budget: oversize image not stored")
        }

        // MARK: Late snapshot cannot restore cleared history
        do {
            let queue = DispatchQueue(label: "boringnotch.clipboard.test.suspended")
            queue.suspend()
            let pasteboard = makePasteboard()
            let store = ClipboardHistoryStore(pasteboard: pasteboard, workQueue: queue)

            writeString("late snapshot", to: pasteboard)
            store.checkForChanges()
            store.clear()

            queue.resume()
            try? await Task.sleep(nanoseconds: 400_000_000)
            check(store.items.isEmpty, "late snapshot: generation rejects cleared read")

            store.checkForChanges()
            try? await Task.sleep(nanoseconds: 200_000_000)
            check(store.items.isEmpty, "late snapshot: current pasteboard aligned after clear")
        }

        if failures.isEmpty {
            print("PASS: clipboard history production store")
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

    with tempfile.TemporaryDirectory(prefix="boring-clipboard-test-") as directory:
        folder = pathlib.Path(directory)
        main_source = folder / "main.swift"
        main_source.write_text(SWIFT_TEST)
        binary = folder / "clipboard-check"

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
