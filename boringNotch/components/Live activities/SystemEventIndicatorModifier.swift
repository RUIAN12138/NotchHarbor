    //
    //  SystemEventIndicatorModifier.swift
    //  boringNotch
    //
    //  Created by Richard Kunkli on 12/08/2024.
    //

import AppKit
import SwiftUI
import Defaults

struct SystemEventIndicatorModifier: View {
    @EnvironmentObject var vm: BoringViewModel
    @Binding var eventType: SneakContentType
    @Binding var value: CGFloat
    @Binding var icon: String
    let showSlider: Bool = false
    var sendEventBack: (CGFloat) -> Void
    
    var body: some View {
        HStack(spacing: 14) {
            switch (eventType) {
                case .volume:
                    Button { VolumeManager.shared.toggleMuteAction() } label: {
                        Image(systemName: icon.isEmpty ? SpeakerSymbol(value) : icon)
                            .contentTransition(.interpolate)
                            .frame(width: 24, height: 24)
                    }.buttonStyle(NotchControlStyle()).help("点击静音；滚动微调音量")
                case .brightness:
                    Image(systemName: "sun.max.fill")
                        .contentTransition(.symbolEffect)
                        .frame(width: 20, height: 15)
                        .foregroundStyle(.white)
                case .backlight:
                    Image(systemName: value > 0.5 ? "light.max" : "light.min")
                        .contentTransition(.interpolate)
                        .frame(width: 20, height: 15)
                        .foregroundStyle(.white)
                case .mic:
                    Image(systemName: "mic")
                        .symbolVariant(value > 0 ? .none : .slash)
                        .contentTransition(.interpolate)
                        .frame(width: 20, height: 15)
                        .foregroundStyle(.white)
                default:
                    EmptyView()
            }
            if (eventType != .mic) {
                DraggableProgressBar(value: $value, controlLabel: eventType.hudControlLabel, onChange: sendEventBack)
            } else {
                Text("Mic \(value > 0 ? "unmuted" : "muted")")
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .allowsTightening(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HUDVolumeScrollArea(enabled: eventType == .volume))
        .symbolVariant(.fill)
        .imageScale(.large)
    }
    
    func SpeakerSymbol(_ value: CGFloat) -> String {
        switch(value) {
            case 0:
                return "speaker.slash"
            case 0...0.3:
                return "speaker.wave.1"
            case 0.3...0.8:
                return "speaker.wave.2"
            case 0.8...1:
                return "speaker.wave.3"
            default:
                return "speaker.wave.2"
        }
    }
}

struct DraggableProgressBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var value: CGFloat
    var controlLabel: String = "进度"
    var onChange: ((CGFloat) -> Void)? = nil
    
    @State private var isDragging = false

    private var normalizedValue: CGFloat { value.isFinite ? max(0, min(value, 1)) : 0 }
    
    var body: some View {
        VStack {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.tertiary)
                    Capsule()
                        .fill(
                            Defaults[.enableGradient] ?
                                AnyShapeStyle(LinearGradient(
                                    colors: Defaults[.systemEventIndicatorUseAccent] ?
                                        [Color.effectiveAccent, Color.effectiveAccent.ensureMinimumBrightness(factor: 0.2)] :
                                        [Color.white, Color.white.opacity(0.2)],
                                    startPoint: .trailing,
                                    endPoint: .leading
                                )) :
                                AnyShapeStyle(Defaults[.systemEventIndicatorUseAccent] ? Color.effectiveAccent : Color.white)
                        )
                        .frame(width: max(0, min(geo.size.width * normalizedValue, geo.size.width)))
                        .shadow(color: Defaults[.systemEventIndicatorShadow] ?
                            (Defaults[.systemEventIndicatorUseAccent] ?
                                Color.effectiveAccent.ensureMinimumBrightness(factor: 0.7) :
                                Color.white) :
                            Color.clear,
                            radius: 8, x: 3)
                        .opacity(normalizedValue.isZero ? 0 : 1)
                        .transaction { transaction in
                            if isDragging || reduceMotion {
                                transaction.animation = nil
                                transaction.disablesAnimations = true
                            }
                        }
                }
                .frame(height: Defaults[.inlineHUD] ? (isDragging ? 8 : 5) : (isDragging ? 9 : 6))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isDragging)
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            if !isDragging {
                                isDragging = true
                                BoringViewCoordinator.shared.setHUDDragging(true)
                            }
                            guard geo.size.width > 0 else { return }
                            setValue(gesture.location.x / geo.size.width)
                        }
                        .onEnded { _ in
                            isDragging = false
                            BoringViewCoordinator.shared.setHUDDragging(false)
                        }
                )
            }
            .onDisappear { BoringViewCoordinator.shared.setHUDDragging(false) }
            .frame(height: 22)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(controlLabel)
            .accessibilityValue("\(Int((normalizedValue * 100).rounded()))%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: setValue(normalizedValue + 0.05)
                case .decrement: setValue(normalizedValue - 0.05)
                @unknown default: break
                }
            }
        }
    }
    
    private func setValue(_ proposed: CGFloat) {
        guard proposed.isFinite else { return }
        let next = max(0, min(proposed, 1))
        guard next != normalizedValue else { return }
        // Direct manipulation must not inherit the surrounding notch spring.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            value = next
            onChange?(next)
        }
    }
}

extension SneakContentType {
    var hudControlLabel: String {
        switch self {
        case .volume: "音量"
        case .brightness: "屏幕亮度"
        case .backlight: "键盘背光"
        default: "进度"
        }
    }
}

// Local scroll handling, reusing the application's existing AppKit event-monitor approach.
// Only consume vertical wheel events within this visible HUD, never a global event tap.
struct HUDVolumeScrollArea: NSViewRepresentable {
    var enabled: Bool
    func makeNSView(context: Context) -> Area { Area() }
    func updateNSView(_ view: Area, context: Context) { view.enabled = enabled }
    static func dismantleNSView(_ view: Area, coordinator: ()) { view.stop() }
    final class Area: NSView {
        var enabled = false
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.enabled, let window = self.window, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }
                guard event.momentumPhase.isEmpty else { return nil }
                let direction: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
                let amount = max(-0.05, min(0.05, event.scrollingDeltaY * direction * (event.hasPreciseScrollingDeltas ? 0.002 : 0.02)))
                Task { @MainActor in
                    let manager = VolumeManager.shared
                    let target = max(0, min(1, manager.rawVolume + Float(amount)))
                    manager.setAbsolute(target)
                }
                return nil
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
