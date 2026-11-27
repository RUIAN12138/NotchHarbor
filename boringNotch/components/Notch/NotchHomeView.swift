//
//  NotchHomeView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//

import Combine
import Defaults
import SwiftUI
import WebKit

// MARK: - Music Player Components

struct MusicPlayerView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var music = MusicManager.shared
    @Default(.playerColorTinting) private var playerColorTinting
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let albumArtNamespace: Namespace.ID
    let viewportHeight: CGFloat
    var hasUnidentifiedAudio = false
    var body: some View {
        Group {
            if music.hasPanelMedia && (music.isPlaying || !hasUnidentifiedAudio) {
                MusicControlsView(albumArtNamespace: albumArtNamespace, viewportHeight: max(1, viewportHeight - 4))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background { albumAtmosphere }
            } else {
                MusicStandbyView(hasUnidentifiedAudio: hasUnidentifiedAudio)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: music.hasPanelMedia)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hasUnidentifiedAudio)
        .onAppear {
            if !UserDefaults.standard.bool(forKey: "lyricsFocusedMusicConfigured") {
                Defaults[.enableLyrics] = true
                UserDefaults.standard.set(true, forKey: "lyricsFocusedMusicConfigured")
            }
            MusicManager.shared.setMusicViewportVisible(true)
            MusicManager.shared.refreshLyrics()
        }
        .onDisappear {
            MusicManager.shared.setMusicViewportVisible(false)
        }
    }

    private var albumAtmosphere: some View {
        GeometryReader { geometry in
            let tint = Color(nsColor: music.avgColor)
            RadialGradient(stops: [
                .init(color: tint.opacity(0.28), location: 0),
                .init(color: tint.opacity(0.15), location: 0.40),
                .init(color: tint.opacity(0.05), location: 0.72),
                .init(color: .clear, location: 1),
            ], center: UnitPoint(x: min(0.32, 64 / max(1, geometry.size.width)), y: 0.38),
               startRadius: 0, endRadius: min(310, max(geometry.size.height * 0.85, geometry.size.width * 0.56)))
            .opacity(!playerColorTinting || music.isPlayerIdle || reduceTransparency || music.usingAppIconForArtwork ? 0 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.42), value: music.avgColor)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct MusicStandbyView: View {
    let hasUnidentifiedAudio: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: hasUnidentifiedAudio ? "waveform" : "music.note")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 29, height: 29)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(hasUnidentifiedAudio ? LocalizedStringKey("未知播放器") : "尚未播放")
                    .font(.system(size: 13, weight: .semibold))
                Text(hasUnidentifiedAudio ? LocalizedStringKey("正在播放系统音频") : "在播放器或浏览器中开始播放")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }
}

struct AlbumArtView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        let cornerRadius = Defaults[.cornerRadiusScaling]
            ? MusicPlayerImageSizes.cornerRadiusInset.opened
            : MusicPlayerImageSizes.cornerRadiusInset.closed

        Button(action: musicManager.openMusicApp) {
            ZStack(alignment: .bottomTrailing) {
                artwork(cornerRadius: cornerRadius)
                    .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                    .overlay(glowOverlay(cornerRadius: cornerRadius))
                    .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开播放应用")
        // simple scale animation instead of custom PhaseAnimator
        .scaleEffect(musicManager.isPlaying ? 1.03 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.75, blendDuration: 0), value: musicManager.isPlaying)
    }

    private func artwork(cornerRadius: CGFloat) -> some View {
        GeometryReader { geo in
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.width)
                .clipped()
                .cornerRadius(cornerRadius, antialiased: true)
                // keep a simple opacity transition when artwork updates
                .id(musicManager.albumArt) // ensure SwiftUI considers this a content change
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.28), value: musicManager.albumArt)
        }
        .aspectRatio(1, contentMode: .fit)
        .drawingGroup(opaque: false)
    }

    private func glowOverlay(cornerRadius: CGFloat) -> some View {
        Group {
            if Defaults[.lightingEffect] {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(nsColor: musicManager.avgColor).opacity(musicManager.isPlaying ? 0.28 : 0.0),
                                Color(nsColor: musicManager.avgColor).opacity(musicManager.isPlaying ? 0.10 : 0.0),
                                .clear,
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: 36
                        )
                    )
                    .scaleEffect(1.06)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.25), value: musicManager.isPlaying)
            } else {
                EmptyView()
            }
        }
    }
}

@MainActor
private enum BundleAppDisplayNameCache {
    private static var names: [String: String] = [:]

    static func displayName(for bundleIdentifier: String) -> String {
        if let cached = names[bundleIdentifier] { return cached }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            names[bundleIdentifier] = ""
            return ""
        }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        names[bundleIdentifier] = name
        return name
    }
}

struct MusicControlsView: View {
    let albumArtNamespace: Namespace.ID
    let viewportHeight: CGFloat
    @ObservedObject var musicManager = MusicManager.shared
    @EnvironmentObject private var vm: BoringViewModel
    @Environment(\.usesSharedGlassShell) private var usesSharedGlassShell
    @State private var dragging: Bool = false
    @Default(.musicControlSlots) private var slotConfig
    @Default(.musicControlSlotLimit) private var slotLimit
    @Default(.enableLyrics) private var lyricsEnabled

    var body: some View {
        let sliderHeight: CGFloat = showsProgress ? 16 : 0
        let controlsHeight: CGFloat = 24
        let dockSpacing: CGFloat = showsProgress ? 2 : 0
        let bottomDockHeight: CGFloat = sliderHeight + dockSpacing + controlsHeight
        let stageBottomGap: CGFloat = 4
        let stageHeight = max(46, viewportHeight - bottomDockHeight - stageBottomGap)
        let artworkSize = max(46, min(74, stageHeight - 2))
        VStack(alignment: .leading, spacing: stageBottomGap) {
            musicStage(height: stageHeight, artworkSize: artworkSize)
                .frame(maxWidth: .infinity)
                .frame(height: stageHeight)

            VStack(spacing: dockSpacing) {
                if showsProgress {
                    musicSlider.frame(height: sliderHeight)
                }
                GeometryReader { geometry in
                    transportControls(in: geometry.size.width)
                        .frame(width: geometry.size.width, height: controlsHeight, alignment: .center)
                }
                .frame(height: controlsHeight)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .onChange(of: showsProgress) { _, visible in
            if !visible { cancelScrub() }
        }
        .onChange(of: scrubTrackIdentity) { _, _ in cancelScrub() }
        .onChange(of: dragging) { _, active in vm.isMusicScrubbing = active }
        .onChange(of: vm.systemIslandPresentationActive) { _, active in
            if active { cancelScrub() }
        }
        .onDisappear { cancelScrub() }
    }

    private func musicStage(height: CGFloat, artworkSize: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace)
                .frame(width: artworkSize, height: artworkSize)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.26), radius: 6, y: 2)

            let showsLyricsStage = !trimmedTitle.isEmpty && lyricsEnabled && musicManager.isSong && height >= 40
            VStack(alignment: .leading, spacing: 2) {
                if showsLyricsStage {
                    songInfo.frame(height: 16)
                    MusicLyricsFocusView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    nonLyricTrackStage
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: height, alignment: .topLeading)
        }
        .frame(height: height)
    }

    private var nonLyricTrackStage: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            if !trimmedTitle.isEmpty {
                Text(trimmedTitle)
                    .notchReadableText()
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let albumText = musicManager.album.trimmingCharacters(in: .whitespacesAndNewlines)
            if !albumText.isEmpty && albumText != "Self Love" && albumText != "Unknown" {
                Text(albumText)
                    .notchReadableText()
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !sourceSubtitle.isEmpty {
                Text(sourceSubtitle)
                    .notchReadableText()
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private var scrubTrackIdentity: [String] {
        [musicManager.bundleIdentifier ?? "", musicManager.songTitle, musicManager.artistName, musicManager.album]
    }

    private func cancelScrub() {
        dragging = false
        vm.isMusicScrubbing = false
    }

    private var songInfo: some View {
        HStack(spacing: 7) {
            if trimmedTitle.isEmpty {
                Text(musicManager.isPlaying ? "正在播放" : "已暂停")
                    .font(.system(size: 13, weight: .semibold))
            } else {
                Text(trimmedTitle).notchReadableText()
                    .font(.system(size: 14, weight: .semibold))
                    .layoutPriority(1)
            }
            if !sourceSubtitle.isEmpty {
                Text(sourceSubtitle).notchReadableText()
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 3)
            if lyricsEnabled && !musicManager.syncedLyrics.isEmpty {
                lyricTimingMenu
            }
        }
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var lyricTimingMenu: some View {
        let adjustment = musicManager.lyricAdjustmentMilliseconds
        let trackKey = musicManager.lyricTimingTrackKey
        let value = adjustment == 0 ? "原始时间" : String(format: "%+.2f 秒", Double(adjustment) / 1000)
        return Menu {
            Text(value)
            Button {
                musicManager.adjustLyricTiming(to: adjustment - MusicLyricCalibration.step, for: trackKey)
            } label: {
                Label("歌词提前 0.25 秒", systemImage: "arrow.left")
            }
            .disabled(adjustment <= -MusicLyricCalibration.limit)
            Button {
                musicManager.adjustLyricTiming(to: adjustment + MusicLyricCalibration.step, for: trackKey)
            } label: {
                Label("歌词延后 0.25 秒", systemImage: "arrow.right")
            }
            .disabled(adjustment >= MusicLyricCalibration.limit)
            Divider()
            Button("恢复原始时间") {
                musicManager.adjustLyricTiming(to: 0, for: trackKey)
            }
            .disabled(adjustment == 0)
        } label: {
            Image(systemName: adjustment == 0 ? "stopwatch" : "stopwatch.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(adjustment == 0 ? Color.secondary : Color.primary)
                .frame(width: 22, height: 19)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("校准这首歌的歌词")
        .accessibilityLabel("校准歌词")
        .accessibilityValue(value)
    }

    private var transportWidth: CGFloat {
        let slots = activeSlots
        let buttons = slots.reduce(CGFloat.zero) { $0 + ($1 == .playPause ? 32 : 25) }
        return buttons + CGFloat(max(0, slots.count - 1)) * 2
    }

    @ViewBuilder
    private func transportControls(in width: CGFloat) -> some View {
        if width < transportWidth {
            ScrollView(.horizontal) { slotToolbar }
                .scrollIndicators(.never)
                .reservesHorizontalNotchScrolling()
        } else {
            slotToolbar
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Pause the tick when the player is idle; lyrics and the scrubber share
    /// the same media clock when a track is playing.
    private var musicSlider: some View {
        let track = scrubTrackIdentity
        return MusicSliderView(
            duration: musicManager.songDuration,
            color: musicManager.avgColor,
            dragging: $dragging,
            timestampDate: musicManager.timestampDate,
            elapsedTime: musicManager.elapsedTime,
            playbackRate: musicManager.playbackRate,
            isPlaying: musicManager.isPlaying
        ) { newValue in
            guard scrubTrackIdentity == track, vm.notchState == .open, !vm.systemIslandPresentationActive else { return }
            musicManager.seek(to: newValue)
        }
        .id(track)
    }

    private var trimmedTitle: String {
        musicManager.songTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedArtist: String {
        musicManager.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sourceSubtitle: String {
        if !trimmedArtist.isEmpty { return trimmedArtist }
        guard !musicManager.isSong, let bundle = musicManager.bundleIdentifier else { return "" }
        return BundleAppDisplayNameCache.displayName(for: bundle)
    }

    private var showsProgress: Bool {
        hasKnownDuration
    }

    private var hasKnownDuration: Bool {
        let duration = musicManager.songDuration
        return duration.isFinite && duration > 0
    }

    private var slotToolbar: some View {
        let slots = activeSlots
        return HStack(spacing: 2) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                slotView(for: slot)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var activeSlots: [MusicControlButton] {
        let sanitizedLimit = min(
            max(slotLimit, MusicControlButton.minSlotCount),
            MusicControlButton.maxSlotCount
        )
        let slots = Array(slotConfig.prefix(sanitizedLimit)).filter { $0 != .none }
        guard !musicManager.isSong else { return slots }
        let mediaSlots = slots.filter { $0 != .shuffle && $0 != .repeatMode && $0 != .favorite }
            .filter { hasKnownDuration || ($0 != .goBackward && $0 != .goForward) }
        return mediaSlots.isEmpty ? [.playPause] : mediaSlots
    }

    @ViewBuilder
    private func slotView(for slot: MusicControlButton) -> some View {
        switch slot {
        case .shuffle:
            MusicDeckButton(icon: "shuffle", label: "随机播放", active: musicManager.isShuffled) {
                MusicManager.shared.toggleShuffle()
            }
        case .previous:
            MusicDeckButton(icon: "backward.end.fill", label: musicManager.isSong ? "上一首" : "上一项") {
                MusicManager.shared.previousTrack()
            }
        case .playPause:
            MusicDeckButton(icon: musicManager.isPlaying ? "pause.fill" : "play.fill",
                            label: musicManager.isPlaying ? "暂停" : "播放", prominent: true) {
                MusicManager.shared.togglePlay()
            }
        case .next:
            MusicDeckButton(icon: "forward.end.fill", label: musicManager.isSong ? "下一首" : "下一项") {
                MusicManager.shared.nextTrack()
            }
        case .repeatMode:
            MusicDeckButton(icon: repeatIcon, label: "循环播放", active: musicManager.repeatMode != .off) {
                MusicManager.shared.toggleRepeat()
            }
        case .volume:
            VolumeControlView()
        case .favorite:
            FavoriteControlButton()
        case .goBackward:
            MusicDeckButton(icon: "gobackward.15", label: "后退 15 秒") {
                MusicManager.shared.skip(seconds: -15)
            }
        case .goForward:
            MusicDeckButton(icon: "goforward.15", label: "前进 15 秒") {
                MusicManager.shared.skip(seconds: 15)
            }
        case .none:
            Color.clear.frame(height: 1)
        }
    }

    private var repeatIcon: String {
        switch musicManager.repeatMode {
        case .off:
            return "repeat"
        case .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

}

struct AirPodsMenuDetails: View {
    let device: DeviceAlert
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(device.name).font(.headline).lineLimit(1)
            HStack(spacing: 13) {
                if device.leftBattery != nil || device.rightBattery != nil {
                    level("左耳", value: device.leftBattery, charging: device.leftCharging)
                    level("右耳", value: device.rightBattery, charging: device.rightCharging)
                } else {
                    level("耳机", value: device.battery, charging: nil)
                }
                if device.symbol != "airpodsmax" {
                    level("充电盒", value: device.caseBattery, charging: device.caseCharging)
                }
            }
            AirPodsOutputControls(snapshotID: device.id, onOpenSettings: close)
        }
    }

    private func level(_ name: String, value: Int?, charging: Bool?) -> some View {
        VStack(spacing: 4) {
            HeadphoneBatteryRing(level: value, size: 25, label: name, charging: charging)
            Text(name).font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .frame(minWidth: 34)
    }
}

private struct AirPodsOutputControls: View {
    let snapshotID: UUID
    let onOpenSettings: () -> Void
    @ObservedObject private var volume = VolumeManager.shared
    @State private var shownVolume: Float?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let shownVolume {
                HStack(spacing: 6) {
                    Label("输出音量", systemImage: "speaker.wave.2")
                    Spacer(minLength: 4)
                    Button { adjust(-1) } label: { Image(systemName: "minus") }
                        .accessibilityLabel("降低 AirPods 音量")
                        .disabled(shownVolume <= 0)
                    Text(shownVolume, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(minWidth: 34)
                    Button { adjust(1) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("提高 AirPods 音量")
                        .disabled(shownVolume >= 1)
                }
                .font(.caption)
            }
            Button {
                onOpenSettings()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("打开系统声音设置", systemImage: "gearshape")
            }
            .font(.caption)
            .help("在系统设置或控制中心管理设备和聆听模式")
        }
        .buttonStyle(.borderless)
        .onAppear(perform: refresh)
        .onChange(of: volume.rawVolume) { _, _ in refresh() }
    }

    private func refresh() {
        let device = UnifiedActivities.shared.airPodsOutputDevice(for: snapshotID)
        shownVolume = device.flatMap { volume.adjustableOutputVolume(deviceID: $0) }
    }

    private func adjust(_ direction: Float) {
        guard let device = UnifiedActivities.shared.airPodsOutputDevice(for: snapshotID) else {
            shownVolume = nil
            return
        }
        volume.stepOutputVolume(deviceID: device, direction: direction)
        refresh()
    }
}

private struct MusicDeckButton: View {
    let icon: String
    let label: String
    var prominent = false
    var active = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: prominent ? 12 : 10.5, weight: prominent ? .bold : .semibold))
                .foregroundStyle(.primary.opacity(prominent || active || hovering ? 1 : 0.76))
                .contentTransition(reduceMotion ? .identity : .symbolEffect)
                .offset(x: icon == "play.fill" ? 0.65 : 0)
                .frame(width: prominent ? 28 : 22, height: prominent ? 22 : 20)
                .background {
                    if prominent || active || hovering {
                        NotchControlSurface(shape: Capsule(), emphasized: prominent || active, isHovered: hovering)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: prominent ? 32 : 25, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchControlStyle())
        .onHover { value in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { hovering = value }
        }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct FavoriteControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        MusicDeckButton(icon: iconName, label: musicManager.isFavoriteTrack ? "取消收藏" : "收藏",
                        active: musicManager.isFavoriteTrack) {
            MusicManager.shared.toggleFavoriteTrack()
        }
        .disabled(!musicManager.canFavoriteTrack)
        .opacity(musicManager.canFavoriteTrack ? 1 : 0.35)
    }

    private var iconName: String {
        musicManager.isFavoriteTrack ? "heart.fill" : "heart"
    }

}

// MARK: - Volume Control View

struct VolumeControlView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var volumeSliderValue: Double = 0.5
    @State private var dragging: Bool = false
    @State private var showVolumeSlider: Bool = false
    @State private var lastVolumeUpdateTime: Date = Date.distantPast
    @State private var volumeUpdateTask: Task<Void, Never>?
    private let volumeUpdateThrottle: Duration = .milliseconds(200)
    
    @EnvironmentObject private var vm: BoringViewModel

    var body: some View {
        MusicDeckButton(icon: volumeIcon, label: "播放器音量", active: showVolumeSlider) {
            showVolumeSlider.toggle()
        }
        .disabled(!musicManager.volumeControlSupported)
        .opacity(musicManager.volumeControlSupported ? 1 : 0.35)
        .popover(isPresented: $showVolumeSlider, arrowEdge: .bottom) {
            VStack(spacing: 6) {
                HStack {
                    Label("播放器音量", systemImage: volumeIcon)
                    Spacer(minLength: 8)
                    Text(volumeSliderValue, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                .font(.caption.weight(.medium))
                CustomSlider(
                    value: $volumeSliderValue, range: 0...1, color: .primary,
                    dragging: $dragging, lastDragged: .constant(.distantPast),
                    effectiveHeight: 22, accessibilityName: "播放器音量",
                    onValueChange: { newValue in
                        volumeUpdateTask?.cancel()
                        MusicManager.shared.setVolume(to: newValue)
                    },
                    onDragChange: { newValue in
                        volumeUpdateTask?.cancel()
                        volumeUpdateTask = Task {
                            try? await Task.sleep(for: volumeUpdateThrottle)
                            if !Task.isCancelled { MusicManager.shared.setVolume(to: newValue) }
                        }
                    }
                )
                .frame(height: 22)
            }
            .padding(12)
            .frame(width: 174)
        }
        .onChange(of: showVolumeSlider) { _, shown in vm.isMusicVolumePopoverActive = shown }
        .onReceive(musicManager.$volume) { volume in
            if !dragging { volumeSliderValue = volume.isFinite ? min(1, max(0, volume)) : 0 }
        }
        .onReceive(musicManager.$volumeControlSupported) { supported in
            if !supported { showVolumeSlider = false }
        }
        .onDisappear {
            volumeUpdateTask?.cancel()
            vm.isMusicVolumePopoverActive = false
        }
    }

    private var volumeIcon: String {
        if !musicManager.volumeControlSupported {
            return "speaker.slash"
        } else if volumeSliderValue == 0 {
            return "speaker.slash.fill"
        } else if volumeSliderValue < 0.33 {
            return "speaker.1.fill"
        } else if volumeSliderValue < 0.66 {
            return "speaker.2.fill"
        } else {
            return "speaker.3.fill"
        }
    }
}

// MARK: - Main View

struct NotchHomeView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject private var activities = UnifiedActivities.shared
    @Default(.notchWeatherCity) private var weatherCity
    let albumArtNamespace: Namespace.ID
    var compactMusic = false
    var viewportHeight: CGFloat = 100
    var hasUnidentifiedAudio = false
    var refreshWeather: () -> Void = {}

    var body: some View {
        mainContent
            .transition(.opacity)
    }

    private var shouldShowCamera: Bool {
        Defaults[.showMirror] && webcamManager.cameraAvailable && vm.isCameraExpanded
    }

    private var mainContent: some View {
        let showsCalendar = !compactMusic
        return HStack(alignment: .top, spacing: (shouldShowCamera && showsCalendar) ? 10 : 15) {
            if showsCalendar {
                HStack(alignment: .top, spacing: 10) {
                    weatherColumn.frame(width: 92)
                    CalendarView()
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .layoutPriority(1)
                }
                    .frame(maxWidth: .infinity)
                    .onHover { isHovering in
                        vm.isHoveringCalendar = isHovering
                    }
                    .environmentObject(vm)
                    .transition(.opacity)
            } else {
                MusicPlayerView(albumArtNamespace: albumArtNamespace, viewportHeight: viewportHeight,
                                hasUnidentifiedAudio: hasUnidentifiedAudio)
            }

            if shouldShowCamera {
                CameraPreviewView(webcamManager: webcamManager)
                    .scaledToFit()
                    .opacity(vm.notchState == .closed ? 0 : 1)
                    .blur(radius: vm.notchState == .closed ? 20 : 0)
                    .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.76, blendDuration: 0), value: shouldShowCamera)
            }
        }
    }

    private var weatherColumn: some View {
        let warnings = activities.weatherWarnings.filter { $0.expires > Date().timeIntervalSince1970 }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Label("天气", systemImage: "cloud.sun")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !weatherCity.isEmpty {
                    Button(action: refreshWeather) {
                        Image(systemName: "arrow.clockwise").font(.caption2)
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("立即刷新天气")
                    .accessibilityLabel("立即刷新天气")
                }
            }
            if let weather = activities.currentWeather {
                Link(destination: URL(string: "https://open-meteo.com/")!) {
                    VStack(alignment: .leading, spacing: 4) {
                        Image(systemName: weather.symbol).font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        Text(weather.detail).notchReadableText().font(.caption.weight(.semibold))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text(weather.title).notchReadableText().font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if warnings.isEmpty, let updated = activities.weatherUpdatedAt {
                            Text("更新于 \(updated.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("天气数据：Open-Meteo")
            } else {
                Text(weatherCity.isEmpty ? "在设置中填写城市" : (activities.weatherRefreshMessage ?? "等待天气数据"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !warnings.isEmpty {
                WeatherWarningsButton(warnings: warnings)
            } else if activities.currentWeather != nil, let message = activities.weatherRefreshMessage {
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(4)
        .background(.primary.opacity(0.07), in: .rect(cornerRadius: 12))
    }
}

private struct WeatherWarningsButton: View {
    let warnings: [IslandActivity]
    @State private var open = false
    @EnvironmentObject private var vm: BoringViewModel

    var body: some View {
        Button { open.toggle() } label: {
            Label("气象预警 \(warnings.count)", systemImage: "exclamationmark.triangle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("notch-weather-warnings")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 9) {
                Text("气象预警").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(warnings) { warning in
                            if let url = warning.weatherWarningURL {
                                Link(destination: url) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(warning.title).font(.subheadline.weight(.semibold))
                                        Text(warning.detail)
                                            .font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if let start = warning.weatherStartsAt {
                                            let date = Date(timeIntervalSince1970: start)
                                            Text(date > Date() ? "即将生效 · \(date.formatted(.dateTime.month().day().hour().minute()))"
                                                : date.formatted(.dateTime.month().day().hour().minute()))
                                                .monospacedDigit().font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxHeight: 215)
            }
            .padding(13)
            .frame(width: 292, alignment: .leading)
        }
        .onChange(of: open) { _, value in vm.isWeatherWarningListOpen = value }
        .onDisappear { vm.isWeatherWarningListOpen = false }
    }
}

private func albumLyricInk(_ color: NSColor) -> NSColor {
    guard let rgb = color.usingColorSpace(.sRGB),
          let mixed = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            .blended(withFraction: 0.08, of: rgb.withAlphaComponent(1)) else { return .white }
    return mixed
}

private struct MusicLyricsFocusView: View {
    @Default(.lyricLineCount) private var lineCount
    @ObservedObject private var music = MusicManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lineHeights: [Int: CGFloat] = [:]
    @State private var foliaRendered = FoliaWebViewHost.shared.hasRenderedOnce
    @State private var foliaFailed = false

    private var plainLyricLines: [String] {
        music.currentLyrics
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func anchorY(for current: Int, in containerHeight: CGFloat) -> CGFloat {
        let activeHeight = max(19, lineHeights[current] ?? 20)
        let preferredCenter = lineCount == 1
            ? containerHeight * 0.48
            : (current <= 0 ? min(containerHeight * 0.30, activeHeight / 2 + 4) : containerHeight * 0.34)
        let unclamped = preferredCenter - activeHeight / 2
        guard activeHeight <= containerHeight - 4 else { return 1 }
        return min(max(2, unclamped), containerHeight - activeHeight - 2)
    }

    private func trackOffset(_ index: Int, around current: Int, in containerHeight: CGFloat) -> CGFloat {
        let base = anchorY(for: current, in: containerHeight)
        func step(_ idx: Int) -> CGFloat {
            let h = max(18, lineHeights[idx] ?? 19)
            return idx == current ? h + 4 : h * 0.86 + 3
        }
        if index == current { return base }
        if index < current {
            return base - (index..<current).reduce(CGFloat.zero) { $0 + step($1) }
        }
        return base + (current..<index).reduce(CGFloat.zero) { $0 + step($1) }
    }

    var body: some View {
        if music.syncedLyrics.isEmpty {
            if music.isFetchingLyrics {
                Text("正在匹配同步歌词…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else if !plainLyricLines.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(plainLyricLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .notchReadableText()
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.88))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .mask(LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.06),
                        .init(color: .black, location: 0.90),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ))
            } else {
                Text("暂无带时间轴的歌词")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        } else {
            let syncTrigger = "\(music.lyricsTimingRevision)|\(music.elapsedTime)|\(music.timestampDate.timeIntervalSinceReferenceDate)|\(music.isPlaying)|\(music.playbackRate)|\(lineCount)"
            ZStack {
                if !foliaRendered || foliaFailed { nativeRail }
                if !foliaFailed, let url = Bundle.main.url(forResource: "FoliaRail", withExtension: "html") {
                    FoliaLyricsRail(
                        file: url,
                        music: music,
                        reduceMotion: reduceMotion,
                        lineCount: lineCount,
                        syncTrigger: syncTrigger
                    ) { rendered in
                        foliaRendered = rendered
                        foliaFailed = !rendered
                    }
                    .opacity(foliaRendered ? 1 : 0.001)
                    .allowsHitTesting(foliaRendered)
                    .accessibilityHidden(!foliaRendered)
                }
            }
            .clipped()
        }
    }

    private var nativeRail: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.08 : 1.0 / 30, paused: !music.isPlaying)) { timeline in
            let elapsed = music.estimatedPlaybackPosition(at: timeline.date)
            let frame = MusicLyricTimeline.frame(lines: music.syncedLyrics, plain: music.currentLyrics, elapsed: elapsed)
            let displayed = frame.isPrelude ? "前奏" : (frame.index != nil && frame.current.isEmpty) ? "间奏" : frame.current.isEmpty
                ? (music.isFetchingLyrics ? "正在载入歌词…" : "暂无匹配歌词") : frame.current
            let current = frame.index ?? -1
            let lowerBound = lineCount == 1 ? current : max(-1, current - 1)
            let upperBound = min(music.syncedLyrics.count - 1, current + (lineCount == 1 ? 0 : 2))
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    if !music.syncedLyrics.isEmpty, lowerBound <= upperBound {
                        ForEach(lowerBound...upperBound, id: \.self) { index in
                            let distance = index - current
                            let active = distance == 0
                            let line = index < 0 ? "前奏" : music.syncedLyrics[index].text
                            let label = line.isEmpty ? "间奏" : line
                            let isCredit = label.trimmingCharacters(in: .whitespacesAndNewlines)
                                .range(of: #"^(?:作[词詞曲]|[编編]曲|[词詞曲]|[製制]作人?)\s*[:：]"#,
                                       options: .regularExpression) != nil
                            let start = index < 0 ? 0 : music.syncedLyrics[index].time
                            let end = index + 1 < music.syncedLyrics.count
                                ? music.syncedLyrics[index + 1].time : max(start + 0.25, music.songDuration)
                            let fraction = min(1, max(0, (elapsed - start) / max(0.25, end - start)))
                            Button {
                                if index >= 0 { music.seek(toLyric: music.syncedLyrics[index].time) }
                            } label: {
                                lyricText(label, active: active, progress: fraction)
                                    .font(.system(size: active ? (isCredit ? 12.5 : 15.5) : 12.5, weight: active ? .bold : .semibold))
                                    .shadow(color: Color(red: 0.12, green: 0.16, blue: 0.24).opacity(0.68), radius: 1.5, y: 1)
                                    .lineLimit(active ? nil : 3)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(width: max(1, geometry.size.width), alignment: .leading)
                                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                                        lineHeights[index] = height
                                    }
                            }
                            .buttonStyle(.plain)
                            .scaleEffect(active ? 1 : 0.88, anchor: .topLeading)
                            .opacity(active ? 1 : distance < 0 ? 0.42 : (distance == 1 ? 0.78 : 0.48))
                            .blur(radius: reduceMotion || active ? 0 : 0.5)
                            .offset(y: trackOffset(index, around: current, in: geometry.size.height))
                            .transition(.identity)
                            .allowsHitTesting(index >= 0)
                            .accessibilityHidden(index < 0)
                            .accessibilityLabel("跳到歌词：\(label)")
                        }
                    } else {
                        Text(displayed)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 7)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: current)
            }
            .mask(LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.90),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            ))
            .accessibilityValue(displayed)
        }
        .id(music.songTitle + "|" + music.artistName)
        .accessibilityLabel("歌词")
    }

    @ViewBuilder
    private func lyricText(_ label: String, active: Bool, progress: Double) -> some View {
        if #available(macOS 15.0, *), active, !reduceMotion {
            Text(label).notchReadableText().foregroundStyle(Color(nsColor: albumLyricInk(music.avgColor)))
                .textRenderer(MonetLineSweep(progress: progress))
        } else if active {
            Text(label).notchReadableText().foregroundStyle(Color(nsColor: albumLyricInk(music.avgColor)))
        } else {
            Text(label).notchReadableText().foregroundStyle(.white)
        }
    }
}

@available(macOS 15.0, *)
private struct MonetLineSweep: TextRenderer {
    var progress: Double

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let total = layout.reduce(CGFloat.zero) { $0 + $1.typographicBounds.rect.width }
        var remaining = total * progress
        for line in layout {
            let rect = line.typographicBounds.rect
            var base = context
            base.opacity = 0.54
            base.draw(line)
            if remaining > 0 {
                var lit = context
                let width = min(rect.width, remaining)
                let rtl = line.first?.layoutDirection == .rightToLeft
                let x = rtl ? rect.maxX - width : rect.minX
                lit.clip(to: Path(CGRect(x: x, y: rect.minY - 3, width: width, height: rect.height + 6)))
                lit.draw(line)
            }
            remaining -= rect.width
        }
    }
}

@MainActor
private final class FoliaWebViewHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = FoliaWebViewHost()

    private(set) var webView: WKWebView?
    private var loadedFileURL: URL?
    private(set) var ready = false
    private(set) var hasRenderedOnce = false
    private var inFlight = false
    private var pendingSync = false
    private var timeout: Task<Void, Never>?
    private var reportRender: ((Bool) -> Void)?

    private var lineCount = 2
    private var reduced = false
    private var lastKey: String?
    private var lastRawElapsed: Double?
    private var lastTimestampDate: Date?
    private var lastPlaying: Bool?
    private var lastRate: Double?
    private var lastReduced: Bool?
    private var lastAlbumInk: String?

    func ensureWebView(for file: URL) -> WKWebView {
        if let existing = webView, loadedFileURL == file {
            return existing
        }
        teardownWebView()
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "foliaReady")
        config.userContentController.add(self, name: "foliaSeek")
        config.userContentController.add(self, name: "foliaRendered")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        web.loadFileURL(file, allowingReadAccessTo: file)
        webView = web
        loadedFileURL = file
        ready = false
        hasRenderedOnce = false
        lastKey = nil
        scheduleRenderTimeout()
        return web
    }

    private func scheduleRenderTimeout() {
        timeout?.cancel()
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard let self, !Task.isCancelled, !self.hasRenderedOnce else { return }
            self.reportRender?(false)
        }
    }

    private func teardownWebView() {
        timeout?.cancel()
        if let webView {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "foliaReady")
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "foliaSeek")
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "foliaRendered")
        }
        webView = nil
        loadedFileURL = nil
        ready = false
        hasRenderedOnce = false
        inFlight = false
        pendingSync = false
        lastKey = nil
    }

    func update(lineCount: Int, reduced: Bool, reportRender: @escaping (Bool) -> Void) {
        self.lineCount = lineCount
        self.reduced = reduced
        self.reportRender = reportRender
        if hasRenderedOnce {
            reportRender(true)
        }
        sync(force: false)
    }

    func forceSyncOnAttach() {
        lastRawElapsed = nil
        sync(force: true)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        teardownWebView()
        reportRender?(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportRender?(false)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportRender?(false)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        if message.name == "foliaRendered" {
            timeout?.cancel()
            hasRenderedOnce = true
            reportRender?(true)
        } else if message.name == "foliaReady" {
            ready = true
            lastKey = nil
            sync(force: true)
        } else if message.name == "foliaSeek", let time = message.body as? Double, time.isFinite {
            let music = MusicManager.shared
            if music.syncedLyrics.contains(where: { abs($0.time - time) < 0.01 }) {
                music.seek(toLyric: time)
            }
        }
    }

    func sync(force: Bool) {
        guard ready, let web = webView else { return }
        if inFlight {
            pendingSync = true
            return
        }
        let music = MusicManager.shared
        let now = Date()
        let elapsed = music.estimatedPlaybackPosition(at: now)
        let rawElapsed = music.elapsedTime
        let timestampDate = music.timestampDate
        let anchorWallMs: Double = timestampDate == .distantPast ? 0 : timestampDate.timeIntervalSince1970 * 1000
        let playing = music.isPlaying
        let rate = music.playbackRate.isFinite ? music.playbackRate : 1
        let rich = music.richSyncedLyrics
        let lyrics = music.syncedLyrics
        let trackKey = music.lyricTimingTrackKey ?? "\(music.songTitle)|\(music.artistName)"
        let key = "\(trackKey)|\(music.lyricsTimingRevision)|\(music.songDuration)|\(lineCount)"
        let changed = force || lastKey != key
        let rgb = albumLyricInk(music.avgColor).usingColorSpace(.sRGB)
        let channels = [rgb?.redComponent, rgb?.greenComponent, rgb?.blueComponent].map {
            Int((min(1, max(0, $0 ?? 1)) * 255).rounded())
        }
        let albumInk = String(format: "#%02x%02x%02x", channels[0], channels[1], channels[2])
        let anchorChanged = lastRawElapsed != rawElapsed || lastTimestampDate != timestampDate
            || lastPlaying != playing || lastRate != rate
        guard changed || anchorChanged || lastReduced != reduced || lastAlbumInk != albumInk else { return }

        var payload: [String: Any] = [
            "key": key,
            "trackKey": trackKey,
            "elapsed": elapsed,
            "anchorElapsed": rawElapsed.isFinite ? max(0, rawElapsed) : 0,
            "anchorWallMs": anchorWallMs,
            "rate": rate,
            "playing": playing,
            "reduced": reduced,
            "albumInk": albumInk,
            "lineCount": lineCount,
            "duration": music.songDuration.isFinite ? music.songDuration : 0,
        ]
        if changed {
            if rich.count == lyrics.count && !rich.isEmpty {
                payload["lines"] = rich.map { line -> [String: Any] in
                    var dict: [String: Any] = ["time": line.time, "text": line.text]
                    if let endTime = line.endTime, endTime.isFinite { dict["endTime"] = endTime }
                    if !line.words.isEmpty {
                        dict["words"] = line.words.map { [
                            "text": $0.text,
                            "startTime": $0.startTime,
                            "endTime": $0.endTime,
                        ] }
                    }
                    return dict
                }
            } else {
                payload["lines"] = lyrics.map { ["time": $0.time, "text": $0.text] }
            }
        }

        inFlight = true
        pendingSync = false
        web.callAsyncJavaScript("window.updateFolia(snapshot)", arguments: ["snapshot": payload],
                                in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            self.inFlight = false
            if case .success = result {
                self.lastKey = key
                self.lastRawElapsed = rawElapsed
                self.lastTimestampDate = timestampDate
                self.lastPlaying = playing
                self.lastRate = rate
                self.lastReduced = payload["reduced"] as? Bool
                self.lastAlbumInk = albumInk
            }
            if self.pendingSync {
                self.pendingSync = false
                self.sync(force: false)
            }
        }
    }
}

@MainActor
private struct FoliaLyricsRail: NSViewRepresentable {
    let file: URL
    let music: MusicManager
    let reduceMotion: Bool
    let lineCount: Int
    let syncTrigger: String
    let reportRender: (Bool) -> Void

    final class ContainerView: NSView {
        override func layout() {
            super.layout()
            for subview in subviews {
                subview.frame = bounds
            }
        }
    }

    func makeNSView(context: Context) -> ContainerView {
        let container = ContainerView(frame: .zero)
        let host = FoliaWebViewHost.shared
        let web = host.ensureWebView(for: file)
        web.removeFromSuperview()
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)
        host.update(lineCount: lineCount, reduced: reduceMotion, reportRender: reportRender)
        host.forceSyncOnAttach()
        return container
    }

    func updateNSView(_ container: ContainerView, context: Context) {
        let host = FoliaWebViewHost.shared
        let web = host.ensureWebView(for: file)
        if web.superview !== container {
            web.removeFromSuperview()
            web.frame = container.bounds
            container.addSubview(web)
        }
        _ = syncTrigger
        host.update(lineCount: lineCount, reduced: reduceMotion, reportRender: reportRender)
    }

    static func dismantleNSView(_ container: ContainerView, coordinator: ()) {
        for subview in container.subviews {
            subview.removeFromSuperview()
        }
    }
}

struct MusicSliderView: View {
    let duration: Double
    var color: NSColor
    @Binding var dragging: Bool
    let timestampDate: Date
    let elapsedTime: Double
    let playbackRate: Double
    let isPlaying: Bool
    var onValueChange: (Double) -> Void

    @State private var scrubValue: Double = 0
    @State private var lastDragged: Date = .distantPast
    @State private var hoverTime: Double?

    private var safeDuration: Double {
        duration.isFinite && duration > 0 ? duration : 0
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !isPlaying || dragging)) { timeline in
            let currentValue = displayedValue(at: timeline.date)
            HStack(spacing: 9) {
                timeLabel(dragging ? currentValue : hoverTime ?? currentValue)
                    .allowsHitTesting(false)
                CustomSlider(
                    value: Binding(
                        get: { currentValue },
                        set: { scrubValue = $0 }
                    ),
                    range: 0...safeDuration,
                    color: Defaults[.sliderColor] == SliderColorEnum.albumArt
                        ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.86)
                        : Defaults[.sliderColor] == SliderColorEnum.accent ? .effectiveAccent : .white,
                    dragging: $dragging,
                    lastDragged: $lastDragged,
                    effectiveHeight: 16,
                    baseTrackHeight: 5.5,
                    accessibilityName: "播放进度",
                    accessibilityText: timeString(from: currentValue),
                    onValueChange: onValueChange,
                    onPreviewChange: { hoverTime = $0 }
                )
                .frame(minWidth: 24, maxWidth: .infinity)
                timeLabel(safeDuration)
                    .allowsHitTesting(false)
            }
        }
        .task(id: lastDragged) {
            guard lastDragged != .distantPast else { return }
            try? await Task.sleep(for: .seconds(MusicScrubPosition.confirmationWindow + 0.02))
            guard !Task.isCancelled else { return }
            if !dragging { lastDragged = .distantPast }
        }
    }

    private func displayedValue(at date: Date) -> Double {
        if dragging { return min(max(scrubValue, 0), safeDuration) }
        if !MusicScrubPosition.shouldFollowPlayback(
            target: scrubValue,
            observedPosition: elapsedTime,
            anchor: timestampDate,
            committedAt: lastDragged,
            now: date
        ) {
            return min(max(scrubValue, 0), safeDuration)
        }
        let estimated = PlaybackPositionClock.position(
            elapsed: elapsedTime,
            anchor: timestampDate,
            rate: playbackRate,
            playing: isPlaying,
            duration: safeDuration,
            now: date
        )
        guard estimated.isFinite else { return 0 }
        return min(max(estimated, 0), safeDuration)
    }

    private func timeLabel(_ seconds: Double) -> some View {
        Text(timeString(from: seconds)).notchReadableText()
            .foregroundStyle(.white)
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .shadow(color: .black.opacity(0.70), radius: 2)
            .accessibilityHidden(true)
    }

    func timeString(from seconds: Double) -> String {
        let wholeSeconds = seconds.isFinite ? (Int(exactly: max(0, seconds).rounded(.down)) ?? 0) : 0
        let totalMinutes = wholeSeconds / 60
        let remainingSeconds = wholeSeconds % 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}

struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var color: Color = .primary
    @Binding var dragging: Bool
    @Binding var lastDragged: Date
    var effectiveHeight: CGFloat = 10
    var baseTrackHeight: CGFloat = 3.5
    var accessibilityName = "进度"
    var accessibilityText: String?
    var onValueChange: ((Double) -> Void)?
    var onDragChange: ((Double) -> Void)?
    var onPreviewChange: ((Double?) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var hoverFraction: CGFloat?
    @GestureState private var trackingDrag = false
    private var span: Double { range.upperBound - range.lowerBound }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let progress = value.isFinite && span.isFinite && span > 0
                ? min(1, max(0, (value - range.lowerBound) / span)) : 0
            let engaging = dragging || hovering
            let trackHeight = baseTrackHeight + (engaging ? 2 : 0)
            let marker = max(8, baseTrackHeight + 4)
            let fill = width * progress

            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(engaging ? 0.27 : 0.18))
                    .frame(height: trackHeight)
                Capsule().fill(color.opacity(engaging ? 1 : 0.86))
                    .frame(width: fill, height: trackHeight)
                if let hoverFraction, !dragging, onPreviewChange != nil {
                    Capsule().fill(.primary.opacity(0.65))
                        .frame(width: 1.5, height: 9)
                        .offset(x: min(max(width - 1.5, 0), width * hoverFraction))
                        .allowsHitTesting(false)
                }
                Circle().fill(color)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: marker, height: marker)
                    .offset(x: min(max(width - marker, 0), max(0, fill - marker / 2)))
                    .opacity(engaging ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: effectiveHeight)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hovering = true
                    if let onPreviewChange, let position = position(point.x, width: width) {
                        hoverFraction = (position - range.lowerBound) / span
                        onPreviewChange(position)
                    }
                case .ended:
                    hovering = false
                    hoverFraction = nil
                    onPreviewChange?(nil)
                }
            }
            .highPriorityGesture(
                SpatialTapGesture().exclusively(before:
                    DragGesture(minimumDistance: 3)
                        .updating($trackingDrag) { _, tracking, _ in tracking = true }
                        .onChanged { gesture in
                            guard let target = position(gesture.location.x, width: width) else { return }
                            dragging = true
                            value = target
                            onDragChange?(target)
                        }
                )
                .onEnded { gesture in
                    let x: CGFloat
                    switch gesture {
                    case .first(let click): x = click.location.x
                    case .second(let drag): x = drag.location.x
                    }
                    defer { dragging = false }
                    guard let target = position(x, width: width) else { return }
                    commit(target)
                }
            )
            .onChange(of: trackingDrag) { _, tracking in
                if !tracking && dragging {
                    lastDragged = .distantPast
                    dragging = false
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: engaging)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(accessibilityText ?? (span > 0 ? ((value - range.lowerBound) / span).formatted(.percent.precision(.fractionLength(0))) : ""))
        .accessibilityAdjustableAction { direction in
            guard span.isFinite, span > 0 else { return }
            let step = span >= 10 ? min(5, span * 0.08) : span * 0.05
            let target: Double
            switch direction {
            case .increment: target = min(range.upperBound, value + step)
            case .decrement: target = max(range.lowerBound, value - step)
            @unknown default: return
            }
            commit(target)
        }
    }

    private func commit(_ target: Double) {
        value = target
        lastDragged = Date()
        onValueChange?(target)
    }

    private func position(_ x: CGFloat, width: CGFloat) -> Double? {
        MusicScrubPosition.at(x: x, width: width, range: range)
    }
}
