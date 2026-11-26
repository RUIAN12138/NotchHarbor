//
//  ClipboardHistoryView.swift
//  boringNotch
//
//  Clipboard history page inside the existing notch shell.
//

import AppKit
import Defaults
import NaturalLanguage
import SwiftUI

private enum ClipboardFilter: String, CaseIterable, Identifiable {
    case all
    case pinned
    case text
    case image
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .pinned: return "已固定"
        case .text: return "文字"
        case .image: return "图片"
        case .files: return "文件"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .pinned: return "pin"
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .files: return "doc"
        }
    }

    func matches(_ entry: ClipboardHistoryEntry) -> Bool {
        switch (self, entry.kind) {
        case (.all, _): return true
        case (.pinned, _): return entry.isPinned
        case (.text, .text): return true
        case (.image, .image): return true
        case (.files, .files): return true
        default: return false
        }
    }
}

private final class ClipboardCardHover {
    var id: UUID?
    var scrolling = false
}

@MainActor
struct ClipboardHistoryView: View {
    @ObservedObject private var store: ClipboardHistoryStore
    private let viewportHeight: CGFloat?
    private let previewColorScheme: ColorScheme?
    private let onCopied: () -> Void
    @Default(.boringShelf) private var boringShelf
    @EnvironmentObject private var vm: BoringViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var filter: ClipboardFilter
    private let cardWidth: CGFloat = 168
    private let cardSpacing: CGFloat = 8
    @State private var copiedEntryID: UUID?
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var shelfBusyEntryID: UUID?
    @State private var cardHover = ClipboardCardHover()
    @State private var hoveredPreviewID: UUID?
    @State private var previewID: UUID?
    @State private var showPreviewTask: Task<Void, Never>?
    @State private var hidePreviewTask: Task<Void, Never>?

    @MainActor
    init(store: ClipboardHistoryStore? = nil, viewportHeight: CGFloat? = nil, previewColorScheme: ColorScheme? = nil,
         onCopied: @escaping () -> Void = {}) {
        let history = store ?? .shared
        self.store = history
        self._filter = State(initialValue: ClipboardFilter(rawValue: history.carouselFilter) ?? .all)
        self.viewportHeight = viewportHeight
        self.previewColorScheme = previewColorScheme
        self.onCopied = onCopied
    }

    private var visibleItems: [ClipboardHistoryEntry] {
        store.items.filter { filter.matches($0) }
    }

    private var canClearHistory: Bool {
        if !store.items.isEmpty { return true }
        if case .degraded = store.persistenceStatus { return true }
        return false
    }

    private var statusText: String? {
        if let notice = store.notice, notice.style == .error { return notice.text }
        if !store.isRecordingEnabled { return "设置中已关闭记录" }
        switch store.persistenceStatus {
        case .unavailable: return "本机保存不可用"
        case .degraded(let message): return message
        case .ready: return nil
        }
    }

    var body: some View {
        let items = visibleItems
        VStack(spacing: 4) {
            header
            content(items)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 2)
        .frame(minHeight: viewportHeight, alignment: .top)
        .background { clearSelectionSurface }
        .task(id: store.notice?.id) {
            await store.dismissInfoNotice(after: 2.5)
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
            vm.clipboardPendingSelectionID = nil
            cancelHoverPreview()
        }
        .onChange(of: filter) { _, current in
            store.carouselFilter = current.rawValue
            cancelHoverPreview()
        }
        .onChange(of: items.map(\.id)) { _, ids in
            if let previewID, !ids.contains(previewID) { cancelHoverPreview() }
        }
        .onChange(of: vm.notchState) { _, state in
            if state == .closed { cancelHoverPreview() }
        }
        .onChange(of: vm.systemIslandPresentationActive) { _, active in
            if active {
                vm.clipboardPendingSelectionID = nil
                cancelHoverPreview()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("剪贴板")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .sharedGlassForeground()

            Text("\(store.items.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.07)))

            if store.isPaused {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("记录已暂停")
            }

            Spacer(minLength: 6)

            filterMenu
            moreMenu
        }
        .frame(height: 21)
    }

    private var filterMenu: some View {
        Menu {
            ForEach(ClipboardFilter.allCases) { option in
                Button {
                    filter = option
                } label: {
                    Label(
                        option.title,
                        systemImage: filter == option ? "checkmark" : option.systemImage
                    )
                }
                .help("只看\(option.title)")
                .accessibilityLabel("只看\(option.title)")
            }
        } label: {
            menuCapsule("line.3.horizontal.decrease")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("筛选剪贴板分类")
        .accessibilityLabel("筛选剪贴板分类")
        .accessibilityValue(filter.title)
    }

    private var moreMenu: some View {
        Menu {
            if let statusText { Text(statusText) }
            Button {
                if store.isPaused {
                    store.resume()
                } else {
                    store.pause()
                }
            } label: {
                Label(
                    store.isPaused ? "恢复记录" : "暂停记录",
                    systemImage: store.isPaused ? "play.circle" : "pause.circle"
                )
            }
            .disabled(!store.isRecordingEnabled)
            .help(store.isPaused ? "恢复记录剪贴板" : "暂停记录剪贴板")
            .accessibilityLabel(store.isPaused ? "恢复记录" : "暂停记录")

            Divider()

            if store.items.contains(where: \.isPinned) {
                Button(role: .destructive) {
                    store.clearUnpinned()
                } label: {
                    Label("清理未固定项", systemImage: "trash")
                }
                .disabled(!store.canManagePins || store.items.allSatisfy(\.isPinned))
            }

            Button(role: .destructive) {
                store.clear()
            } label: {
                Label("清空全部历史", systemImage: "trash")
            }
            .disabled(!canClearHistory)
            .help("清空剪贴板历史，不影响系统剪贴板")
            .accessibilityLabel("清空全部历史")
        } label: {
            menuCapsule("ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多剪贴板操作")
        .accessibilityLabel("更多剪贴板操作")
    }

    private func menuCapsule(_ systemName: String) -> some View {
        ZStack {
            NotchControlSurface(shape: Capsule())
                .frame(width: 32, height: 22)
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
        }
        .frame(width: 32, height: 26)
        .contentShape(Rectangle())
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ items: [ClipboardHistoryEntry]) -> some View {
        if items.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: cardSpacing) {
                        ForEach(items) { entry in
                            card(for: entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 1)
                    .background(ClipboardWheelScrollBridge(
                        savedOffset: { [category = filter.rawValue] in savedOffset(for: items, category: category) },
                        onOffsetChanged: { [category = filter.rawValue] offset in
                            rememberOffset(offset, in: items, category: category)
                        },
                        onScrollingChanged: cardScrollingChanged
                    ))
                    .background { clearSelectionSurface }
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .frame(height: 56)
                .reservesHorizontalNotchScrolling()
                .onChange(of: copiedEntryID) { _, id in
                    guard let id, previewID != id else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .leading)
                    }
                }
            }
            .id(filter)
        }
    }

    private var cardStride: CGFloat { cardWidth + cardSpacing }

    private func savedOffset(for items: [ClipboardHistoryEntry], category: String) -> CGFloat {
        guard let saved = store.carouselPositions[category] else { return 0 }
        guard let index = items.firstIndex(where: { $0.id == saved.entryID }) else { return saved.offset }
        return CGFloat(index) * cardStride + saved.inset
    }

    private func rememberOffset(_ offset: CGFloat, in items: [ClipboardHistoryEntry], category: String) {
        guard offset.isFinite, offset >= 0, !items.isEmpty else { return }
        let index = Int(min(offset / cardStride, CGFloat(items.count - 1)))
        store.carouselPositions[category] = (items[index].id, offset - CGFloat(index) * cardStride, offset)
    }

    private var emptyMessage: String {
        if filter == .pinned { return "右键点击条目即可固定" }
        if store.isPaused { return "记录已暂停" }
        if !store.items.isEmpty { return "此分类暂无内容" }
        return "复制文字、图片或文件后会出现在这里"
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: store.isPaused ? "pause.circle" : "doc.on.clipboard")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text(emptyMessage)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(emptyMessage)
    }

    private func card(for entry: ClipboardHistoryEntry) -> some View {
        Button {
            copyCard(entry, whole: NSEvent.modifierFlags.contains(.option))
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                preview(for: entry)
                    .frame(width: 152, height: 31, alignment: .topLeading)
                    .clipped()

                HStack(spacing: 4) {
                    Text(entry.kindLabel)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.85))
                        .sharedGlassForeground()
                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 2)
                    if copiedEntryID == entry.id {
                        Label("已复制", systemImage: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.primary)
                            .transition(.opacity)
                    } else if store.hasSelectedText(entry) {
                        Label("已选", systemImage: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    if shelfBusyEntryID == entry.id {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                            .frame(width: 10, height: 10)
                    }
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(width: cardWidth, height: 56, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(previewID == entry.id ? 0.11 : 0.052))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(previewID == entry.id ? 0.24 : 0.10), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: previewID == entry.id)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: copiedEntryID == entry.id)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(NotchControlStyle())
        .overlay {
            ClipboardCardDragSource(
                onClick: { copyCard(entry, whole: $0) },
                prepareDrag: { whole in
                    guard let payload = store.dragPayload(for: entry, whole: whole) else {
                        store.report("无法拖出此条剪贴板内容", isError: true)
                        return nil
                    }
                    vm.clipboardPendingSelectionID = nil
                    cancelHoverPreview()
                    let renderer = ImageRenderer(content: ClipboardDragGhost(entry: entry, item: payload.items[0]))
                    renderer.scale = 2
                    return ClipboardCardDragSource.Payload(items: payload.items, lease: payload.lease,
                                                           preview: renderer.nsImage)
                },
                onDrop: { store.markUsed(entry) },
                preview: previewID == entry.id ? hoverPreview(for: entry) : nil,
                animatesPreview: !reduceMotion,
                onPreviewClosed: { closePreview(entry.id) }
            )
            .accessibilityHidden(true)
        }
        .onHover { inside in hoverCard(entry.id, inside: inside) }
        .onDisappear {
            if cardHover.id == entry.id { hoverCard(entry.id, inside: false) }
            if previewID == entry.id { closePreview(entry.id) }
        }
        .contextMenu {
            Button {
                store.togglePin(entry)
            } label: {
                Label(entry.isPinned ? "取消固定" : "固定此条",
                      systemImage: entry.isPinned ? "pin.slash" : "pin")
            }
            .disabled(!store.canManagePins)

            if boringShelf {
                Button {
                    addToShelf(entry)
                } label: {
                    Label("加入文件架", systemImage: "tray.and.arrow.down")
                }
                .disabled(shelfBusyEntryID != nil)
                .help("把此条加入文件架")
                .accessibilityLabel("加入文件架")
            }
            Button(role: .destructive) {
                store.remove(entry)
            } label: {
                Label("删除此条", systemImage: "trash")
            }
            .help("从历史中删除此条")
            .accessibilityLabel("删除此条")
        }
        .help(store.hasSelectedText(entry) ? "点击复制选中文字；按住 ⌥ 可复制或拖出整段" : "点击复制，按住拖到其他应用")
        .accessibilityLabel("\(entry.kindLabel)：\(entry.title)")
        .accessibilityValue(entry.isPinned ? "已固定" : "")
        .accessibilityHint(store.hasSelectedText(entry) ? "点击复制选中文字" : "点击复制整条")
    }

    private func hoverPreview(for entry: ClipboardHistoryEntry) -> some View {
        ClipboardExpandedPreview(entry: entry, selection: store.textSelection(for: entry),
                                 onCopy: { copy(entry) }, onSelect: { range, toggles in
            if let pending = vm.clipboardPendingSelectionID, pending != entry.id {
                store.clearTextSelection(id: pending)
            }
            store.selectText(from: entry, range: range, toggles: toggles)
            vm.clipboardPendingSelectionID = store.hasSelectedText(entry) ? entry.id : nil
        }, onClearSelection: clearSelection)
            .environment(\.colorScheme, previewColorScheme ?? colorScheme)
            .preferredColorScheme(previewColorScheme)
            .onHover { inside in
                guard previewID == entry.id else { return }
                hoveredPreviewID = inside ? entry.id : nil
                if inside { hidePreviewTask?.cancel() }
                else { schedulePreviewClose(entry.id) }
            }
    }

    private var clearSelectionSurface: some View {
        Rectangle().fill(.clear).contentShape(Rectangle())
            .onTapGesture { clearSelection() }
            .accessibilityHidden(true)
    }

    private func clearSelection() {
        vm.clipboardPendingSelectionID = nil
        store.clearTextSelections()
    }

    private func hoverCard(_ id: UUID, inside: Bool) {
        if inside { cardHover.id = id }
        else if cardHover.id == id { cardHover.id = nil }
        guard !cardHover.scrolling else { return }
        if inside {
            hidePreviewTask?.cancel()
            showPreviewTask?.cancel()
            if let previewID, previewID != id { closePreview(previewID) }
            guard previewID != id else { return }
            showPreviewTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(170))
                guard !Task.isCancelled, cardHover.id == id, !cardHover.scrolling,
                      vm.notchState == .open, !vm.systemIslandPresentationActive,
                      NSEvent.pressedMouseButtons == 0 else { return }
                vm.isClipboardPreviewActive = true
                previewID = id
            }
        } else {
            if cardHover.id == nil { showPreviewTask?.cancel() }
            if previewID == id { schedulePreviewClose(id) }
        }
    }

    private func cardScrollingChanged(_ scrolling: Bool) {
        cardHover.scrolling = scrolling
        if scrolling {
            showPreviewTask?.cancel()
            hidePreviewTask?.cancel()
            if let previewID { closePreview(previewID) }
        } else if let id = cardHover.id {
            hoverCard(id, inside: true)
        }
    }

    private func schedulePreviewClose(_ id: UUID) {
        hidePreviewTask?.cancel()
        hidePreviewTask = Task { @MainActor in
            // Leave enough time to move from the card across the popover tip.
            try? await Task.sleep(for: .milliseconds(250))
            while !Task.isCancelled, NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(80))
            }
            guard !Task.isCancelled, cardHover.id != id, hoveredPreviewID != id else { return }
            closePreview(id)
        }
    }

    private func closePreview(_ id: UUID) {
        guard previewID == id else { return }
        previewID = nil
        hoveredPreviewID = nil
        vm.isClipboardPreviewActive = false
    }

    private func cancelHoverPreview() {
        showPreviewTask?.cancel()
        hidePreviewTask?.cancel()
        cardHover.id = nil
        if let previewID { closePreview(previewID) }
    }

    @ViewBuilder
    private func preview(for entry: ClipboardHistoryEntry) -> some View {
        switch entry.kind {
        case .text:
            Text(entry.previewText).notchReadableText()
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .image:
            if let thumbnail = entry.thumbnailData, let image = NSImage(data: thumbnail) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .files:
            let names = entry.fileDisplayNames
            HStack(alignment: .center, spacing: 4) {
                Image(systemName: names.count > 1 ? "doc.on.doc" : "doc")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(.secondary)
                ForEach(Array(names.prefix(1).enumerated()), id: \.offset) { _, name in
                    Text(name).notchReadableText()
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if names.count > 1 {
                    Text("等 \(names.count) 个文件")
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func copyCard(_ entry: ClipboardHistoryEntry, whole: Bool) {
        guard store.copyFromCard(entry, whole: whole) else { return }
        vm.clipboardPendingSelectionID = nil
        if previewID == entry.id { closePreview(entry.id) }
        showCopyFeedback(entry.id)
    }

    @discardableResult
    private func copy(_ entry: ClipboardHistoryEntry) -> Bool {
        guard store.copy(entry) else { return false }
        vm.clipboardPendingSelectionID = nil
        if previewID == entry.id { closePreview(entry.id) }
        showCopyFeedback(entry.id)
        return true
    }

    private func showCopyFeedback(_ id: UUID) {
        onCopied()
        copyFeedbackTask?.cancel()
        copiedEntryID = id
        copyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, copiedEntryID == id else { return }
            copiedEntryID = nil
        }
    }

    private func addToShelf(_ entry: ClipboardHistoryEntry) {
        guard boringShelf, shelfBusyEntryID == nil else { return }

        let providers = store.itemProviders(for: entry)
        guard !providers.isEmpty else {
            store.report("加入文件架失败", isError: true)
            return
        }

        shelfBusyEntryID = entry.id
        ShelfStateViewModel.shared.beginLoading()

        // Restored file entries carry sandbox bookmarks; keep the scope alive
        // until the async shelf copy has actually finished reading.
        let lease = store.fileAccessLease(for: entry)

        Task { @MainActor in
            defer {
                lease?.release()
                ShelfStateViewModel.shared.endLoading()
                shelfBusyEntryID = nil
            }

            let shelfItems = await ShelfDropService.items(from: providers)
            guard !shelfItems.isEmpty else {
                store.report("加入文件架失败", isError: true)
                return
            }

            ShelfStateViewModel.shared.add(shelfItems)
            if shelfItems.count < providers.count {
                store.report("已加入 \(shelfItems.count)/\(providers.count) 项到文件架")
            } else {
                store.report("已加入文件架")
            }
        }
    }
}

private struct ClipboardDragGhost: View {
    let entry: ClipboardHistoryEntry
    let item: NSPasteboardItem

    var body: some View {
        switch entry.kind {
        case .text:
            Text(verbatim: String((item.string(forType: .string) ?? "").prefix(240)))
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(3)
                .frame(maxWidth: 228, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                .padding(5)
        case .image(let content):
            if let image = NSImage(data: content.thumbnailData ?? content.pngData) {
                let scale = min(112 / image.size.width, 80 / image.size.height, 1)
                Image(nsImage: image)
                    .resizable()
                    .frame(width: image.size.width * scale, height: image.size.height * scale)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .opacity(0.88)
                    .shadow(color: .black.opacity(0.32), radius: 4, y: 2)
                    .padding(5)
            }
        case .files:
            DragPreviewView(thumbnail: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil),
                            displayName: entry.title)
        }
    }
}

/// Like the Shelf's AppKit drag source, this supports multiple drag items and
/// holds file scopes through the drop. Only left presses inside the card are
/// claimed, leaving scrolling, hover and the SwiftUI context menu alone.
private struct ClipboardCardDragSource<Preview: View>: NSViewRepresentable {
    struct Payload {
        let items: [NSPasteboardItem]
        let lease: ClipboardFileAccessLease?
        let preview: NSImage?
    }

    let onClick: (Bool) -> Void
    let prepareDrag: (Bool) -> Payload?
    let onDrop: () -> Void
    let preview: Preview?
    let animatesPreview: Bool
    let onPreviewClosed: () -> Void

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.onClick = onClick
        view.prepareDrag = prepareDrag
        view.onDrop = onDrop
        view.onPreviewClosed = onPreviewClosed
        view.updatePreview(preview, animates: animatesPreview)
    }

    static func dismantleNSView(_ view: DragView, coordinator: ()) {
        view.updatePreview(nil, animates: false)
    }

    final class DragView: NSView, NSDraggingSource, NSPopoverDelegate {
        var onClick: ((Bool) -> Void)?
        var prepareDrag: ((Bool) -> Payload?)?
        var onDrop: (() -> Void)?
        var onPreviewClosed: (() -> Void)?
        private var hoverPopover: NSPopover?
        private var pressPoint: NSPoint?
        private var lease: ClipboardFileAccessLease?
        private var completeDrop: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            if let event = NSApp.currentEvent,
               event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
                return nil // Let the card's SwiftUI context menu handle this press.
            }
            return super.hitTest(point)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        func updatePreview(_ preview: Preview?, animates: Bool) {
            guard let preview else {
                let previous = hoverPopover
                hoverPopover = nil
                previous?.animates = animates
                previous?.close()
                return
            }
            if let host = hoverPopover?.contentViewController as? NSHostingController<Preview> {
                host.rootView = preview
                return
            }

            let host = NSHostingController(rootView: preview)
            host.sizingOptions = []
            let popover = NSPopover()
            // SwiftUI's automatically dismissed popover can consume the
            // initial press on the card. The hover timer already owns dismissal.
            popover.behavior = .applicationDefined
            popover.animates = animates
            popover.contentViewController = host
            popover.delegate = self
            hoverPopover = popover
            DispatchQueue.main.async { [weak self, weak popover] in
                guard let self, let popover, self.hoverPopover === popover, self.window != nil else { return }
                popover.contentSize = host.sizeThatFits(in: CGSize(width: 368, height: 440))
                popover.show(relativeTo: self.bounds, of: self, preferredEdge: .minY)
            }
        }

        func popoverDidClose(_ notification: Notification) {
            guard let closed = notification.object as? NSPopover, hoverPopover === closed else { return }
            hoverPopover = nil
            onPreviewClosed?()
        }

        override func mouseDown(with event: NSEvent) {
            pressPoint = event.locationInWindow
        }

        override func mouseUp(with event: NSEvent) {
            let wasPressed = pressPoint != nil
            pressPoint = nil
            if wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) {
                onClick?(event.modifierFlags.contains(.option))
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let pressPoint else { return }
            let location = event.locationInWindow
            guard hypot(location.x - pressPoint.x, location.y - pressPoint.y) >= 5 else { return }
            self.pressPoint = nil
            guard let payload = prepareDrag?(event.modifierFlags.contains(.option)) else { return }
            lease = payload.lease
            completeDrop = onDrop
            let pointer = convert(location, from: nil)
            let itemSize = payload.preview?.size ?? NSSize(width: 60, height: 40)
            let frame = NSRect(x: pointer.x + 8, y: pointer.y - itemSize.height - 6,
                               width: itemSize.width, height: itemSize.height)
            let dragItems = payload.items.enumerated().map { index, writer in
                let item = NSDraggingItem(pasteboardWriter: writer)
                item.setDraggingFrame(frame.offsetBy(dx: CGFloat(min(index, 3)) * 4, dy: 0),
                                      contents: payload.preview)
                return item
            }
            ShelfSelectionModel.shared.beginDrag()
            beginDraggingSession(with: dragItems, event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            lease?.release()
            lease = nil
            ShelfSelectionModel.shared.endDrag()
            (window as? BoringNotchSkyLightWindow)?.refreshMouseRouting()
            if operation.contains(.copy) { completeDrop?() }
            completeDrop = nil
        }
    }
}

enum NotchPreviewPaper {
    static func color(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.087, green: 0.102, blue: 0.132)
            : Color(red: 0.973, green: 0.978, blue: 0.988)
    }
}

private struct ClipboardExpandedPreview: View {
    let entry: ClipboardHistoryEntry
    let selection: [NSRange]
    let onCopy: () -> Bool
    let onSelect: (NSRange, Bool) -> Void
    let onClearSelection: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var presented = false
    @State private var copyFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.primary.opacity(0.07), in: .rect(cornerRadius: 7))
                    .accessibilityHidden(true)
                Text(entry.kindLabel).font(.caption.weight(.semibold))
                Spacer()
                if case .text = entry.kind {
                    Label(selection.isEmpty ? "点选或拖选" : "离开后复制",
                          systemImage: selection.isEmpty ? "cursorarrow" : "checkmark")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(selection.isEmpty ? Color.secondary : Color.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.primary.opacity(selection.isEmpty ? 0.045 : 0.10), in: Capsule())
                }
            }
            .padding(.bottom, 2)
            if copyFailed {
                Text("复制失败，内容可能已不可用")
                    .font(.caption).foregroundStyle(.red)
            }
            switch entry.kind {
            case .text(let data):
                ClipboardSelectableText(text: data.text, selection: selection,
                                        select: onSelect, clear: onClearSelection)
                    .accessibilityHint("点选词语或拖选一段；离开灵动岛后复制，点空白处清除")
            case .image(let data):
                if let image = NSImage(data: data.pngData) {
                    copyTarget {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 340, maxHeight: 270)
                            .clipShape(.rect(cornerRadius: 8))
                            .accessibilityLabel(entry.title)
                    }
                }
                Text(entry.title).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            case .files:
                readable {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(entry.fileDisplayNames.enumerated()), id: \.offset) { _, name in
                            copyTarget {
                                Label {
                                    Text(verbatim: name)
                                        .fixedSize(horizontal: false, vertical: true)
                                } icon: {
                                    Image(systemName: "doc").foregroundStyle(.secondary)
                                }
                                .font(.system(size: 13))
                            }
                            .accessibilityHint("复制此条中的所有文件")
                        }
                    }
                }
            }
        }
        .frame(width: 340, alignment: .leading)
        .padding(14)
        .background {
            if case .text = entry.kind {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { onClearSelection() }
                    .accessibilityHidden(true)
            }
        }
        .background(NotchPreviewPaper.color(for: colorScheme))
        .scaleEffect(reduceMotion || presented ? 1 : 0.95, anchor: .top)
        .offset(y: reduceMotion || presented ? 0 : -4)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.23, dampingFraction: 0.82)) {
                presented = true
            }
        }
        .accessibilityLabel("剪贴板预览")
    }

    private func copy() { copyFailed = !onCopy() }

    private func copyTarget<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Button(action: copy) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点击复制此条")
    }

    private var icon: String {
        switch entry.kind {
        case .text: "text.alignleft"
        case .image: "photo"
        case .files: "doc.on.doc"
        }
    }

    private func readable<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let payload = content()
        return ViewThatFits(in: .vertical) {
            payload.fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) { payload }
                .scrollIndicators(.never)
        }
        .frame(maxHeight: 240, alignment: .topLeading)
    }
}

// === CLIPBOARD_SELECTION_BEGIN ===
/// Work in UTF-16 so ranges can be passed directly to AppKit.
struct ClipboardTextTokens {
    let text: String
    private static let links = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let email = try? NSRegularExpression(
        pattern: #"(?i)[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)+"#
    )

    private static let compound = try? NSRegularExpression(
        pattern: #"[A-Za-z0-9]+(?:[-_.][A-Za-z0-9]+)+"#
    )
    private static let terminalMarks = CharacterSet(charactersIn: ",:;!?，。；：！？、")

    func blocks(in visible: NSRange) -> [NSRange] {
        let string = text as NSString
        guard visible.length > 0, NSMaxRange(visible) <= string.length else { return [] }
        // Extremely long single-line clips must not force tokenization of the whole line.
        let line = string.lineRange(for: visible)
        let lower = max(line.location, visible.location - min(512, visible.location - line.location))
        let upper = min(NSMaxRange(line), NSMaxRange(visible) + 512)
        let scope = string.rangeOfComposedCharacterSequences(for: NSRange(location: lower, length: upper - lower))
        let atomicRanges = [Self.links as NSRegularExpression?, Self.email, Self.compound].compactMap { $0 }.reduce(into: [NSRange]()) { ranges, matcher in
            for match in matcher.matches(in: text, range: scope)
                where !ranges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                ranges.append(match.range)
            }
        }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        guard let range = Range(scope, in: text) else { return atomicRanges }
        let words = tokenizer.tokens(for: range).map { NSRange($0, in: text) }
            .filter { word in !atomicRanges.contains { NSIntersectionRange($0, word).length > 0 } }
            .map { word in
                let end = NSMaxRange(word)
                if end < NSMaxRange(scope) {
                    let next = string.rangeOfComposedCharacterSequence(at: end)
                    let mark = string.substring(with: next)
                    if mark.unicodeScalars.allSatisfy(Self.terminalMarks.contains) {
                        return NSUnionRange(word, next)
                    }
                }
                return word
            }
        return (atomicRanges + words).filter { NSIntersectionRange($0, visible).length > 0 }
            .sorted { $0.location < $1.location }
    }

    func token(at offset: Int) -> NSRange? {
        let string = text as NSString
        guard offset >= 0, offset < string.length else { return nil }
        let cluster = string.rangeOfComposedCharacterSequence(at: offset)
        guard !string.substring(with: cluster).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return blocks(in: string.lineRange(for: cluster)).first { NSLocationInRange(offset, $0) } ?? cluster
    }

    func expanding(_ range: NSRange) -> NSRange? {
        let count = (text as NSString).length
        guard range.location >= 0, range.location < count, range.length > 0,
              range.length <= count - range.location else { return nil }
        let first = token(at: range.location)
        let last = token(at: NSMaxRange(range) - 1)
        let start = min(range.location, first?.location ?? range.location)
        let end = max(NSMaxRange(range), last.map(NSMaxRange) ?? NSMaxRange(range))
        return NSRange(location: start, length: end - start)
    }
}
// === CLIPBOARD_SELECTION_END ===

/// TextKit provides native drag selection and keeps character hit testing
/// aligned with wrapping, bidirectional text and different display scales.
private struct ClipboardSelectableText: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let selection: [NSRange]
    let select: (NSRange, Bool) -> Void
    let clear: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let view = WordPicker(frame: .zero)
        view.drawsBackground = false
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.isAutomaticLinkDetectionEnabled = false
        view.font = .systemFont(ofSize: 13)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 6, height: 4)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.setAccessibilityLabel("剪贴板可选文字")
        view.toolTip = "点选或拖选；离开灵动岛后复制"
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? WordPicker else { return }
        let dark = colorScheme == .dark
        if view.string != text || view.darkPalette != dark { view.installTokenText(text, dark: dark) }
        view.pending = selection
        view.selectRange = select
        view.clearSelection = clear
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: 240)
    }

    final class WordPicker: NSTextView {
        var selectRange: ((NSRange, Bool) -> Void)?
        var clearSelection: (() -> Void)?
        var pending: [NSRange] = [] {
            didSet { if oldValue != pending { needsDisplay = true } }
        }
        private var rollover: NSRange? {
            didSet { if oldValue != rollover { needsDisplay = true } }
        }
        private var pointerTracking: NSTrackingArea?
        private(set) var darkPalette = false
        private var cachedScope: NSRange?
        private var cachedBlocks: [NSRange] = []

        override var string: String {
            didSet {
                cachedScope = nil
                rollover = nil
            }
        }

        fileprivate func installTokenText(_ original: String, dark: Bool) {
            darkPalette = dark
            appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            paragraph.minimumLineHeight = 20
            let styled = NSMutableAttributedString(string: original, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: dark
                    ? NSColor(srgbRed: 0.91, green: 0.93, blue: 0.97, alpha: 1)
                    : NSColor(srgbRed: 0.12, green: 0.16, blue: 0.22, alpha: 1),
                .paragraphStyle: paragraph
            ])
            let source = original as NSString
            // Space neighboring tokens without inserting characters into
            // the string. Long previews still use the same block gutters;
            // avoid an eager full-text token pass for very large clips.
            if source.length <= 24_000, source.length > 0 {
                let tokens = ClipboardTextTokens(text: original)
                    .blocks(in: NSRange(location: 0, length: source.length))
                styled.beginEditing()
                for token in tokens where NSMaxRange(token) < source.length {
                    let end = NSMaxRange(token)
                    let next = source.rangeOfComposedCharacterSequence(at: end)
                    if source.substring(with: next).rangeOfCharacter(from: .newlines) != nil { continue }
                    styled.addAttribute(.kern, value: 6.5,
                                        range: source.rangeOfComposedCharacterSequence(at: end - 1))
                }
                styled.endEditing()
            }
            cachedScope = nil
            rollover = nil
            textStorage?.setAttributedString(styled)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let pointerTracking { removeTrackingArea(pointerTracking) }
            let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            pointerTracking = area
        }

        override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
        override func mouseExited(with event: NSEvent) { rollover = nil }
        override func mouseMoved(with event: NSEvent) {
            let index = character(at: convert(event.locationInWindow, from: nil))
            rollover = index.flatMap { offset in cachedBlocks.first { NSLocationInRange(offset, $0) } }
        }

        override func mouseDown(with event: NSEvent) {
            let tokens = ClipboardTextTokens(text: string)
            let clicked = character(at: convert(event.locationInWindow, from: nil))
            setSelectedRange(NSRange(location: clicked ?? 0, length: 0))
            super.mouseDown(with: event) // TextKit tracks the drag and wraps lines.
            let native = selectedRange()
            if native.length > 0, event.clickCount == 1, let range = tokens.expanding(native) {
                selectRange?(range, false)
            } else if let clicked, let range = tokens.token(at: clicked) {
                selectRange?(range, true)
            } else {
                clearSelection?()
            }
            setSelectedRange(NSRange(location: native.location, length: 0))
        }

        override func copy(_ sender: Any?) {
            if let range = ClipboardTextTokens(text: string).expanding(selectedRange()) {
                selectRange?(range, false)
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            // The view has no opaque background, so TextKit draws glyphs and
            // its native drag highlight over these per-token blocks.
            defer { super.draw(dirtyRect) }
            guard let layoutManager, let textContainer, !string.isEmpty else { return }
            let origin = textContainerOrigin
            let visible = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
            let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
            guard glyphs.length > 0 else { return }
            let scope = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            if cachedScope != scope {
                cachedBlocks = ClipboardTextTokens(text: string).blocks(in: scope)
                cachedScope = scope
            }
            let resting: NSColor = darkPalette ? .white.withAlphaComponent(0.08) : .black.withAlphaComponent(0.058)
            let hover = NSColor.systemBlue.withAlphaComponent(darkPalette ? 0.25 : 0.12)
            let selectedFill = NSColor.systemBlue.withAlphaComponent(darkPalette ? 0.38 : 0.23)
            let selectedOutline = NSColor.systemBlue.withAlphaComponent(darkPalette ? 0.65 : 0.43)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            for token in cachedBlocks {
                let selected = pending.contains { NSIntersectionRange($0, token).length > 0 }
                let glyphRange = layoutManager.glyphRange(forCharacterRange: token, actualCharacterRange: nil)
                guard glyphRange.length > 0 else { continue }
                let finalLine = layoutManager.lineFragmentRect(forGlyphAt: NSMaxRange(glyphRange) - 1, effectiveRange: nil)
                let hasGutter = textStorage?.attribute(.kern, at: NSMaxRange(token) - 1, effectiveRange: nil) != nil
                let usePadding = (string as NSString).length <= 24_000
                layoutManager.enumerateEnclosingRects(forGlyphRange: glyphRange,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
                    let height = min(19, max(0, rect.height))
                    let leading = usePadding ? -2.0 : 0.75
                    // TextKit includes the trailing kern in its selection rect.
                    let trailing = usePadding ? (hasGutter && finalLine.intersects(rect) ? -4.25 : 2.0) : -0.75
                    let block = CGRect(x: rect.minX + origin.x + leading, y: rect.midY + origin.y - height * 0.5,
                                       width: rect.width + trailing - leading, height: height)
                    guard block.width > 0, block.height > 0 else { return }
                    let chip = NSBezierPath(roundedRect: block, xRadius: 5, yRadius: 5)
                    (selected ? selectedFill : token == self.rollover ? hover : resting).setFill()
                    chip.fill()
                    if selected {
                        selectedOutline.setStroke()
                        chip.lineWidth = 0.7
                        chip.stroke()
                    }
                }
            }
        }

        private func character(at point: NSPoint) -> Int? {
            guard let layoutManager, let textContainer, !string.isEmpty else { return nil }
            let pointInText = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            let glyph = layoutManager.glyphIndex(for: pointInText, in: textContainer)
            guard glyph < layoutManager.numberOfGlyphs,
                  layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                             in: textContainer).contains(pointInText) else { return nil }
            return layoutManager.characterIndexForGlyph(at: glyph)
        }
    }
}

#Preview {
    ClipboardHistoryView()
        .environmentObject(BoringViewModel())
        .frame(width: 640, height: 150)
        .padding()
        .background(Color.black)
}


/// Uses AppKit's scroll position and clipping; never copies or changes selection.
enum ClipboardWheelNavigation {
    static func targetX(current: CGFloat, deltaY: CGFloat, precise: Bool,
                        minimum: CGFloat, maximum: CGFloat) -> CGFloat? {
        guard current.isFinite, deltaY.isFinite, minimum.isFinite, maximum.isFinite,
              maximum > minimum, deltaY != 0 else { return nil }
        let delta = precise ? deltaY : min(80, max(-80, deltaY * 12))
        return min(maximum, max(minimum, current - delta))
    }
}

private struct ClipboardWheelScrollBridge: NSViewRepresentable {
    let savedOffset: () -> CGFloat
    let onOffsetChanged: (CGFloat) -> Void
    let onScrollingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> WheelView { WheelView() }
    func updateNSView(_ nsView: WheelView, context: Context) {
        nsView.savedOffset = savedOffset
        nsView.onOffsetChanged = onOffsetChanged
        nsView.onScrollingChanged = onScrollingChanged
        nsView.preparePositionTracking()
    }
    static func dismantleNSView(_ nsView: WheelView, coordinator: ()) { nsView.stop() }

    final class WheelView: NSView {
        var savedOffset: (() -> CGFloat)?
        var onOffsetChanged: ((CGFloat) -> Void)?
        var onScrollingChanged: ((Bool) -> Void)?
        private var monitor: Any?
        private var idleTimer: Timer?
        private weak var observedClip: NSClipView?
        private var positionTrackingQueued = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            preparePositionTracking()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      NotchScrollHitRegion.contains(eventWindow: event.window, locationInWindow: event.locationInWindow, in: self),
                      let scroll = self.enclosingScrollView,
                      let document = scroll.documentView else { return event }
                let clip = scroll.contentView
                guard clip.bounds.contains(clip.convert(event.locationInWindow, from: nil)) else { return event }

                // Leave the full trackpad stroke, including its momentum, to AppKit.
                if event.hasPreciseScrollingDeltas {
                    if abs(event.scrollingDeltaX) > 0.2 { self.markScrolling() }
                    return event
                }
                guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                      let target = ClipboardWheelNavigation.targetX(
                        current: clip.bounds.minX, deltaY: event.scrollingDeltaY,
                        precise: false,
                        minimum: document.bounds.minX,
                        maximum: document.bounds.maxX - clip.bounds.width
                      ) else { return event }
                if target != clip.bounds.minX {
                    self.markScrolling()
                    clip.scroll(to: NSPoint(x: target, y: clip.bounds.minY))
                    scroll.reflectScrolledClipView(clip)
                }
                return nil
            }
        }
        override func layout() {
            super.layout()
            preparePositionTracking()
        }

        func preparePositionTracking() {
            guard window != nil, observedClip == nil, !positionTrackingQueued else { return }
            positionTrackingQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.positionTrackingQueued = false
                guard self.window != nil, self.observedClip == nil,
                      let scroll = self.enclosingScrollView, let document = scroll.documentView,
                      let savedOffset = self.savedOffset else { return }
                let clip = scroll.contentView
                guard clip.bounds.width > 0, document.bounds.width > 0 else { return }
                let start = document.bounds.minX
                let available = max(0, document.bounds.width - clip.bounds.width)
                let restoredX = start + min(max(savedOffset(), 0), available)
                if restoredX != clip.bounds.minX {
                    clip.scroll(to: NSPoint(x: restoredX, y: clip.bounds.minY))
                    scroll.reflectScrolledClipView(clip)
                }
                self.observedClip = clip
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(self.clipPositionChanged),
                    name: NSView.boundsDidChangeNotification, object: clip)
            }
        }

        @objc private func clipPositionChanged() {
            guard window != nil, let clip = observedClip, let document = enclosingScrollView?.documentView,
                  document.bounds.width > 0 else { return }
            let available = max(0, document.bounds.width - clip.bounds.width)
            let offset = min(available, max(0, clip.bounds.minX - document.bounds.minX))
            onOffsetChanged?(offset)
        }

        func stop() {
            if let clip = observedClip {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip)
            }
            observedClip = nil
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            finishScrolling()
        }

        private func markScrolling() {
            if let idleTimer {
                idleTimer.fireDate = Date(timeIntervalSinceNow: 0.16)
                return
            }
            let timer = Timer(timeInterval: 0.16, target: self, selector: #selector(finishScrolling),
                              userInfo: nil, repeats: false)
            idleTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            onScrollingChanged?(true)
        }

        @objc private func finishScrolling() {
            guard let idleTimer else { return }
            idleTimer.invalidate()
            self.idleTimer = nil
            onScrollingChanged?(false)
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
