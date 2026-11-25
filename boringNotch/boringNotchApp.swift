//
//  boringNotchApp.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//

import AVFoundation
import ApplicationServices
import Combine
import Defaults
import KeyboardShortcuts
import Sparkle
import SwiftUI

private enum SystemIslandAccessibility {
    struct Snapshot: Sendable { var expanded = false; var compactWidth: CGFloat?; var reservedWidth: CGFloat? }
    static func snapshot(on display: CGRect, notchHeight: CGFloat) -> Snapshot {
        guard AXIsProcessTrusted(),
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else {
            return Snapshot()
        }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.08)
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return Snapshot() }
        var result = Snapshot(reservedWidth: 0)
        var incomplete = false
        for window in windows where value(window, kAXIdentifierAttribute) as? String == "ax-center-hud-window" {
            guard let children = value(window, kAXChildrenAttribute) as? [AXUIElement] else {
                incomplete = true
                continue
            }
            for child in children {
                guard let origin = value(child, kAXPositionAttribute),
                      let size = value(child, kAXSizeAttribute),
                      CFGetTypeID(origin) == AXValueGetTypeID(),
                      CFGetTypeID(size) == AXValueGetTypeID() else {
                    incomplete = true
                    continue
                }
                var point = CGPoint.zero
                var dimensions = CGSize.zero
                if AXValueGetValue(origin as! AXValue, .cgPoint, &point),
                   AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
                   abs(point.y - display.minY) <= notchHeight + 12,
                   dimensions.width > 16, dimensions.width < display.width - 40, dimensions.height > 0 {
                    let centered = abs(point.x + dimensions.width / 2 - display.midX) < 80
                    if dimensions.height > notchHeight + 8 {
                        if centered { result.expanded = true }
                    } else {
                        let reserved = 2 * max(abs(point.x - display.midX), abs(point.x + dimensions.width - display.midX))
                        result.reservedWidth = max(result.reservedWidth ?? 0, reserved)
                        if centered, dimensions.width > 100 { result.compactWidth = max(result.compactWidth ?? 0, dimensions.width) }
                    }
                }
            }
        }
        if incomplete && result.reservedWidth == 0 { result.reservedWidth = nil }
        return result
    }

    /// Public WindowServer mouse-down hit testing needs no Accessibility or capture permission.
    /// Read only owner/geometry metadata; never synthesize an event or move the pointer.
    @MainActor static func hitTestSnapshot(on screen: NSScreen, ownWindow: Int) -> Snapshot {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else {
            return Snapshot(reservedWidth: 0)
        }
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let hudIDs = Set(rows.compactMap { row -> Int? in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == agent.processIdentifier,
                  let bounds = row[kCGWindowBounds as String] as? [String: NSNumber],
                  (bounds["Height"]?.doubleValue ?? 0) > screen.safeAreaInsets.top + 8 else { return nil }
            return (row[kCGWindowNumber as String] as? NSNumber)?.intValue
        })
        func nativeHit(_ point: NSPoint) -> Bool {
            var hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
            if hit == ownWindow { hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: ownWindow) }
            return hudIDs.contains(hit)
        }
        let height = max(24, screen.safeAreaInsets.top)
        let physical = screen.auxiliaryTopRightArea.flatMap { right in screen.auxiliaryTopLeftArea.map { right.minX - $0.maxX } } ?? 185
        let y = screen.frame.maxY - height / 2
        let compact = nativeHit(NSPoint(x: screen.frame.midX - physical / 2 - 17, y: y))
            || nativeHit(NSPoint(x: screen.frame.midX + physical / 2 + 17, y: y))
        let expanded = nativeHit(NSPoint(x: screen.frame.midX, y: screen.frame.maxY - height - 20))
        return Snapshot(expanded: expanded, reservedWidth: compact ? physical + 68 : 0)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
}

@main
struct DynamicNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @MainActor static let updaterController: SPUStandardUpdaterController? = {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feed.isEmpty else { return nil }
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }()

    init() {
        SettingsWindowController.shared.setUpdaterController(Self.updaterController)
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// A single AppKit popover owns both the window surface and its current size.
@MainActor
private final class HarborStatusPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var itemVisibility: NSKeyValueObservation?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var presentationID: UUID?
    private var pendingSize: CGSize?
    private let memoryMonitor = MenuMemoryMonitor.shared
    private var observers = Set<AnyCancellable>()

    override init() {
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self

        Defaults.publisher(.menubarIcon).map(\.newValue).removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in self?.setEnabled(enabled) }
            .store(in: &observers)
        UnifiedActivities.shared.objectWillChange
            .merge(with: AgentAPIUsageLedger.shared.objectWillChange,
                   NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLabel() }
            .store(in: &observers)
        memoryMonitor.$points
            .map { $0.last?.pressure }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard UserDefaults.standard.string(forKey: HarborMenuMetric.key) == HarborMenuMetric.memory.rawValue else { return }
                self?.updateLabel()
            }
            .store(in: &observers)
        setEnabled(Defaults[.menubarIcon])
    }

    private func setEnabled(_ enabled: Bool) {
        if enabled {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.behavior = .removalAllowed
            item.button?.target = self
            item.button?.action = #selector(toggle)
            item.button?.sendAction(on: .leftMouseUp)
            statusItem = item
            itemVisibility = item.observe(\.isVisible, options: [.new]) { [weak self] _, change in
                guard change.newValue == false else { return }
                Task { @MainActor in
                    guard self?.statusItem?.isVisible == false else { return }
                    Defaults[.menubarIcon] = false
                }
            }
            updateLabel()
        } else if let statusItem {
            popover.performClose(nil)
            itemVisibility = nil
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func updateLabel() {
        guard let button = statusItem?.button else { return }
        let preferences = UserDefaults.standard
        if preferences.string(forKey: HarborMenuMetric.key) == HarborMenuMetric.memory.rawValue {
            HarborMenuMetric.applyMemory(to: button, snapshot: memoryMonitor.points.last)
            return
        }

        let activity = UnifiedActivities.shared
        let selection = AgentUsageSelection.resolve(
            activity.agentUsage, preferred: preferences.string(forKey: AgentUsageSelection.key) ?? "",
            active: activity.runningAgent?.source, apiEnabled: preferences.bool(forKey: AgentSuggestionAPI.enabledKey),
            today: AgentAPIUsageLedger.shared.today
        )
        AgentUsageStatusLabel.apply(to: button, selection: selection)
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        let id = UUID()
        presentationID = id
        let content = AgentUsagePopover(readMemoryApps: { await XPCHelperClient.shared.appMemoryRanking() }) { [weak self] in
            self?.popover.performClose(nil)
            SettingsWindowController.shared.showWindow()
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { [weak self] size in
            self?.queueResize(size, presentation: id)
        }
        let host = NSHostingController(rootView: content)
        host.sizingOptions = []
        popover.contentViewController = host
        popover.contentSize = host.sizeThatFits(in: CGSize(width: 276, height: 800))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func queueResize(_ size: CGSize, presentation id: UUID) {
        guard presentationID == id, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        let wasQueued = pendingSize != nil
        pendingSize = CGSize(width: ceil(size.width), height: ceil(size.height))
        guard !wasQueued else { return }
        // Geometry reports can arrive during AppKit's layout pass. Commit one
        // size after that pass; resizing here would invalidate the same pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentationID == id, let target = self.pendingSize else { return }
            self.pendingSize = nil
            guard self.popover.isShown, self.popover.contentSize != target else { return }
            self.popover.contentSize = target
        }
    }

    func popoverDidShow(_ notification: Notification) {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self, self.popover.isShown,
                  event.window !== self.popover.contentViewController?.view.window,
                  !self.isOverStatusButton(NSEvent.mouseLocation) else { return event }
            self.popover.performClose(nil)
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            guard let self, self.popover.isShown, !self.isOverStatusButton(NSEvent.mouseLocation) else { return }
            self.popover.performClose(nil)
        }
    }

    private func isOverStatusButton(_ point: NSPoint) -> Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point)
    }

    func popoverDidClose(_ notification: Notification) {
        presentationID = nil
        pendingSize = nil
        popover.contentViewController = nil
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    let isSystemIslandCompanion = !ProcessInfo.processInfo.arguments.contains("--standalone-notch")
        && (ProcessInfo.processInfo.arguments.contains("--system-island-companion")
            || Defaults[.systemIslandCompanionEnabled])
    private var companionTrackingTimer: Timer?
    private var companionClickMonitor: Any?
    private var companionCheckInFlight = false
    private var lastCompanionBackgroundCheck = Date.distantPast
    private var lastCompanionPoint: NSPoint?
    private var systemIslandClickUntil = Date.distantPast
    private var nativeIslandMayReleaseAt = ProcessInfo.processInfo.systemUptime
    private var nativeIslandVacancy = SystemIslandVacancy()
    private weak var sampledNativeNotchWindow: NSWindow?
    private weak var suppressedNotchWindow: NSWindow?
    private var harborStatusPopover: HarborStatusPopover?
    var statusItem: NSStatusItem?
    var windows: [String: NSWindow] = [:] // UUID -> NSWindow
    var viewModels: [String: BoringViewModel] = [:] // UUID -> BoringViewModel
    var window: NSWindow?
    let vm: BoringViewModel = .init()
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    var quickShareService = QuickShareService.shared
    var whatsNewWindow: NSWindow?
    var timer: Timer?
    var closeNotchTask: Task<Void, Never>?
    private var previousScreens: [NSScreen]?
    private var onboardingWindowController: NSWindowController?
    private var screenLockedObserver: Any?
    private var screenUnlockedObserver: Any?
    private var isScreenLocked: Bool = false
    private var windowScreenDidChangeObserver: Any?
    private var dragDetectors: [String: DragDetector] = [:] // UUID -> DragDetector
    private var clipboardRecordingCancellable: AnyCancellable?
    private var appearanceCancellable: AnyCancellable?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if coordinator.firstLaunch { showOnboardingWindow() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionTrackingTimer?.invalidate()
        if let companionClickMonitor { NSEvent.removeMonitor(companionClickMonitor) }
        NotificationCenter.default.removeObserver(self)
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockedObserver = nil
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockedObserver = nil
        }
        MusicManager.shared.destroy()
        MainActor.assumeIsolated {
            ClipboardHistoryStore.shared.stop()
        }
        cleanupDragDetectors()
        cleanupWindows()
    }

    @MainActor
    func onScreenLocked(_ notification: Notification) {
        isScreenLocked = true
        ClipboardHistoryStore.shared.pauseForScreenLock()
        if !Defaults[.showOnLockScreen] {
            cleanupWindows()
        } else {
            enableSkyLightOnAllWindows()
        }
    }

    @MainActor
    func onScreenUnlocked(_ notification: Notification) {
        isScreenLocked = false
        ClipboardHistoryStore.shared.resumeFromScreenLock()
        if !Defaults[.showOnLockScreen] {
            adjustWindowPosition(changeAlpha: true)
        } else {
            disableSkyLightOnAllWindows()
        }
    }
    
    @MainActor
    private func enableSkyLightOnAllWindows() {
        if Defaults[.showOnAllDisplays] {
            windows.values.forEach { window in
                if let skyWindow = window as? BoringNotchSkyLightWindow {
                    skyWindow.enableSkyLight()
                }
            }
        } else {
            if let skyWindow = window as? BoringNotchSkyLightWindow {
                skyWindow.enableSkyLight()
            }
        }
    }
    
    @MainActor
    private func disableSkyLightOnAllWindows() {
        // Delay disabling SkyLight to avoid flicker during unlock transition
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await MainActor.run {
                if Defaults[.showOnAllDisplays] {
                    self.windows.values.forEach { window in
                        if let skyWindow = window as? BoringNotchSkyLightWindow {
                            skyWindow.disableSkyLight()
                        }
                    }
                } else {
                    if let skyWindow = self.window as? BoringNotchSkyLightWindow {
                        skyWindow.disableSkyLight()
                    }
                }
            }
        }
    }

    private func cleanupWindows(shouldInvert: Bool = false) {
        let shouldCleanupMulti = shouldInvert ? !Defaults[.showOnAllDisplays] : Defaults[.showOnAllDisplays]
        
        if shouldCleanupMulti {
            windows.values.forEach { window in
                window.close()
                NotchSpaceManager.shared.notchSpace.windows.remove(window)
            }
            windows.removeAll()
            viewModels.removeAll()
        } else if let window = window {
            window.close()
            NotchSpaceManager.shared.notchSpace.windows.remove(window)
            if let obs = windowScreenDidChangeObserver {
                NotificationCenter.default.removeObserver(obs)
                windowScreenDidChangeObserver = nil
            }
            self.window = nil
        }
    }

    private func cleanupDragDetectors() {
        dragDetectors.values.forEach { detector in
            detector.stopMonitoring()
        }
        dragDetectors.removeAll()
    }

    private func setupDragDetectors() {
        cleanupDragDetectors()

        if Defaults[.showOnAllDisplays] {
            for screen in NSScreen.screens {
                setupDragDetectorForScreen(screen)
            }
        } else {
            let preferredScreen: NSScreen? = window?.screen
                ?? NSScreen.screen(withUUID: coordinator.selectedScreenUUID)
                ?? NSScreen.main

            if let screen = preferredScreen {
                setupDragDetectorForScreen(screen)
            }
        }
    }

    private func setupDragDetectorForScreen(_ screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }
        
        let screenFrame = screen.frame
        let notchHeight = openNotchSize.height
        let notchWidth = (viewModels[uuid] ?? vm).requiredWindowWidth
        
        // Create notch region at the top-center of the screen where an open notch would occupy
        let notchRegion = CGRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: max(0, notchHeight - (isSystemIslandCompanion && screen.safeAreaInsets.top > 0
                ? screen.safeAreaInsets.top + SystemIslandHoverGeometry.gap : 0))
        )
        
        let detector = DragDetector(notchRegion: notchRegion)
        
        detector.onDragMove = { [weak self] point in
            Task { @MainActor in self?.handleDragEntersNotchRegion(onScreen: screen, at: point) }
        }

        detector.onFileDragChanged = { [weak self] dragging in
            Task { @MainActor in
                guard let self else { return }
                let target = Defaults[.showOnAllDisplays] ? self.windows[uuid] : self.window
                (target as? BoringNotchSkyLightWindow)?.setExternalFileDragActive(dragging)
            }
        }

        dragDetectors[uuid] = detector
        detector.startMonitoring()
    }

    @MainActor
    private func handleDragEntersNotchRegion(onScreen screen: NSScreen, at point: NSPoint) {
        guard Defaults[.expandedDragDetection], Defaults[.boringShelf],
              NSEvent.pressedMouseButtons & 1 != 0,
              !ShelfSelectionModel.shared.isDragging, let uuid = screen.displayUUID else { return }
        let model = Defaults[.showOnAllDisplays] ? viewModels[uuid] : (window?.screen == screen ? vm : nil)
        guard let model, !model.compactAlertPresented,
              model.notchState == .closed || coordinator.currentView != .shelf else { return }
        let dropFrame = model.shelfFileDropFrame(preparesExpansion: true)
        guard dropFrame.contains(point), dropFrame.contains(NSEvent.mouseLocation) else { return }
        coordinator.currentView = .shelf
        if model.notchState == .closed { model.open(forShelfDrag: true) }
    }

    private func createBoringNotchWindow(for screen: NSScreen, with viewModel: BoringViewModel) -> NSWindow {
        viewModel.usesSystemIslandTrigger = isSystemIslandCompanion && screen.safeAreaInsets.top > 0
        let rect = NSRect(x: 0, y: 0, width: viewModel.requiredWindowWidth, height: viewModel.requiredWindowHeight)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]
        
        let window = BoringNotchSkyLightWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)
        if isSystemIslandCompanion && screen.safeAreaInsets.top > 0 {
            window.keepsPhysicalNotchAnchor = true
            window.level = .mainMenu + 1
        }
        
        // Enable SkyLight only when screen is locked
        if isScreenLocked {
            window.enableSkyLight()
        } else {
            window.disableSkyLight()
        }

        let hostingView = NotchHostingView(
            rootView: ContentView()
                .environmentObject(viewModel)
        )
        hostingView.notchViewModel = viewModel
        // The window model owns the panel size. Hosting constraints can
        // otherwise feed animated AppKit child sizes back into the same pass.
        hostingView.sizingOptions = []
        let container = NSView(frame: window.contentView?.bounds ?? NSRect(origin: .zero, size: rect.size))
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        window.contentView = container

        window.enableShelfFileDrops(for: viewModel)
        window.orderFrontRegardless()
        NotchSpaceManager.shared.notchSpace.windows.insert(window)

        // Observe when the window's screen changes so we can update drag detectors
        windowScreenDidChangeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.setupDragDetectors()
                }
        }
        return window
    }

    @MainActor
    private func positionWindow(_ window: NSWindow, on screen: NSScreen, changeAlpha: Bool = false) {
        (window as? BoringNotchSkyLightWindow)?.shelfViewModel?.usesSystemIslandTrigger =
            isSystemIslandCompanion && screen.safeAreaInsets.top > 0
        if let model = (window as? BoringNotchSkyLightWindow)?.shelfViewModel {
            window.setContentSize(CGSize(width: model.requiredWindowWidth, height: model.requiredWindowHeight))
            if !model.usesSystemIslandTrigger { model.systemIslandPresentationActive = false }
        }
        if isSystemIslandCompanion {
            (window as? BoringNotchSkyLightWindow)?.keepsPhysicalNotchAnchor = screen.safeAreaInsets.top > 0
            window.level = screen.safeAreaInsets.top > 0 ? .mainMenu + 1 : .mainMenu + 3
        }
        if changeAlpha {
            window.alphaValue = 0
        }

        let screenFrame = screen.frame
        window.setFrameOrigin(
            NSPoint(
                x: screenFrame.origin.x + (screenFrame.width / 2) - window.frame.width / 2,
                y: screenFrame.origin.y + screenFrame.height - window.frame.height
            ))
        window.alphaValue = 1
        (window as? BoringNotchSkyLightWindow)?.refreshMouseRouting()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let managedLogin = CommandLine.arguments.contains("--background-login")
        if managedLogin && !HarborLoginItem.managedEnabled {
            NSApp.terminate(nil)
            return
        }
        SettingsWindowController.shared.previewModel = { [weak self] in
            guard let self else { return nil }
            if Defaults[.showOnAllDisplays], let uuid = NSScreen.main?.displayUUID, let model = self.viewModels[uuid] {
                return model
            }
            return self.window.flatMap { ($0 as? BoringNotchSkyLightWindow)?.shelfViewModel }
                ?? self.viewModels.values.first ?? self.vm
        }
        harborStatusPopover = HarborStatusPopover()
        appearanceCancellable = Defaults.publisher(.appAppearance)
            .map(\.newValue)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { mode in NSApp.appearance = mode.name.flatMap { NSAppearance(named: $0) } }
        Task { @MainActor in
            AgentInteraction.shared.startCompletionMonitoring()
            _ = CalendarManager.shared
        }
        let previewRain = CommandLine.arguments.contains("--preview-rain-alert")
        if previewRain || CommandLine.arguments.contains("--preview-compact-alert") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, !self.isScreenLocked, !Task.isCancelled else { return }
                UnifiedActivities.shared.previewCompactAlert(rain: previewRain)
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            forName: Notification.Name.selectedScreenChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition(changeAlpha: true)
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.notchHeightChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.automaticallySwitchDisplayChanged, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self = self, let window = self.window else { return }
            Task { @MainActor in
                window.alphaValue = self.coordinator.selectedScreenUUID == self.coordinator.preferredScreenUUID ? 1 : 0
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.showOnAllDisplaysChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.cleanupWindows(shouldInvert: true)
                self.adjustWindowPosition(changeAlpha: true)
                self.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.expandedDragDetectionChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setupDragDetectors()
            }
        }

        // Use closure-based observers for DistributedNotificationCenter and keep tokens for removal
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenLocked(notification)
                }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenUnlocked(notification)
                }
        }

        ClipboardHistoryStore.shared.setRecordingEnabled(Defaults[.clipboardHistoryEnabled])
        ClipboardHistoryStore.shared.start()
        clipboardRecordingCancellable = Defaults.publisher(.clipboardHistoryEnabled)
            .sink { change in
                Task { @MainActor in
                    ClipboardHistoryStore.shared.setRecordingEnabled(change.newValue)
                }
            }

        KeyboardShortcuts.onKeyUp(for: .agentVoiceReply) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isScreenLocked else { return }
                let editing = self.viewModels.values.first(where: \.isAgentReplyEditing)
                let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                let underPointer = screen?.displayUUID.flatMap { self.viewModels[$0] }
                let active = editing ?? underPointer ?? self.vm
                self.closeNotchTask?.cancel()
                active.agentVoiceHotkey = UUID()
            }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let mouseLocation = NSEvent.mouseLocation

                var viewModel = self.vm

                if Defaults[.showOnAllDisplays] {
                    for screen in NSScreen.screens {
                        if screen.frame.contains(mouseLocation) {
                            if let uuid = screen.displayUUID, let screenViewModel = self.viewModels[uuid] {
                                viewModel = screenViewModel
                                break
                            }
                        }
                    }
                }

                self.closeNotchTask?.cancel()
                self.closeNotchTask = nil

                switch viewModel.notchState {
                case .closed:
                    await MainActor.run {
                        viewModel.open()
                    }

                    let task = Task { [weak viewModel] in
                        do {
                            try await Task.sleep(for: .seconds(3))
                            await MainActor.run {
                                guard let viewModel, !viewModel.isMouseHovering(),
                                      !viewModel.anyDropZoneTargeting,
                                      !ShelfSelectionModel.shared.isDragging,
                                      !ShelfStateViewModel.shared.isLoading else { return }
                                viewModel.close()
                            }
                        } catch { }
                    }
                    self.closeNotchTask = task
                case .open:
                    await MainActor.run {
                        viewModel.close()
                    }
                }
            }
        }

        if !Defaults[.showOnAllDisplays] {
            let viewModel = self.vm
            let window = createBoringNotchWindow(
                for: NSScreen.main ?? NSScreen.screens.first!, with: viewModel)
            self.window = window
            adjustWindowPosition(changeAlpha: true)
        } else {
            adjustWindowPosition(changeAlpha: true)
        }

        setupDragDetectors()

        NotchSpotlightGuideController.shared.onRequestOpenNotch = { [weak self] in
            guard let self else { return }
            self.closeNotchTask?.cancel()
            self.closeNotchTask = nil
            self.coordinator.firstLaunch = false
            var targetVM = self.vm
            if Defaults[.showOnAllDisplays] {
                let mouse = NSEvent.mouseLocation
                if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
                   let uuid = screen.displayUUID,
                   let screenVM = self.viewModels[uuid] {
                    targetVM = screenVM
                }
            }
            if let win = (Defaults[.showOnAllDisplays] ? targetVM.screenUUID.flatMap { self.windows[$0] } : self.window) {
                win.orderFrontRegardless()
            }
            withAnimation(targetVM.animation) {
                targetVM.open()
            }
        }

        if CommandLine.arguments.contains("--spotlight-guide") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                NotchSpotlightGuideController.shared.start(force: true)
            }
        } else if coordinator.firstLaunch {
            DispatchQueue.main.async {
                self.showOnboardingWindow()
            }
            playWelcomeSound()
        } else if MusicManager.shared.isNowPlayingDeprecated
            && Defaults[.mediaController] == .nowPlaying
        {
            DispatchQueue.main.async {
                self.showOnboardingWindow(step: .musicPermission)
            }
        }
        previousScreens = NSScreen.screens

        if isSystemIslandCompanion {
            startCompanionTracking()
        }
    }

    func playWelcomeSound() {
        NSSound(named: "Glass")?.play()
    }

    func deviceHasNotch() -> Bool {
        if #available(macOS 12.0, *) {
            for screen in NSScreen.screens {
                if screen.safeAreaInsets.top > 0 {
                    return true
                }
            }
        }
        return false
    }

    @objc func screenConfigurationDidChange() {
        let currentScreens = NSScreen.screens

        let screensChanged =
            currentScreens.count != previousScreens?.count
            || Set(currentScreens.compactMap { $0.displayUUID })
                != Set(previousScreens?.compactMap { $0.displayUUID } ?? [])
            || Set(currentScreens.map { $0.frame }) != Set(previousScreens?.map { $0.frame } ?? [])

        previousScreens = currentScreens

        if screensChanged {
            DispatchQueue.main.async { [weak self] in
                self?.cleanupWindows()
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        }
    }

    @objc func adjustWindowPosition(changeAlpha: Bool = false) {
        if Defaults[.showOnAllDisplays] {
            let currentScreenUUIDs = Set(NSScreen.screens.compactMap { $0.displayUUID })

            // Remove windows for screens that no longer exist
            for uuid in windows.keys where !currentScreenUUIDs.contains(uuid) {
                if let window = windows[uuid] {
                    window.close()
                    NotchSpaceManager.shared.notchSpace.windows.remove(window)
                    windows.removeValue(forKey: uuid)
                    viewModels.removeValue(forKey: uuid)
                }
            }

            // Create or update windows for all screens
            for screen in NSScreen.screens {
                guard let uuid = screen.displayUUID else { continue }
                
                if windows[uuid] == nil {
                    let viewModel = BoringViewModel(screenUUID: uuid)
                    let window = createBoringNotchWindow(for: screen, with: viewModel)

                    windows[uuid] = window
                    viewModels[uuid] = viewModel
                }

                if let window = windows[uuid], let viewModel = viewModels[uuid] {
                    positionWindow(window, on: screen, changeAlpha: changeAlpha)
                    viewModel.refreshNotchSize(screenUUID: uuid)
                }
            }
        } else {
            let selectedScreen: NSScreen

            if let preferredScreen = NSScreen.screen(withUUID: coordinator.preferredScreenUUID ?? "") {
                coordinator.selectedScreenUUID = coordinator.preferredScreenUUID ?? ""
                selectedScreen = preferredScreen
            } else if Defaults[.automaticallySwitchDisplay], let mainScreen = NSScreen.main,
                      let mainUUID = mainScreen.displayUUID {
                coordinator.selectedScreenUUID = mainUUID
                selectedScreen = mainScreen
            } else {
                if let window = window {
                    window.alphaValue = 0
                }
                return
            }

            vm.screenUUID = selectedScreen.displayUUID

            if window == nil {
                window = createBoringNotchWindow(for: selectedScreen, with: vm)
            }

            if let window = window {
                positionWindow(window, on: selectedScreen, changeAlpha: changeAlpha)
                vm.refreshNotchSize(screenUUID: selectedScreen.displayUUID)
            }
        }
    }

    @MainActor
    private func startCompanionTracking() {
        let timer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trackSystemIsland() }
        }
        timer.tolerance = 0.025
        companionTrackingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        companionClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.yieldAfterSystemIslandClick() }
        }
    }

    @MainActor
    private func notchOnBuiltInScreen() -> (NSScreen, NSWindow, BoringViewModel)? {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let id = screen.displayUUID else { return nil }
        if Defaults[.showOnAllDisplays], let window = windows[id], let model = viewModels[id] {
            return (screen, window, model)
        }
        if let window, window.screen?.displayUUID == id { return (screen, window, vm) }
        return nil
    }

    @MainActor
    private func yieldAfterSystemIslandClick() {
        guard !isScreenLocked, let (_, window, model) = notchOnBuiltInScreen(),
              model.usesSystemIslandTrigger else { return }
        let point = NSEvent.mouseLocation
        guard model.isOverNativeIsland(point) else { return }
        systemIslandClickUntil = Date().addingTimeInterval(0.65)
        yieldNotchWindow(window, model: model)
    }

    @MainActor
    private func yieldNotchWindow(_ window: NSWindow, model: BoringViewModel) {
        model.lastConfirmedNativeVacancyAt = nil
        model.systemIslandPresentationActive = true
        if model.notchState == .open {
            closeNotchTask?.cancel()
            let animation: Animation = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? .easeOut(duration: 0.15)
                : .interactiveSpring(response: 0.43, dampingFraction: 0.9, blendDuration: 0.12)
            withAnimation(animation) { model.close() }
        }
        // Keep the window mounted so its closing spring can finish. The native
        // island is already above it; only interaction and reopening are gated.
        if suppressedNotchWindow !== window {
            suppressedNotchWindow = window
        }
    }

    @MainActor
    private func trackSystemIsland() {
        guard !isScreenLocked, !companionCheckInFlight,
              let (screen, window, model) = notchOnBuiltInScreen() else { return }
        let confirmWings = model.showsRunningAgent &&
            (model.nativeWingReleaseCheckAt != nil || nativeIslandVacancy.awaitingConfirmation)
        let interactive = isNearIsland(screen) || model.notchState == .open || suppressedNotchWindow === window || confirmWings
        guard interactive || (model.showsRunningAgent && Date().timeIntervalSince(lastCompanionBackgroundCheck) >= 1),
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        let point = NSEvent.mouseLocation
        let stationary = lastCompanionPoint == point
        lastCompanionPoint = point
        if stationary && model.notchState == .open && !confirmWings && suppressedNotchWindow !== window
            && Date().timeIntervalSince(lastCompanionBackgroundCheck) < 0.7 { return }
        lastCompanionBackgroundCheck = Date()
        let display = CGDisplayBounds(id.uint32Value)
        let notchHeight = screen.safeAreaInsets.top
        let sampledAt = ProcessInfo.processInfo.systemUptime
        companionCheckInFlight = true
        Task { @MainActor [weak self, weak window, weak model] in
            var snapshot = await Task.detached(priority: .utility) {
                SystemIslandAccessibility.snapshot(on: display, notchHeight: notchHeight)
            }.value
            guard let self else { return }
            self.companionCheckInFlight = false
            guard let window, let model, !self.isScreenLocked,
                  self.notchOnBuiltInScreen()?.1 === window else { return }
            if self.sampledNativeNotchWindow !== window {
                self.nativeIslandVacancy = SystemIslandVacancy()
                self.sampledNativeNotchWindow = window
                model.lastConfirmedNativeVacancyAt = nil
            }
            // A transient empty Accessibility snapshot can leave the native island
            // on screen. Corroborate it before releasing the Agent wings.
            if snapshot.reservedWidth == nil || (snapshot.reservedWidth == 0 && !snapshot.expanded) {
                let hit = SystemIslandAccessibility.hitTestSnapshot(on: screen, ownWindow: window.windowNumber)
                snapshot.expanded = snapshot.expanded || hit.expanded
                snapshot.reservedWidth = hit.reservedWidth
            }
            let now = ProcessInfo.processInfo.systemUptime
            let compactActive = (snapshot.reservedWidth ?? 0) > 0
            let vacant = self.nativeIslandVacancy.observe(width: snapshot.reservedWidth,
                expanded: snapshot.expanded, at: now, since: model.nativeWingReleaseCheckAt)
            if snapshot.expanded { self.nativeIslandMayReleaseAt = now + 0.48 }
            let reservedWidth = compactActive ? snapshot.reservedWidth
                : vacant ? 0 : model.systemIslandReservedWidth
            if model.systemIslandReservedWidth != reservedWidth {
                model.systemIslandReservedWidth = reservedWidth
                if window.frame.width != model.requiredWindowWidth { self.positionWindow(window, on: screen) }
            }
            if let closeTime = model.nativeWingReleaseCheckAt,
               vacant || (compactActive && !snapshot.expanded && now - closeTime >= 0.65) {
                model.nativeWingReleaseCheckAt = nil
            }
            if let width = snapshot.compactWidth,
               width > model.systemIslandWidth + 2 || (model.notchState == .closed && abs(width - model.systemIslandWidth) > 2) {
                model.systemIslandWidth = width
                if window.frame.width != model.requiredWindowWidth { self.positionWindow(window, on: screen) }
            }
            if snapshot.expanded || now < self.nativeIslandMayReleaseAt || Date() < self.systemIslandClickUntil {
                self.yieldNotchWindow(window, model: model)
            } else {
                // A screen/lock transition may recreate the window. Always
                // release the gate once the native presentation has ended.
                model.lastConfirmedNativeVacancyAt = vacant ? sampledAt : nil
                model.systemIslandPresentationActive = false
                if self.suppressedNotchWindow === window { self.suppressedNotchWindow = nil }
            }
        }
    }

    @MainActor
    private func isNearIsland(_ screen: NSScreen) -> Bool {
        let point = NSEvent.mouseLocation
        return screen.frame.contains(point) && abs(point.x - screen.frame.midX) <= 330
            && point.y >= screen.frame.maxY - 72
    }

    @objc func togglePopover(_ sender: Any?) {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    @objc func showMenu() {
        statusItem?.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(self)
    }

    private func showOnboardingWindow(step: OnboardingStep = .welcome) {
        if onboardingWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Notch Harbor"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    step: step,
                    onFinish: { [weak self] in
                        window.orderOut(nil)
                        window.close()
                        NSApp.deactivate()
                        self?.coordinator.firstLaunch = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                            NotchSpotlightGuideController.shared.start(force: true)
                        }
                    },
                    onSkipGuide: { [weak self] in
                        NotchSpotlightGuideController.shared.hasCompleted = true
                        window.orderOut(nil)
                        window.close()
                        NSApp.deactivate()
                        self?.coordinator.firstLaunch = false
                    },
                    onOpenSettings: {
                        window.close()
                        SettingsWindowController.shared.showWindow()
                    }
                ))
            window.isRestorable = false
            window.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")

            onboardingWindowController = NSWindowController(window: window)
        }

//        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        onboardingWindowController?.window?.orderFrontRegardless()
    }
}

extension Notification.Name {
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")
    static let expandedDragDetectionChanged = Notification.Name("expandedDragDetectionChanged")
}

extension CGRect: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(origin.x)
        hasher.combine(origin.y)
        hasher.combine(size.width)
        hasher.combine(size.height)
    }

    public static func == (lhs: CGRect, rhs: CGRect) -> Bool {
        return lhs.origin == rhs.origin && lhs.size == rhs.size
    }
}
