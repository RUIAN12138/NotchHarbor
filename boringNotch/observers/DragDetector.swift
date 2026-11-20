//
//  DragDetector.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-20.
//

import Cocoa
import UniformTypeIdentifiers

enum ShelfFileDrag {
    static let legacyFileNames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, legacyFileNames]

    static func containsFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: types) != nil
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let files = urls.filter { $0.isFileURL && $0.path.hasPrefix("/") }
        if !files.isEmpty { return files }
        let filenames = pasteboard.propertyList(forType: legacyFileNames) as? [String] ?? []
        return filenames.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
    }
}

final class DragDetector {

    // MARK: - Callbacks

    typealias PositionCallback = (_ globalPoint: CGPoint) -> Void

    var onDragMove: PositionCallback?
    var onFileDragChanged: ((Bool) -> Void)?


    private var mouseDownMonitor: Any?
    private var mouseDraggedMonitor: Any?
    private var mouseUpMonitor: Any?

    private var pasteboardChangeCount: Int = -1
    private var isDragging: Bool = false
    private var isContentDragging: Bool = false
    private var fileDragActive = false

    private let notchRegion: CGRect
    private let dragPasteboard = NSPasteboard(name: .drag)

    init(notchRegion: CGRect) {
        self.notchRegion = notchRegion
    }

    // MARK: - Private Helpers
    
    /// Checks if the drag pasteboard contains valid content types that can be dropped on the shelf
    private func hasValidDragContent() -> Bool {
        let validTypes = ShelfFileDrag.types + [
            NSPasteboard.PasteboardType(UTType.url.identifier),
            .string
        ]
        return dragPasteboard.types?.contains(where: validTypes.contains) ?? false
    }

    func startMonitoring() {
        stopMonitoring()

        // Track pasteboard to detect content drag
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            self.pasteboardChangeCount = self.dragPasteboard.changeCount
            self.isDragging = true
            self.isContentDragging = false
        }

        // Track drag movement and notch region intersection
        mouseDraggedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            guard let self = self else { return }
            guard self.isDragging else { return }

            let newContent = self.dragPasteboard.changeCount != self.pasteboardChangeCount
            
            // Detect if actual content is being dragged AND it's valid content
            if newContent && !self.isContentDragging && self.hasValidDragContent() {
                self.isContentDragging = true
            }

            // Keep classification stable until mouse-up. AppKit may republish
            // the drag pasteboard as the destination changes.
            if !self.fileDragActive, self.isContentDragging, ShelfFileDrag.containsFiles(self.dragPasteboard) {
                self.fileDragActive = true
                self.onFileDragChanged?(true)
            }

            if self.isContentDragging {
                let mouseLocation = NSEvent.mouseLocation
                if self.notchRegion.contains(mouseLocation) { self.onDragMove?(mouseLocation) }
            }
        }

        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self = self else { return }
            guard self.isDragging else { return }

            if self.fileDragActive { self.onFileDragChanged?(false) }
            self.fileDragActive = false
            self.isDragging = false
            self.isContentDragging = false
            self.pasteboardChangeCount = -1
        }
    }

    func stopMonitoring() {
        [mouseDownMonitor, mouseDraggedMonitor, mouseUpMonitor].forEach { monitor in
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        mouseDownMonitor = nil
        mouseDraggedMonitor = nil
        mouseUpMonitor = nil
        if fileDragActive { onFileDragChanged?(false) }
        fileDragActive = false
        isDragging = false
        isContentDragging = false
    }

    deinit {
        stopMonitoring()
    }
}
