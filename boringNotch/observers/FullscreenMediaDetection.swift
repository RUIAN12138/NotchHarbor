//
//  FullscreenMediaDetection.swift
//  boringNotch
//
//  Created by Richard Kunkli on 06/09/2024.
//

import Foundation
import Combine
import Defaults
import MacroVisionKit

@MainActor
final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()
    
    @Published var fullscreenStatus: [String: Bool] = [:]
    
    private var currentSpaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo] = []
    private var monitorTask: Task<Void, Never>?
    private var preferenceObservation: AnyCancellable?
    
    private init() {
        preferenceObservation = Publishers.CombineLatest(
            Defaults.publisher(.hideNotchOption).map(\.newValue),
            MusicManager.shared.$bundleIdentifier
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] option, mediaBundle in
            self?.updateStatus(option: option, mediaBundle: mediaBundle)
        }
        startMonitoring()
    }
    
    deinit {
        monitorTask?.cancel()
    }
    
    private func startMonitoring() {
        monitorTask = Task { @MainActor in
            let stream = await FullScreenMonitor.shared.spaceChanges()
            for await spaces in stream {
                currentSpaces = spaces
                updateStatus(option: Defaults[.hideNotchOption], mediaBundle: MusicManager.shared.bundleIdentifier)
            }
        }
    }
    
    private func updateStatus(option: HideNotchOption, mediaBundle: String?) {
        var status: [String: Bool] = [:]
        for space in currentSpaces {
            guard let uuid = space.screenUUID else { continue }
            let matchesMedia = mediaBundle.map(space.runningApps.contains) ?? false
            if option == .always || (option == .nowPlayingOnly && matchesMedia) {
                status[uuid] = true
            }
        }
        fullscreenStatus = status
    }
}
