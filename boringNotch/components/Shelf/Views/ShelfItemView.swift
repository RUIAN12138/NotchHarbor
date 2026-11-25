//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import SwiftUI
import Defaults

import QuickLook

struct ShelfItemView: View {
    let item: ShelfItem
    @ObservedObject var selection = ShelfSelectionModel.shared
    @StateObject private var viewModel: ShelfItemViewModel
    @EnvironmentObject private var quickLookService: QuickLookService
    @State private var cachedPreviewImage: NSImage?
    @State private var debouncedDropTarget = false

    private var isSelected: Bool { viewModel.isSelected }
    private var shouldHideDuringDrag: Bool { selection.isDragging && selection.isSelected(item.id) && false }
    
    init(item: ShelfItem) {
        self.item = item
        _viewModel = StateObject(wrappedValue: ShelfItemViewModel(item: item))
    }

    var body: some View {
        ZStack {
            if !shouldHideDuringDrag {
                VStack(alignment: .center, spacing: 2) {
                    if viewModel.isRenaming {
                        renameEditor
                    } else {
                        iconView
                        textView
                    }
                }
                .frame(width: 105)
                .padding(.vertical, 4)
                .padding(.horizontal, 5)
                .background(backgroundView)
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.1), value: debouncedDropTarget)
                .animation(.easeInOut(duration: 0.1), value: isSelected)

                if !viewModel.isRenaming {
                    DraggableClickHandler(
                        item: item,
                        viewModel: viewModel,
                        cachedPreviewImage: $cachedPreviewImage,
                        dragPreviewContent: {
                            DragPreviewView(thumbnail: viewModel.thumbnail ?? item.icon, displayName: item.displayName)
                        },
                        onRightClick: viewModel.handleRightClick,
                        onClick: { event, nsview in
                            viewModel.handleClick(event: event, view: nsview)
                        }
                    )
                }
            } else {
                Color.clear
                    .frame(width: 105)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 5)
            }
        }
        .onChange(of: viewModel.isDropTargeted) { _, targeted in
            // Debounce drop target state changes
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                debouncedDropTarget = targeted
            }
        }
        .onAppear {
            Task { 
                await viewModel.loadThumbnail()
                // Pre-render drag preview once on appear
                if cachedPreviewImage == nil {
                    cachedPreviewImage = await renderDragPreview()
                }
            }
            viewModel.onQuickLookRequest = { urls in
                quickLookService.show(urls: urls, selectFirst: true)
            }
        }
        .onChange(of: item) { _, _ in
            Task { cachedPreviewImage = await renderDragPreview() }
        }
        .onChange(of: viewModel.thumbnail) { _, _ in
            // Invalidate cached preview when thumbnail changes
            Task {
                cachedPreviewImage = await renderDragPreview()
            }
        }
        .quickLookPresenter(using: quickLookService)
    }

    // MARK: - View Components

    private var renameEditor: some View {
        VStack(spacing: 3) {
            Group {
                if viewModel.renameNeedsFolderAccess {
                    Button("授权文件夹") { viewModel.requestRenameFolderAccess() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if let error = viewModel.renameError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .help(error)
                } else {
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 29)

            ShelfRenameField(name: viewModel.draftTitle, submit: viewModel.commitRename,
                             cancel: viewModel.cancelRename)
                .frame(height: 22)
                .padding(.horizontal, 2)
        }
        .frame(height: 68)
    }

    private var iconView: some View {
        Image(nsImage: viewModel.thumbnail ?? item.icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
    }

    private var textView: some View {
        Text(item.displayName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .truncationMode(.middle)
            .multilineTextAlignment(.center)
            .frame(height: 26, alignment: .top)
    }

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        strokeColor,
                        lineWidth: strokeWidth
                    )
            )
    }

    private var backgroundColor: Color {
        if debouncedDropTarget {
            return Color.accentColor.opacity(0.25)
        } else if isSelected {
            return Color.accentColor.opacity(0.15)
        } else {
            return Color.clear
        }
    }

    private var strokeColor: Color {
        if debouncedDropTarget {
            return Color.accentColor.opacity(0.9)
        } else if isSelected {
            return Color.accentColor.opacity(0.8)
        } else {
            return Color.clear
        }
    }

    private var strokeWidth: CGFloat {
        if debouncedDropTarget {
            return 3
        } else if isSelected {
            return 2
        } else {
            return 1
        }
    }
    
    // MARK: - Drag Preview Rendering
    
    @MainActor
    private func renderDragPreview() async -> NSImage {
        let content = DragPreviewView(thumbnail: viewModel.thumbnail ?? item.icon, displayName: item.displayName)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return renderer.nsImage ?? (viewModel.thumbnail ?? item.icon)
    }

    
}

private struct ShelfRenameField: NSViewRepresentable {
    let name: String
    let submit: (String) -> Void
    let cancel: () -> Void

    final class Input: NSTextField {
        weak var editingPanel: BoringNotchSkyLightWindow?

        override var needsPanelToBecomeKey: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.beginEditing(selectBasename: true) }
        }

        override func mouseDown(with event: NSEvent) {
            beginEditing(selectBasename: false)
            super.mouseDown(with: event)
        }

        private func beginEditing(selectBasename: Bool) {
            guard let panel = window as? BoringNotchSkyLightWindow,
                  panel.beginShelfRenameEditing(self) else { return }
            editingPanel = panel
            guard selectBasename, let editor = currentEditor() else { return }
            let fileExtension = (stringValue as NSString).pathExtension
            let basename = fileExtension.isEmpty ? stringValue : (stringValue as NSString).deletingPathExtension
            editor.selectedRange = NSRange(location: 0, length: basename.utf16.count)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var field: ShelfRenameField
        init(_ field: ShelfRenameField) { self.field = field }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if command == #selector(NSResponder.insertNewline(_:)) {
                field.submit(textView.string)
                return true
            }
            if command == #selector(NSResponder.cancelOperation(_:)) {
                field.cancel()
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let input = notification.object as? Input else { return }
            DispatchQueue.main.async { [weak input] in
                guard let input, input.currentEditor() == nil else { return }
                input.editingPanel?.endPanelTextEditing(input)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Input {
        let input = Input()
        input.delegate = context.coordinator
        input.stringValue = name
        input.font = .systemFont(ofSize: 12)
        input.usesSingleLineMode = true
        input.setAccessibilityLabel(String(localized: "文件名"))
        input.setAccessibilityIdentifier("shelf-rename-input")
        input.toolTip = String(localized: "按回车保存，按 Escape 取消")
        return input
    }

    func updateNSView(_ input: Input, context: Context) {
        context.coordinator.field = self
    }

    static func dismantleNSView(_ input: Input, coordinator: Coordinator) {
        let panel = input.editingPanel
        DispatchQueue.main.async { [weak panel] in panel?.endPanelTextEditing(input) }
    }
}

// MARK: - Draggable Click Handler with NSDraggingSource
private struct DraggableClickHandler<Content: View>: NSViewRepresentable {
    let item: ShelfItem
    let viewModel: ShelfItemViewModel
    @Binding var cachedPreviewImage: NSImage?
    @ViewBuilder let dragPreviewContent: () -> Content
    let onRightClick: (NSEvent, NSView) -> Void
    let onClick: (NSEvent, NSView) -> Void
    
    func makeNSView(context: Context) -> DraggableClickView {
        let view = DraggableClickView()
        view.item = item
        view.viewModel = viewModel
        view.dragPreviewImage = cachedPreviewImage ?? renderDragPreview()
        view.onRightClick = onRightClick
        view.onClick = onClick
        return view
    }
    
    func updateNSView(_ nsView: DraggableClickView, context: Context) {
        nsView.item = item
        nsView.viewModel = viewModel
        // Only update preview if cached version is available
        if let cached = cachedPreviewImage {
            nsView.dragPreviewImage = cached
        }
        nsView.onRightClick = onRightClick
        nsView.onClick = onClick
    }
    
    private func renderDragPreview() -> NSImage {
        let content = dragPreviewContent()
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        
        if let nsImage = renderer.nsImage {
            return nsImage
        }
        
        // Fallback to icon if rendering fails
        return viewModel.thumbnail ?? item.icon
    }
    
    final class DraggableClickView: NSView, NSDraggingSource {
        var item: ShelfItem!
        weak var viewModel: ShelfItemViewModel?
        var dragPreviewImage: NSImage?
        var onRightClick: ((NSEvent, NSView) -> Void)?
        var onClick: ((NSEvent, NSView) -> Void)?

        private var mouseDownEvent: NSEvent?
        private let dragThreshold: CGFloat = 3.0
        private var draggedURLs: [URL] = []
        private var draggedItems: [ShelfItem] = []
        
        override func rightMouseDown(with event: NSEvent) {
            onRightClick?(event, self)
        }
        
        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            onClick?(event, self)
        }
        
        override func mouseDragged(with event: NSEvent) {
            guard let mouseDownEvent = mouseDownEvent else {
                super.mouseDragged(with: event)
                return
            }
            
            let dragDistance = hypot(
                event.locationInWindow.x - mouseDownEvent.locationInWindow.x,
                event.locationInWindow.y - mouseDownEvent.locationInWindow.y
            )
            
            if dragDistance > dragThreshold {
                startDragSession(with: event)
                self.mouseDownEvent = nil
            } else {
                super.mouseDragged(with: event)
            }
        }
        
        private func startDragSession(with event: NSEvent) {
            // Prepare dragging items
            let selectedItems = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
            let itemsToDrag: [ShelfItem]

            if selectedItems.count > 1 && selectedItems.contains(where: { $0.id == item.id }) {
                itemsToDrag = selectedItems
            } else {
                itemsToDrag = [item]
            }

            // Store items being dragged for auto-remove feature
            draggedItems = itemsToDrag

            // Create dragging items for AppKit
            var draggingItems: [NSDraggingItem] = []

            for dragItem in itemsToDrag {
                if let pasteboardItem = createPasteboardItem(for: dragItem) {
                    let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

                    // Use the drag preview image
                    let image = dragPreviewImage ?? dragItem.icon
                    let imageFrame = NSRect(
                        x: 0,
                        y: 0,
                        width: image.size.width,
                        height: image.size.height
                    )
                    draggingItem.setDraggingFrame(imageFrame, contents: image)

                    draggingItems.append(draggingItem)
                }
            }

            guard !draggingItems.isEmpty else { return }

            beginDraggingSession(with: draggingItems, event: event, source: self)
        }
        
        private func createPasteboardItem(for item: ShelfItem) -> NSPasteboardItem? {
            let pasteboardItem = NSPasteboardItem()

            switch item.kind {
            case .file:
                guard let url = ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item) else {
                    pasteboardItem.setString(item.displayName, forType: .string)
                    return pasteboardItem
                }
                
                // Start accessing security-scoped resource and keep it active during drag
                if url.startAccessingSecurityScopedResource() {
                    draggedURLs.append(url)
                    NSLog("🔐 Started security-scoped access for drag: \(url.path)")
                }
                
                pasteboardItem.setString(url.absoluteString, forType: .fileURL)
                pasteboardItem.setString(url.path, forType: .string)
                return pasteboardItem

            case .text(let string):
                pasteboardItem.setString(string, forType: .string)
                return pasteboardItem

            case .link(let url):
                pasteboardItem.setString(url.absoluteString, forType: .URL)
                pasteboardItem.setString(url.absoluteString, forType: .string)
                return pasteboardItem
            }
        }
        
        // MARK: - NSDraggingSource
        
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // When copyOnDrag is enabled, only allow copy operations
            if Defaults[.copyOnDrag] {
                return [.copy]
            }
            
            switch context {
            case .outsideApplication:
                return [.copy, .move]
            case .withinApplication:
                return [.copy, .move, .generic]
            @unknown default:
                return [.copy]
            }
        }
        
        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            ShelfSelectionModel.shared.beginDrag()
        }
        
        
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            ShelfSelectionModel.shared.endDrag()

            // Stop accessing security-scoped resources after drag completes
            for url in draggedURLs {
                url.stopAccessingSecurityScopedResource()
                NSLog("🔐 Stopped security-scoped access after drag: \(url.path)")
            }
            draggedURLs.removeAll()

            // Auto-remove items from shelf if enabled and drag succeeded
            if Defaults[.autoRemoveShelfItems] && !operation.isEmpty {
                for item in draggedItems {
                    ShelfStateViewModel.shared.remove(item)
                }
            }
            draggedItems.removeAll()
        }
        
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
            return false
        }
    }
}
