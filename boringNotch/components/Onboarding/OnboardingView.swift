//
//  OnboardingView.swift
//  boringNotch
//
//  1. Clean native portrait Onboarding Sheet (inspired by Atoll & boring.notch on GitHub).
//  2. Live In-Notch Localized Spotlight Coachmark Guide (局部高光强调 directly inside the real Notch).
//

import AVFoundation
import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Defaults
import EventKit
import SwiftUI

enum OnboardingStep {
    case welcome
    case cameraPermission
    case calendarPermission
    case remindersPermission
    case accessibilityPermission
    case musicPermission
    case finished
}

@MainActor private let onboardingCalendarService = CalendarService()

struct OnboardingView: View {
    @Default(.settingsLanguage) private var settingsLanguage
    @State var step: OnboardingStep = .welcome
    let onFinish: () -> Void
    var onSkipGuide: (() -> Void)? = nil
    let onOpenSettings: () -> Void

    private var isEnglish: Bool {
        settingsLanguage.lowercased().hasPrefix("en")
    }

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeView {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        step = AXIsProcessTrusted() ? .calendarPermission : .accessibilityPermission
                    }
                }
                .transition(.opacity)

            case .accessibilityPermission:
                PermissionRequestView(
                    icon: Image(systemName: "hand.raised.fill"),
                    title: isEnglish ? "Enable Accessibility" : "开启辅助功能权限",
                    description: isEnglish
                        ? "Allows Notch Harbor to smoothly coexist with the macOS Dynamic Island, handle media/brightness HUDs, and approve Codex Desktop prompts in place."
                        : "用于实现与系统原生灵动岛平滑避让、接管音量亮度 HUD，以及在灵动岛内直接点击放行桌面端审批请求。",
                    privacyNote: isEnglish
                        ? "Used strictly for window geometry and explicit approval clicks — never logs keystrokes."
                        : "仅用于窗口几何避让与你主动触发的审批点击，绝不记录任何键盘输入。",
                    onAllow: {
                        Task {
                            _ = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
                            withAnimation(.easeInOut(duration: 0.4)) {
                                step = .calendarPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            step = .calendarPermission
                        }
                    }
                )
                .transition(.opacity)

            case .calendarPermission:
                PermissionRequestView(
                    icon: Image(systemName: "calendar"),
                    title: isEnglish ? "Calendar & Reminders" : "开启日历与提醒事项",
                    description: isEnglish
                        ? "Displays your upcoming 7-day schedule and reminders right inside the notch wheel."
                        : "授权后可在顶部灵动岛七日滚轮中快速浏览近期会议、日程安排与待办提醒。",
                    privacyNote: isEnglish
                        ? "Read locally on your Mac and never uploaded anywhere."
                        : "日程数据仅在本机读取展示，绝不会外传。",
                    onAllow: {
                        Task {
                            _ = try? await onboardingCalendarService.requestAccess(to: .event)
                            _ = try? await onboardingCalendarService.requestAccess(to: .reminder)
                            withAnimation(.easeInOut(duration: 0.4)) {
                                step = .cameraPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            step = .cameraPermission
                        }
                    }
                )
                .transition(.opacity)

            case .remindersPermission:
                PermissionRequestView(
                    icon: Image(systemName: "checklist"),
                    title: isEnglish ? "Enable Reminders" : "开启提醒事项",
                    description: isEnglish
                        ? "View due reminders alongside your calendar schedule."
                        : "在灵动岛日程旁同步展示今日待办提醒。",
                    privacyNote: nil,
                    onAllow: {
                        Task {
                            _ = try? await onboardingCalendarService.requestAccess(to: .reminder)
                            withAnimation(.easeInOut(duration: 0.4)) {
                                step = .cameraPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            step = .cameraPermission
                        }
                    }
                )
                .transition(.opacity)

            case .cameraPermission:
                PermissionRequestView(
                    icon: Image(systemName: "camera.fill"),
                    title: isEnglish ? "Camera Access (Optional)" : "摄像头权限（可选）",
                    description: isEnglish
                        ? "Used only when you open the in-notch mirror or enable head-gesture quick replies."
                        : "仅在你主动打开岛内随身镜或启用点头/摇头快捷回复时调用画面，随时可关闭。",
                    privacyNote: isEnglish
                        ? "Processed live on device — never recorded or stored."
                        : "所有画面均在本地实时处理，绝不录制或存储。",
                    onAllow: {
                        Task {
                            _ = await AVCaptureDevice.requestAccess(for: .video)
                            withAnimation(.easeInOut(duration: 0.4)) {
                                step = .musicPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            step = .musicPermission
                        }
                    }
                )
                .transition(.opacity)

            case .musicPermission:
                MusicControllerSelectionView {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        step = .finished
                    }
                }
                .transition(.opacity)

            case .finished:
                OnboardingFinishView(
                    onFinish: onFinish,
                    onSkipGuide: onSkipGuide,
                    onOpenSettings: onOpenSettings
                )
                .transition(.opacity)
            }
        }
        .frame(width: 400, height: 560)
    }
}

// MARK: - Minimal Interactive Click-on-Island Guide (无弹窗极简点击式灵动岛引导)

enum SpotlightGuideStepKind: Int, CaseIterable, Sendable {
    case clickCollapsedIsland = 0
    case clickShelfTab = 1
    case clickClipboardTab = 2
    case clickAgentTab = 3
    case clickCalendarTab = 4
    case clickMusicTab = 5

    var targetPage: NotchPage? {
        switch self {
        case .clickCollapsedIsland: return nil
        case .clickShelfTab: return .shelf
        case .clickClipboardTab: return .clipboard
        case .clickAgentTab: return .agent
        case .clickCalendarTab: return .calendar
        case .clickMusicTab: return .music
        }
    }

    func shortCue(english: Bool) -> String {
        switch self {
        case .clickCollapsedIsland:
            return english ? "Click Island" : "点击展开灵动岛"
        case .clickShelfTab:
            return english ? "Click Shelf" : "点击切换暂存架"
        case .clickClipboardTab:
            return english ? "Click Clipboard" : "点击切换剪贴板"
        case .clickAgentTab:
            return english ? "Click Agents" : "点击查看智能体"
        case .clickCalendarTab:
            return english ? "Click Agenda" : "点击查看日程"
        case .clickMusicTab:
            return english ? "Click Music" : "点击返回音乐"
        }
    }
}

struct SpotlightGuideGeometry: Equatable, Sendable {
    static let coachBarHeight: CGFloat = 0
    static let coachBarTopSpacing: CGFloat = 0
    static var reservedExtraHeight: CGFloat { 0 }

    var panelWidth: CGFloat
    var headerHeight: CGFloat
    var cameraClearanceWidth: CGFloat
    var topInset: CGFloat
    var pageWidth: CGFloat
    var pageHeight: CGFloat
    var shelfEnabled: Bool

    var upperBounds: CGRect {
        let w = max(1, panelWidth.isFinite ? panelWidth : 1)
        let h = max(1, (headerHeight + topInset + pageHeight).isFinite ? (headerHeight + topInset + pageHeight) : 1)
        return CGRect(x: 0, y: 0, width: w, height: h)
    }

    static func availableSteps(shelfEnabled: Bool) -> [SpotlightGuideStepKind] {
        SpotlightGuideStepKind.allCases.filter { shelfEnabled || $0 != .clickShelfTab }
    }

    /// Highlights the exact nav button inside the real Island header that the user clicks next.
    func spotlightRect(for step: SpotlightGuideStepKind) -> CGRect {
        let bounds = upperBounds
        let destinations = NotchPage.available(shelfEnabled: shelfEnabled)
        let camW = min(bounds.width, max(0, cameraClearanceWidth.isFinite ? cameraClearanceWidth : 0))
        let wing = max(0, (bounds.width - camW) / 2)
        let count = max(1, destinations.count)
        let buttonW = min(24, wing / CGFloat(count))
        let railW = CGFloat(count) * buttonW
        let railStartX = max(0, wing - railW)

        if let target = step.targetPage, let idx = destinations.firstIndex(of: target) {
            let centerX = railStartX + (CGFloat(idx) + 0.5) * buttonW
            let boxW = max(24, buttonW + 4)
            let boxH = max(20, min(26, headerHeight - 4))
            let y = max(1, (headerHeight - boxH) / 2 + 1)
            let raw = CGRect(x: centerX - boxW / 2, y: y, width: boxW, height: boxH)
            return Self.clamp(raw, inside: bounds)
        }

        let raw = CGRect(x: max(2, railStartX - 3), y: 2, width: max(24, railW + 6), height: max(20, headerHeight - 4))
        return Self.clamp(raw, inside: bounds)
    }

    func cornerRadius(for step: SpotlightGuideStepKind) -> CGFloat {
        let rect = spotlightRect(for: step)
        return min(12, min(rect.width, rect.height) / 2)
    }

    static func clamp(_ rect: CGRect, inside bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let w = min(bounds.width, max(1, rect.width.isFinite ? rect.width : 1))
        let h = min(bounds.height, max(1, rect.height.isFinite ? rect.height : 1))
        let rawX = rect.origin.x.isFinite ? rect.origin.x : bounds.minX
        let rawY = rect.origin.y.isFinite ? rect.origin.y : bounds.minY
        let x = min(max(bounds.minX, rawX), bounds.maxX - w)
        let y = min(max(bounds.minY, rawY), bounds.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

@MainActor
final class NotchSpotlightGuideController: ObservableObject {
    static let shared = NotchSpotlightGuideController()
    static let completedDefaultsKey = "hasCompletedSpotlightGuide"

    @Published private(set) var isActive: Bool = false
    @Published private(set) var stepIndex: Int = 0

    var onRequestOpenNotch: (() -> Void)?
    var onRequestCollapseNotch: (() -> Void)?
    private var keyMonitor: Any?

    private init() {}

    var hasCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: Self.completedDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.completedDefaultsKey) }
    }

    var activeSteps: [SpotlightGuideStepKind] {
        SpotlightGuideGeometry.availableSteps(shelfEnabled: Defaults[.boringShelf])
    }

    var currentStep: SpotlightGuideStepKind {
        let steps = activeSteps
        guard !steps.isEmpty else { return .clickCollapsedIsland }
        let safeIdx = min(max(0, stepIndex), steps.count - 1)
        return steps[safeIdx]
    }

    var isWaitingForInitialClick: Bool {
        isActive && currentStep == .clickCollapsedIsland
    }

    func start(force: Bool = true) {
        if !force && hasCompleted { return }
        BoringViewCoordinator.shared.firstLaunch = false
        BoringViewCoordinator.shared.isOnboardingActive = false
        NotchPage.music.activate(coordinator: BoringViewCoordinator.shared, activities: UnifiedActivities.shared)
        stepIndex = 0
        withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.86)) {
            isActive = true
        }
        onRequestCollapseNotch?()
        installKeyMonitorIfNeeded()
    }

    func notifyNotchOpened() {
        guard isActive, currentStep == .clickCollapsedIsland else { return }
        withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.85)) {
            stepIndex = min(1, max(0, activeSteps.count - 1))
        }
    }

    func handleNavTap(_ page: NotchPage) {
        guard isActive else { return }
        if currentStep.targetPage == page {
            nextStep(autoSwitchPage: false)
        }
    }

    func nextStep(autoSwitchPage: Bool = true) {
        let steps = activeSteps
        guard isActive, !steps.isEmpty else { return }
        if stepIndex + 1 < steps.count {
            withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.85)) {
                stepIndex += 1
            }
            if autoSwitchPage, let target = currentStep.targetPage {
                target.activate(coordinator: BoringViewCoordinator.shared, activities: UnifiedActivities.shared)
            }
            if currentStep != .clickCollapsedIsland {
                onRequestOpenNotch?()
            }
        } else {
            finish()
        }
    }

    func previousStep() {
        guard isActive, stepIndex > 1 else { return }
        withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.85)) {
            stepIndex -= 1
        }
    }

    func skip() {
        finish()
    }

    func finish() {
        hasCompleted = true
        removeKeyMonitor()
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.88)) {
            isActive = false
            stepIndex = 0
        }
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive else { return event }
            if event.keyCode == 53 { // Escape
                self.skip()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

private struct AnimatableSpotlightData: VectorArithmetic {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var radius: Double

    static var zero: Self { .init(x: 0, y: 0, width: 0, height: 0, radius: 0) }

    static func + (lhs: Self, rhs: Self) -> Self {
        .init(x: lhs.x + rhs.x, y: lhs.y + rhs.y, width: lhs.width + rhs.width, height: lhs.height + rhs.height, radius: lhs.radius + rhs.radius)
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        .init(x: lhs.x - rhs.x, y: lhs.y - rhs.y, width: lhs.width - rhs.width, height: lhs.height - rhs.height, radius: lhs.radius - rhs.radius)
    }

    mutating func scale(by rhs: Double) {
        x *= rhs; y *= rhs; width *= rhs; height *= rhs; radius *= rhs
    }

    var magnitudeSquared: Double {
        x * x + y * y + width * width + height * height + radius * radius
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: max(1, width), height: max(1, height))
    }
}

private struct SpotlightReverseCutoutShape: Shape {
    var hole: AnimatableSpotlightData

    var animatableData: AnimatableSpotlightData {
        get { hole }
        set { hole = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        let clampedHole = SpotlightGuideGeometry.clamp(hole.rect, inside: rect)
        let r = min(CGFloat(max(0, hole.radius)), min(clampedHole.width, clampedHole.height) / 2)
        path.addRoundedRect(in: clampedHole, cornerSize: CGSize(width: r, height: r), style: .continuous)
        return path
    }
}

private struct SpotlightHaloRimView: View, Animatable {
    var hole: AnimatableSpotlightData
    var pulse: Bool

    var animatableData: AnimatableSpotlightData {
        get { hole }
        set { hole = newValue }
    }

    var body: some View {
        let rect = hole.rect
        let r = min(CGFloat(max(0, hole.radius)), min(rect.width, rect.height) / 2)
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)

        ZStack {
            shape
                .stroke(
                    Color(red: 0.20, green: 0.85, blue: 0.98).opacity(pulse ? 0.72 : 0.34),
                    lineWidth: pulse ? 5.0 : 2.5
                )
                .blur(radius: 4)

            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white,
                            Color(red: 0.32, green: 0.92, blue: 0.84),
                            Color(red: 0.25, green: 0.68, blue: 1.0),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.8
                )
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }
}

struct NotchSpotlightCutoutOverlay: View {
    let geometry: SpotlightGuideGeometry
    let step: SpotlightGuideStepKind
    @ObservedObject private var controller = NotchSpotlightGuideController.shared
    @Default(.settingsLanguage) private var settingsLanguage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var isEnglish: Bool {
        settingsLanguage.lowercased().hasPrefix("en")
    }

    private var holeData: AnimatableSpotlightData {
        let rect = geometry.spotlightRect(for: step)
        let r = geometry.cornerRadius(for: step)
        return AnimatableSpotlightData(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height,
            radius: r
        )
    }

    var body: some View {
        let bounds = geometry.upperBounds
        let spot = geometry.spotlightRect(for: step)
        let pillX = min(max(64, spot.midX + 18), bounds.width - 74)
        let pillY = min(bounds.height - 16, spot.maxY + 18)

        ZStack(alignment: .topLeading) {
            SpotlightReverseCutoutShape(hole: holeData)
                .fill(Color.black.opacity(0.36), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

            SpotlightHaloRimView(hole: holeData, pulse: pulse)
                .allowsHitTesting(false)

            HStack(spacing: 5) {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0.38, green: 0.94, blue: 0.86))
                Text(step.shortCue(english: isEnglish))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Button {
                    controller.skip()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 15, height: 15)
                        .background(Color.white.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 9)
            .padding(.trailing, 5)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(Color.black.opacity(0.82))
                    .overlay {
                        Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8)
                    }
            }
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            .position(x: pillX, y: pillY)
        }
        .frame(width: bounds.width, height: bounds.height)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

struct ClosedIslandGuideCue: View {
    let islandSize: CGSize
    let isNotchShape: Bool
    var onTapIsland: () -> Void
    @ObservedObject private var controller = NotchSpotlightGuideController.shared
    @Default(.settingsLanguage) private var settingsLanguage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var isEnglish: Bool {
        settingsLanguage.lowercased().hasPrefix("en")
    }

    var body: some View {
        let shape: NotchShape = isNotchShape ? NotchShape() : .panel(expanded: false)
        VStack(spacing: 7) {
            ZStack {
                shape
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 0.24, green: 0.95, blue: 0.82),
                                Color(red: 0.22, green: 0.68, blue: 1.0),
                                Color(red: 0.56, green: 0.46, blue: 1.0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: pulse ? 4.2 : 2.2
                    )
                    .blur(radius: pulse ? 4.5 : 2.0)
                    .opacity(pulse ? 0.95 : 0.55)

                shape
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.95),
                                Color(red: 0.34, green: 0.94, blue: 0.86),
                                Color(red: 0.32, green: 0.72, blue: 1.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.6
                    )
            }
            .frame(width: max(120, islandSize.width), height: max(26, islandSize.height))
            .contentShape(Rectangle())
            .onTapGesture { onTapIsland() }

            HStack(spacing: 5) {
                Image(systemName: "cursorarrow.click.2")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0.36, green: 0.95, blue: 0.84))
                Text(SpotlightGuideStepKind.clickCollapsedIsland.shortCue(english: isEnglish))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Button {
                    controller.skip()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 15, height: 15)
                        .background(Color.white.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 9)
            .padding(.trailing, 5)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(Color.black.opacity(0.84))
                    .overlay {
                        Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8)
                    }
            }
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
