//
//  LottieView.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-14.
//

import SwiftUI
import Lottie
import ObjectiveC

struct LottieView: NSViewRepresentable {
    let url: URL
    let speed: Double
    let loopMode: LottieLoopMode

    private static var associatedURLKey: UInt8 = 0

    func makeNSView(context: Context) -> NSView {
        let animationView = LottieAnimationView()
        animationView.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(animationView)
        NSLayoutConstraint.activate([
            animationView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            animationView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            animationView.topAnchor.constraint(equalTo: container.topAnchor),
            animationView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let animationView = nsView.subviews.first as? LottieAnimationView else { return }
        let lastURL = objc_getAssociatedObject(animationView, &Self.associatedURLKey) as? URL
        if lastURL != url {
            LottieAnimation.loadedFrom(url: url) { animation in
                animationView.animation = animation
                animationView.loopMode = loopMode
                animationView.animationSpeed = CGFloat(speed)
                animationView.play()
                objc_setAssociatedObject(animationView, &Self.associatedURLKey, url, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        } else {
            animationView.loopMode = loopMode
            animationView.animationSpeed = CGFloat(speed)
            if !animationView.isAnimationPlaying {
                animationView.play()
            }
        }
    }
}

enum WeatherAlertAnimation: String {
    case wind
    case rain = "extreme-rain"
    case thunder = "thunderstorms-day-rain"
    case snow
    case heat = "thermometer-warmer"
    case sun = "clear-day"

    static func matching(_ description: String) -> Self? {
        let patterns: [(Self, [String])] = [
            (.thunder, ["雷电", "雷雨", "雷暴", "强对流", "冰雹"]),
            (.snow, ["暴雪", "降雪", "冻雨", "冰冻"]),
            (.rain, ["暴雨", "大雨", "降雨", "短时强降水", "下雨"]),
            (.heat, ["高温", "酷热", "热浪"]),
            (.wind, ["台风", "大风", "阵风", "沙尘", "寒潮"]),
            (.sun, ["晴"])
        ]
        return patterns.first { $0.1.contains(where: description.contains) }?.0
    }

    // Retain the source artwork and timings inside a representative excerpt.
    var frames: ClosedRange<AnimationFrameTime> {
        switch self {
        case .wind: 24...180
        case .rain: 10...131
        case .thunder: 18...50
        case .snow: 5...126
        case .heat: 20...142
        case .sun: 0...180
        }
    }

    var symbol: String {
        switch self {
        case .wind: "wind"
        case .rain: "cloud.heavyrain"
        case .thunder: "cloud.bolt.rain"
        case .snow: "cloud.snow"
        case .heat: "thermometer.sun"
        case .sun: "sun.max"
        }
    }

    @MainActor func applyPalette(to view: LottieAnimationView, dark: Bool) {
        switch self {
        case .wind:
            let color = dark ? LottieColor(r: 0.80, g: 0.93, b: 0.98, a: 1)
                : LottieColor(r: 0.13, g: 0.39, b: 0.48, a: 1)
            view.setValueProvider(ColorValueProvider(color), keypath: AnimationKeypath(keypath: "**.Color"))
        case .snow, .thunder:
            let color = dark ? LottieColor(r: 0.90, g: 0.94, b: 0.99, a: 1)
                : LottieColor(r: 0.34, g: 0.42, b: 0.51, a: 1)
            view.setValueProvider(ColorValueProvider(color), keypath: AnimationKeypath(keypath: "Clouds.**.Color"))
        default:
            break
        }
    }
}

struct WeatherAlertLottieView: NSViewRepresentable {
    let asset: WeatherAlertAnimation
    let animation: LottieAnimation
    let duration: Double
    let playing: Bool
    let onFinished: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    final class Coordinator {
        var playing: Bool?
        var colorScheme: ColorScheme?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView(animation: animation, configuration: .init(renderingEngine: .mainThread))
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateNSView(_ view: LottieAnimationView, context: Context) {
        if context.coordinator.colorScheme != colorScheme {
            context.coordinator.colorScheme = colorScheme
            asset.applyPalette(to: view, dark: colorScheme == .dark)
        }
        guard context.coordinator.playing != playing else { return }
        context.coordinator.playing = playing
        let frames = asset.frames
        if playing {
            view.animationSpeed = (frames.upperBound - frames.lowerBound) / animation.framerate / duration
            view.play(fromFrame: frames.lowerBound, toFrame: frames.upperBound, loopMode: .playOnce) { finished in
                if finished { onFinished() }
            }
        } else {
            view.currentFrame = frames.lowerBound
        }
    }

    static func dismantleNSView(_ view: LottieAnimationView, coordinator: Coordinator) {
        view.stop()
    }
}

struct WeatherAlertArtwork: View {
    static let popupPlayback: TimeInterval = 2.85
    static let startDelay: TimeInterval = 0.09

    let asset: WeatherAlertAnimation
    let duration: Double
    var onFinished: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playing = false

    var body: some View {
        Group {
            if !reduceMotion, let animation = LottieAnimation.named(asset.rawValue, subdirectory: "WeatherAnimations") {
                WeatherAlertLottieView(asset: asset, animation: animation, duration: duration,
                                       playing: playing, onFinished: onFinished)
                    .task {
                        playing = false
                        do {
                            try await Task.sleep(for: .seconds(Self.startDelay))
                            playing = true
                        } catch { return }
                    }
            } else {
                Image(systemName: asset.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
        .allowsHitTesting(false)
    }
}
