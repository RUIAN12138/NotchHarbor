//
//  NowPlayingController.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import AppKit
import Combine
import Foundation

final class NowPlayingController: ObservableObject, MediaControllerProtocol {
    // Stub for now to conform with ControllerProtocol
    func updatePlaybackInfo() async {}

    // MARK: - Properties
    @Published private(set) var playbackState = PlaybackState(bundleIdentifier: "", title: "", artist: "", album: "")

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music" || bundleID == "com.spotify.client"
    }

    var supportsFavorite: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music"
    }

    func setFavorite(_ favorite: Bool) async {
        let bundleID = playbackState.bundleIdentifier
        
        if bundleID == "com.apple.Music" {
            let script = """
            tell application "Music"
                try
                    set favorited of current track to \(favorite ? "true" : "false")
                end try
            end tell
            """
            try? await AppleScriptHelper.executeVoid(script)
        }
        
        // Update the favorite state locally and fetch updated info
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }

    private var lastMusicItem:
        (title: String, artist: String, album: String, duration: TimeInterval, artworkData: Data?)?

    // The bundled adapter reads and controls the same system media session.
    private let adapterScript: URL
    private let adapterFramework: String

    private var process: Process?
    private var pipeHandler: JSONLinesPipeHandler?
    private var streamTask: Task<Void, Never>?

    // MARK: - Initialization
    init?() {
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworks = Bundle.main.privateFrameworksPath else { return nil }
        adapterScript = script
        adapterFramework = frameworks.appending("/MediaRemoteAdapter.framework")
        Task { [weak self] in await self?.setupNowPlayingObserver() }
    }

    deinit {
        streamTask?.cancel()
        
        if let pipeHandler = self.pipeHandler {
            Task { await pipeHandler.close()
            }
        }
        
        if let process = self.process {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        self.process = nil
        self.pipeHandler = nil
    }

    // MARK: - Protocol Implementation
    func play() async { await command("send", "0") }
    func pause() async { await command("send", "1") }
    func togglePlay() async { await command("send", "2") }
    func nextTrack() async { await command("send", "4") }
    func previousTrack() async { await command("send", "5") }

    func seek(to time: Double) async {
        guard time.isFinite, time >= 0, time <= Double(Int64.max / 1_000_000) else { return }
        await command("seek", String(Int64((time * 1_000_000).rounded())))
    }

    func isActive() -> Bool { true }

    func toggleShuffle() async {
        await command("shuffle", playbackState.isShuffled ? "1" : "3")
    }

    func toggleRepeat() async {
        let mode = playbackState.repeatMode == .off ? 3 : playbackState.repeatMode.rawValue - 1
        await command("repeat", String(mode))
    }

    private func command(_ function: String, _ argument: String) async {
        let process = adapterProcess(function, argument)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in done.resume() }
            do { try process.run() }
            catch { done.resume() }
        }
    }

    private func adapterProcess(_ arguments: String...) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [adapterScript.path, adapterFramework] + arguments
        return process
    }

    func setVolume(_ level: Double) async {
        // MediaRemote framework doesn't provide direct volume control for the active audio session
        // As a workaround, try to control the currently active music app directly
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        
        let bundleID = playbackState.bundleIdentifier
        if !bundleID.isEmpty {
            if bundleID == "com.apple.Music" {
                let script = "tell application \"Music\" to set sound volume to \(volumePercentage)"
                try? await AppleScriptHelper.executeVoid(script)
            } else if bundleID == "com.spotify.client" {
                let script = "tell application \"Spotify\" to set sound volume to \(volumePercentage)"
                try? await AppleScriptHelper.executeVoid(script)
            }
        }
        
        playbackState.volume = clampedLevel
    }
    
    // MARK: - Setup Methods
    private func setupNowPlayingObserver() async {
        let process = adapterProcess("stream")
        let pipeHandler = JSONLinesPipeHandler()
        process.standardOutput = await pipeHandler.getPipe()
        
        self.process = process
        self.pipeHandler = pipeHandler

        do {
            try process.run()
            streamTask = Task { [weak self] in
                await pipeHandler.readJSONLines(as: NowPlayingUpdate.self) { [weak self] update in
                    await self?.handleAdapterUpdate(update)
                }
            }
        } catch {
            assertionFailure("Failed to launch mediaremote-adapter.pl: \(error)")
        }
    }

    // MARK: - Update Methods
    private func handleAdapterUpdate(_ update: NowPlayingUpdate) async {
        let payload = update.payload
        let diff = update.diff ?? false

        let incomingBundle = payload.parentApplicationBundleIdentifier ?? payload.bundleIdentifier
        let sourceChanged = incomingBundle.map { $0 != playbackState.bundleIdentifier } == true
        let canInherit = diff && !sourceChanged
        var newPlaybackState = PlaybackState(bundleIdentifier: incomingBundle ?? (diff ? playbackState.bundleIdentifier : ""))
        newPlaybackState.title = payload.title ?? (canInherit ? playbackState.title : "")
        newPlaybackState.artist = payload.artist ?? (canInherit ? playbackState.artist : "")
        newPlaybackState.album = payload.album ?? (canInherit ? playbackState.album : "")
        newPlaybackState.duration = payload.duration ?? (canInherit ? playbackState.duration : 0)
        newPlaybackState.mediaType = payload.mediaType ?? (canInherit ? playbackState.mediaType : nil)
        newPlaybackState.isMusicApp = payload.isMusicApp ?? (canInherit ? playbackState.isMusicApp : nil)
        let trackChanged = newPlaybackState.title != playbackState.title
            || newPlaybackState.artist != playbackState.artist || sourceChanged
        if let shuffleMode = payload.shuffleMode {
            newPlaybackState.isShuffled = shuffleMode != 1
        } else if !canInherit {
            newPlaybackState.isShuffled = false
        } else {
            newPlaybackState.isShuffled = self.playbackState.isShuffled
        }
        if let repeatModeValue = payload.repeatMode {
            newPlaybackState.repeatMode = RepeatMode(rawValue: repeatModeValue) ?? .off
        } else if !canInherit {
            newPlaybackState.repeatMode = .off
        } else {
            newPlaybackState.repeatMode = self.playbackState.repeatMode
        }

        if let artworkDataString = payload.artworkData {
            newPlaybackState.artwork = Data(
                base64Encoded: artworkDataString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else if diff && !trackChanged {
            newPlaybackState.artwork = playbackState.artwork
        }

        newPlaybackState.isPlaying = payload.playing ?? (diff ? playbackState.isPlaying : false)
        let resumed = newPlaybackState.isPlaying && !playbackState.isPlaying
        let fallbackRate = newPlaybackState.isPlaying ? (playbackState.playbackRate > 0 ? playbackState.playbackRate : 1) : 0
        let reportedRate = payload.playbackRate ?? (diff && !resumed && payload.playing == nil ? playbackState.playbackRate : fallbackRate)
        newPlaybackState.playbackRate = newPlaybackState.isPlaying && (!reportedRate.isFinite || reportedRate <= 0)
            ? fallbackRate : reportedRate
        let timing = PlaybackPositionClock.merge(
            previous: playbackState, elapsed: payload.elapsedTime,
            stamp: PlaybackPositionClock.timestamp(payload.timestamp), now: Date(),
            sameTrack: !trackChanged, playing: newPlaybackState.isPlaying,
            rate: newPlaybackState.playbackRate
        )
        newPlaybackState.currentTime = timing.elapsed
        newPlaybackState.lastUpdated = timing.anchor
        newPlaybackState.volume = payload.volume ?? (canInherit ? playbackState.volume : 0.5)
        
        self.playbackState = newPlaybackState
        
        // Fetch favorite state for supported apps asynchronously
        await fetchFavoriteStateIfSupported()
    }
    
    private func fetchFavoriteStateIfSupported() async {
        let bundleID = playbackState.bundleIdentifier
        
        if bundleID == "com.apple.Music" {
            let script = """
            tell application "Music"
                try
                    return favorited of current track
                on error
                    return false
                end try
            end tell
            """
            if let result = try? await AppleScriptHelper.execute(script) {
                var updated = self.playbackState
                updated.isFavorite = result.booleanValue
                self.playbackState = updated
            }
        }
    }
    
}

struct NowPlayingUpdate: Codable {
    let payload: NowPlayingPayload
    let diff: Bool?
}

struct NowPlayingPayload: Codable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let shuffleMode: Int?
    let repeatMode: Int?
    let artworkData: String?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let mediaType: String?
    let isMusicApp: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
    let volume: Double?
}

actor JSONLinesPipeHandler {
    private let pipe: Pipe
    private let fileHandle: FileHandle
    private var buffer = ""
    
    init() {
        self.pipe = Pipe()
        self.fileHandle = pipe.fileHandleForReading
    }
    
    func getPipe() -> Pipe {
        return pipe
    }
    
    func readJSONLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async {
        do {
            try await self.processLines(as: type) { decodedObject in
                await onLine(decodedObject)
            }
        } catch {
            print("Error processing JSON stream: \(error)")
        }
    }
    
    private func processLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async throws {
        while true {
            let data = try await readData()
            guard !data.isEmpty else { break }
            
            if let chunk = String(data: data, encoding: .utf8) {
                buffer.append(chunk)
                
                while let range = buffer.range(of: "\n") {
                    let line = String(buffer[..<range.lowerBound])
                    buffer = String(buffer[range.upperBound...])
                    
                    if !line.isEmpty {
                        await processJSONLine(line, as: type, onLine: onLine)
                    }
                }
            }
        }
    }
    
    private func processJSONLine<T: Decodable>(_ line: String, as type: T.Type, onLine: @escaping (T) async -> Void) async {
        guard let data = line.data(using: .utf8) else {
            return
        }
        do {
            let decodedObject = try JSONDecoder().decode(T.self, from: data)
            await onLine(decodedObject)
        } catch {
            // Ignore lines that can't be decoded
        }
    }
    
    private func readData() async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                handle.readabilityHandler = nil
                continuation.resume(returning: data)
            }
        }
    }
    
    func close() async {
        do {
            fileHandle.readabilityHandler = nil
            try fileHandle.close()
            try pipe.fileHandleForWriting.close()
        } catch {
            print("Error closing pipe handler: \(error)")
        }
    }
}
