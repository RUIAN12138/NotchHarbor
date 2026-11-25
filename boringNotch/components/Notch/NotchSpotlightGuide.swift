//
//  NotchSpotlightGuide.swift
//  NotchHarbor
//
//  Interactive spotlight coach-mark guided tour for first-launch onboarding
//  and on-demand replay inside the live Notch shell.
//

import AppKit
import Combine
import CoreGraphics
import Defaults
import Foundation
import SwiftUI

// === SPOTLIGHT_GUIDE_MODEL_BEGIN ===
enum SpotlightGuideStepKind: Int, CaseIterable, Sendable {
    case navHubs = 0
    case musicFolia = 1
    case shelfAirDrop = 2
    case clipboardAutoCopy = 3
    case agentSessions = 4
    case calendarWeather = 5

    var pageRawValue: Int {
        switch self {
        case .navHubs, .musicFolia:
            return 0 // NotchPage.music
        case .shelfAirDrop:
            return 1 // NotchPage.shelf
        case .clipboardAutoCopy:
            return 2 // NotchPage.clipboard
        case .agentSessions:
            return 3 // NotchPage.agent
        case .calendarWeather:
            return 4 // NotchPage.calendar
        }
    }

    var symbolName: String {
        switch self {
        case .navHubs: return "sparkles.rectangle.stack"
        case .musicFolia: return "waveform"
        case .shelfAirDrop: return "tray.and.arrow.up.fill"
        case .clipboardAutoCopy: return "doc.on.clipboard.fill"
        case .agentSessions: return "terminal.fill"
        case .calendarWeather: return "cloud.sun.rain.fill"
        }
    }

    func title(english: Bool) -> String {
        switch self {
        case .navHubs:
            return english ? "5-in-1 Top Hub Rail" : "五合一顶栏中枢"
        case .musicFolia:
            return english ? "Word-Synced Lyrics & Spectrum" : "Folia 逐词歌词与液态光谱"
        case .shelfAirDrop:
            return english ? "Drop Shelf & Quick AirDrop" : "跨窗文件暂存与一键投送"
        case .clipboardAutoCopy:
            return english ? "Wheel History & Substring Auto-Copy" : "滚轮横滑与划选自动复制"
        case .agentSessions:
            return english ? "Multi-Agent Hub & Menu Power Flow" : "多路 CLI Agent 监管与功耗监控"
        case .calendarWeather:
            return english ? "Weather Alerts & 7-Day Wheel" : "气象预警与七日滚轮日程"
        }
    }

    func detail(english: Bool) -> String {
        switch self {
        case .navHubs:
            return english
                ? "Hover the left-wing icons for Dock magnification, or swipe horizontally with two fingers to switch hubs."
                : "掠过左翼图标触发邻近放大，点击或双指横滑即可在五大高频工作台间秒切。"
        case .musicFolia:
            return english
                ? "Follow live Folia word-by-word lyrics and the 16-band SiriGlass waterline without leaving your active app."
                : "实时同步逐词扫光歌词与底部 16 频段折射光波，支持直接拖拽进度条与调节音量。"
        case .shelfAirDrop:
            return english
                ? "Drag any file toward the closed notch to wake the glass orb, stash items, or drop left for instant AirDrop."
                : "抓起桌面或访达文件移向刘海即可唤醒光球暂存，拖入左侧绿色区域即可隔空投送。"
        case .clipboardAutoCopy:
            return english
                ? "Scroll horizontally through text, images, and files; hover to expand, select a substring, and leave to auto-copy."
                : "滚轮翻阅文字图片与多文件记录；悬停展开长文本并划选局部，鼠标移出刘海即自动复制。"
        case .agentSessions:
            return english
                ? "Track Codex, Claude Code, Antigravity, and Doubao inline, send quick replies, and inspect 65W power flow in the menu bar."
                : "同屏掌握多路 AI 会话审批并岛内发令；点击右上角菜单栏图标还可查看配额与功率丝带。"
        case .calendarWeather:
            return english
                ? "Check live weather alerts on the left and spin the 7-day wheel picker to preview upcoming events and reminders."
                : "左侧实时展示气温与降水预警，右侧拨动七日滚轮即可速览会议日程与待办提醒。"
        }
    }
}

struct SpotlightGuideGeometry: Equatable, Sendable {
    static let coachBarHeight: CGFloat = 66
    static let coachBarTopSpacing: CGFloat = 6
    static var reservedExtraHeight: CGFloat { coachBarHeight + coachBarTopSpacing }

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
        SpotlightGuideStepKind.allCases.filter { shelfEnabled || $0 != .shelfAirDrop }
    }

    func availableSteps() -> [SpotlightGuideStepKind] {
        Self.availableSteps(shelfEnabled: shelfEnabled)
    }

    func spotlightRect(for step: SpotlightGuideStepKind) -> CGRect {
        let bounds = upperBounds
        let raw: CGRect

        switch step {
        case .navHubs:
            let camW = min(bounds.width, max(0, cameraClearanceWidth.isFinite ? cameraClearanceWidth : 0))
            let wing = max(0, (bounds.width - camW) / 2)
            let count = max(1, shelfEnabled ? 5 : 4)
            let buttonW = min(24, wing / CGFloat(count))
            let railW = max(36, CGFloat(count) * buttonW)
            let x = max(2, wing - railW - 5)
            let w = min(bounds.width - x - 2, railW + 10)
            let h = max(20, min(bounds.height - 2, headerHeight - 2))
            raw = CGRect(x: x, y: 1, width: max(24, w), height: h)

        case .musicFolia, .shelfAirDrop, .clipboardAutoCopy, .agentSessions, .calendarWeather:
            let safePageW = min(bounds.width - 4, max(40, pageWidth.isFinite ? pageWidth : bounds.width - 4))
            let x = max(2, (bounds.width - safePageW) / 2)
            let y = max(0, min(bounds.height - 24, headerHeight + topInset))
            let w = min(bounds.width - x - 2, safePageW)
            let h = max(20, min(bounds.maxY - y - 1, pageHeight))
            raw = CGRect(x: x, y: y, width: max(24, w), height: h)
        }

        return Self.clamp(raw, inside: bounds)
    }

    func cornerRadius(for step: SpotlightGuideStepKind) -> CGFloat {
        let rect = spotlightRect(for: step)
        let preferred: CGFloat = (step == .navHubs) ? 13 : 15
        return min(preferred, min(rect.width, rect.height) / 2)
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
// === SPOTLIGHT_GUIDE_MODEL_END ===

@MainActor
final class NotchSpotlightGuideController: ObservableObject {
    static let shared = NotchSpotlightGuideController()
    static let completedDefaultsKey = "hasCompletedSpotlightGuide"

    @Published private(set) var isActive: Bool = false
    @Published private(set) var stepIndex: Int = 0

    var onRequestOpenNotch: (() -> Void)?
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
        guard !steps.isEmpty else { return .navHubs }
        let safeIdx = min(max(0, stepIndex), steps.count - 1)
        return steps[safeIdx]
    }

    func startIfNeededAfterFirstLaunch() {
        guard !hasCompleted else { return }
        start(force: true)
    }

    func start(force: Bool = true) {
        if !force && hasCompleted { return }
        BoringViewCoordinator.shared.firstLaunch = false
        stepIndex = 0
        onRequestOpenNotch?()
        withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.86)) {
            isActive = true
        }
        activatePageForCurrentStep()
        installKeyMonitorIfNeeded()
    }

    func nextStep() {
        let steps = activeSteps
        guard isActive, !steps.isEmpty else { return }
        if stepIndex + 1 < steps.count {
            withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.84)) {
                stepIndex += 1
            }
            activatePageForCurrentStep()
        } else {
            finish()
        }
    }

    func previousStep() {
        guard isActive, stepIndex > 0 else { return }
        withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.84)) {
            stepIndex -= 1
        }
        activatePageForCurrentStep()
    }

    func selectStep(_ index: Int) {
        let steps = activeSteps
        guard isActive, steps.indices.contains(index) else { return }
        withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.84)) {
            stepIndex = index
        }
        activatePageForCurrentStep()
    }

    func skip() {
        finish()
    }

    func finish() {
        hasCompleted = true
        removeKeyMonitor()
        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.88)) {
            isActive = false
            stepIndex = 0
        }
    }

    private func activatePageForCurrentStep() {
        guard let page = NotchPage(rawValue: currentStep.pageRawValue) else { return }
        withAnimation(.smooth(duration: 0.22)) {
            page.activate(coordinator: BoringViewCoordinator.shared, activities: UnifiedActivities.shared)
        }
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive else { return event }
            switch event.keyCode {
            case 53: // Escape
                self.skip()
                return nil
            case 123: // Left Arrow
                self.previousStep()
                return nil
            case 124, 36, 76: // Right Arrow, Return, Enter
                self.nextStep()
                return nil
            default:
                return event
            }
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
        .init(
            x: lhs.x + rhs.x,
            y: lhs.y + rhs.y,
            width: lhs.width + rhs.width,
            height: lhs.height + rhs.height,
            radius: lhs.radius + rhs.radius
        )
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        .init(
            x: lhs.x - rhs.x,
            y: lhs.y - rhs.y,
            width: lhs.width - rhs.width,
            height: lhs.height - rhs.height,
            radius: lhs.radius - rhs.radius
        )
    }

    mutating func scale(by rhs: Double) {
        x *= rhs
        y *= rhs
        width *= rhs
        height *= rhs
        radius *= rhs
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
                    Color(red: 0.62, green: 0.84, blue: 1.0).opacity(pulse ? 0.52 : 0.28),
                    lineWidth: pulse ? 4.2 : 2.6
                )
                .blur(radius: 4)

            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color(red: 0.62, green: 0.84, blue: 1.0),
                            Color.white.opacity(0.96),
                            Color(red: 0.39, green: 0.88, blue: 0.82),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.65
                )
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }
}

struct NotchSpotlightCutoutOverlay: View {
    let geometry: SpotlightGuideGeometry
    let step: SpotlightGuideStepKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

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
        ZStack(alignment: .topLeading) {
            SpotlightReverseCutoutShape(hole: holeData)
                .fill(Color.black.opacity(0.54), style: FillStyle(eoFill: true))

            SpotlightHaloRimView(hole: holeData, pulse: pulse)
        }
        .frame(width: bounds.width, height: bounds.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

struct NotchSpotlightCoachBar: View {
    @ObservedObject var controller = NotchSpotlightGuideController.shared
    @Default(.settingsLanguage) private var settingsLanguage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isEnglish: Bool {
        settingsLanguage.lowercased().hasPrefix("en")
    }

    var body: some View {
        let steps = controller.activeSteps
        let count = max(1, steps.count)
        let safeIdx = min(max(0, controller.stepIndex), count - 1)
        let step = steps.isEmpty ? .navHubs : steps[safeIdx]
        let isLast = safeIdx == count - 1

        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.62, green: 0.84, blue: 1.0).opacity(0.24),
                                Color(red: 0.39, green: 0.88, blue: 0.82).opacity(0.16),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
                    }
                Image(systemName: step.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.68, green: 0.88, blue: 1.0))
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(safeIdx + 1)/\(count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.62, green: 0.84, blue: 1.0))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.white.opacity(0.1), in: Capsule())

                    Text(step.title(english: isEnglish))
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                Text(step.detail(english: isEnglish))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 4) {
                    ForEach(Array(steps.enumerated()), id: \.element.rawValue) { idx, _ in
                        Button {
                            controller.selectStep(idx)
                        } label: {
                            Capsule()
                                .fill(idx == safeIdx
                                      ? Color(red: 0.62, green: 0.84, blue: 1.0)
                                      : Color.white.opacity(0.24))
                                .frame(width: idx == safeIdx ? 14 : 5, height: 5)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isEnglish ? "Step \(idx + 1)" : "第 \(idx + 1) 步")
                    }
                }

                HStack(spacing: 6) {
                    Button {
                        controller.skip()
                    } label: {
                        Text(isEnglish ? "Skip" : "跳过")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.68))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)

                    if safeIdx > 0 {
                        Button {
                            controller.previousStep()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Color.white.opacity(0.12), in: Capsule())
                                .overlay {
                                    Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.6)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isEnglish ? "Previous step" : "上一步")
                    }

                    Button {
                        controller.nextStep()
                    } label: {
                        HStack(spacing: 4) {
                            Text(isLast ? (isEnglish ? "Get Started" : "开始使用") : (isEnglish ? "Next" : "下一步"))
                                .font(.system(size: 11.5, weight: .bold))
                            Image(systemName: isLast ? "checkmark" : "arrow.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(Color(red: 0.03, green: 0.06, blue: 0.12))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.68, green: 0.88, blue: 1.0),
                                    Color(red: 0.48, green: 0.90, blue: 0.84),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: SpotlightGuideGeometry.coachBarHeight)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.white.opacity(0.075))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
                }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: safeIdx)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isEnglish ? "Notch Harbor Spotlight Guide" : "Notch Harbor 高光使用引导")
    }
}
