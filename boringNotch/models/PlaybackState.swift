//
//  PlaybackState.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation

enum RepeatMode: Int, Codable {
    case off = 1
    case one = 2
    case all = 3
}

struct PlaybackState {
    var bundleIdentifier: String
    var isPlaying: Bool = false
    var title: String = "I'm Handsome"
    var artist: String = "Me"
    var album: String = "Self Love"
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Double = 1
    var isShuffled: Bool = false
    var repeatMode: RepeatMode = .off
    var lastUpdated: Date = Date.distantPast
    var artwork: Data?
    var volume: Double = 0.5
    var isFavorite: Bool = false
    var mediaType: String? = nil
    var isMusicApp: Bool? = nil

    var isSong: Bool {
        let kind = mediaType?.lowercased() ?? ""
        if kind.contains("video") || kind.contains("movie") || kind.contains("podcast") { return false }
        if kind.contains("music") || isMusicApp == true { return true }
        let bundle = bundleIdentifier.lowercased()
        return ["com.apple.music", "com.spotify.client", "com.netease.163music",
                "com.github.th-ch.youtube-music", "com.tencent.qqmusicmac"].contains(bundle)
    }

    var hasMedia: Bool {
        isPlaying || (!title.isEmpty && title != "I'm Handsome"
            && !(title == "Not Playing" && artist == "Unknown"))
    }

    /// A real paused track stays visible. Some controllers publish placeholder
    /// metadata when their player opens before loading any media.
    var hasPanelMedia: Bool {
        if isPlaying || (duration.isFinite && duration > 0) { return true }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, hasMedia else { return false }
        return !(name == "Unknown" && artist == "Unknown" && album == "Unknown")
    }

    /// Honor the chosen integration for its own track. Playback reported from
    /// another system source should still be visible and receive the controls.
    static func preferSystem(_ system: Self, over preferred: Self?, previouslySystem: Bool) -> Bool {
        guard let preferred else { return true }
        if system.isPlaying {
            return !preferred.isPlaying || system.bundleIdentifier != preferred.bundleIdentifier
        }
        if preferred.isPlaying { return false }
        return system.hasMedia && (previouslySystem || !preferred.hasMedia)
    }
}

extension PlaybackState: Equatable {
    static func == (lhs: PlaybackState, rhs: PlaybackState) -> Bool {
        return lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.isPlaying == rhs.isPlaying
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.currentTime == rhs.currentTime
            && lhs.playbackRate == rhs.playbackRate
            && lhs.lastUpdated == rhs.lastUpdated
            && lhs.volume == rhs.volume
            && lhs.duration == rhs.duration
            && lhs.isShuffled == rhs.isShuffled
            && lhs.repeatMode == rhs.repeatMode
            && lhs.artwork == rhs.artwork
            && lhs.isFavorite == rhs.isFavorite
            && lhs.mediaType == rhs.mediaType
            && lhs.isMusicApp == rhs.isMusicApp
    }
}

/// The media timestamp is an anchor, not a timer that resets on metadata updates.
enum PlaybackPositionClock {
    static func timestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    /// Elapsed time and media timestamp are one sample. A standalone
    /// timestamp must not move the read head or rewind it on pause/resume.
    static func merge(previous: PlaybackState, elapsed: Double?, stamp: Date?,
                      now: Date, sameTrack: Bool, playing: Bool, rate: Double)
        -> (elapsed: Double, anchor: Date) {
        if let elapsed, elapsed.isFinite, elapsed >= 0 {
            let observed = stamp.map { min($0, now) } ?? now
            if !sameTrack || observed >= previous.lastUpdated {
                return (elapsed, observed)
            }
        }
        guard sameTrack else { return (0, now) }
        if previous.isPlaying != playing || previous.playbackRate != rate {
            return (position(elapsed: previous.currentTime, anchor: previous.lastUpdated,
                             rate: previous.playbackRate, playing: previous.isPlaying,
                             duration: previous.duration, now: now), now)
        }
        return (previous.currentTime, previous.lastUpdated)
    }

    static func position(elapsed: Double, anchor: Date, rate: Double, playing: Bool,
                         duration: Double, now: Date) -> Double {
        let base = elapsed.isFinite ? max(0, elapsed) : 0
        let delta = now.timeIntervalSince(anchor)
        let advances = playing && rate.isFinite && rate > 0 && anchor != .distantPast && delta.isFinite
        let estimate = advances ? base + max(0, delta) * rate : base
        let finite = estimate.isFinite ? max(0, estimate) : base
        return duration.isFinite && duration > 0 ? min(finite, duration) : finite
    }
}

enum MusicScrubPosition {
    static let confirmationWindow: TimeInterval = 0.9

    static func at(x: Double, width: Double, range: ClosedRange<Double>) -> Double? {
        let span = range.upperBound - range.lowerBound
        guard x.isFinite, width.isFinite, width > 0, span.isFinite, span > 0 else { return nil }
        return range.lowerBound + min(1, max(0, x / width)) * span
    }

    static func shouldFollowPlayback(target: Double, observedPosition: Double, anchor: Date,
                                     committedAt: Date, now: Date) -> Bool {
        if now.timeIntervalSince(committedAt) >= confirmationWindow { return true }
        return anchor >= committedAt && abs(observedPosition - target) <= 1.25
    }
}
