//
//  BoringViewModel.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Combine
import Defaults
import SwiftUI

class BoringViewModel: NSObject, ObservableObject {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var detector = FullscreenMediaDetector.shared

    let animationLibrary: BoringAnimations = .init()
    let animation: Animation?

    @Published var contentType: ContentType = .normal
    @Published private(set) var notchState: NotchState = .closed

    @Published var dragDetectorTargeting: Bool = false
    @Published var generalDropTargeting: Bool = false
    @Published var windowDropTargeting: Bool = false
    @Published var externalFileDragActive = false
    @Published private(set) var openedForShelfDrag = false
    @Published var pointerWithinHitRegion = false
    @Published var pointerWithinIslandHoverTrigger = false
    @Published var dropZoneTargeting: Bool = false
    @Published var dropEvent: Bool = false {
        didSet {
            // Once a drop lands, the shelf can use the full optical surface.
            if dropEvent && openedForShelfDrag { openedForShelfDrag = false }
        }
    }
    @Published var anyDropZoneTargeting: Bool = false
    var cancellables: Set<AnyCancellable> = []
    
    @Published var hideOnClosed: Bool = false

    @Published var edgeAutoOpenActive: Bool = false
    @Published var usesSystemIslandTrigger = false
    @Published var systemIslandPresentationActive = false
    @Published var systemIslandWidth: CGFloat = 0
    @Published var systemIslandReservedWidth: CGFloat?
    @Published var nativeWingReleaseCheckAt: TimeInterval?
    var lastConfirmedNativeVacancyAt: TimeInterval?
    @Published var showsRunningAgent = false
    @Published var isHoveringCalendar: Bool = false
    @Published var isWeatherWarningListOpen = false
    @Published var isBatteryPopoverActive: Bool = false
    @Published var isHeaderMenuActive = false
    @Published var isMusicVolumePopoverActive = false
    @Published var isAirPodsPopoverActive = false
    @Published var isMusicScrubbing = false
    @Published var isPanelPointerPressed = false
    @Published var isClipboardPreviewActive = false
    let outsideCompactAlertClick = PassthroughSubject<Void, Never>()
    @Published var agentListPreviewHeightHeld = false
    @Published var agentConversationPreviewID: String?
    @Published var isAgentReplyEditing = false
    @Published var isShelfRenameEditing = false
    @Published var agentVoiceHotkey = UUID()
    @Published var agentVoiceFocus: AgentVoiceFocus?
    @Published var isAgentVoiceReplyActive = false
    @Published var isSpotlightGuideActive = false
    private let isSettingsPreviewInstance: Bool
    var clipboardPendingSelectionID: UUID?

    @Published var screenUUID: String?

    @Published var notchSize: CGSize = getClosedNotchSize()
    @Published var closedNotchSize: CGSize = getClosedNotchSize()
    
    let webcamManager = WebcamManager.shared
    @Published var isCameraExpanded: Bool = false
    @Published var isRequestingAuthorization: Bool = false
    
    deinit {
        destroy()
    }

    func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    init(screenUUID: String? = nil, isSettingsPreview: Bool = false) {
        animation = animationLibrary.animation
        isSettingsPreviewInstance = isSettingsPreview

        super.init()
        
        self.screenUUID = screenUUID
        notchSize = getClosedNotchSize(screenUUID: screenUUID)
        closedNotchSize = notchSize

        guard !isSettingsPreview else { return }

        Publishers.CombineLatest4($dropZoneTargeting, $dragDetectorTargeting, $generalDropTargeting, $windowDropTargeting)
            .map { shelf, drag, general, window in
                shelf || drag || general || window
            }
            .removeDuplicates()
            .assign(to: \.anyDropZoneTargeting, on: self)
            .store(in: &cancellables)
        
        setupDetectorObserver()

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isSpotlightGuideActive = NotchSpotlightGuideController.shared.isActive
            NotchSpotlightGuideController.shared.$isActive
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] active in
                    guard let self else { return }
                    self.isSpotlightGuideActive = active
                    if self.notchState == .open {
                        withAnimation(NotchPanelMotion.spring(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
                            self.notchSize = self.expandedNotchSize
                        }
                    }
                }
                .store(in: &self.cancellables)
        }
    }
    
    private func setupDetectorObserver() {
        let screenPublisher = $screenUUID.compactMap { $0 }.removeDuplicates()
        Publishers.CombineLatest(screenPublisher, detector.$fullscreenStatus)
            .map { screenUUID, fullscreenStatus in fullscreenStatus[screenUUID] ?? false }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldHide in
                withAnimation(.smooth) {
                    self?.hideOnClosed = shouldHide
                }
            }
            .store(in: &cancellables)
    }

    // Computed property for effective notch height
    var effectiveClosedNotchHeight: CGFloat {
        let currentScreen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) }
        let noNotchAndFullscreen = hideOnClosed && (currentScreen?.safeAreaInsets.top ?? 0 <= 0 || currentScreen == nil)
        return noNotchAndFullscreen ? 0 : closedNotchSize.height
    }

    func toggleCameraPreview() {
        if isRequestingAuthorization {
            return
        }

        switch webcamManager.authorizationStatus {
        case .authorized:
            if webcamManager.isSessionRunning {
                webcamManager.stopSession()
                isCameraExpanded = false
            } else if webcamManager.cameraAvailable {
                webcamManager.startSession()
                isCameraExpanded = true
            }

        case .denied, .restricted:
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)

                let alert = NSAlert()
                alert.messageText = "Camera Access Required"
                alert.informativeText = "Please allow camera access in System Settings."
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Cancel")

                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }

                NSApp.setActivationPolicy(.accessory)
                NSApp.deactivate()
            }

        case .notDetermined:
            isRequestingAuthorization = true
            webcamManager.checkAndRequestVideoAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.isRequestingAuthorization = false
            }

        default:
            break
        }
    }
    
    var systemIslandTriggerTopInset: CGFloat {
        guard usesSystemIslandTrigger,
              let screen = screenUUID.flatMap({ NSScreen.screen(withUUID: $0) }) else { return 0 }
        return screen.safeAreaInsets.top + SystemIslandHoverGeometry.gap
    }

    var collapsedTriggerTopInset: CGFloat {
        usesSystemIslandTrigger ? systemIslandTriggerTopInset
            : effectiveClosedNotchHeight + SystemIslandHoverGeometry.gap
    }

    var collapsedTriggerWidth: CGFloat {
        max(closedNotchSize.width, usesSystemIslandTrigger ? systemIslandClearanceWidth : 0) + 28
    }

    var runningAgentCenterWidth: CGFloat {
        getPhysicalNotchSize(screenUUID: screenUUID)?.width ?? closedNotchSize.width
    }
    var runningAgentHeight: CGFloat {
        getPhysicalNotchSize(screenUUID: screenUUID)?.height ?? max(24, effectiveClosedNotchHeight)
    }
    var runningAgentVisible: Bool {
        guard !hideOnClosed, !systemIslandPresentationActive else { return false }
        guard usesSystemIslandTrigger else { return true }
        guard nativeWingReleaseCheckAt == nil, let systemIslandReservedWidth else { return false }
        return systemIslandReservedWidth <= runningAgentCenterWidth + 2
    }
    var runningAgentWings: SystemIslandHoverGeometry.AgentWings {
        SystemIslandHoverGeometry.agentWings(screen: getScreenFrame(screenUUID) ?? .zero,
                                            centerWidth: runningAgentCenterWidth, height: runningAgentHeight)
    }
    var runningAgentOffset: CGFloat {
        guard !runningAgentWings.frame.isNull, let screen = getScreenFrame(screenUUID) else { return 0 }
        return runningAgentWings.frame.midX - screen.midX
    }

    var systemIslandClearanceWidth: CGFloat {
        guard usesSystemIslandTrigger else { return closedNotchSize.width }
        let physical = getPhysicalNotchSize(screenUUID: screenUUID)?.width ?? closedNotchSize.width
        return SystemIslandHoverGeometry.clearanceWidth(physical: physical, observed: systemIslandWidth)
    }

    var expandedShoulderInset: CGFloat {
        if usesSystemIslandTrigger { return 0 }
        return Defaults[.cornerRadiusScaling] ? cornerRadiusInsets.opened.top : cornerRadiusInsets.closed.top
    }

    @Published private var compactAlertWidth: CGFloat?
    private var compactAlertContentHeight: CGFloat = 67
    private var compactAlertMinimumTopInset: CGFloat = 0
    var compactAlertPresented: Bool { compactAlertWidth != nil }

    func setCompactAlertPresented(_ presented: Bool, contentHeight: CGFloat = 67,
                                  extraWidth: CGFloat = 0, physicalWidth: Bool = false,
                                  minimumTopInset: CGFloat = 0) {
        compactAlertContentHeight = contentHeight
        compactAlertMinimumTopInset = presented ? minimumTopInset : 0
        if presented {
            let width = SystemIslandHoverGeometry.compactAlertWidth(
                reserved: usesSystemIslandTrigger ? systemIslandReservedWidth : nil,
                measured: usesSystemIslandTrigger ? systemIslandWidth : 0,
                fallback: runningAgentCenterWidth + 2 * SystemIslandHoverGeometry.agentWingWidth,
                available: fullPanelWidth
            )
            compactAlertWidth = physicalWidth ? runningAgentCenterWidth : min(fullPanelWidth, width + extraWidth)
        } else {
            compactAlertWidth = nil
        }
    }
    @Published var selectedAgentID: String?
    var agentDetailExpanded: Bool { selectedAgentID != nil }
    @Published var agentListExtraHeight: CGFloat = 0
    @Published var previewPageOverride: NotchPage? = nil

    var expandedPanelWidth: CGFloat {
        compactAlertWidth ?? fullPanelWidth
    }

    private var fullPanelWidth: CGFloat {
        let preferred: CGFloat = Defaults[.largerPanel] ? 600 : 530
        guard usesSystemIslandTrigger else { return min(getScreenFrame(screenUUID)?.width ?? preferred, preferred) }
        // Compact the body while reserving both banks beside the native island.
        let available = max(1, (getScreenFrame(screenUUID)?.width ?? 1512) - 40)
        let clearance = systemIslandClearanceWidth + 212
        return min(available, max(clearance, min(preferred, systemIslandClearanceWidth * (Defaults[.largerPanel] ? 1.95 : 1.65))))
    }

    var requiredWindowWidth: CGFloat {
        max(fullPanelWidth, showsRunningAgent ? runningAgentWings.frame.width + 2 * abs(runningAgentOffset) : closedNotchSize.width + 180)
    }

    // Regular pages share one shell; only transient alerts keep their
    // compact presentation. Layout and window hit testing use the same size.
    var compactAlertTopInset: CGFloat {
        max(compactAlertMinimumTopInset, max(runningAgentHeight, collapsedTriggerTopInset) + 3)
    }

    static let regularPanelHeight: CGFloat = 141
    static let musicPanelHeight: CGFloat = 177

    @MainActor
    private var activeExpandedPage: NotchPage {
        previewPageOverride ?? NotchPage.selection(coordinator: coordinator, activities: UnifiedActivities.shared)
    }

    var spotlightGuideExtraHeight: CGFloat {
        (!isSettingsPreviewInstance && isSpotlightGuideActive && !compactAlertPresented)
            ? SpotlightGuideGeometry.reservedExtraHeight
            : 0
    }

    @MainActor
    var expandedNotchSize: CGSize {
        let baseHeight: CGFloat
        if compactAlertPresented {
            baseHeight = compactAlertTopInset + compactAlertContentHeight
        } else if agentDetailExpanded {
            baseHeight = 346
        } else if activeExpandedPage == .music {
            baseHeight = Self.musicPanelHeight
        } else {
            baseHeight = Self.regularPanelHeight + agentListExtraHeight
        }
        let largerExtra: CGFloat = (!compactAlertPresented && Defaults[.largerPanel])
            ? (activeExpandedPage == .music && !agentDetailExpanded ? 24 : 32)
            : 0
        return CGSize(width: expandedPanelWidth, height: baseHeight + largerExtra + spotlightGuideExtraHeight)
    }

    var expandedHeaderSize: CGSize {
        getPhysicalNotchSize(screenUUID: screenUUID)
            ?? CGSize(width: closedNotchSize.width, height: max(24, effectiveClosedNotchHeight))
    }

    static let expandedBottomInset: CGFloat = 8
    static let expandedPageTopInset: CGFloat = 9

    var expandedPageSize: CGSize {
        CGSize(width: max(1, expandedNotchSize.width - 2 * (usesSystemIslandTrigger ? expandedShoulderInset + 8 : 24)),
               height: max(1, expandedNotchSize.height - expandedHeaderSize.height
                   - Self.expandedPageTopInset - Self.expandedBottomInset - spotlightGuideExtraHeight))
    }

    var fileDropTopInset: CGFloat {
        usesSystemIslandTrigger ? systemIslandTriggerTopInset : 0
    }

    func shelfFileDropFrame(preparesExpansion: Bool = false) -> CGRect {
        guard !systemIslandPresentationActive, let screen = getScreenFrame(screenUUID) else { return .null }
        if notchState == .closed && !preparesExpansion {
            return SystemIslandHoverGeometry.triggerFrame(screen: screen,
                islandHeight: collapsedTriggerTopInset - SystemIslandHoverGeometry.gap,
                width: collapsedTriggerWidth)
        }
        if notchState == .open {
            guard !compactAlertPresented, !coordinator.firstLaunch else { return .null }
            let page = expandedPageSize
            let pageFrame = CGRect(x: screen.midX - page.width / 2,
                                   y: screen.maxY - expandedNotchSize.height + Self.expandedBottomInset,
                                   width: page.width, height: page.height)
            guard NotchPage.selection(coordinator: coordinator, activities: UnifiedActivities.shared) == .shelf else {
                return pageFrame
            }
            return ShelfDropLayout(size: page).shelf.offsetBy(dx: pageFrame.minX, dy: pageFrame.minY)
        }
        let size = expandedNotchSize
        return SystemIslandHoverGeometry.shelfDropFrame(screen: screen, width: size.width,
                                                      height: size.height, topInset: fileDropTopInset)
    }

    func isOverNativeIsland(_ position: NSPoint) -> Bool {
        guard usesSystemIslandTrigger, !systemIslandPresentationActive,
              let frame = getScreenFrame(screenUUID), runningAgentHeight > 0 else { return false }
        let width = systemIslandReservedWidth == 0 ? runningAgentCenterWidth
            : max(runningAgentCenterWidth, systemIslandReservedWidth ?? 0, systemIslandWidth)
        return SystemIslandHoverGeometry.capsuleContains(position, screen: frame,
            width: min(frame.width, width), height: runningAgentHeight)
    }

    func acceptsIslandHover(at position: NSPoint) -> Bool {
        if isOverNativeIsland(position) { return true }
        if notchState == .closed, runningAgentVisible, Defaults[.collapsedShellStyle] != .hidden,
           let screen = getScreenFrame(screenUUID) {
            let width = runningAgentCenterWidth + 2 * Defaults[.restingExtension]
            let bounds = CGRect(x: 0, y: 0, width: width, height: runningAgentHeight)
            let local = CGPoint(x: position.x - screen.midX + width / 2, y: screen.maxY - position.y)
            let shape = Defaults[.collapsedShellStyle] == .notch ? NotchShape() : NotchShape.panel(expanded: false)
            if shape.path(in: bounds).contains(local) { return true }
        }
        let wings = runningAgentWings
        guard showsRunningAgent, runningAgentVisible, wings.contains(position),
              let screen = getScreenFrame(screenUUID) else { return false }
        return SystemIslandHoverGeometry.capsuleContains(position, screen: screen,
            width: wings.frame.width, height: runningAgentHeight)
    }

    func acceptsWindowPointer(at position: NSPoint) -> Bool {
        guard !systemIslandPresentationActive, let frame = getScreenFrame(screenUUID),
              position.x >= frame.minX, position.x < frame.maxX,
              position.y >= frame.minY, position.y <= frame.maxY else { return false }
        let depth = frame.maxY - position.y
        let offset = abs(position.x - frame.midX)
        if notchState == .closed, isSpotlightGuideActive,
           depth <= runningAgentHeight + 36, offset <= (collapsedTriggerWidth / 2) + 28 {
            return true
        }
        if notchState == .closed, showsRunningAgent, runningAgentVisible,
           runningAgentWings.contains(position) { return true }
        if externalFileDragActive,
           shelfFileDropFrame(preparesExpansion: Defaults[.expandedDragDetection]).contains(position) { return true }
        if usesSystemIslandTrigger, depth < systemIslandTriggerTopInset,
           offset <= systemIslandClearanceWidth / 2 { return false }
        return isMouseHovering(position: position)
    }

    // Keep transparent animation headroom; only the visible panel receives hits.
    var requiredWindowHeight: CGFloat { 512 }

    func isMouseHovering(position: NSPoint = NSEvent.mouseLocation, width: CGFloat? = nil) -> Bool {
        let screenFrame = getScreenFrame(screenUUID)
        if let frame = screenFrame {
            if notchState == .closed {
                if showsRunningAgent && runningAgentVisible && runningAgentWings.contains(position) { return true }
                let islandHeight = collapsedTriggerTopInset - SystemIslandHoverGeometry.gap
                return SystemIslandHoverGeometry.triggerFrame(
                    screen: frame, islandHeight: islandHeight,
                    width: width ?? collapsedTriggerWidth
                ).contains(position)
            }
            
            let baseY = frame.maxY - notchSize.height
            let hitWidth = width ?? notchSize.width
            let baseX = frame.midX - hitWidth / 2
            
            return position.y >= baseY && position.y <= frame.maxY && position.x >= baseX && position.x <= baseX + hitWidth
        }
        
        return false
    }

    func setSettingsPreviewExpanded(_ expanded: Bool) {
        notchState = expanded ? .open : .closed
        if !expanded {
            selectedAgentID = nil
            agentListExtraHeight = 0
        }
        notchSize = expanded ? expandedNotchSize : closedNotchSize
    }

    func open(forShelfDrag: Bool = false, forCompactAlert: Bool = false) {
        guard !systemIslandPresentationActive else { return }
        if !forCompactAlert && compactAlertPresented {
            setCompactAlertPresented(false)
        }
        openedForShelfDrag = forShelfDrag
        self.notchSize = expandedNotchSize
        self.notchState = .open
        
        // A drag preview goes straight to the shelf, so avoid unrelated media work.
        if !forShelfDrag && !forCompactAlert { MusicManager.shared.forceUpdate() }
    }

    /// Refreshes the cached notch sizes for the screen the window is now on.
    /// The collapsed size always follows the current screen; the active
    /// `notchSize` is only reset while the notch is closed so an open notch
    /// keeps its expanded layout and hit area.
    func refreshNotchSize(screenUUID: String?) {
        let closedSize = getClosedNotchSize(screenUUID: screenUUID)
        self.closedNotchSize = closedSize

        if notchState == .closed {
            self.notchSize = closedSize
        } else {
            self.notchSize.height = expandedNotchSize.height
        }
    }

    func close(allowDuringGuide: Bool = false) {
        // Do not close while a share picker, sharing service, or active open spotlight step is running
        if SharingStateManager.shared.preventNotchClose
            || (!allowDuringGuide && isSpotlightGuideActive && !NotchSpotlightGuideController.shared.isWaitingForInitialClick && !systemIslandPresentationActive) {
            return
        }
        if usesSystemIslandTrigger && notchState == .open {
            let now = ProcessInfo.processInfo.systemUptime
            // A fresh, confirmed vacancy can carry through our own close spring.
            // A native transition still requires a new quiet interval.
            let recheck = SystemIslandVacancy.requiresConfirmationOnClose(at: now,
                lastVacantSample: lastConfirmedNativeVacancyAt,
                nativePresentationActive: systemIslandPresentationActive || systemIslandReservedWidth != 0)
            nativeWingReleaseCheckAt = recheck ? now : nil
        }
        if notchState == .open, !compactAlertPresented, !openedForShelfDrag, !coordinator.firstLaunch {
            coordinator.lastNotchPage = NotchPage.selection(coordinator: coordinator,
                                                             activities: UnifiedActivities.shared).rawValue
        }
        refreshNotchSize(screenUUID: self.screenUUID)
        self.notchSize = self.closedNotchSize
        self.notchState = .closed
        self.setCompactAlertPresented(false)
        self.agentVoiceFocus = nil
        self.selectedAgentID = nil
        self.agentListExtraHeight = 0
        self.isBatteryPopoverActive = false
        self.isHeaderMenuActive = false
        self.isMusicVolumePopoverActive = false
        self.isAirPodsPopoverActive = false
        self.isMusicScrubbing = false
        self.isPanelPointerPressed = false
        self.isWeatherWarningListOpen = false
        self.isClipboardPreviewActive = false
        self.agentListPreviewHeightHeld = false
        self.agentConversationPreviewID = nil
        self.clipboardPendingSelectionID = nil
        self.coordinator.sneakPeek.show = false
        self.edgeAutoOpenActive = false

        if Defaults[.boringShelf], Defaults[.openShelfByDefault], !ShelfStateViewModel.shared.isEmpty {
            NotchPage.shelf.activate(coordinator: coordinator, activities: UnifiedActivities.shared)
        } else if !coordinator.openLastTabByDefault ||
                    (coordinator.currentView == .shelf && !Defaults[.boringShelf]) {
            NotchPage.music.activate(coordinator: coordinator, activities: UnifiedActivities.shared)
        }
    }

    func closeHello() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self else { return }
            self.coordinator.firstLaunch = false
            Task { @MainActor in
                withAnimation(self.animationLibrary.animation) { self.close() }
            }
        }
    }
}
