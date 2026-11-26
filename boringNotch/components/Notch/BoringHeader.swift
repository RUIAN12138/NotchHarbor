//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import AppKit
import Defaults
import SwiftUI

enum NotchPage: Int, CaseIterable, Identifiable {
    case music, shelf, clipboard, agent, calendar

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .music: return "音乐"
        case .shelf: return "文件架"
        case .clipboard: return "剪贴板"
        case .agent: return "Agent 会话"
        case .calendar: return "日历"
        }
    }

    var assetName: String {
        switch self {
        case .music: return "NotchNavMusic"
        case .shelf: return "NotchNavShelf"
        case .clipboard: return "NotchNavClipboard"
        case .agent: return "NotchNavAgent"
        case .calendar: return "NotchNavCalendar"
        }
    }

    var symbolName: String {
        switch self {
        case .music: return "music.note"
        case .shelf: return "tray"
        case .clipboard: return "doc.on.clipboard"
        case .agent: return "terminal"
        case .calendar: return "calendar"
        }
    }

    static func available(shelfEnabled: Bool) -> [Self] {
        allCases.filter { shelfEnabled || $0 != .shelf }
    }

    func neighbor(step: Int, shelfEnabled: Bool) -> Self? {
        let pages = Self.available(shelfEnabled: shelfEnabled)
        guard let index = pages.firstIndex(of: self), (-1...1).contains(step), step != 0 else { return nil }
        let target = index + step
        return pages.indices.contains(target) ? pages[target] : nil
    }

    @MainActor
    static func selection(coordinator: BoringViewCoordinator, activities: UnifiedActivities) -> Self {
        if coordinator.currentView == .shelf { return .shelf }
        if coordinator.currentView == .clipboard { return .clipboard }
        if activities.showPanel { return .agent }
        if activities.showDashboard { return .calendar }
        return .music
    }

    @MainActor
    func activate(coordinator: BoringViewCoordinator, activities: UnifiedActivities) {
        switch self {
        case .music:
            coordinator.currentView = .home
            activities.showPanel = false
            activities.showDashboard = false
        case .shelf:
            coordinator.currentView = .shelf
            activities.showPanel = false
            activities.showDashboard = false
        case .clipboard:
            coordinator.currentView = .clipboard
            activities.showPanel = false
            activities.showDashboard = false
        case .agent:
            coordinator.currentView = .home
            activities.showPanel = true
            activities.showDashboard = false
        case .calendar:
            coordinator.currentView = .home
            activities.showPanel = false
            activities.showDashboard = true
        }
    }
}

struct BoringHeader: View {
    @Default(.showBatteryIndicator) private var showBatteryIndicator
    @Default(.showMirror) private var showMirror
    @Default(.settingsIconInNotch) private var settingsIconInNotch
    @ObservedObject var activities = UnifiedActivities.shared
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.boringShelf) private var shelfEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredDestination: NotchPage?
    @State private var showsTools = false
    var cameraClearanceWidth: CGFloat? = nil
    /// Expanded header row height, normally the physical notch height (32 pt).
    var headerHeight: CGFloat = 32
    var showsSpotlightTargets = false
    var previewPage: Binding<NotchPage>?

    /// Hit target stays inside the header row and never exceeds 36 pt.
    private var controlHitHeight: CGFloat {
        min(30, max(0, headerHeight))
    }

    /// The visible capsule is inset by 3 pt top and bottom inside the hit area.
    private var controlCapsuleHeight: CGFloat {
        max(0, controlHitHeight - 6)
    }

    /// Shared label used by the camera preview and settings controls so both
    /// keep the same footprint and capsule treatment.
    private func controlLabel(_ systemName: String, weight: Font.Weight = .semibold) -> some View {
        ZStack {
            NotchControlSurface(shape: Capsule())
                .frame(width: 32, height: controlCapsuleHeight)
            Image(systemName: systemName)
                .font(.system(size: 13, weight: weight))
        }
        .frame(width: 32, height: controlHitHeight)
        .contentShape(Rectangle())
    }

    /// Anchor the rail to the camera clearance. Switching to a wider page
    /// changes the empty space to its left, not the targets under the pointer.
    private var navBar: some View {
        GeometryReader { proxy in
            let destinations = NotchPage.available(shelfEnabled: shelfEnabled)
            let width = min(24, proxy.size.width / CGFloat(destinations.count))
            let hoveredIndex = hoveredDestination.flatMap { destinations.firstIndex(of: $0) }
            HStack(spacing: 0) {
                ForEach(Array(destinations.enumerated()), id: \.element.id) { index, destination in
                    let adjacent = hoveredIndex.map { abs($0 - index) == 1 } ?? false
                    navButton(destination, width: width, adjacentToHover: adjacent)
                }
            }
            .anchorPreference(key: NotchSpotlightNavigationAnchor.self, value: .bounds) {
                showsSpotlightTargets ? $0 : nil
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: headerHeight)
    }

    private func navButton(_ destination: NotchPage, width: CGFloat, adjacentToHover: Bool) -> some View {
        let selected = (previewPage?.wrappedValue ?? NotchPage.selection(coordinator: coordinator, activities: activities)) == destination
        let hovered = hoveredDestination == destination
        let magnification: CGFloat = reduceMotion ? 0 : (hovered ? 1 : adjacentToHover ? 0.30 : 0)
        let iconSize = min(16, max(11, width * 0.56))

        return Button {
            if let previewPage {
                previewPage.wrappedValue = destination
            } else {
                destination.activate(coordinator: coordinator, activities: activities)
            }
        } label: {
            ZStack {
                NotchControlSurface(shape: Capsule(), emphasized: selected, isHovered: hovered)
                    // Leave vertical room for the whole button to rise without
                    // being clipped by the physical top edge of the display.
                    .frame(width: max(0, width - 2), height: min(18, controlCapsuleHeight))
                    .opacity(selected || hovered ? 1 : 0)
                    .accessibilityHidden(true)

                navGlyph(destination, size: iconSize)
                    .foregroundStyle(selected || hovered ? Color.primary : Color.primary.opacity(0.76))
                    .shadow(color: selected ? Color.primary.opacity(0.45) : .clear,
                            radius: selected ? 4 : 0)

                if destination == .agent, activities.hasPendingAgentApprovals {
                    Circle().fill(.red).frame(width: 5, height: 5)
                        .offset(x: iconSize * 0.45, y: -iconSize * 0.38)
                        .accessibilityHidden(true)
                }
            }
            // Move the glass button and its glyph as one object, while the
            // outer pointer target remains stable during Dock-style motion.
            .scaleEffect(1 + magnification * 0.24, anchor: .bottom)
            .offset(y: (vm.closedNotchSize.height > 0 ? 3 : 0) - magnification)
            .allowsHitTesting(false)
            .frame(width: width, height: controlHitHeight)
            .background { Color.clear }
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchControlStyle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.24, dampingFraction: 0.88)) {
                if hovering { hoveredDestination = destination }
                else if hoveredDestination == destination { hoveredDestination = nil }
            }
        }
        .help(destination.title)
        .accessibilityLabel(destination.title)
        .accessibilityValue(destination == .agent && activities.hasPendingAgentApprovals ? "有待审批请求" : "")
        .accessibilityIdentifier(destination.assetName)
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : [])
    }

    @ViewBuilder
    private func navGlyph(_ destination: NotchPage, size: CGFloat) -> some View {
        if let image = NSImage(named: destination.assetName) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: destination.symbolName)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size, height: size)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let cameraWidth = min(proxy.size.width, (cameraClearanceWidth ?? vm.closedNotchSize.width) + (vm.usesSystemIslandTrigger ? 4 : 16))
            let wing = max(0, (proxy.size.width - cameraWidth) / 2)
            HStack(spacing: 0) {
                navBar
                    .frame(width: wing, alignment: .leading)
                Color.clear.frame(width: cameraWidth)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                tools.frame(width: wing, alignment: .trailing)
            }
            .frame(height: headerHeight)
        }
        .frame(height: headerHeight)
        .onChange(of: showsTools) { _, open in
            vm.isHeaderMenuActive = open
            if open { activities.refreshConnectedAirPods() }
        }
        .onDisappear { vm.isHeaderMenuActive = false }
    }

    private var tools: some View {
        HStack(spacing: 5) {
            if showBatteryIndicator {
                BoringBatteryView(
                    batteryWidth: 23,
                    isCharging: batteryModel.isCharging,
                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                    isPluggedIn: batteryModel.isPluggedIn,
                    levelBattery: batteryModel.levelBattery,
                    maxCapacity: batteryModel.maxCapacity,
                    timeToFullCharge: batteryModel.timeToFullCharge,
                    isForNotification: false,
                    compact: true
                )
            }
            if settingsIconInNotch || showMirror || activities.connectedAirPods != nil ||
                MusicManager.shared.bundleIdentifier?.isEmpty == false {
                Button { showsTools.toggle() } label: { controlLabel("ellipsis", weight: .bold) }
                    .buttonStyle(NotchControlStyle())
                    .help("岛内菜单")
                    .accessibilityLabel("岛内菜单")
                    .popover(isPresented: $showsTools, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 9) {
                            if settingsIconInNotch {
                                Button { showsTools = false; SettingsWindowController.shared.showWindow() } label: {
                                    Label("打开设置", systemImage: "gear")
                                }
                            }
                            Button {
                                showsTools = false
                                NotchSpotlightGuideController.shared.start(force: true)
                            } label: {
                                Label("高光使用引导", systemImage: "sparkles")
                            }
                            if showMirror {
                                Button { showsTools = false; vm.toggleCameraPreview() } label: {
                                    Label("摄像头预览", systemImage: "web.camera")
                                }
                            }
                            if MusicManager.shared.bundleIdentifier != nil {
                                Button { showsTools = false; MusicManager.shared.openMusicApp() } label: {
                                    Label("打开播放应用", systemImage: "arrow.up.right.app")
                                }
                            }
                            if let device = activities.connectedAirPods {
                                Divider()
                                AirPodsMenuDetails(device: device) { showsTools = false }
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                        .padding(12)
                        .frame(minWidth: 150, alignment: .leading)
                    }
            }
        }
        .foregroundStyle(.secondary)
        .frame(height: headerHeight, alignment: .center)
        .padding(.trailing, 6)
    }

}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
