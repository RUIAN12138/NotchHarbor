import AppKit
import SwiftUI

struct MenuPowerFlowDetail: View {
    let sample: MenuPowerSample?
    let measured: Bool
    let animates: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color {
        colorScheme == .dark ? Color(red: 0.39, green: 0.88, blue: 0.82)
            : Color(red: 0.05, green: 0.46, blue: 0.43)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if sample == nil && measured {
                Label("暂无功率读数", systemImage: "bolt.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                diagram
                if sample?.isLive == false {
                    Label("系统采样", systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("读数由 macOS 定期更新")
                }
            }
        }
        .padding(8)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.065)))
        .accessibilityIdentifier("menu-power-detail")
    }

    private var diagram: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let flow = sample?.flow
            let moving = animates && flow?.hasFlow == true

            ZStack(alignment: .topLeading) {
                ZStack {
                    Canvas { context, _ in
                        for route in PowerFlowRoute.routes(width: width, flow: flow) {
                            drawFlow(in: context, route: route)
                        }
                    }
                    if moving, let flow {
                        PowerFlowAnimation(flow: flow, color: NSColor(tint), dark: colorScheme == .dark)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                node("MenuPowerInput", sample?.pluggedIn == false ? "未接电" : "充电器",
                     watts: sample?.adapter, active: (flow?.fromAdapter ?? 0) > 0)
                    .position(x: 46, y: 26)
                node("MenuPowerBattery", batteryLabel(flow?.toBattery ?? 0),
                     watts: sample?.battery.map(abs), active: (flow?.toBattery ?? 0) != 0)
                    .position(x: 46, y: 76)
                node("MenuPowerLoad", "本机耗电", watts: sample?.system,
                     active: (flow?.toSystem ?? 0) > 0, featured: true)
                    .position(x: width - 31, y: 67)
            }
        }
        .frame(height: 101)
    }

    private func batteryLabel(_ flow: Double) -> LocalizedStringKey {
        if flow > 0 { return "电池充电" }
        if flow < 0 { return "电池供电" }
        return sample?.battery == nil ? "电池" : "电池待机"
    }

    private func node(_ icon: String, _ title: LocalizedStringKey, watts: Double?,
                      active: Bool, featured: Bool = false) -> some View {
        let badgeSize: CGFloat = featured ? 34 : 28
        let layout = featured ? AnyLayout(VStackLayout(spacing: 4))
                              : AnyLayout(HStackLayout(spacing: 7))
        return layout {
            Image(icon).resizable().frame(width: featured ? 19 : 14, height: featured ? 19 : 14)
                .foregroundStyle(active ? tint : .secondary)
                .frame(width: badgeSize, height: badgeSize)
                .background(active ? tint.opacity(colorScheme == .dark ? 0.14 : 0.095) : .primary.opacity(0.055), in: Circle())
                .overlay(Circle().strokeBorder(active ? tint.opacity(0.24) : .primary.opacity(0.08)))
                .accessibilityHidden(true)

            VStack(alignment: featured ? .center : .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(watts?.formatted(.number.precision(.fractionLength(1))) ?? "—")
                        .font(.system(size: featured ? 17 : 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(animates ? .easeOut(duration: 0.2) : nil, value: watts)
                    if watts != nil {
                        Text("W").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .frame(width: featured ? 62 : 92, height: featured ? 66 : 36,
               alignment: featured ? .top : .leading)
        .accessibilityElement(children: .combine)
    }

    private func drawFlow(in context: GraphicsContext, route: PowerFlowRoute) {
        let active = route.watts != 0
        let style = StrokeStyle(lineWidth: active ? route.thickness : 1.5, lineCap: .round)
        let path = route.path
        context.stroke(path, with: .color(active ? tint.opacity(0.34) : .primary.opacity(0.10)), style: style)

    }

}

private struct PowerFlowRoute {
    let start: CGPoint
    let end: CGPoint
    let watts: Double

    var thickness: CGFloat { 2.4 + min(4, sqrt(abs(watts)) * 0.45) }

    var path: Path { path(reversed: false) }

    func path(reversed: Bool) -> Path {
        let width = end.x - start.x
        let outgoing = CGPoint(x: start.x + width * 0.56, y: start.y)
        let incoming = CGPoint(x: end.x - width * 0.40, y: end.y)
        var path = Path()
        path.move(to: reversed ? end : start)
        path.addCurve(to: reversed ? start : end,
                      control1: reversed ? incoming : outgoing,
                      control2: reversed ? outgoing : incoming)
        return path
    }

    static func routes(width: CGFloat, flow: MenuPowerSample.Flow?) -> [Self] {
        let junction = CGPoint(x: width * 0.59, y: 51)
        return [
            .init(start: CGPoint(x: 92, y: 26), end: junction, watts: flow?.fromAdapter ?? 0),
            .init(start: CGPoint(x: 92, y: 76), end: junction, watts: -(flow?.toBattery ?? 0)),
            .init(start: junction, end: CGPoint(x: width - 50, y: junction.y), watts: flow?.toSystem ?? 0)
        ]
    }
}

struct PowerFlowAnimation: NSViewRepresentable {
    let flow: MenuPowerSample.Flow
    let color: NSColor
    let dark: Bool

    func makeNSView(context: Context) -> PowerFlowAnimationView { PowerFlowAnimationView() }

    func updateNSView(_ view: PowerFlowAnimationView, context: Context) {
        view.update(flow: flow, color: color, dark: dark)
    }
}

/// Core Animation drives the flow independently of SwiftUI's popup refresh cadence.
final class PowerFlowAnimationView: NSView {
    private final class Ribbon {
        let container = CALayer()
        let mask = CAShapeLayer()
        let gleam = CAGradientLayer()
        let particles = [CALayer(), CALayer()]
        var direction: Int = 0
        var extent: ClosedRange<CGFloat>?

        init() {
            container.mask = mask
            mask.fillColor = nil
            mask.strokeColor = NSColor.white.cgColor
            mask.lineCap = .round
            gleam.startPoint = CGPoint(x: 0, y: 0.5)
            gleam.endPoint = CGPoint(x: 1, y: 0.5)
            gleam.locations = [0, 0.25, 0.58, 0.83, 1]
            container.addSublayer(gleam)
            for particle in particles {
                particle.bounds = CGRect(x: 0, y: 0, width: 3.5, height: 3.5)
                particle.cornerRadius = 1.75
                particle.opacity = 0
                container.addSublayer(particle)
            }
        }
    }

    private let ribbons = (0..<3).map { _ in Ribbon() }
    private let batteryRing = CAShapeLayer()
    private var flow: MenuPowerSample.Flow?
    private var color: NSColor = .systemTeal
    private var dark = false
    private var batterySign: Int = 0

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        for ribbon in ribbons { layer?.addSublayer(ribbon.container) }
        batteryRing.bounds = CGRect(x: 0, y: 0, width: 48, height: 48)
        batteryRing.position = CGPoint(x: 14, y: 76)
        batteryRing.path = CGPath(ellipseIn: CGRect(x: 10, y: 10, width: 28, height: 28), transform: nil)
        batteryRing.fillColor = nil
        batteryRing.lineWidth = 1.4
        batteryRing.opacity = 0
        layer?.addSublayer(batteryRing)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(flow: MenuPowerSample.Flow, color: NSColor, dark: Bool) {
        self.flow = flow
        self.color = color
        self.dark = dark
        updateLayers()
    }

    override func layout() {
        super.layout()
        updateLayers()
    }

    private func updateLayers() {
        guard bounds.width > 180, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for (index, route) in PowerFlowRoute.routes(width: bounds.width, flow: flow).enumerated() {
            let ribbon = ribbons[index]
            let direction = route.watts == 0 ? 0 : route.watts > 0 ? 1 : -1
            ribbon.container.isHidden = direction == 0
            guard direction != 0 else {
                ribbon.direction = 0
                ribbon.gleam.removeAllAnimations()
                for particle in ribbon.particles { particle.removeAllAnimations() }
                continue
            }

            ribbon.container.frame = bounds
            ribbon.mask.frame = bounds
            ribbon.mask.path = route.path.cgPath
            ribbon.mask.lineWidth = route.thickness + 0.9
            let bright = dark ? NSColor(red: 0.82, green: 1, blue: 0.96, alpha: 1) : color
            let clear = bright.withAlphaComponent(0).cgColor
            let stops = [clear, color.withAlphaComponent(0.36).cgColor, bright.cgColor,
                         bright.withAlphaComponent(0.5).cgColor, clear]
            ribbon.gleam.colors = direction > 0 ? stops : Array(stops.reversed())
            for particle in ribbon.particles {
                particle.backgroundColor = bright.cgColor
            }

            let extent = (route.start.x - 23)...(route.end.x + 23)
            if ribbon.direction != direction || ribbon.extent != extent {
                ribbon.direction = direction
                ribbon.extent = extent
                ribbon.gleam.bounds = CGRect(x: 0, y: 0, width: 45, height: bounds.height)
                let origin = direction > 0 ? extent.lowerBound : extent.upperBound
                let destination = direction > 0 ? extent.upperBound : extent.lowerBound
                ribbon.gleam.position = CGPoint(x: origin, y: bounds.midY)
                let move = CABasicAnimation(keyPath: "position.x")
                move.fromValue = origin
                move.toValue = destination
                move.duration = 1.45
                move.repeatCount = .infinity
                move.timingFunction = CAMediaTimingFunction(name: .linear)
                ribbon.gleam.add(move, forKey: "power-flow")
                let routePath = route.path(reversed: direction < 0).cgPath
                let cycle = CFTimeInterval(1.45)
                for (index, particle) in ribbon.particles.enumerated() {
                    let motion = CAKeyframeAnimation(keyPath: "position")
                    motion.path = routePath
                    motion.calculationMode = .paced
                    motion.duration = cycle
                    let fade = CAKeyframeAnimation(keyPath: "opacity")
                    fade.values = [0, 0.95, 0.95, 0]
                    fade.keyTimes = [0, 0.15, 0.83, 1]
                    fade.duration = cycle
                    let travel = CAAnimationGroup()
                    travel.animations = [motion, fade]
                    travel.duration = cycle
                    travel.repeatCount = .infinity
                    travel.beginTime = particle.convertTime(CACurrentMediaTime(), from: nil) + Double(index) * cycle / 2
                    particle.add(travel, forKey: "flow-particle")
                }
            }
        }

        let battery = flow?.toBattery ?? 0
        let sign = battery == 0 ? 0 : battery > 0 ? 1 : -1
        batteryRing.strokeColor = color.cgColor
        if sign != batterySign {
            batterySign = sign
            batteryRing.removeAllAnimations()
            if sign != 0 {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = sign > 0 ? 1.15 : 0.86
                scale.toValue = sign > 0 ? 0.86 : 1.15
                scale.duration = 1.45
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 0.52, 0]
                fade.duration = scale.duration
                let pulse = CAAnimationGroup()
                pulse.animations = [scale, fade]
                pulse.duration = scale.duration
                pulse.repeatCount = .infinity
                batteryRing.add(pulse, forKey: "battery-flow")
            }
        }
    }
}
