//
//  NotchShape.swift
//  boringNotch
//
// Created by Kai Azim on 2023-08-24.
// Original source: https://github.com/MrKai77/DynamicNotchKit
// Modified by Alexander on 2025-05-18.

import SwiftUI

struct NotchShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat
    private var topCornerIsConvex: Bool

    static func panel(expanded: Bool) -> NotchShape {
        let radius: CGFloat = expanded ? 28 : 16
        return NotchShape(topCornerRadius: radius, bottomCornerRadius: radius, topCornerIsConvex: true)
    }

    init(
        topCornerRadius: CGFloat? = nil,
        bottomCornerRadius: CGFloat? = nil,
        topCornerIsConvex: Bool = false
    ) {
        self.topCornerRadius = topCornerRadius ?? 6
        self.bottomCornerRadius = bottomCornerRadius ?? 14
        self.topCornerIsConvex = topCornerIsConvex
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get {
            .init(
                topCornerRadius,
                bottomCornerRadius
            )
        }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    /// The resolved silhouette shared with the optical renderer. `path(in:)`
    /// and the Metal distance field consume the same values, so the light can
    /// never drift away from the clipped boundary.
    func surfaceGeometry(in rect: CGRect) -> NotchSurfaceGeometry {
        NotchSurfaceGeometry(
            rect: rect,
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            topCornerIsConvex: topCornerIsConvex
        )
    }

    func path(in rect: CGRect) -> Path {
        Path(surfaceGeometry(in: rect).makePath())
    }
}

#Preview {
    NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
        .frame(width: 200, height: 32)
        .padding(10)
}

// All curves consume the same reversible open/close spring. These are
// spatial envelopes, not delayed animations: a reversal retraces the layers.
func notchPhase(_ progress: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
    let t = min(1, max(0, (progress - start) / (end - start)))
    return t * t * (3 - 2 * t)
}

struct NotchContentReveal: ViewModifier, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let visibility = notchPhase(progress, from: 0.28, to: 0.88)
        let travel = notchPhase(progress, from: 0.18, to: 1)
        content.opacity(Double(visibility)).offset(y: (travel - 1) * 8)
    }
}

struct NotchShellVisibility: ViewModifier, Animatable {
    var progress: CGFloat
    var collapsedPresence: CGFloat
    var allowsCollapsedShell: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, collapsedPresence) }
        set { (progress, collapsedPresence) = (newValue.first, newValue.second) }
    }

    func body(content: Content) -> some View {
        let expanded = notchPhase(progress, from: 0.01, to: 0.27)
        let collapsed = allowsCollapsedShell ? notchPhase(collapsedPresence, from: 0.02, to: 0.84) : 0
        content.opacity(Double(max(expanded, collapsed)))
    }
}

/// The icon travels outward under its own fixed side slot. Clipping keeps
/// the movement out of the physical notch and the surrounding menu bar.
struct NotchWingVisibility: ViewModifier, Animatable {
    var progress: CGFloat
    let side: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let visibility = notchPhase(progress, from: 0.03, to: 0.96)
        content
            .offset(x: -side * (1 - visibility) * SystemIslandHoverGeometry.agentWingWidth / 2)
            .mask(alignment: side < 0 ? .trailing : .leading) {
                Rectangle().frame(width: SystemIslandHoverGeometry.agentWingWidth * visibility)
            }
            .opacity(Double(visibility))
    }
}

/// A single backdrop for the expanded notch. Content stays outside the glass
/// renderer so text, artwork and camera previews retain their original clarity.
///
/// The shell is `Animatable`: the silhouette's radii and one `reveal` value
/// (0 = closed black, 1 = glass) travel in the same vector. The black veil is
/// part of that same outline and retreats from the bottom, so no second
/// closed silhouette or independently faded optical layer can cross it.
struct NotchGlassBackground: View, Animatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    var shape: NotchShape
    var isExpanded: Bool
    var reduceTransparency: Bool
    var headerHeight: CGFloat
    var hardwareWidth: CGFloat
    var attentionGlow: Bool
    var hoverAmount: CGFloat
    var usesSharedGlassShell: Bool
    var tint: Color?
    var glassEnabled: Bool
    var lightIntensity: Double
    var motionActive: Bool
    var musicSignal: MusicSpectrumSignal?
    var desktopRefractionEnabled: Bool
    var usesDarkGlassAppearance: Bool
    var transparency: Double
    var previewCaptureSize: CGSize?
    var textContrastChanged: ((Bool?) -> Void)?
    private var agentConversationContrast: CGFloat

    /// Driven by `isExpanded`, but interpolated between states instead of
    /// switching. The stored value is what the animation engine mutates.
    private var reveal: CGFloat

    init(
        shape: NotchShape,
        isExpanded: Bool,
        reduceTransparency: Bool = false,
        headerHeight: CGFloat = 0,
        hardwareWidth: CGFloat = 185,
        attentionGlow: Bool = false,
        hoverAmount: CGFloat = 0,
        usesSharedGlassShell: Bool = false,
        tint: Color? = nil,
        glassEnabled: Bool = true,
        lightIntensity: Double = 1,
        motionActive: Bool = false,
        musicSignal: MusicSpectrumSignal? = nil,
        desktopRefractionEnabled: Bool = false,
        keepsAgentConversationContrast: Bool = false,
        usesDarkGlassAppearance: Bool = false,
        transparency: Double = 0.5,
        previewCaptureSize: CGSize? = nil,
        textContrastChanged: ((Bool?) -> Void)? = nil
    ) {
        self.shape = shape
        self.isExpanded = isExpanded
        self.reduceTransparency = reduceTransparency
        self.headerHeight = headerHeight
        self.hardwareWidth = hardwareWidth
        self.attentionGlow = attentionGlow
        self.hoverAmount = hoverAmount
        self.usesSharedGlassShell = usesSharedGlassShell
        self.tint = tint
        self.glassEnabled = glassEnabled
        self.lightIntensity = lightIntensity
        self.motionActive = motionActive
        self.musicSignal = musicSignal
        self.desktopRefractionEnabled = desktopRefractionEnabled
        self.agentConversationContrast = keepsAgentConversationContrast ? 1 : 0
        self.usesDarkGlassAppearance = usesDarkGlassAppearance
        self.transparency = transparency
        self.previewCaptureSize = previewCaptureSize
        self.textContrastChanged = textContrastChanged
        self.reveal = isExpanded ? 1 : 0
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(reveal, agentConversationContrast), shape.animatableData) }
        set {
            reveal = newValue.first.first
            agentConversationContrast = newValue.first.second
            shape.animatableData = newValue.second
        }
    }

    private var clampedReveal: CGFloat {
        min(1, max(0, reveal))
    }

    private var effectiveLightIntensity: Double {
        lightIntensity.isFinite ? min(1, max(0, lightIntensity)) : 1
    }

    private var transmission: Double {
        transparency.isFinite ? min(1, max(0, transparency)) : 0.5
    }

    private var density: Double { 1.65 - 1.3 * transmission }

    private var usesSystemGlass: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// The optical coating is independent of the optional desktop capture.
    private var opticalSurfaceActive: Bool {
        guard usesSharedGlassShell, glassEnabled, !reduceTransparency else {
            return false
        }
        if #available(macOS 14.0, *) {
            return NotchOpticalSupport.isAvailable
        }
        return false
    }

    var body: some View {
        ZStack {
            // Keep the system material in place while an optional desktop
            // texture starts, and after it stops or is denied.
            baseSurface

            if opticalSurfaceActive && desktopRefractionEnabled && clampedReveal > 0.08 {
                NotchDesktopRefraction(shape: shape, intensity: effectiveLightIntensity,
                                           previewCaptureSize: previewCaptureSize, textContrastChanged: textContrastChanged)
                    .opacity(Double(notchPhase(clampedReveal, from: 0.08, to: 0.70)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.identity)
            }

            if glassEnabled {
                let conversation = min(1, max(0, agentConversationContrast))
                NotchGlassBacking(darkAppearance: usesDarkGlassAppearance, conversation: conversation,
                                  reduceTransparency: reduceTransparency, density: density)
                    .opacity(Double(clampedReveal) * (usesDarkGlassAppearance ? 1 : Double(conversation)))
            }

            if usesSharedGlassShell && glassEnabled && !reduceTransparency {
                if opticalSurfaceActive {
                    // Optics and dark-to-clear depth are the same surface
                    // with or without a captured background.
                    opticalSurfaceLayer(edgeOnly: false)
                } else if usesSystemGlass {
                    systemGlassShoulder
                    if #available(macOS 14.0, *), NotchOpticalSupport.isAvailable {
                        opticalSurfaceLayer(edgeOnly: true)
                    }
                } else {
                    // Clear glass needs a local pillow of contrast under the
                    // controls. It is an off-centre ellipse with clear edges,
                    // never a full-width horizontal strip.
                    lowerContrastPillow.opacity(Double(clampedReveal))
                    upperBlackFade.opacity(Double(clampedReveal))
                    if clampedReveal > 0.001 && effectiveLightIntensity > 0 {
                        NotchWaveBands(tint: tint, reduceMotion: reduceMotion, headerHeight: headerHeight,
                                       hardwareWidth: hardwareWidth, motionActive: motionActive || attentionGlow,
                                       musicSignal: musicSignal)
                            .opacity(Double(clampedReveal) * effectiveLightIntensity)
                    }
                }
            }

            // Fade the physical cutout into the material without covering the
            // content. Only the non-shared fallback needs this extra seam.
            if glassEnabled && !reduceTransparency && headerHeight > 0 && !usesSharedGlassShell {
                hardwareCutoutFade.opacity(Double(clampedReveal))
            }

            // One black shell over the same outline. It starts fully opaque,
            // retreats upward from the bottom while the shell opens, and is
            // completely gone at reveal == 1 so it never covers the expanded
            // shoulder absorption or the clear lower lip.
            blackVeil

            if glassEnabled && !reduceTransparency {
                edgeHighlights
            }
        }
        .clipShape(shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The closed black is a spatial veil rather than a uniform opacity. Its
    /// front rises from the bottom lip first while the shoulder stays dark,
    /// then the whole veil releases so the glass shoulder is not double-inked.
    private var blackVeil: some View {
        LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: veilFront),
            .init(color: .clear, location: veilFadeEnd),
        ], startPoint: .top, endPoint: .bottom)
            .opacity(veilOpacity)
    }

    private var veilFront: CGFloat {
        max(0.06, 0.999 - 0.939 * notchPhase(clampedReveal, from: 0.04, to: 0.98))
    }

    private var veilFadeEnd: CGFloat {
        let softness = 0.16 + 0.14 * sin(.pi * clampedReveal)
        return min(1, veilFront + softness)
    }

    private var veilOpacity: Double {
        Double(1 - notchPhase(clampedReveal, from: 0.18, to: 0.94))
    }

    /// One interpolated edge, never a second contour. On the shared optical
    /// shell the expanded rim belongs to the Metal surface, so the drawn edge
    /// only survives as the closed hover glint and fades out with the reveal.
    private var edgeHighlights: some View {
        let r = Double(clampedReveal)
        let closed = Double(hoverAmount) * 0.22
        let expanded = opticalSurfaceActive || usesSystemGlass ? 0 : (usesSharedGlassShell ? 0.34 : 1)
        let base = ((1 - r) * closed + r * expanded) * effectiveLightIntensity
        return Group {
            shape.softEdgeHighlight(
                colors: [.white.opacity(0.35), .white.opacity(0.08), .clear, .white.opacity(0.14)],
                opacity: base
            )
            if !opticalSurfaceActive && !usesSystemGlass {
                shape.softEdgeHighlight(
                    colors: [.blue.opacity(0.55), .purple.opacity(0.35), .clear],
                    opacity: attentionGlow ? 0.5 * r * effectiveLightIntensity : 0
                )
            }
        }
    }

    private var hardwareCutoutFade: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.28))
                .frame(width: hardwareWidth + 6, height: headerHeight + 2)
                .blur(radius: 18)
                .offset(y: -5)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var systemGlassShoulder: some View {
        GeometryReader { proxy in
            let height = max(1, proxy.size.height)
            let top = min(height * 0.85, max(0, headerHeight))
            let body = height - top
            let span = min(body, max(38, min(77, body * 0.44)))
            // A Gaussian release begins with zero slope at the black header
            // and carries a soft tail into the glass without a gradient knee.
            let release = (0...24).map { index in
                let progress = Double(index) / 24
                return Gradient.Stop(
                    color: .black.opacity(exp(-8 * progress * progress)),
                    location: (top + span * progress) / height
                )
            }
            ZStack {
                LinearGradient(stops: [.init(color: .black, location: 0)] + release + [
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                // Reuse the physical cutout's feathered depth so the release
                // extends slightly further beneath the real camera region.
                hardwareCutoutFade.opacity(0.5)
            }
        }
    }

    /// One native shader layer for the shared shell, mounted for both states so
    /// it never remounts or fades against the black veil. It receives the same
    /// interpolated `shape` used by the single outer clip.
    @ViewBuilder
    private func opticalSurfaceLayer(edgeOnly: Bool) -> some View {
        if #available(macOS 14.0, *) {
            NotchOpticalSurface(
                shape: shape,
                reveal: clampedReveal,
                headerHeight: headerHeight,
                hardwareWidth: hardwareWidth,
                intensity: effectiveLightIntensity,
                density: density,
                tint: tint,
                motionActive: motionActive || attentionGlow,
                attentionGlow: attentionGlow,
                reduceMotion: reduceMotion,
                edgeOnly: edgeOnly,
                musicSignal: musicSignal
            )
        }
    }

    /// A local, feathered lobe under the controls instead of a full-width band.
    /// The soft ellipse keeps the lower area from flattening into a gray strip
    /// while leaving both the middle and the bottom edge clear. Shared by every
    /// expanded page.
    private var lowerContrastPillow: some View {
        let ink: Color = colorScheme == .dark ? .black : .white
        let strength = 0.12
        return GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let height = max(1, proxy.size.height)
            Ellipse()
                .fill(
                    LinearGradient(stops: [
                        .init(color: ink.opacity(strength * 0.55), location: 0),
                        .init(color: ink.opacity(strength), location: 0.34),
                        .init(color: ink.opacity(strength * 0.82), location: 0.70),
                        .init(color: ink.opacity(strength * 0.24), location: 1),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: width * 0.62, height: height * 0.38)
                .blur(radius: 22)
                .position(x: width * 0.575, y: height * 0.75)
        }
        .mask {
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.80),
                .init(color: .clear, location: 0.98),
            ], startPoint: .top, endPoint: .bottom)
        }
    }

    /// The shoulder stays dark behind content and opens into a clear lower lip.
    /// Keeping depth in this gradient, rather than in a uniformly tinted glass
    /// sheet, gives the bottom edge room to transmit the desktop. The centre
    /// lobe connects that depth to the physical cutout without a vertical seam.
    private var upperBlackFade: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let height = max(1, proxy.size.height)
            // Keep a little room for the tail even when a transitional frame is
            // shorter than the header itself. Real layouts sit well below this.
            let safeTop = min(max(0, headerHeight), height * 0.82)

            // Most controls sit in the upper 72% of the body. Keep contrast
            // there, then release the depth in the empty lower optical lip.
            let fadeSpan = max(0, height - safeTop)
            let safeLocation = safeTop / height
            let fadeMidLocation = (safeTop + fadeSpan * 0.38) / height
            let fadeKneeLocation = (safeTop + fadeSpan * 0.72) / height
            let fadeLipLocation = (safeTop + fadeSpan * 0.92) / height

            // Centre extension: roughly the hardware width plus 130pt, clamped
            // to the available width. Its longer 56pt tail carries the black
            // down past the shoulders without pressing the page content.
            let extensionWidth = min(width, max(0, hardwareWidth) + 130)
            let extensionSpan = min(56, max(0, height - safeTop))
            let extensionEndLocation = (safeTop + extensionSpan) / height

            ZStack {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: safeLocation),
                    .init(color: .black.opacity(0.86), location: fadeMidLocation),
                    .init(color: .black.opacity(0.74), location: fadeKneeLocation),
                    .init(color: .black.opacity(0.30), location: fadeLipLocation),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)

                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.10), location: 0.18),
                    .init(color: .black.opacity(0.34), location: 0.42),
                    .init(color: .black.opacity(0.40), location: 0.50),
                    .init(color: .black.opacity(0.34), location: 0.58),
                    .init(color: .black.opacity(0.10), location: 0.82),
                    .init(color: .clear, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
                    .frame(width: extensionWidth)
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: safeLocation),
                            .init(color: .black.opacity(0.52), location: (safeTop + extensionSpan * 0.45) / height),
                            .init(color: .clear, location: extensionEndLocation),
                        ], startPoint: .top, endPoint: .bottom)
                    }
            }
        }
    }

    @ViewBuilder
    private var baseSurface: some View {
        if !glassEnabled {
            shape.fill(.black)
        } else if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else if #available(macOS 26.0, *) {
            let layer = Color.clear
                // SiriGlass pairs clear compositor glass with an independent
                // optical ink/light layer. A light smoky tint preserves depth
                // while keeping the water-drop clarity and highlights crisp.
                .glassEffect(opticalSurfaceActive ? .clear.tint(.black.opacity(0.045 * density)) : .regular, in: shape)
            layer.opacity(min(1, 1.3 - 0.6 * transmission))
        } else {
            shape.fill(.regularMaterial).opacity(min(1, 1.3 - 0.6 * transmission))
        }
    }
}

/// A graphite backing behind the optical surface. The conversation adds
/// contrast without changing the shell when the input gets keyboard focus.
private struct NotchGlassBacking: View {
    let darkAppearance: Bool
    let conversation: CGFloat
    let reduceTransparency: Bool
    let density: Double

    private func ink(_ opacity: Double) -> Double { 1 - pow(1 - opacity, density) }

    var body: some View {
        if reduceTransparency {
            Color(red: 0.09, green: 0.10, blue: 0.12)
        } else {
            let emphasis = Double(conversation)
            let graphite: SIMD3<Double> = darkAppearance ? .init(0.052, 0.062, 0.079) : .init(0.095, 0.106, 0.129)
            let lower = graphite + (.init(0.13, 0.15, 0.18) - graphite) * emphasis
            let graphiteColor = Color(red: graphite.x, green: graphite.y, blue: graphite.z)
            let lowerGlass = Color(red: lower.x, green: lower.y, blue: lower.z)
            let bodyOpacity = darkAppearance ? 0.81 + 0.10 * emphasis : 0.98
            let controlOpacity = darkAppearance ? 0.84 + 0.09 * emphasis : 0.96
            let lipOpacity = darkAppearance ? 0.34 : 0.40
            let lowerOpacity = bodyOpacity + ((darkAppearance ? 0.72 : 0.76) - bodyOpacity) * emphasis

            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: graphiteColor.opacity(ink(bodyOpacity)), location: 0.29),
                .init(color: graphiteColor.opacity(ink(bodyOpacity - 0.045 * emphasis)), location: 0.58),
                .init(color: lowerGlass.opacity(ink(lowerOpacity)), location: 0.91),
                .init(color: graphiteColor.opacity(ink(controlOpacity - 0.32 * emphasis)), location: 0.966),
                .init(color: graphiteColor.opacity(ink(lipOpacity)), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .mask {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.32), location: 0),
                    .init(color: .black.opacity(0.85), location: 0.018),
                    .init(color: .black, location: 0.055),
                    .init(color: .black, location: 0.945),
                    .init(color: .black.opacity(0.85), location: 0.982),
                    .init(color: .black.opacity(0.32), location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            }
        }
    }
}

/// Countdown and hover illumination share the popup's existing glass outline.
struct CompactAlertEdgeLight: View {
    let shape: NotchShape
    let countdown: CompactAlertCountdown
    let hovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : 1.0 / 24,
                                    paused: countdown.isPaused || hovered)) { _ in
                let now = ContinuousClock.now
                let remaining = countdown.fractionRemaining(at: now)
                let fade = min(1, countdown.remaining(at: now) / .milliseconds(220))
                Canvas { context, size in
                    guard remaining > 0, size.width > 6, size.height > 6 else { return }
                    let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
                    let band = shape.path(in: bounds).trimmedPath(from: 0, to: remaining)
                    var context = context
                    context.opacity = fade
                    context.stroke(band, with: .color(.white.opacity(0.13)),
                                   style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    context.stroke(band, with: .linearGradient(
                        Gradient(colors: [.white.opacity(0.46), .white.opacity(0.9)]),
                        startPoint: CGPoint(x: bounds.midX, y: bounds.minY),
                        endPoint: CGPoint(x: bounds.midX, y: bounds.maxY)
                    ), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
            .opacity(hovered ? 0 : 1)

            Canvas { context, size in
                guard size.width > 6, size.height > 6 else { return }
                let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
                let rim = shape.path(in: bounds)
                context.drawLayer { bloom in
                    bloom.addFilter(.blur(radius: 3))
                    bloom.stroke(rim, with: .color(.white.opacity(0.24)),
                                 style: StrokeStyle(lineWidth: 4, lineJoin: .round))
                }
                context.stroke(rim, with: .color(.white.opacity(0.33)),
                               style: StrokeStyle(lineWidth: 0.9, lineJoin: .round))
            }
            .opacity(hovered ? 1 : 0)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: hovered)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A soft, outward falloff around the physical camera cutout.
struct AgentCompletionHalo: View {
    let startedAt: Date
    let duration: TimeInterval
    let cutout: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            let progress = min(1, elapsed / duration)
            let fade = reduceMotion ? 0.68 : notchPhase(progress, from: 0, to: 0.055)
                * (1 - notchPhase(progress, from: 0.86, to: 1))
            let shimmer = reduceMotion ? 0.85 : 0.86 + 0.09 * sin(elapsed * 3.1) + 0.035 * sin(elapsed * 6.3)
            Canvas { context, size in
                let camera = CGRect(x: (size.width - cutout.width) / 2, y: -16,
                                    width: cutout.width, height: cutout.height + 16)
                let silhouette = NotchShape(topCornerRadius: 0, bottomCornerRadius: 9,
                                            topCornerIsConvex: true).path(in: camera)
                let bounds = Path(CGRect(origin: .zero, size: size))
                let drift = reduceMotion ? 0.5 : 0.5 - 0.43 * cos(progress * .pi * 4)
                let pool = CGPoint(x: camera.minX + cutout.width * drift, y: cutout.height + 2)

                context.drawLayer { halo in
                    halo.opacity = Double(fade) * shimmer
                    halo.fill(bounds, with: .color(.white.opacity(0.60)))
                    halo.fill(bounds, with: .radialGradient(
                        Gradient(colors: [.white.opacity(0.82), .clear]),
                        center: pool, startRadius: 2, endRadius: cutout.width * 0.36
                    ))
                    halo.opacity = 1
                    halo.blendMode = .destinationIn
                    halo.drawLayer { mask in
                        mask.addFilter(.blur(radius: 6))
                        mask.stroke(silhouette, with: .color(.white),
                                    style: StrokeStyle(lineWidth: 14, lineJoin: .round))
                    }
                    halo.blendMode = .destinationOut
                    halo.drawLayer { inset in
                        inset.addFilter(.blur(radius: 1.6))
                        inset.fill(silhouette, with: .color(.white))
                    }
                }
            }
        }
        .frame(width: cutout.width + 44, height: cutout.height + 23)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Preserves the light phase when a page settles or resumes real activity.
/// Shared by the Canvas fallback and the Metal optical surface.
struct NotchLightClock {
    private var accumulated: TimeInterval = 0
    private var runningSince: Date?

    func elapsed(at date: Date) -> TimeInterval {
        accumulated + (runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    mutating func setRunning(_ running: Bool, at date: Date) {
        if running {
            if runningSince == nil { runningSince = date }
        } else if runningSince != nil {
            accumulated = elapsed(at: date)
            runningSince = nil
        }
    }
}

/// One Canvas drives the shoulder and bottom lights. Static pages settle after
/// entry; active content can resume the same light phase across navigation.
private struct NotchWaveBands: View {
    var tint: Color?
    var reduceMotion: Bool
    var headerHeight: CGFloat
    /// Physical cutout width, used to place the shoulder's centre sag.
    var hardwareWidth: CGFloat
    var motionActive: Bool
    var musicSignal: MusicSpectrumSignal?
    @State private var clock = NotchLightClock()
    @State private var isEntering = true

    private var minimumFrameInterval: TimeInterval {
        isEntering || motionActive || musicSignal != nil ? 1.0 / 30.0 : 1.0 / 8.0
    }

    private static let steps = 72
    /// The bottom bands step back ~15% so the shoulder stays the focal light.
    private static let bottomBandOpacity: Double = 0.85

    var body: some View {
        TimelineView(.animation(minimumInterval: minimumFrameInterval, paused: reduceMotion)) { timeline in
            let music = (reduceMotion ? nil : musicSignal)?.lightResponse()
            let phase = reduceMotion ? 0.9 : clock.elapsed(at: timeline.date) * 1.15
            let time = phase
            Canvas { context, size in
                guard size.width > 0, size.height > 70 else { return }

                let ice = Color.white
                let violet = Color.white
                let warm = Color.white

                // Shoulder first: a short curved specular just under the header.
                Self.drawShoulder(
                    in: &context, size: size, time: time,
                    headerHeight: headerHeight, hardwareWidth: hardwareWidth,
                    warm: warm, cool: ice
                )

                let bands = music ?? .zero
                let musicWeight = min(1, max(0, Double((bands.max() - 0.02) / 0.15)))
                var bandContext = context
                let strip = CGRect(x: 0, y: size.height - 39, width: size.width, height: 35)
                bandContext.clip(to: Path(strip))
                var ambient = bandContext
                ambient.opacity = Self.bottomBandOpacity * (1 - 0.64 * musicWeight)
                Self.drawBand(
                    in: &ambient, size: size, time: time,
                    index: 0, colorA: ice, colorB: violet, core: warm, tint: nil
                )
                Self.drawBand(
                    in: &ambient, size: size, time: time,
                    index: 1, colorA: violet, colorB: ice, core: warm, tint: nil
                )
                Self.drawRidge(in: &ambient, size: size, time: time, warm: warm)

                if musicWeight > 0 {
                    let intervals = MusicSpectrumSignal.lightBandCount - 1
                    var band = Path()
                    for step in 0...Self.steps {
                        let fraction = CGFloat(step) / CGFloat(Self.steps)
                        let x = 0.025 + 0.95 * fraction
                        let position = min(1, max(0, (x - 0.14) / 0.72)) * CGFloat(intervals)
                        let left = min(Int(position), intervals - 1)
                        let t = position - CGFloat(left)
                        let blend = t * t * (3 - 2 * t)
                        let low = 0.8 * bands[left] + 0.1 * (bands[max(0, left - 1)] + bands[left + 1])
                        let high = 0.8 * bands[left + 1] + 0.1 * (bands[left] + bands[min(intervals, left + 2)])
                        let level = CGFloat(low) * (1 - blend) + CGFloat(high) * blend
                        let endFade = min(1, min(fraction, 1 - fraction) * 8)
                        let point = CGPoint(x: size.width * x, y: size.height - 4 - (14 + 10 * level) * endFade)
                        if step == 0 { band.move(to: point) } else { band.addLine(to: point) }
                    }
                    band.addLine(to: CGPoint(x: size.width * 0.975, y: size.height))
                    band.addLine(to: CGPoint(x: size.width * 0.025, y: size.height))
                    band.closeSubpath()
                    bandContext.opacity = 0.54 * musicWeight
                    bandContext.addFilter(.blur(radius: 4))
                    bandContext.fill(band, with: .linearGradient(
                        Gradient(colors: [.clear, .white.opacity(0.85), .white.opacity(0.50)]),
                        startPoint: CGPoint(x: 0, y: size.height - 29),
                        endPoint: CGPoint(x: 0, y: size.height)
                    ))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: reduceMotion, initial: true) { _, reduced in
            clock.setRunning(!reduced, at: Date())
        }
        .task {
            do { try await Task.sleep(for: .seconds(1.2)) }
            catch { return }
            isEntering = false
        }
    }

    /// A narrow white-warm core inside a faint cool halo, centred under the
    /// header and fading out toward both sides. Purely decorative; it does not
    /// sample the desktop or the album artwork. The light is slightly brighter
    /// as the panel opens, then settles without a second timeline. The centre
    /// sags ~4pt below the sides across the physical cutout width, echoing the
    /// curve where the black shoulder meets the glass.
    private static func drawShoulder(
        in context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        headerHeight: CGFloat,
        hardwareWidth: CGFloat,
        warm: Color,
        cool: Color
    ) {
        // Reserve room for the sag so a short transitional frame keeps the
        // whole curve under the header and clear of the bottom bands.
        let dipDepth = 4.0
        let baseCenter = max(
            Double(headerHeight),
            min(Double(size.height) - 26 - dipDepth, Double(headerHeight) + 10.5)
        )
        // The sag spans the cutout only; outside it the shoulder stays flat.
        let dipHalfWidth = min(
            0.5,
            max(0.10, Double(max(0, hardwareWidth)) * 0.5 / Double(max(size.width, 1)))
        )
        let drift = sin(time * 0.11) * 0.032 + sin(time * 0.047 + 1.3) * 0.012
        let peak = min(0.70, max(0.30, 0.50 + drift))
        let coreHalfWidth = 0.085 // bright core spans ~17% of the panel width
        // Opens a touch brighter, then eases back instead of staying at full.
        let settle = 0.86 + 0.14 * exp(-time * 0.5)

        let centerline: (Double) -> Double = { u in
            let arc = (u - 0.5) * (u - 0.5) * 4
            let edgeDistance = abs(u - 0.5) / dipHalfWidth
            let dip = edgeDistance >= 1 ? 0 : 0.5 * (1 + cos(edgeDistance * .pi))
            return baseCenter + arc * 2.2 + dipDepth * dip + sin(time * 0.22) * 0.35
        }

        // Cool, blurred halo. It stays under the title and transport buttons.
        var halo = context
        halo.addFilter(.blur(radius: 4.5))
        halo.fill(
            ribbon(size: size, centerline: centerline, halfThickness: 3.2),
            with: shading(size: size, stops: [
                (0, .clear),
                (max(0.0, peak - coreHalfWidth * 2.4), .clear),
                (max(0.0, peak - coreHalfWidth * 1.5), cool.opacity(0.10 * settle)),
                (peak, cool.opacity(0.17 * settle)),
                (min(1.0, peak + coreHalfWidth * 1.5), cool.opacity(0.10 * settle)),
                (min(1.0, peak + coreHalfWidth * 2.4), .clear),
                (1, .clear),
            ])
        )

        // Narrow warm heart.
        context.fill(
            ribbon(size: size, centerline: centerline, halfThickness: 1.15),
            with: shading(size: size, stops: [
                (0, .clear),
                (max(0.0, peak - coreHalfWidth * 1.9), .clear),
                (max(0.0, peak - coreHalfWidth * 1.1), cool.opacity(0.10 * settle)),
                (max(0.0, peak - coreHalfWidth * 0.5), warm.opacity(0.30 * settle)),
                (peak, .white.opacity(0.55 * settle)),
                (min(1.0, peak + coreHalfWidth * 0.5), warm.opacity(0.30 * settle)),
                (min(1.0, peak + coreHalfWidth * 1.1), cool.opacity(0.10 * settle)),
                (min(1.0, peak + coreHalfWidth * 1.9), .clear),
                (1, .clear),
            ])
        )
    }

    private static func drawBand(
        in context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        index: Int,
        colorA: Color,
        colorB: Color,
        core: Color,
        tint: Color?
    ) {
        let bottom = Double(size.height)
        let first = index == 0

        // Distinct centre, thickness, curvature and phase per band.
        let center = first ? 8.8 : 15.2
        let halfThickness = first ? 2.0 : 2.9
        let curvature = first ? 1.8 : -2.5
        let frequency = first ? 3.4 : 2.6
        let phase = first ? 0.0 : 2.2

        let centerline: (Double) -> Double = { u in
            let envelope = sin(u * .pi)
            let wave = sin(u * frequency * .pi + time * 0.95 + phase)
            let travel = sin(u * 1.5 * .pi - time * 0.58 + phase) * 0.34
            return bottom - center + (wave * curvature + travel) * envelope
        }

        // Wide soft halo: light gathers as a loose lobe, slides, then dissolves.
        let haloPeak = movingPeak(time: time, phase: phase + 0.6, span: 0.30, rate: 0.49)
        var halo = context
        halo.addFilter(.blur(radius: first ? 2.4 : 3.2))
        halo.fill(
            ribbon(size: size, centerline: centerline, halfThickness: halfThickness * 3.0),
            with: shading(size: size, stops: [
                (0, .clear),
                (max(0.02, haloPeak - 0.32), colorA.opacity(first ? 0.10 : 0.08)),
                (haloPeak, colorB.opacity(0.18)),
                (min(0.98, haloPeak + 0.28), colorA.opacity(0.08)),
                (1, .clear),
            ])
        )

        // A restrained cover-colour reflection, only while music is playing.
        if let tint, !first {
            let reflectionPeak = movingPeak(time: time, phase: phase + 1.9, span: 0.26, rate: 0.33)
            var reflection = context
            reflection.addFilter(.blur(radius: 4.5))
            reflection.fill(
                ribbon(size: size, centerline: centerline, halfThickness: halfThickness * 3.8),
                with: shading(size: size, stops: [
                    (0, .clear),
                    (max(0.02, reflectionPeak - 0.24), .clear),
                    (reflectionPeak, tint.opacity(0.16)),
                    (min(0.98, reflectionPeak + 0.24), .clear),
                    (1, .clear),
                ])
            )
        }

        // Narrow moving peak: the visible concentration of light inside the band.
        let peak = movingPeak(time: time, phase: phase + 1.1, span: 0.32, rate: 0.64)
        context.fill(
            ribbon(size: size, centerline: centerline, halfThickness: halfThickness),
            with: shading(size: size, stops: [
                (0, .clear),
                (max(0.02, peak - 0.26), colorA.opacity(first ? 0.16 : 0.13)),
                (max(0.05, peak - 0.10), colorB.opacity(0.30)),
                (max(0.06, peak - 0.035), core.opacity(0.38)),
                (peak, core.opacity(first ? 0.62 : 0.52)),
                (min(0.94, peak + 0.035), colorB.opacity(0.32)),
                (min(0.97, peak + 0.20), colorA.opacity(0.13)),
                (1, .clear),
            ])
        )
    }

    private static func drawRidge(
        in context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        warm: Color
    ) {
        let bottom = Double(size.height)
        let center = 12.4
        let centerline: (Double) -> Double = { u in
            let envelope = sin(u * .pi)
            return bottom - center + sin(u * 2.2 * .pi - time * 0.82 + 4.1) * 1.4 * envelope
        }
        let peak = movingPeak(time: time, phase: 4.6, span: 0.32, rate: 0.74)
        context.fill(
            ribbon(size: size, centerline: centerline, halfThickness: 0.4),
            with: shading(size: size, stops: [
                (0, .clear),
                (max(0.02, peak - 0.20), warm.opacity(0.10)),
                (max(0.06, peak - 0.04), .white.opacity(0.50)),
                (peak, warm.opacity(0.78)),
                (min(0.94, peak + 0.04), .white.opacity(0.48)),
                (min(0.98, peak + 0.20), warm.opacity(0.10)),
                (1, .clear),
            ])
        )
    }

    private static func ribbon(
        size: CGSize,
        centerline: (Double) -> Double,
        halfThickness: Double
    ) -> Path {
        var leading: [CGPoint] = []
        var trailing: [CGPoint] = []
        leading.reserveCapacity(steps + 1)
        trailing.reserveCapacity(steps + 1)

        for step in 0...steps {
            let u = Double(step) / Double(steps)
            let taper = sin(u * .pi) // transparent ends
            let x = u * Double(size.width)
            let y = centerline(u)
            let thickness = halfThickness * taper
            leading.append(CGPoint(x: x, y: y - thickness))
            trailing.append(CGPoint(x: x, y: y + thickness))
        }

        var path = Path()
        path.move(to: leading[0])
        for point in leading.dropFirst() { path.addLine(to: point) }
        for point in trailing.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    private static func shading(
        size: CGSize,
        stops: [(Double, Color)]
    ) -> GraphicsContext.Shading {
        GraphicsContext.Shading.linearGradient(
            Gradient(stops: stops.map { Gradient.Stop(color: $0.1, location: $0.0) }),
            startPoint: .zero,
            endPoint: CGPoint(x: size.width, y: 0)
        )
    }

    /// A lobe that slides across the band and narrows as it dissipates.
    private static func movingPeak(
        time: Double,
        phase: Double,
        span: Double,
        rate: Double
    ) -> Double {
        let primary = sin(time * rate + phase)
        let secondary = sin(time * rate * 0.47 + phase * 1.7) * 0.25
        return min(0.76, max(0.24, 0.5 + (primary * 0.75 + secondary) * span))
    }
}

/// Restrained feedback for controls on the main glass surface; no second blur.
struct NotchControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// A thin raised surface over the shared shell. It reuses the panel's
/// translucency and reserves contrast for the actual button footprint.
struct NotchControlSurface<S: InsettableShape>: View {
    @Environment(\.usesSharedGlassShell) private var usesSharedGlassShell
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var shape: S
    var emphasized = false
    var isHovered = false

    var body: some View {
        if usesSharedGlassShell && !reduceTransparency {
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(isHovered ? 0.23 : emphasized ? 0.17 : 0.10),
                            .white.opacity(emphasized ? 0.065 : 0.025),
                            .black.opacity(isHovered ? 0.10 : 0.22),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(isHovered || emphasized ? 0.37 : 0.19),
                                     .white.opacity(0.035), .white.opacity(0.12)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.6
                    )
                }
                .background(.black.opacity(emphasized ? 0.30 : 0.26), in: shape)
        } else {
            shape.fill(.primary.opacity(isHovered ? 0.14 : emphasized ? 0.11 : 0.055))
        }
    }
}

/// True only for expanded content mounted on the shared clear-glass shell.
/// The collapsed HUD, hardware header and settings leave this false, so their
/// original foreground treatment is untouched.
private struct SharedGlassShellEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var usesSharedGlassShell: Bool {
        get { self[SharedGlassShellEnvironmentKey.self] }
        set { self[SharedGlassShellEnvironmentKey.self] = newValue }
    }
}

/// A 1pt contact shadow for small foreground glyphs on clear glass. It is a
/// no-op whenever the shared shell is inactive (glass off, Reduce Transparency
/// or first launch), so those paths render exactly as before. Apply it to the
/// glyph or text itself, never to a card, cover or video surface.
struct SharedGlassForeground: ViewModifier {
    @Environment(\.usesSharedGlassShell) private var usesSharedGlassShell
    var opacity: Double = 0.32

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesSharedGlassShell {
            content.shadow(color: .black.opacity(opacity), radius: 1, x: 0, y: 1)
        } else {
            content
        }
    }
}

extension View {
    func sharedGlassForeground(opacity: Double = 0.32) -> some View {
        modifier(SharedGlassForeground(opacity: opacity))
    }
}

private extension NotchShape {
    func softEdgeHighlight(colors: [Color], opacity: Double) -> some View {
        self.stroke(
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
            lineWidth: 1
        )
        .blur(radius: 0.8)
        .opacity(opacity)
    }
}
