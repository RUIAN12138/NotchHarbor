//
//  BoringNotchSkyLightWindow.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-20.
//

import Cocoa
import SkyLightWindow
import Defaults
import Combine
import SwiftUI

extension SkyLightOperator {
    func undelegateWindow(_ window: NSWindow) {
        typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32
        
        let handler = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        guard let SLSRemoveWindowsFromSpaces = unsafeBitCast(
            dlsym(handler, "SLSRemoveWindowsFromSpaces"),
            to: F_SLSRemoveWindowsFromSpaces?.self
        ) else {
            return
        }
        
        // Remove the window from the SkyLight space
        _ = SLSRemoveWindowsFromSpaces(
            connection,
            [window.windowNumber] as CFArray,
            [space] as CFArray
        )
    }
}

/// Hosting view that accepts the first click even while the panel is not key.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    weak var notchViewModel: BoringViewModel?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit passes the point in the superview's coordinates. Using the
        // hosting view's flipped coordinates can move a top click below the panel.
        let windowPoint = superview?.convert(point, to: nil) ?? point
        guard let model = notchViewModel, let window,
              model.acceptsWindowPointer(at: window.convertPoint(toScreen: windowPoint)) else { return nil }
        if let hit = super.hitTest(point) { return hit }
        return model.notchState == .open ? self : nil
    }
}

class BoringNotchSkyLightWindow: NSPanel, NSWindowDelegate {
    var keepsPhysicalNotchAnchor = false
    private var isSkyLightEnabled: Bool = false
    private var pendingDragClearTask: Task<Void, Never>?
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var pointerState: AnyCancellable?
    private var pressedInPanel = false
    private weak var agentReplyInput: NSTextField?
    weak var shelfViewModel: BoringViewModel?

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // The built-in notch straddles the menu bar's safe area, even when
        // this panel is layered below the system island.
        if keepsPhysicalNotchAnchor { return frameRect }
        return super.constrainFrameRect(frameRect, to: screen)
    }

    func setExternalFileDragActive(_ active: Bool) {
        // A new drag supersedes any pending deferred clear.
        pendingDragClearTask?.cancel()
        pendingDragClearTask = nil

        guard !active else {
            if let model = shelfViewModel, !model.externalFileDragActive,
               Defaults[.boringShelf], !ShelfSelectionModel.shared.isDragging {
                model.externalFileDragActive = true
            }
            refreshMouseRouting()
            return
        }

        // Only a release over the shelf can be followed by its drop callback.
        // Release desktop drops immediately so Finder owns the rest of the drag.
        guard let model = shelfViewModel, model.externalFileDragActive,
              model.shelfFileDropFrame(preparesExpansion: Defaults[.expandedDragDetection])
                .contains(NSEvent.mouseLocation) else {
            clearExternalFileDragActiveImmediately()
            return
        }
        pendingDragClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.clearExternalFileDragActiveImmediately()
        }
    }

    private func clearExternalFileDragActiveImmediately() {
        pendingDragClearTask?.cancel()
        pendingDragClearTask = nil
        if let model = shelfViewModel {
            if model.windowDropTargeting { model.windowDropTargeting = false }
            if model.externalFileDragActive { model.externalFileDragActive = false }
        }
        refreshMouseRouting()
    }

    // Window-level fallback for Finder files when no SwiftUI child claims the drag.
    func enableShelfFileDrops(for viewModel: BoringViewModel) {
        shelfViewModel = viewModel
        delegate = self
        registerForDraggedTypes(ShelfFileDrag.types)
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                            .leftMouseUp, .rightMouseUp, .otherMouseUp]
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            self?.refreshMouseRouting()
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.refreshMouseRouting()
            return event
        }
        pointerState = viewModel.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshMouseRouting()
        }
        refreshMouseRouting()
    }

    deinit {
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            pressedInPanel = true
        default: break
        }
        super.sendEvent(event)
        refreshMouseRouting()
    }

    func refreshMouseRouting() {
        guard let model = shelfViewModel else { return }
        if let input = agentReplyInput, model.notchState != .open || model.systemIslandPresentationActive {
            endAgentReplyEditing(input)
        }
        if NSEvent.pressedMouseButtons == 0 { pressedInPanel = false }
        let pressed = pressedInPanel && model.notchState == .open && !model.systemIslandPresentationActive
        if model.isPanelPointerPressed != pressed { model.isPanelPointerPressed = pressed }
        let point = NSEvent.mouseLocation
        let islandHover = model.acceptsIslandHover(at: point)
        if model.pointerWithinIslandHoverTrigger != islandHover { model.pointerWithinIslandHoverTrigger = islandHover }
        let inside = model.acceptsWindowPointer(at: point)
        if model.pointerWithinHitRegion != inside { model.pointerWithinHitRegion = inside }
        let shouldReceive = !model.systemIslandPresentationActive && (pressedInPanel || inside)
        if ignoresMouseEvents == shouldReceive { ignoresMouseEvents = !shouldReceive }
    }

    @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = draggingUpdated(sender)
        if !operation.isEmpty { setExternalFileDragActive(true) }
        return operation
    }

    @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let vm = shelfViewModel else { return [] }
        let operation = shelfFileDropOperation(sender, viewModel: vm)
        let accepted = !operation.isEmpty
        if vm.windowDropTargeting != accepted { vm.windowDropTargeting = accepted }
        return operation
    }

    @objc func draggingExited(_ sender: NSDraggingInfo?) {
        if shelfViewModel?.windowDropTargeting == true { shelfViewModel?.windowDropTargeting = false }
    }

    @objc func draggingEnded(_ sender: NSDraggingInfo) {
        clearExternalFileDragActiveImmediately()
    }

    @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let vm = shelfViewModel else { return false }
        defer { clearExternalFileDragActiveImmediately() }
        guard !shelfFileDropOperation(sender, viewModel: vm).isEmpty else { return false }
        let urls = ShelfFileDrag.fileURLs(from: sender.draggingPasteboard)
        let items = urls.compactMap { url -> ShelfItem? in
            guard let bookmark = try? Bookmark(url: url) else { return nil }
            return ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: false)
        }
        guard !items.isEmpty else { return false }
        vm.dropEvent = true
        BoringViewCoordinator.shared.currentView = .shelf
        if vm.notchState == .closed { vm.open() }
        ShelfStateViewModel.shared.add(items)
        return true
    }

    @objc func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let vm = shelfViewModel else { return false }
        return !shelfFileDropOperation(sender, viewModel: vm).isEmpty
    }

    private func shelfFileDropOperation(_ sender: NSDraggingInfo, viewModel vm: BoringViewModel) -> NSDragOperation {
        guard Defaults[.boringShelf], !ShelfSelectionModel.shared.isDragging,
              ShelfFileDrag.containsFiles(sender.draggingPasteboard),
              vm.shelfFileDropFrame(preparesExpansion: vm.externalFileDragActive && Defaults[.expandedDragDetection])
                .contains(convertPoint(toScreen: sender.draggingLocation)) else { return [] }
        return [.copy, .link, .generic].first { sender.draggingSourceOperationMask.contains($0) } ?? []
    }

    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )
        
        configureWindow()
        setupObservers()
    }
    
    private func configureWindow() {
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        ignoresMouseEvents = true
        level = .mainMenu + 3
        hasShadow = false
        isReleasedWhenClosed = false
        
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        
        // Apply initial sharing type setting
        updateSharingType()
    }
    
    private func setupObservers() {
        // Listen for changes to the hideFromScreenRecording setting
        Defaults.publisher(.hideFromScreenRecording)
            .sink { [weak self] _ in
                self?.updateSharingType()
            }
            .store(in: &observers)
    }
    
    private func updateSharingType() {
        if Defaults[.hideFromScreenRecording] {
            sharingType = .none
        } else {
            sharingType = .readWrite
        }
    }
    
    func enableSkyLight() {
        if let input = agentReplyInput { endAgentReplyEditing(input) }
        if !isSkyLightEnabled {
            SkyLightOperator.shared.delegateWindow(self)
            isSkyLightEnabled = true
        }
    }
    
    func disableSkyLight() {
        if isSkyLightEnabled {
            SkyLightOperator.shared.undelegateWindow(self)
            isSkyLightEnabled = false
        }
    }
    
    private var observers: Set<AnyCancellable> = []
    
    func beginAgentReplyEditing(_ input: NSTextField) -> Bool {
        guard shelfViewModel?.notchState == .open, !isSkyLightEnabled,
              shelfViewModel?.systemIslandPresentationActive != true else { return false }
        agentReplyInput = input
        if !isKeyWindow { makeKey() }
        guard isKeyWindow, makeFirstResponder(input) else {
            endAgentReplyEditing(input)
            return false
        }
        shelfViewModel?.isAgentReplyEditing = true
        return true
    }

    func endAgentReplyEditing(_ input: NSTextField) {
        guard agentReplyInput === input else { return }
        agentReplyInput = nil
        if let editor = input.currentEditor(), firstResponder === editor {
            makeFirstResponder(nil)
        }
        if isKeyWindow { resignKey() }
        shelfViewModel?.isAgentReplyEditing = false
    }

    func windowDidResignKey(_ notification: Notification) {
        let input = agentReplyInput
        agentReplyInput = nil
        if let editor = input?.currentEditor(), firstResponder === editor {
            makeFirstResponder(nil)
        }
        shelfViewModel?.isAgentReplyEditing = false
    }

    override var canBecomeKey: Bool { agentReplyInput != nil }
    override var canBecomeMain: Bool { false }
}
