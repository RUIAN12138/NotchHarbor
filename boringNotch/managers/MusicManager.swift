//
//  MusicManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import AppKit
import Combine
import Defaults
import OSLog
import SwiftUI

let defaultImage: NSImage = .init(
    systemSymbolName: "music.note",
    accessibilityDescription: "Album Art"
)!

class MusicManager: ObservableObject {
    // MARK: - Properties
    static let shared = MusicManager()
    private var cancellables = Set<AnyCancellable>()
    private var controllerCancellables = Set<AnyCancellable>()
    private var debounceIdleTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var lyricsRequestID = UUID()
    private var lyricsTrackKey: String?
    private var lyricsAttemptAt = Date.distantPast
    private let lyricsLogger = Logger(subsystem: "app.notchharbor", category: "Lyrics")

    // Helper to check if macOS has removed support for NowPlayingController
    @Published public private(set) var isNowPlayingDeprecated: Bool = false
    private let mediaChecker = MediaChecker()

    // Active controller
    private var activeController: (any MediaControllerProtocol)?
    private var systemController: NowPlayingController?
    private var preferredController: (any MediaControllerProtocol)?
    private var systemState: PlaybackState?
    private var preferredState: PlaybackState?
    private var controllerGeneration = UUID()

    // Published properties for UI
    @Published var songTitle: String = "I'm Handsome"
    @Published var artistName: String = "Me"
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published private(set) var hasPanelMedia = false
    @Published private(set) var isSong = false
    @Published var album: String = "Self Love"
    @Published var isPlayerIdle: Bool = true
    @Published var animations: BoringAnimations = .init()
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String? = nil
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = .init()
    @Published var playbackRate: Double = 1
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.5
    @Published var volumeControlSupported: Bool = true
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Published var usingAppIconForArtwork: Bool = false
    @Published var currentLyrics: String = ""
    @Published var isFetchingLyrics: Bool = false
    private(set) var lyricsTimingRevision = 0
    @Published private(set) var lyricAdjustmentMilliseconds = 0
    @Published private(set) var syncedLyrics: [(time: Double, text: String)] = [] {
        didSet { lyricsTimingRevision &+= 1 }
    }
    private var sourceTimedLyrics: [(time: Double, text: String)] = [] {
        didSet { updateLyricPresentation() }
    }
    @Published var canFavoriteTrack: Bool = false
    @Published var isFavoriteTrack: Bool = false

    private var artworkData: Data? = nil

    // Store last values at the time artwork was changed
    private var lastArtworkTitle: String = "I'm Handsome"
    private var lastArtworkArtist: String = "Me"
    private var lastArtworkAlbum: String = "Self Love"
    private var lastArtworkBundleIdentifier: String? = nil

    @Published var isFlipping: Bool = false
    private var flipWorkItem: DispatchWorkItem?

    @Published var isTransitioning: Bool = false
    private var transitionWorkItem: DispatchWorkItem?

    // MARK: - Initialization
    init() {
        // Listen for changes to the default controller preference
        NotificationCenter.default.publisher(for: Notification.Name.mediaControllerChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setActiveControllerBasedOnPreference()
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableLyrics)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshLyrics() }
            }
            .store(in: &cancellables)

        // Initialize deprecation check asynchronously
        Task { @MainActor in
            do {
                self.isNowPlayingDeprecated = try await self.mediaChecker.checkDeprecationStatus()
                print("Deprecation check completed: \(self.isNowPlayingDeprecated)")
            } catch {
                print("Failed to check deprecation status: \(error). Defaulting to false.")
                self.isNowPlayingDeprecated = false
            }
            
            // Initialize the active controller after deprecation check
            self.setActiveControllerBasedOnPreference()
        }
    }

    deinit {
        destroy()
    }
    
    public func destroy() {
        debounceIdleTask?.cancel()
        lyricsTask?.cancel()
        cancellables.removeAll()
        controllerCancellables.removeAll()
        flipWorkItem?.cancel()
        transitionWorkItem?.cancel()

        // Release active controller
        activeController = nil
        preferredController = nil
        systemController = nil
    }

    // MARK: - Setup Methods
    @MainActor
    private func setActiveControllerBasedOnPreference() {
        controllerCancellables.removeAll()
        controllerGeneration = UUID()
        if !isNowPlayingDeprecated && systemController == nil {
            systemController = NowPlayingController()
        }
        let preference = Defaults[.mediaController]
        switch preference {
        case .nowPlaying:
            preferredController = systemController == nil ? AppleMusicController() : nil
        case .appleMusic: preferredController = AppleMusicController()
        case .spotify: preferredController = SpotifyController()
        case .youtubeMusic: preferredController = YouTubeMusicController()
        }

        preferredState = nil
        activeController = preferredController ?? systemController
        if let systemController { observe(systemController, system: true) }
        if let preferredController { observe(preferredController, system: false) }
        forceUpdate()
    }

    @MainActor
    private func observe(_ controller: any MediaControllerProtocol, system: Bool) {
        let generation = controllerGeneration
        controller.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, self.controllerGeneration == generation else { return }
                if system { self.systemState = state } else { self.preferredState = state }
                self.selectPlayback()
            }
            .store(in: &controllerCancellables)
    }

    @MainActor
    private func selectPlayback() {
        if let systemController, let systemState, PlaybackState.preferSystem(
            systemState, over: preferredState, previouslySystem: activeController === systemController
        ) {
            activeController = systemController
            updateFromPlaybackState(systemState)
        } else if let preferredController, let preferredState {
            activeController = preferredController
            updateFromPlaybackState(preferredState)
        }
    }

    // MARK: - Update Methods
    @MainActor
    private func updateFromPlaybackState(_ state: PlaybackState) {
        if hasPanelMedia != state.hasPanelMedia { hasPanelMedia = state.hasPanelMedia }
        let kindChanged = isSong != state.isSong
        if kindChanged { isSong = state.isSong }
        let canAdjustVolume = activeController?.supportsVolumeControl ?? false
        let canFavorite = state.isSong && (activeController?.supportsFavorite ?? false)
        if volumeControlSupported != canAdjustVolume { volumeControlSupported = canAdjustVolume }
        if canFavoriteTrack != canFavorite { canFavoriteTrack = canFavorite }

        // Check for playback state changes (playing/paused)
        if state.isPlaying != self.isPlaying {
            NSLog("Playback state changed: \(state.isPlaying ? "Playing" : "Paused")")
            withAnimation(.smooth) {
                self.isPlaying = state.isPlaying
                self.updateIdleState(state: state.isPlaying)
            }

            if state.isPlaying && state.hasMedia {
            }
        }

        // Check for changes in track metadata using last artwork change values
        let titleChanged = state.title != self.lastArtworkTitle
        let artistChanged = state.artist != self.lastArtworkArtist
        let albumChanged = state.album != self.lastArtworkAlbum
        let bundleChanged = state.bundleIdentifier != self.lastArtworkBundleIdentifier

        // Check for artwork changes
        let artworkChanged = state.artwork != self.artworkData
        let hasContentChange = titleChanged || artistChanged || albumChanged || artworkChanged || bundleChanged

        // Handle artwork and visual transitions for changed content
        if hasContentChange {
            self.triggerFlipAnimation()

            if artworkChanged, let artwork = state.artwork {
                self.updateArtwork(artwork)
            } else if state.artwork == nil {
                // Try to use app icon if no artwork but track changed
                self.usingAppIconForArtwork = true
                self.updateAlbumArt(newAlbumArt: AppIconAsNSImage(for: state.bundleIdentifier) ?? defaultImage)
            }
            self.artworkData = state.artwork

            self.lastArtworkTitle = state.title
            self.lastArtworkArtist = state.artist
            self.lastArtworkAlbum = state.album
            self.lastArtworkBundleIdentifier = state.bundleIdentifier

            // Only update sneak peek if there's actual content and something changed
            if state.isPlaying && state.hasMedia {
            }

        }

        let timeChanged = state.currentTime != self.elapsedTime
        let durationChanged = state.duration != self.songDuration
        let playbackRateChanged = state.playbackRate != self.playbackRate
        let shuffleChanged = state.isShuffled != self.isShuffled
        let repeatModeChanged = state.repeatMode != self.repeatMode
        let volumeChanged = state.volume != self.volume
        
        if state.title != self.songTitle {
            self.songTitle = state.title
        }

        if state.artist != self.artistName {
            self.artistName = state.artist
        }

        if state.album != self.album {
            self.album = state.album
        }

        if timeChanged {
            self.elapsedTime = state.currentTime
        }

        if durationChanged {
            self.songDuration = state.duration
        }

        if playbackRateChanged {
            self.playbackRate = state.playbackRate
        }
        
        if shuffleChanged {
            self.isShuffled = state.isShuffled
        }

        if state.bundleIdentifier != self.bundleIdentifier {
            self.bundleIdentifier = state.bundleIdentifier
        }

        if repeatModeChanged {
            self.repeatMode = state.repeatMode
        }
        if state.isFavorite != self.isFavoriteTrack {
            self.isFavoriteTrack = state.isFavorite
        }
        
        if volumeChanged {
            self.volume = state.volume
        }
        
        self.timestampDate = state.lastUpdated
        if kindChanged || titleChanged || artistChanged || albumChanged || bundleChanged || (durationChanged && state.duration > 0 && currentLyrics.isEmpty) {
            fetchLyricsIfAvailable(bundleIdentifier: state.bundleIdentifier, title: state.title,
                                  artist: state.artist, album: state.album, duration: state.duration)
        }
    }

    func toggleFavoriteTrack() {
        guard canFavoriteTrack else { return }
        // Toggle based on current state
        setFavorite(!isFavoriteTrack)
    }

    @MainActor
    private func toggleAppleMusicFavorite() async {
        let script = """
        tell application \"Music\"
            if it is running then
                try
                    set loved of current track to (not loved of current track)
                    return loved of current track
                on error
                    return false
                end try
            else
                return false
            end if
        end tell
        """

        if let result = try? await AppleScriptHelper.execute(script) {
            let loved = result.booleanValue
            self.isFavoriteTrack = loved
            self.forceUpdate()
        }
    }

    func setFavorite(_ favorite: Bool) {
        guard canFavoriteTrack else { return }
        guard let controller = activeController else { return }

        Task { @MainActor in
            await controller.setFavorite(favorite)
            try? await Task.sleep(for: .milliseconds(150))
            await controller.updatePlaybackInfo()
        }
    }

    /// Placeholder dislike function
    func dislikeCurrentTrack() {
        setFavorite(false)
    }

    // MARK: - Lyrics
    @MainActor
    func refreshLyrics() {
        guard Defaults[.enableLyrics] else { resetLyrics(); return }
        guard isPlaying || (songDuration.isFinite && songDuration > 0)
                || !(bundleIdentifier ?? "").isEmpty else { return }
        fetchLyricsIfAvailable(bundleIdentifier: bundleIdentifier, title: songTitle,
                              artist: artistName, album: album, duration: songDuration)
    }

    @MainActor
    private func resetLyrics() {
        lyricsTask?.cancel()
        lyricsRequestID = UUID()
        lyricsTrackKey = nil
        currentLyrics = ""
        lyricAdjustmentMilliseconds = 0
        sourceTimedLyrics = []
        isFetchingLyrics = false
    }

    @MainActor
    private func fetchLyricsIfAvailable(bundleIdentifier: String?, title: String, artist: String, album: String,
                                        duration: TimeInterval, retry: Bool = false) {
        let seconds = duration.isFinite ? min(864_000, max(0, duration)) : 0
        let key = [bundleIdentifier ?? "", title, artist, album, String(Int(seconds))].joined(separator: "\u{1F}")
        guard Defaults[.enableLyrics], isSong, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            resetLyrics()
            return
        }
        if key == lyricsTrackKey && (isFetchingLyrics || !syncedLyrics.isEmpty || (!retry && Date().timeIntervalSince(lyricsAttemptAt) < 30)) { return }
        lyricsTask?.cancel()
        let requestID = UUID()
        lyricsRequestID = requestID
        lyricsTrackKey = key
        lyricAdjustmentMilliseconds = MusicLyricCalibration.load(trackKey: key)
        lyricsAttemptAt = Date()
        isFetchingLyrics = true
        currentLyrics = ""
        sourceTimedLyrics = []
        lyricsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if bundleIdentifier?.contains("com.apple.Music") == true {
                do {
                    let script = """
                    tell application \"Music\"
                        if it is running then
                            if player state is playing or player state is paused then
                                try
                                    set l to lyrics of current track
                                    if l is missing value then
                                        return \"\"
                                    else
                                        return l
                                    end if
                                on error
                                    return \"\"
                                end try
                            else
                                return \"\"
                            end if
                        else
                            return \"\"
                        end if
                    end tell
                    """
                    if let result = try await AppleScriptHelper.execute(script),
                       let lyrics = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !lyrics.isEmpty {
                        guard self.lyricsRequestID == requestID, !Task.isCancelled else { return }
                        let timed = self.parseLRC(lyrics)
                        self.currentLyrics = MusicLyricText.simplified(lyrics)
                        self.sourceTimedLyrics = timed
                        if !timed.isEmpty {
                            self.isFetchingLyrics = false
                            return
                        }
                    }
                } catch { /* Continue to the existing public lyrics source. */ }
            }
            guard self.lyricsRequestID == requestID, !Task.isCancelled else { return }
            if bundleIdentifier?.lowercased().contains("netease") == true,
               let lrc = await self.fetchNetEaseLyrics(title: title, artist: artist, album: album, duration: duration) {
                guard self.lyricsRequestID == requestID, !Task.isCancelled else { return }
                self.sourceTimedLyrics = self.parseLRC(lrc)
                if !self.syncedLyrics.isEmpty {
                    self.isFetchingLyrics = false
                    self.lyricsLogger.info("Loaded \(self.syncedLyrics.count, privacy: .public) timed lines from NetEase")
                    return
                }
            }
            guard self.lyricsRequestID == requestID, !Task.isCancelled else { return }
            await self.fetchLyricsFromWeb(title: title, artist: artist, duration: duration, requestID: requestID)
            guard !retry, self.lyricsRequestID == requestID, self.syncedLyrics.isEmpty else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self.lyricsRequestID == requestID, self.syncedLyrics.isEmpty, self.isPlaying else {
                return
            }
            self.fetchLyricsIfAvailable(bundleIdentifier: bundleIdentifier, title: title, artist: artist,
                                       album: album, duration: duration, retry: true)
        }
    }

    private func fetchNetEaseLyrics(title: String, artist: String, album: String, duration: Double) async -> String? {
        guard !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        func get(_ path: String, _ query: [URLQueryItem]) async throws -> [String: Any] {
            var address = URLComponents()
            address.scheme = "https"
            address.host = "music.163.com"
            address.path = path
            address.queryItems = query
            guard let url = address.url else { throw URLError(.badURL) }
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count <= 2_000_000,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.badServerResponse)
            }
            return json
        }
        let queries = [
            (path: "/api/search/get", term: title + " " + artist),
            (path: "/api/cloudsearch/pc", term: title)
        ]
        var attempted = Set<Int>()
        for query in queries {
            guard !Task.isCancelled else { return nil }
            let result = try? await get(query.path, [
                .init(name: "s", value: query.term), .init(name: "type", value: "1"),
                .init(name: "limit", value: "12")
            ])
            let songs = (result?["result"] as? [String: Any])?["songs"] as? [[String: Any]] ?? []
            let ids = LyricsRecordSelection.netEaseIDs(songs, title: title, artist: artist, album: album, duration: duration)
            for id in ids.prefix(3) where attempted.insert(id).inserted {
                guard !Task.isCancelled else { return nil }
                guard let lyric = try? await get("/api/song/lyric", [
                    .init(name: "id", value: String(id)), .init(name: "lv", value: "1")
                ]), let lrc = (lyric["lrc"] as? [String: Any])?["lyric"] as? String,
                      MusicLyricText.parse(lrc).contains(where: { !$0.text.isEmpty }) else { continue }
                return lrc
            }
        }
        return nil
    }

    @MainActor
    private func fetchLyricsFromWeb(title: String, artist: String, duration: TimeInterval, requestID: UUID) async {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        guard let url = components.url else {
            if lyricsRequestID == requestID { isFetchingLyrics = false }
            return
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard lyricsRequestID == requestID, !Task.isCancelled else { return }
            defer { isFetchingLyrics = false }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count <= 2_000_000,
                  let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let record = LyricsRecordSelection.best(records, title: title, artist: artist, duration: duration) else { return }
            let plain = (record["plainLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let synced = (record["syncedLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let timed = parseLRC(synced)
            if !timed.isEmpty { lyricsLogger.info("Loaded \(timed.count, privacy: .public) timed lines from LRCLIB") }
            if !timed.isEmpty || currentLyrics.isEmpty {
                currentLyrics = MusicLyricText.simplified(plain.isEmpty ? synced : plain)
            }
            sourceTimedLyrics = timed
        } catch {
            guard lyricsRequestID == requestID, !Task.isCancelled else { return }
            isFetchingLyrics = false
        }
    }

    // MARK: - Synced lyrics helpers
    var lyricTimingTrackKey: String? { lyricsTrackKey }

    @MainActor
    func adjustLyricTiming(to milliseconds: Int, for trackKey: String?) {
        guard let trackKey, trackKey == lyricsTrackKey, !sourceTimedLyrics.isEmpty else { return }
        let value = MusicLyricCalibration.clamp(milliseconds)
        guard lyricAdjustmentMilliseconds != value else { return }
        lyricAdjustmentMilliseconds = value
        MusicLyricCalibration.save(value, trackKey: trackKey)
        updateLyricPresentation()
    }

    private func updateLyricPresentation() {
        syncedLyrics = MusicLyricCalibration.adjusted(sourceTimedLyrics, by: lyricAdjustmentMilliseconds)
    }

    func seek(toLyric timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        seek(to: songDuration.isFinite && songDuration > 0 ? min(timestamp, songDuration) : timestamp)
    }

    private func parseLRC(_ lrc: String) -> [(time: Double, text: String)] {
        MusicLyricText.parse(lrc)
    }

    func lyricLine(at elapsed: Double) -> String {
        MusicLyricTimeline.frame(lines: syncedLyrics, plain: currentLyrics, elapsed: elapsed).current
    }

    private func triggerFlipAnimation() {
        // Cancel any existing animation
        flipWorkItem?.cancel()

        // Create a new animation
        let workItem = DispatchWorkItem { [weak self] in
            self?.isFlipping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.isFlipping = false
            }
        }

        flipWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func updateArtwork(_ artworkData: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if let artworkImage = NSImage(data: artworkData) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.artworkData == artworkData else { return }
                    self.usingAppIconForArtwork = false
                    self.updateAlbumArt(newAlbumArt: artworkImage)
                }
            }
        }
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                withAnimation {
                    self.isPlayerIdle = !self.isPlaying
                }
            }
        }
    }

    private var workItem: DispatchWorkItem?

    func updateAlbumArt(newAlbumArt: NSImage) {
        workItem?.cancel()
        withAnimation(.smooth) {
            self.albumArt = newAlbumArt
            self.calculateAverageColor()
        }
    }

    // MARK: - Playback Position Estimation
    public func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        PlaybackPositionClock.position(elapsed: elapsedTime, anchor: timestampDate,
                                       rate: playbackRate, playing: isPlaying,
                                       duration: songDuration, now: date)
    }

    func calculateAverageColor() {
        let artwork = albumArt
        artwork.averageColor { [weak self] color in
            DispatchQueue.main.async {
                guard let self, self.albumArt === artwork else { return }
                withAnimation(.smooth) {
                    self.avgColor = color ?? .white
                }
            }
        }
    }

    // MARK: - Public Methods for controlling playback
    func playPause() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func play() {
        Task {
            await activeController?.play()
        }
    }

    func pause() {
        Task {
            await activeController?.pause()
        }
    }

    func toggleShuffle() {
        Task {
            await activeController?.toggleShuffle()
        }
    }

    func toggleRepeat() {
        Task {
            await activeController?.toggleRepeat()
        }
    }
    
    func togglePlay() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func nextTrack() {
        Task {
            await activeController?.nextTrack()
        }
    }

    func previousTrack() {
        Task {
            await activeController?.previousTrack()
        }
    }

    func seek(to position: TimeInterval) {
        Task {
            await activeController?.seek(to: position)
        }
    }
    func skip(seconds: TimeInterval) {
        let newPos = min(max(0, estimatedPlaybackPosition() + seconds), songDuration)
        seek(to: newPos)
    }
    
    func setVolume(to level: Double) {
        if let controller = activeController {
            Task {
                await controller.setVolume(level)
            }
        }
    }
    func openMusicApp() {
        guard let bundleID = bundleIdentifier else {
            print("Error: appBundleIdentifier is nil")
            return
        }

        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: appURL, configuration: configuration) { (app, error) in
                if let error = error {
                    print("Failed to launch app with bundle ID: \(bundleID), error: \(error)")
                } else {
                    print("Launched app with bundle ID: \(bundleID)")
                }
            }
        } else {
            print("Failed to find app with bundle ID: \(bundleID)")
        }
    }

    func forceUpdate() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            async let systemRefresh: Void? = systemController?.updatePlaybackInfo()
            if let controller = preferredController, controller.isActive() {
                if let youtubeController = controller as? YouTubeMusicController {
                    await youtubeController.pollPlaybackState()
                } else {
                    await controller.updatePlaybackInfo()
                }
            }
            _ = await systemRefresh
            await self.syncVolumeFromActiveApp()
        }
    }
    
    
    func syncVolumeFromActiveApp() async {
        guard let bundleID = bundleIdentifier, !bundleID.isEmpty else { return }
        
        var script: String?
        if bundleID == "com.apple.Music" {
            script = "tell application \"Music\" to get sound volume"
        } else if bundleID == "com.spotify.client" {
            script = "tell application \"Spotify\" to get sound volume"
        } else {
            // For unsupported apps, don't sync volume
            return
        }
        
        if let volumeScript = script,
           let result = try? await AppleScriptHelper.execute(volumeScript) {
            let volumeValue = result.int32Value
            let currentVolume = Double(volumeValue) / 100.0
            
            await MainActor.run {
                if abs(currentVolume - self.volume) > 0.01 {
                    self.volume = currentVolume
                }
            }
        }
    }
}


/// Convert Han variants once on receipt; foreign words are not translated.
enum MusicLyricText {
    static func simplified(_ text: String) -> String {
        text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
    }

    static func parse(_ source: String) -> [(time: Double, text: String)] {
        guard let stamp = try? NSRegularExpression(pattern: #"\[(\d{1,3}):([0-5]\d)(?:\.(\d{1,3}))?\]"#),
              let offset = try? NSRegularExpression(pattern: #"(?i)\[offset:\s*([+-]?\d+)\s*\]"#) else { return [] }
        let raw = source as NSString
        let shift = offset.matches(in: source, range: NSRange(location: 0, length: raw.length)).last
            .flatMap { Double(raw.substring(with: $0.range(at: 1))) }.map { $0 / 1000 } ?? 0
        var result: [(time: Double, text: String, order: Int)] = []
        for line in source.components(separatedBy: .newlines) {
            let ns = line as NSString
            let matches = stamp.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = simplified(ns.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces))
            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
                let range = match.range(at: 3)
                let fraction = range.location == NSNotFound ? 0 : (Double(ns.substring(with: range)) ?? 0) / pow(10, Double(range.length))
                let time = minutes * 60 + seconds + fraction + shift
                if time.isFinite { result.append((max(0, time), text, result.count)) }
            }
        }
        return result.sorted { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
            .map { (time: $0.time, text: $0.text) }
    }
}

/// Match recording metadata before displaying lyrics; search order is not identity.
enum LyricsRecordSelection {
    static func normalized(_ text: String) -> String {
        String(String.UnicodeScalarView(MusicLyricText.simplified(text).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }
    static func best(_ records: [[String: Any]], title: String, artist: String, duration: TimeInterval) -> [String: Any]? {
        let titleKey = normalized(title), artistKey = normalized(artist)
        guard !titleKey.isEmpty else { return nil }
        let knownDuration = duration.isFinite && duration > 0
        var candidates: [(record: [String: Any], score: Double, timed: Bool)] = []
        for record in records.prefix(100) {
            guard let name = record["trackName"] as? String, normalized(name) == titleKey else { continue }
            let candidateArtist = normalized(record["artistName"] as? String ?? "")
            guard artistKey.isEmpty || candidateArtist == artistKey ||
                (candidateArtist.count >= 2 && artistKey.contains(candidateArtist)) ||
                (artistKey.count >= 2 && candidateArtist.contains(artistKey)) else { continue }
            let seconds = (record["duration"] as? NSNumber)?.doubleValue
            if knownDuration {
                guard let seconds, seconds.isFinite, abs(seconds-duration) <= max(5, duration * 0.025) else { continue }
            }
            let plain = record["plainLyrics"] as? String ?? ""
            let synced = record["syncedLyrics"] as? String ?? ""
            let visible = (plain + "\n" + synced).replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            guard visible.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { continue }
            let delta = knownDuration ? abs((seconds ?? duration) - duration) : 0
            candidates.append((record, delta, MusicLyricText.parse(synced).contains { !$0.text.isEmpty }))
        }
        return candidates.min {
            $0.timed != $1.timed ? $0.timed : $0.score < $1.score
        }?.record
    }

    static func netEaseIDs(_ songs: [[String: Any]], title: String, artist: String, album: String, duration: Double) -> [Int] {
        let titleKey = normalized(title), artistKey = normalized(artist)
        guard !titleKey.isEmpty, !artistKey.isEmpty else { return [] }
        let albumKey = normalized(album)
        let knownDuration = duration.isFinite && duration > 0
        let matching = songs.prefix(12).enumerated().compactMap { index, song -> (id: Int, delta: Double, milliseconds: Double, albumMatch: Bool, index: Int)? in
            guard let id = song["id"] as? Int, id > 0,
                  let name = song["name"] as? String, normalized(name) == titleKey,
                  let artists = (song["artists"] ?? song["ar"]) as? [[String: Any]],
                  let milliseconds = ((song["duration"] ?? song["dt"]) as? NSNumber)?.doubleValue,
                  milliseconds.isFinite, milliseconds > 0 else { return nil }
            let delta = knownDuration ? abs(milliseconds / 1000 - duration) : 0
            guard !knownDuration || delta <= max(5, duration * 0.025) else { return nil }
            let albumName = ((song["album"] ?? song["al"]) as? [String: Any])?["name"] as? String ?? ""
            let albumMatch = !albumKey.isEmpty && normalized(albumName) == albumKey
            let credits = artists.compactMap { ($0["name"] as? String).map(normalized) }.filter { !$0.isEmpty }
            guard credits.joined() == artistKey || (knownDuration && delta <= 1 && albumMatch && credits.contains(artistKey)) else {
                return nil
            }
            return (id, delta, milliseconds, albumMatch, index)
        }
        let preferred = matching.filter(\.albumMatch)
        let ordered = (preferred.isEmpty ? matching : preferred).sorted {
            $0.delta == $1.delta ? $0.index < $1.index : $0.delta < $1.delta
        }
        guard let first = ordered.first else { return [] }
        guard knownDuration else { return ordered.count == 1 ? [first.id] : [] }
        // Reissues can have distinct IDs for the same exact recorded length.
        // A different, nearly tied length remains ambiguous.
        let duplicates = ordered.filter { $0.milliseconds == first.milliseconds }
        if let alternative = ordered.first(where: { $0.milliseconds != first.milliseconds }),
           alternative.delta - first.delta <= 0.2 { return [] }
        var seen = Set<Int>()
        let ranked = duplicates + matching.filter { $0.milliseconds == first.milliseconds && !$0.albumMatch }
        return ranked.map(\.id).filter { seen.insert($0).inserted }
    }
}


/// A presentation of real timestamped lines, including pre-roll and backwards seeking.
enum MusicLyricTimeline {
    struct Frame: Equatable {
        let current: String
        let next: String?
        let index: Int?
        let isPrelude: Bool
    }

    static func frame(lines: [(time: Double, text: String)], plain: String, elapsed: Double) -> Frame {
        guard !lines.isEmpty else {
            let text = plain.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .prefix(2).joined(separator: "\n")
            return Frame(current: text, next: nil, index: nil, isPrelude: false)
        }
        let time = elapsed.isFinite ? max(0, elapsed) : 0
        // parseLRC provides sorted timestamps; upper-bound selects the last
        // line at duplicate timestamps without a linear scan on every frame.
        var low = 0, high = lines.count
        while low < high {
            let mid = low + (high - low) / 2
            if lines[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else {
            return Frame(current: "", next: lines.first?.text, index: nil, isPrelude: true)
        }
        let index = low - 1
        return Frame(current: lines[index].text,
                     next: lines.indices.contains(index + 1) ? lines[index + 1].text : nil,
                     index: index, isPrelude: false)
    }
}

enum MusicLyricCalibration {
    static let step = 250
    static let limit = 5000
    private static let storageKey = "musicLyricCalibration"
    private static let maximumRecords = 200

    static func clamp(_ milliseconds: Int) -> Int {
        min(limit, max(-limit, milliseconds))
    }

    static func adjusted(_ lines: [(time: Double, text: String)], by milliseconds: Int) -> [(time: Double, text: String)] {
        guard milliseconds != 0 else { return lines }
        let shift = Double(clamp(milliseconds)) / 1000
        return lines.map { (max(0, $0.time + shift), $0.text) }
    }

    static func load(trackKey: String, defaults: UserDefaults = .standard) -> Int {
        let records = defaults.array(forKey: storageKey) as? [[String: Any]] ?? []
        return clamp(records.first { $0["track"] as? String == trackKey }?["ms"] as? Int ?? 0)
    }

    static func save(_ milliseconds: Int, trackKey: String, defaults: UserDefaults = .standard) {
        var records = defaults.array(forKey: storageKey) as? [[String: Any]] ?? []
        records.removeAll { $0["track"] as? String == trackKey }
        if milliseconds != 0 {
            records.insert(["track": trackKey, "ms": clamp(milliseconds)], at: 0)
        }
        defaults.set(Array(records.prefix(maximumRecords)), forKey: storageKey)
    }
}
