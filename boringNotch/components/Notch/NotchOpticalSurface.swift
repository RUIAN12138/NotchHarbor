//
//  NotchOpticalSurface.swift
//  boringNotch
//
//  A curvature-driven optical layer for the shared glass shell. The black
//  absorption and the bottom specular field are produced by one Metal
//  surface, so the light follows the real quadratic corner curves instead of
//  being drawn as detached Canvas ribbons.
//

import AppKit
import CoreGraphics
import Metal
import SwiftUI

// === OPTICAL_GEOMETRY_MODEL_BEGIN ===
/// Pure geometry shared by the SwiftUI silhouette and the Metal optical
/// surface. Resolving the radii here keeps the shader's distance field tied to
/// the exact path used by `NotchShape.path(in:)`.
struct NotchSurfaceGeometry: Equatable {
    let rect: CGRect
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    let topCornerIsConvex: Bool
    var encodedTopRadius: CGFloat { topCornerIsConvex ? -topCornerRadius : topCornerRadius }
    var sideInset: CGFloat { topCornerIsConvex ? 0 : topCornerRadius }

    init(rect: CGRect, topCornerRadius: CGFloat, bottomCornerRadius: CGFloat, topCornerIsConvex: Bool = false) {
        self.topCornerIsConvex = topCornerIsConvex
        let originX = Self.finite(rect.origin.x)
        let originY = Self.finite(rect.origin.y)
        let width = max(0, Self.finite(rect.size.width))
        let height = max(0, Self.finite(rect.size.height))
        self.rect = CGRect(x: originX, y: originY, width: width, height: height)

        // During a narrow or short transition frame the requested radii can
        // exceed the available space. Scale both radii uniformly, bounded by
        // the height and half-width, so the original curve stays intact.
        let radiusLimit = max(0, min(width / 2, height))
        let requestedTop = max(0, Self.finite(topCornerRadius))
        let requestedBottom = max(0, Self.finite(bottomCornerRadius))
        let radiusSum = requestedTop + requestedBottom
        let radiusScale = radiusSum > radiusLimit && radiusSum > 0
            ? radiusLimit / radiusSum
            : 1

        self.topCornerRadius = requestedTop * radiusScale
        self.bottomCornerRadius = requestedBottom * radiusScale
    }

    private static func finite(_ value: CGFloat) -> CGFloat {
        value.isFinite ? value : 0
    }

    /// Reproduces the original notch outline: concave quadratic shoulders,
    /// straight sides, and quadratic bottom corners.
    func makePath() -> CGPath {
        let path = CGMutablePath()
        let minX = rect.minX
        let minY = rect.minY
        let maxX = rect.maxX
        let maxY = rect.maxY
        let top = topCornerRadius
        let bottom = bottomCornerRadius
        let side = sideInset

        let startX = minX + (topCornerIsConvex ? top : 0)
        path.move(to: CGPoint(x: startX, y: minY))

        path.addQuadCurve(
            to: CGPoint(x: minX + side, y: minY + top),
            control: CGPoint(x: minX + side, y: minY)
        )

        path.addLine(to: CGPoint(x: minX + side, y: maxY - bottom))

        path.addQuadCurve(
            to: CGPoint(x: minX + side + bottom, y: maxY),
            control: CGPoint(x: minX + side, y: maxY)
        )

        path.addLine(to: CGPoint(x: maxX - side - bottom, y: maxY))

        path.addQuadCurve(
            to: CGPoint(x: maxX - side, y: maxY - bottom),
            control: CGPoint(x: maxX - side, y: maxY)
        )

        path.addLine(to: CGPoint(x: maxX - side, y: minY + top))

        path.addQuadCurve(
            to: CGPoint(x: maxX - (topCornerIsConvex ? top : 0), y: minY),
            control: CGPoint(x: maxX - side, y: minY)
        )

        path.addLine(to: CGPoint(x: startX, y: minY))
        path.closeSubpath()
        return path
    }
}
// === OPTICAL_GEOMETRY_MODEL_END ===

/// Runtime gate for the native shader path. When Metal is unavailable the
/// existing Canvas fallback stays in charge.
enum NotchOpticalSupport {
    static let isAvailable: Bool = {
        if #available(macOS 14.0, *) {
            return MTLCreateSystemDefaultDevice() != nil
        }
        return false
    }()
}

@available(macOS 14.0, *)
struct NotchOpticalSurface: View {
    var shape: NotchShape
    /// 0 while the shell is closed black, 1 once the glass is fully open. The
    /// parent shell already interpolates the shape, so this view must not
    /// animate its own copy and fall a frame behind the clip.
    var reveal: CGFloat
    var headerHeight: CGFloat
    var hardwareWidth: CGFloat
    var intensity: Double
    var tint: Color?
    var motionActive: Bool
    var attentionGlow: Bool
    var reduceMotion: Bool
    var edgeOnly: Bool = false
    @State private var motionTransition = Date.distantPast
    @State private var precedingMotion = 0.0

    var musicSignal: MusicSpectrumSignal?
    @State private var clock = NotchLightClock()
    @State private var entryMotion = true
    @State private var settlingMotion = false

    /// Keep the timeline parked while the veil fully covers the shell. This
    /// avoids drawing dynamic light behind the closed notch.
    private var isActive: Bool {
        reveal > 0.001
    }

    private var isAnimating: Bool {
        !reduceMotion && isActive && clampedIntensity > 0
    }

    private var minimumFrameInterval: TimeInterval {
        let activeMotion = entryMotion || settlingMotion || motionActive || musicSignal != nil
        return activeMotion ? 1.0 / 30.0 : 1.0 / 8.0
    }

    private var clampedIntensity: Float {
        guard intensity.isFinite else { return 1 }
        return Float(min(1, max(0, intensity)))
    }

    private var safeHeader: Float {
        guard headerHeight.isFinite else { return 0 }
        return Float(max(0, headerHeight))
    }

    private var safeHardware: Float {
        guard hardwareWidth.isFinite else { return 0 }
        return Float(max(0, hardwareWidth))
    }

    private var tintVector: SIMD4<Float> {
        guard let tint else { return SIMD4<Float>(0, 0, 0, 0) }
        guard let color = NSColor(tint).usingColorSpace(.sRGB) else {
            return SIMD4<Float>(0, 0, 0, 0)
        }
        func clamp01(_ value: CGFloat) -> Float {
            guard value.isFinite else { return 0 }
            return Float(min(1, max(0, value)))
        }
        return SIMD4<Float>(
            clamp01(color.redComponent),
            clamp01(color.greenComponent),
            clamp01(color.blueComponent),
            1
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = shape.surfaceGeometry(
                in: CGRect(origin: .zero, size: proxy.size)
            )
            TimelineView(.animation(minimumInterval: minimumFrameInterval, paused: !isAnimating)) { timeline in
                // A single phase survives page and activity changes. Let the
                // shader vary the light envelope instead of jumping its clock.
                let level = reduceMotion ? 0 : motionLevel(at: timeline.date)
                let time = reduceMotion ? 1.05 : clock.elapsed(at: timeline.date)
                let music = (reduceMotion ? nil : musicSignal)?.lightResponse()
                Rectangle()
                    .fill(.black)
                    .colorEffect(shader(geometry: geometry, time: time, motionLevel: level, music: music))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: isAnimating, initial: true) { _, running in
            clock.setRunning(running, at: Date())
        }
        .task(id: isActive) {
            entryMotion = isActive
            guard isActive else { clock = NotchLightClock(); return }
            try? await Task.sleep(for: .milliseconds(1550))
            if !Task.isCancelled { entryMotion = false }
        }
        .task(id: motionActive) {
            settlingMotion = !motionActive && precedingMotion > 0
            guard settlingMotion else { return }
            try? await Task.sleep(for: .milliseconds(580))
            if !Task.isCancelled { settlingMotion = false }
        }
        .onChange(of: motionActive) { previous, _ in
            let date = Date()
            precedingMotion = motionLevel(at: date, target: previous)
            motionTransition = date
        }
    }

    private func motionLevel(at date: Date, target: Bool? = nil) -> Double {
        let destination = (target ?? motionActive) ? 1.0 : 0.0
        let progress = min(1, max(0, date.timeIntervalSince(motionTransition) / 0.58))
        let eased = progress * progress * (3 - 2 * progress)
        return precedingMotion + (destination - precedingMotion) * eased
    }

    private func shader(geometry: NotchSurfaceGeometry, time: TimeInterval, motionLevel: Double,
                        music: SIMD3<Float>?) -> Shader {
        let rect = geometry.rect
        let tint = tintVector
        let function = edgeOnly ? ShaderLibrary.default.notchEdgeOptics : ShaderLibrary.default.notchOpticalSurface
        return function(
            .float4(
                Float(rect.minX), Float(rect.minY),
                Float(rect.width), Float(rect.height)
            ),
            .float4(
                Float(geometry.encodedTopRadius), Float(geometry.bottomCornerRadius),
                safeHeader, safeHardware
            ),
            .float4(
                Float(time.isFinite ? time : 0),
                clampedIntensity,
                attentionGlow ? 1 : 0,
                Float(motionLevel)
            ),
            .float4(tint.x, tint.y, tint.z, tint.w),
            .float4(music?.x ?? 0, music?.y ?? 0, music?.z ?? 0, music == nil ? 0 : 1)
        )
    }
}
