//
//  PanGesture.swift
//  boringNotch
//
//  Created by Richard Kunkli on 21/08/2024.
//

import AppKit
import SwiftUI

enum PanDirection {
    case left, right, up, down

    var isHorizontal: Bool { self == .left || self == .right }
    var sign: CGFloat { (self == .right || self == .down) ? 1 : -1 }

    func signed(from translation: CGSize) -> CGFloat { (isHorizontal ? translation.width : translation.height) * sign }
    func signed(deltaX: CGFloat, deltaY: CGFloat) -> CGFloat { (isHorizontal ? deltaX : deltaY) * sign }
}

extension View {
    func panGesture(direction: PanDirection, threshold: CGFloat = 4, startsWithMomentum: Bool = true,
                    requiresEligibleStart: Bool = false, isEnabled: @escaping () -> Bool = { true },
                    action: @escaping (CGFloat, NSEvent.Phase) -> Void) -> some View {
        self
            .simultaneousGesture(
                DragGesture(minimumDistance: max(threshold, 8))
                    .onChanged { value in
                        guard isEnabled() else { action(0, .cancelled); return }
                        let s = direction.signed(from: value.translation)
                        let crossAxis = direction.isHorizontal ? value.translation.height : value.translation.width
                        guard s >= threshold, s >= crossAxis.magnitude * 1.5 else { return }
                        action(s.magnitude, .changed)
                    }
                    .onEnded { _ in action(0, .ended) }
            )
            .background(ScrollMonitor(direction: direction, threshold: threshold,
                                      startsWithMomentum: startsWithMomentum, requiresEligibleStart: requiresEligibleStart,
                                      isEnabled: isEnabled, action: action))
    }
}

/// AppKit window coordinates; reject detached views and transparent window slack.
enum NotchScrollHitRegion {
    static func contains(eventWindow: NSWindow?, locationInWindow: NSPoint, in view: NSView) -> Bool {
        guard let window = view.window, eventWindow === window else { return false }
        return view.bounds.contains(view.convert(locationInWindow, from: nil))
    }
}

/// A phased trackpad stroke and its inertia belong to the region where it began.
struct NotchScrollOwnership {
    private var owned = false

    mutating func update(phase: NSEvent.Phase, momentum: NSEvent.Phase, inside: Bool) -> Bool {
        if !momentum.isEmpty {
            let result = owned
            if momentum.contains(.ended) || momentum.contains(.cancelled) { owned = false }
            return result
        }
        if phase.isEmpty { return inside }
        if phase.contains(.mayBegin) { owned = false }
        if phase.contains(.began) { owned = inside }
        let result = owned
        if phase.contains(.cancelled) { owned = false }
        return result
    }
}

private struct ScrollMonitor: NSViewRepresentable {
    let direction: PanDirection
    let threshold: CGFloat
    let startsWithMomentum: Bool
    let requiresEligibleStart: Bool
    let isEnabled: () -> Bool
    let action: (CGFloat, NSEvent.Phase) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.installMonitor(on: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.action = action
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.removeMonitor() }

    func makeCoordinator() -> Coordinator { 
        Coordinator(direction: direction, threshold: threshold,
                    startsWithMomentum: startsWithMomentum, requiresEligibleStart: requiresEligibleStart,
                    isEnabled: isEnabled, action: action)
    }

    @MainActor final class Coordinator: NSObject {
        private let direction: PanDirection
        private let threshold: CGFloat
        private let startsWithMomentum: Bool
        private let requiresEligibleStart: Bool
        private var ownership = NotchScrollOwnership()
        var action: (CGFloat, NSEvent.Phase) -> Void
        var isEnabled: () -> Bool
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var active = false
        private var endTask: Task<Void, Never>?
        private let noiseThreshold: CGFloat = 0.2

        init(direction: PanDirection, threshold: CGFloat, startsWithMomentum: Bool, requiresEligibleStart: Bool,
             isEnabled: @escaping () -> Bool, action: @escaping (CGFloat, NSEvent.Phase) -> Void) {
            self.direction = direction
            self.threshold = threshold
            self.startsWithMomentum = startsWithMomentum
            self.requiresEligibleStart = requiresEligibleStart
            self.action = action
            self.isEnabled = isEnabled
        }

        private func scheduleEndTimeout() {
            // Cancel any existing scheduled end and schedule a new one.
            endTask?.cancel()
            endTask = Task { @MainActor in
                // If no new scroll event arrives within this window, consider the gesture ended.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                if active {
                    action(accumulated.magnitude, .ended)
                } else {
                    action(0, .ended)
                }
                active = false
                accumulated = 0
            }
        }

        func installMonitor(on view: NSView) {
            removeMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self, weak view] event in
                guard let self, let view else { return event }
                let inside = NotchScrollHitRegion.contains(eventWindow: event.window,
                                                         locationInWindow: event.locationInWindow, in: view)
                    && self.isEnabled()
                let owned = self.requiresEligibleStart
                    ? self.ownership.update(phase: event.phase, momentum: event.momentumPhase, inside: inside)
                    : inside
                guard owned, inside else {
                    self.cancelGesture()
                    return event
                }
                self.handleScroll(event)
                return event
            }
        }

        func removeMonitor() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            cancelGesture()
        }

        private func cancelGesture() {
            endTask?.cancel()
            endTask = nil
            let hadProgress = active || accumulated != 0
            accumulated = 0
            active = false
            if hadProgress { action(0, .cancelled) }
        }

        private func handleScroll(_ event: NSEvent) {
            guard startsWithMomentum || active || event.momentumPhase.isEmpty else { return }
            if event.phase == .ended || event.momentumPhase == .ended {
                if active {
                    action(accumulated.magnitude, .ended)
                } else {
                    action(0, .ended)
                }
                active = false
                accumulated = 0
                return
            }

            // Only consider scroll events that are primarily along the configured axis.
            let absDX = abs(event.scrollingDeltaX)
            let absDY = abs(event.scrollingDeltaY)
            // Require the movement along the gesture axis to be at least 1.5x the orthogonal axis.
            let axisDominanceFactor: CGFloat = 1.5
            let isAxisDominant: Bool = direction.isHorizontal ? (absDX >= axisDominanceFactor * absDY) : (absDY >= axisDominanceFactor * absDX)
            guard isAxisDominant else { return }

            // Scale non-precise (mouse wheel) scrolling deltas so they feel similar to
            // trackpad gestures.
            let raw = direction.signed(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            let s = raw * scale
            guard s.magnitude > noiseThreshold else { return }
            accumulated = s > 0 ? accumulated + s : 0

            if !active && accumulated >= threshold {
                active = true
                action(accumulated.magnitude, .began)
            } else if active {
                action(accumulated.magnitude, .changed)
            }
            // Schedule a timeout to end the gesture if no further scroll events arrive.
            scheduleEndTimeout()
        }
    }
}

/// Install inside the preview's document so its native scroll view can be
/// identified without depending on the view hierarchy used by the outer list.
struct AgentPreviewScrollBoundary: NSViewRepresentable {
    func makeNSView(context: Context) -> BoundaryView { BoundaryView() }
    func updateNSView(_ view: BoundaryView, context: Context) {}
    static func dismantleNSView(_ view: BoundaryView, coordinator: ()) { view.stop() }

    final class BoundaryView: NSView {
        private var monitor: Any?
        private var ownership = NotchScrollOwnership()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.route(event)
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            ownership = NotchScrollOwnership()
        }

        private func route(_ event: NSEvent) -> NSEvent? {
            guard let scrollView = enclosingScrollView, let window, event.window === window else { return event }
            let clip = scrollView.contentView
            let location = clip.convert(event.locationInWindow, from: nil)
            let inside = clip.visibleRect.contains(location)
            guard ownership.update(phase: event.phase, momentum: event.momentumPhase, inside: inside) else { return event }

            // Clamp within the preview so an overscroll never bubbles to the list.
            let scale = event.hasPreciseScrollingDeltas ? 1.0 : 8.0
            let delta = event.scrollingDeltaY * scale * (clip.isFlipped ? -1 : 1)
            if delta != 0, !event.phase.contains(.cancelled) {
                var target = clip.bounds
                target.origin.y += delta
                let constrained = clip.constrainBoundsRect(target).origin
                if constrained != clip.bounds.origin {
                    clip.scroll(to: constrained)
                    scrollView.reflectScrolledClipView(clip)
                }
            }
            return nil
        }
    }
}

private struct NotchHorizontalScrollAreas: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// A stroke starting on a horizontal content scroller belongs to that scroller.
    func reservesHorizontalNotchScrolling() -> some View {
        anchorPreference(key: NotchHorizontalScrollAreas.self, value: .bounds) { [$0] }
    }

    func notchPageSwipe(
        isEnabled: @escaping () -> Bool,
        acceptsPoint: @escaping (CGPoint, CGRect) -> Bool,
        action: @escaping (Int) -> Bool
    ) -> some View {
        overlayPreferenceValue(NotchHorizontalScrollAreas.self) { anchors in
            GeometryReader { proxy in
                NotchPageSwipeMonitor(excluded: anchors.map { proxy[$0] },
                                      isEnabled: isEnabled, acceptsPoint: acceptsPoint, action: action)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Recognizes one page per physical stroke. Momentum can finish a claimed
/// stroke but cannot start another one, and diagonal/vertical strokes pass through.
struct NotchPageSwipe {
    enum Decision: Equatable { case forward, consume, switchPage(Int) }
    private enum State { case idle, tracking, rejected, claimed }
    private var state = State.idle
    private var x: CGFloat = 0
    private var verticalTravel: CGFloat = 0
    private var consumeMomentum = false

    mutating func update(phase: NSEvent.Phase, momentum: NSEvent.Phase,
                         fingerX: CGFloat, deltaY: CGFloat, canStart: Bool) -> Decision {
        if !momentum.isEmpty {
            let decision: Decision = consumeMomentum ? .consume : .forward
            if momentum.contains(.ended) || momentum.contains(.cancelled) { consumeMomentum = false }
            return decision
        }
        if phase.contains(.mayBegin) { self = Self() }
        if phase.contains(.began) {
            self = Self()
            state = canStart ? .tracking : .rejected
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            let decision: Decision = state == .claimed ? .consume : .forward
            consumeMomentum = state == .claimed && phase.contains(.ended)
            state = .idle
            return decision
        }
        guard phase.contains(.began) || phase.contains(.changed) else { return .forward }
        switch state {
        case .claimed: return .consume
        case .idle, .rejected: return .forward
        case .tracking:
            x += fingerX
            verticalTravel += abs(deltaY)
            if verticalTravel >= 10 && abs(x) < verticalTravel * 1.6 {
                state = .rejected
                return .forward
            }
            guard abs(x) >= 36, abs(x) >= verticalTravel * 1.6 else { return .forward }
            state = .claimed
            return .switchPage(x < 0 ? 1 : -1)
        }
    }

    mutating func reject() { state = .rejected }
}

private struct NotchPageSwipeMonitor: NSViewRepresentable {
    let excluded: [CGRect]
    let isEnabled: () -> Bool
    let acceptsPoint: (CGPoint, CGRect) -> Bool
    let action: (Int) -> Bool

    func makeNSView(context: Context) -> SwipeView { SwipeView() }
    func updateNSView(_ view: SwipeView, context: Context) { view.configuration = self }
    static func dismantleNSView(_ view: SwipeView, coordinator: ()) { view.stop() }

    final class SwipeView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        var configuration: NotchPageSwipeMonitor?
        private var monitor: Any?
        private var gesture = NotchPageSwipe()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.process(event)
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            gesture = NotchPageSwipe()
        }

        private func process(_ event: NSEvent) -> NSEvent? {
            guard let configuration, configuration.isEnabled(),
                  event.hasPreciseScrollingDeltas,
                  NotchScrollHitRegion.contains(eventWindow: event.window, locationInWindow: event.locationInWindow, in: self) else {
                gesture = NotchPageSwipe()
                return event
            }
            let point = convert(event.locationInWindow, from: nil)
            let canStart = configuration.acceptsPoint(point, bounds)
                && !configuration.excluded.contains { $0.contains(point) }
            let fingerX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            switch gesture.update(phase: event.phase, momentum: event.momentumPhase,
                                  fingerX: fingerX, deltaY: event.scrollingDeltaY, canStart: canStart) {
            case .forward: return event
            case .consume: return nil
            case .switchPage(let step):
                if configuration.action(step) { return nil }
                gesture.reject()
                return event
            }
        }
    }
}
