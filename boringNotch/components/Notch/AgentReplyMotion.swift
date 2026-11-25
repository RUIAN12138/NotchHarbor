import CoreMotion
import SwiftUI

struct AgentReplyHeadGesture {
    enum Action: Equatable { case left, right, confirm, dismiss }
    private var shake = DoubleShake()
    private var centeredSince: TimeInterval?
    private var movement: (action: Action, began: TimeInterval)?
    private var blocked = false

    mutating func update(yaw: Double, pitch: Double, at time: TimeInterval, allowsDismissal: Bool = false) -> Action? {
        if allowsDismissal && shake.update(yaw: yaw, pitch: pitch, at: time) {
            self = AgentReplyHeadGesture()
            return .dismiss
        }
        let centered = abs(yaw) < 7 && abs(pitch) < 7
        if let movement {
            if time - movement.began > 1.3
                || (movement.action == .confirm ? abs(yaw) > 10 : abs(pitch) > 12) {
                self.movement = nil
                centeredSince = nil
                blocked = true
            } else if centered {
                self.movement = nil
                centeredSince = time
                if time - movement.began >= 0.12 { return movement.action }
            }
            return nil
        }
        if centered {
            if centeredSince == nil { centeredSince = time }
            blocked = false
        } else if !blocked, let centeredSince, time - centeredSince >= 0.2 {
            if abs(yaw) >= 17 && abs(pitch) < 11 {
                movement = (yaw < 0 ? .left : .right, time)
            } else if pitch <= -14 && abs(yaw) < 10 {
                movement = (.confirm, time)
            }
        }
        return nil
    }

    /// Count opposite yaw peaks within one short shake, followed by a return to center.
    private struct DoubleShake {
        private var firstPeak: TimeInterval?
        private var lastPeak: TimeInterval = 0
        private var lastDirection = 0
        private var peakCount = 0
        private var neutralSince: TimeInterval?

        mutating func update(yaw: Double, pitch: Double, at time: TimeInterval) -> Bool {
            if let firstPeak, time - firstPeak > 1.30 || time - lastPeak > 0.60 { self = DoubleShake() }
            guard abs(pitch) < 12 else {
                self = DoubleShake()
                return false
            }
            if abs(yaw) < 7 {
                if peakCount >= 3 {
                    self = DoubleShake()
                    return true
                }
                if neutralSince == nil { neutralSince = time }
                if let neutralSince, time - neutralSince >= 0.18 { self = DoubleShake() }
                return false
            }
            // A deliberate pause at center separates ordinary selection turns.
            if let neutralSince, time - neutralSince >= 0.18 { self = DoubleShake() }
            neutralSince = nil
            guard abs(yaw) >= 17 else { return false }
            let direction = yaw < 0 ? -1 : 1
            guard direction != lastDirection else { return false }
            if firstPeak == nil { firstPeak = time }
            lastPeak = time
            lastDirection = direction
            peakCount += 1
            return false
        }
    }
}

struct AgentReplyMotionCommand: Equatable {
    let id = UUID()
    let action: AgentReplyHeadGesture.Action
}

struct AgentReplyMotionExcursion {
    enum Change: Equatable { case began, ended }
    private(set) var active = false

    mutating func observe(yaw: Double, pitch: Double) -> Change? {
        if !active && (abs(yaw) >= 12 || abs(pitch) >= 11) {
            active = true
            return .began
        }
        if active && abs(yaw) < 7 && abs(pitch) < 7 {
            active = false
            return .ended
        }
        return nil
    }
}

struct AgentReplyMotionAngles: Equatable {
    let yaw: Double
    let pitch: Double
    let roll: Double

    var isFinite: Bool { yaw.isFinite && pitch.isFinite && roll.isFinite }

    static func displayOffset(_ degrees: Double) -> Double {
        min(1, max(-1, degrees / 32))
    }
}

struct AgentReplyMotionPractice {
    static let steps: [AgentReplyHeadGesture.Action] = [.left, .right, .confirm]
    private(set) var completed = 0
    var passed: Bool { completed == Self.steps.count }

    mutating func recognize(_ action: AgentReplyHeadGesture.Action) {
        if !passed, Self.steps[completed] == action { completed += 1 }
    }
}

@MainActor
final class AgentReplyAngleReadout: ObservableObject {
    @Published private(set) var angles: AgentReplyMotionAngles?
    private var lastPublishedAt = -Double.infinity

    func publish(_ newAngles: AgentReplyMotionAngles, at time: TimeInterval) {
        guard newAngles.isFinite, time - lastPublishedAt >= 1.0 / 24 else { return }
        lastPublishedAt = time
        if angles != newAngles { angles = newAngles }
    }

    func clear() {
        lastPublishedAt = -.infinity
        if angles != nil { angles = nil }
    }
}

@MainActor
final class AgentReplyMotionStream: ObservableObject {
    enum Status: Equatable { case waiting, aligning, ready, denied }
    @Published private(set) var status: Status = .waiting
    let readout = AgentReplyAngleReadout()
    private let manager = CMHeadphoneMotionManager()
    private var reference: CMAttitude?
    private var referenceStartedAt: TimeInterval = 0
    private var lastTime: TimeInterval?
    private var lastArrival: ContinuousClock.Instant?
    private var recognizer = AgentReplyHeadGesture()
    private var excursion = AgentReplyMotionExcursion()
    private var lastHeadActivity: ContinuousClock.Instant?
    private var generation = 0

    var hasRecentHeadActivity: Bool {
        lastHeadActivity.map { $0.duration(to: .now) < .milliseconds(800) } ?? false
    }

    func run(allowsDismissal: Bool, showsAngles: Bool = false,
             onMotion: @escaping (AgentReplyMotionExcursion.Change) -> Void = { _ in },
             onGesture: @escaping (AgentReplyHeadGesture.Action) -> Void) async {
        generation += 1
        let session = generation
        manager.stopDeviceMotionUpdates()
        reset()
        var previousAuthorization = CMHeadphoneMotionManager.authorizationStatus()
        defer {
            if generation == session {
                manager.stopDeviceMotionUpdates()
                reset()
            }
        }
        while !Task.isCancelled && generation == session {
            let authorization = CMHeadphoneMotionManager.authorizationStatus()
            let justAuthorized = previousAuthorization == .notDetermined && authorization == .authorized
            previousAuthorization = authorization
            let streamStalled = lastArrival.map { $0.duration(to: .now) > .seconds(1) } ?? false
            if justAuthorized || streamStalled {
                manager.stopDeviceMotionUpdates()
                if excursion.active { onMotion(.ended) }
                reset()
            }
            if authorization == .denied || authorization == .restricted {
                if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
                if status != .denied { status = .denied }
            } else if manager.isDeviceMotionAvailable {
                if !manager.isDeviceMotionActive {
                    reset()
                    manager.startDeviceMotionUpdates(to: .main) { [weak self] sample, _ in
                        MainActor.assumeIsolated {
                            guard let self, self.generation == session, let sample else { return }
                            self.receive(sample, allowsDismissal: allowsDismissal, showsAngles: showsAngles,
                                         onMotion: onMotion, onGesture: onGesture)
                        }
                    }
                }
            } else {
                if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
                if status != .waiting {
                    if excursion.active { onMotion(.ended) }
                    reset()
                }
            }
            try? await Task.sleep(for: .milliseconds(350))
        }
    }

    private func reset() {
        reference = nil
        referenceStartedAt = 0
        lastTime = nil
        lastArrival = nil
        recognizer = AgentReplyHeadGesture()
        excursion = AgentReplyMotionExcursion()
        lastHeadActivity = nil
        readout.clear()
        status = .waiting
    }

    private func receive(_ sample: CMDeviceMotion, allowsDismissal: Bool, showsAngles: Bool,
                         onMotion: (AgentReplyMotionExcursion.Change) -> Void,
                         onGesture: (AgentReplyHeadGesture.Action) -> Void) {
        let time = sample.timestamp
        // A route change or an interruption can reset the headphone's reference frame.
        if let lastTime, time < lastTime || time - lastTime > 0.7 {
            if excursion.active { onMotion(.ended) }
            reset()
        }
        lastTime = time
        lastArrival = .now
        guard let relative = sample.attitude.copy() as? CMAttitude else { return }
        guard let reference else {
            self.reference = relative
            referenceStartedAt = time
            status = .aligning
            return
        }
        relative.multiply(byInverseOf: reference)
        let yaw = -relative.yaw * 180 / .pi
        let pitch = relative.pitch * 180 / .pi
        guard yaw.isFinite, pitch.isFinite else { return }
        if status != .ready {
            if abs(yaw) > 6 || abs(pitch) > 6 {
                self.reference = sample.attitude.copy() as? CMAttitude
                referenceStartedAt = time
            } else if time - referenceStartedAt >= 0.35 {
                status = .ready
            }
            return
        }
        if showsAngles {
            readout.publish(.init(yaw: yaw, pitch: pitch, roll: relative.roll * 180 / .pi), at: time)
        }
        let change = excursion.observe(yaw: yaw, pitch: pitch)
        if abs(yaw) >= 8 || abs(pitch) >= 8 || change == .ended { lastHeadActivity = .now }
        if change == .began { onMotion(.began) }
        if let action = recognizer.update(yaw: yaw, pitch: pitch, at: time, allowsDismissal: allowsDismissal) {
            onGesture(action)
        }
        if change == .ended { onMotion(.ended) }
    }
}

struct AgentPopupSummary: View {
    let markdown: String

    var body: some View {
        Text(AgentMarkdownFormatting.inline(markdown))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

struct AgentReplyChoiceCard: View {
    static let practiceHeight: CGFloat = 172
    let title: String
    var summary: String? = nil
    let options: [AgentReplyOption]
    let isPractice: Bool
    var openSummary: (() -> Void)? = nil
    let acceptsHeadMotion: Bool
    var motionCommand: AgentReplyMotionCommand? = nil
    let submit: (Int) -> Bool
    let dismiss: () -> Void

    @AppStorage(AgentReplyMotionSettings.enabledKey) private var motionEnabled = false
    @AppStorage(AgentReplyMotionSettings.testedKey) private var motionTested = false
    @StateObject private var motion = AgentReplyMotionStream()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: Int?
    private var selected: Int { selection ?? options.count / 2 }
    @State private var practice = AgentReplyMotionPractice()
    @State private var rejected = false
    @State private var submitted = false

    private let choiceHeight: CGFloat = 40

    private var usesMotion: Bool {
        acceptsHeadMotion && motionEnabled && (isPractice ? !practice.passed : motionTested && !submitted && !rejected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(rejected ? "会话已更新" : title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                if isPractice {
                    Button(action: dismiss) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    }
                    .accessibilityLabel("关闭练习")
                }
            }

            if isPractice {
                practicePanel
            } else if let summary {
                if let openSummary {
                    Button(action: openSummary) {
                        AgentPopupSummary(markdown: summary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityHint("打开对应会话")
                } else {
                    AgentPopupSummary(markdown: summary)
                }
                choices
            } else {
                choices
            }
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .task(id: isPractice && usesMotion) {
            if isPractice && usesMotion {
                await motion.run(allowsDismissal: false, showsAngles: true, onGesture: receive)
            }
        }
        .onChange(of: motionCommand) { _, command in
            if !isPractice, let command { receive(command.action) }
        }
    }

    @ViewBuilder
    private var choices: some View {
        if !options.isEmpty {
            choiceTrack
        }
    }

    private var choiceTrack: some View {
        GeometryReader { geometry in
                let spacing: CGFloat = 3
                let width = max(0, (geometry.size.width - spacing * CGFloat(options.count - 1)) / CGFloat(options.count))
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(.primary.opacity(0.065))
                        .allowsHitTesting(false)

                    AgentReplyGlassThumb()
                        .frame(width: max(0, width - 4), height: choiceHeight - 6)
                        .offset(x: 2 + CGFloat(selected) * (width + spacing), y: 3)
                        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.85), value: selected)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    HStack(spacing: spacing) {
                        ForEach(options.indices, id: \.self) { index in
                            choiceButton(index, width: width)
                        }
                    }
                }
        }
        .frame(height: choiceHeight)
    }

    private var practicePanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                if practice.passed {
                    HStack(spacing: 12) {
                        AgentMotionSuccessMark()
                        VStack(alignment: .leading, spacing: 3) {
                            Text("头动测试通过").font(.system(size: 14, weight: .semibold))
                            Text("左转、右转和点头均已识别").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 12)
                    .transition(.opacity)
                } else {
                    AgentMotionLiveAngles(readout: motion.readout)
                        .transition(.opacity)
                }
            }
            .frame(height: 77)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 5) {
                ForEach(Array(["左转", "右转", "点头"].enumerated()), id: \.offset) { index, title in
                    let done = index < practice.completed
                    Label(title, systemImage: done ? "checkmark.circle.fill" : ["arrow.left", "arrow.right", "arrow.down"][index])
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(done ? Color.green : index == practice.completed ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(.primary.opacity(index == practice.completed ? 0.12 : 0.055), in: Capsule())
                        .accessibilityValue(done ? "已通过" : index == practice.completed ? "等待操作" : "未开始")
                }
            }

            HStack {
                Text(practiceInstruction).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 3)
                if practice.passed { Button("完成", action: dismiss).buttonStyle(.bordered) }
            }
            .frame(minHeight: 23)
        }
    }

    private func choiceButton(_ index: Int, width: CGFloat) -> some View {
        Button {
            select(index)
        } label: {
            Text(AgentMarkdownFormatting.inline(options[index].title))
                .font(.system(size: 11, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 5)
                .frame(width: width, height: choiceHeight)
                .contentShape(Rectangle())
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard !isPractice, !submitted else { return }
            select(index)
            confirm(index)
        })
        .disabled(isPractice || submitted)
        .accessibilityAddTraits(index == selected ? [.isSelected] : [])
        .accessibilityHint(isPractice ? "" : "单击选中，双击发送")
        .accessibilityAction(named: "发送此回复") {
            guard !isPractice else { return }
            select(index)
            confirm(index)
        }
        .help(options[index].body)
    }

    private var practiceInstruction: String {
        if practice.passed { return "可以关闭测试。快捷回复已启用。" }
        guard usesMotion else { return "请先开启头动快捷回复" }
        switch motion.status {
        case .waiting: return "请佩戴支持头部追踪的 AirPods 并连接此 Mac"
        case .denied: return "请在系统设置中允许 Notch Harbor 访问运动数据"
        case .aligning: return "请看向屏幕并保持头部不动"
        case .ready: return ["向左转头，再回正", "向右转头，再回正", "低头再抬起，确认选项"][practice.completed]
        }
    }

    private func receive(_ action: AgentReplyHeadGesture.Action) {
        guard usesMotion else { return }
        if isPractice {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                practice.recognize(action)
            }
            if practice.passed { motionTested = true }
        } else {
            switch action {
            case .left: select(max(0, selected - 1))
            case .right: select(min(options.count - 1, selected + 1))
            case .confirm: confirm(selected)
            case .dismiss: dismiss()
            }
        }
    }

    private func select(_ index: Int) {
        guard !submitted, options.indices.contains(index) else { return }
        selection = index
        rejected = false
    }

    private func confirm(_ index: Int) {
        guard !isPractice, !submitted, !rejected, options.indices.contains(index) else { return }
        submitted = submit(index)
        rejected = !submitted
    }
}

private struct AgentMotionLiveAngles: View {
    @ObservedObject var readout: AgentReplyAngleReadout

    var body: some View {
        HStack(spacing: 14) {
            let angles = readout.angles
            ZStack {
                Circle().strokeBorder(.primary.opacity(0.13), lineWidth: 1)
                Circle().strokeBorder(.primary.opacity(0.11), lineWidth: 1).padding(10)
                Rectangle().fill(.primary.opacity(0.11)).frame(width: 1, height: 50)
                Rectangle().fill(.primary.opacity(0.11)).frame(width: 50, height: 1)
                Capsule().fill(angles == nil ? Color.secondary : .cyan)
                    .frame(width: 13, height: 5)
                    .rotationEffect(.degrees(angles?.roll ?? 0))
                    .offset(x: 20 * AgentReplyMotionAngles.displayOffset(angles?.yaw ?? 0),
                            y: -20 * AgentReplyMotionAngles.displayOffset(angles?.pitch ?? 0))
            }
            .frame(width: 55, height: 55)
            .accessibilityHidden(true)

            HStack(spacing: 8) {
                angle("转头", angles?.yaw)
                angle("点头", angles?.pitch)
                angle("侧倾", angles?.roll)
            }
        }
        .padding(.horizontal, 10)
        .accessibilityIdentifier("agent-head-motion-angles")
    }

    private func angle(_ title: String, _ degrees: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(degrees.map { String(format: "%+.0f°", abs($0) < 0.5 ? 0 : $0) } ?? "—")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct AgentMotionSuccessMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        ZStack {
            Circle().fill(.green.opacity(0.12))
            Circle().trim(from: 0, to: drawn ? 1 : 0)
                .stroke(.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Path { path in
                path.move(to: CGPoint(x: 14, y: 23))
                path.addLine(to: CGPoint(x: 20, y: 29))
                path.addLine(to: CGPoint(x: 32, y: 16))
            }
            .trim(from: 0, to: drawn ? 1 : 0)
            .stroke(.green, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 46, height: 46)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) { drawn = true }
        }
    }
}

/// One persistent glass surface moves below the option labels.
private struct AgentReplyGlassThumb: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    private let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)

    var body: some View {
        surface
            .overlay {
                shape.strokeBorder(
                    LinearGradient(stops: [
                        .init(color: .white.opacity(colorScheme == .dark ? 0.63 : 0.87), location: 0),
                        .init(color: .white.opacity(0.22), location: 0.42),
                        .init(color: .black.opacity(0.16), location: 1)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.33 : 0.17), radius: 4, y: 2)
    }

    @ViewBuilder
    private var surface: some View {
        if reduceTransparency {
            shape.fill(colorScheme == .dark ? Color(white: 0.24) : .white)
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.regularMaterial)
        }
    }
}
