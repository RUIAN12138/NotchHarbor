//
//  VolumeManager.swift
//  boringNotch
//
//  Created by JeanLouis on 22/08/2025.
//

import AppKit
import Combine
import CoreAudio
import Foundation

final class VolumeManager: NSObject, ObservableObject {
    static let shared = VolumeManager()

    @Published private(set) var rawVolume: Float = 0
    @Published private(set) var isMuted: Bool = false
    @Published private(set) var lastChangeAt: Date = .distantPast

    let visibleDuration: TimeInterval = 1.2

    private var didInitialFetch = false
    private var outputGeneration = UUID()
    private var observedDevice: AudioObjectID = kAudioObjectUnknown
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let step: Float32 = 1.0 / 16.0
    // Fallback software if hardware mute is not supported
    private var previousVolumeBeforeMute: Float32 = 0.2
    private var softwareMuted: Bool = false

    private override init() {
        super.init()
        setupAudioListener()
        fetchCurrentVolume()
    }

    var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

    // MARK: - Public Control API
    @MainActor func increase(stepDivisor: Float = 1.0) {
        let divisor = max(stepDivisor, 0.25)
        let delta = step / Float32(divisor)
        let current = readVolumeInternal() ?? rawVolume
        let target = max(0, min(1, current + delta))
        setAbsolute(target)
    }

    @MainActor func decrease(stepDivisor: Float = 1.0) {
        let divisor = max(stepDivisor, 0.25)
        let delta = step / Float32(divisor)
        let current = readVolumeInternal() ?? rawVolume
        let target = max(0, min(1, current - delta))
        setAbsolute(target)
    }

    @MainActor func toggleMuteAction() {
        let previousMuted = isMutedInternal()
        toggleMuteInternal()
        let muted = isMutedInternal()
        let actual = readVolumeInternal() ?? rawVolume
        publish(volume: actual, muted: muted, touchDate: true)
        BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(muted ? 0 : actual),
            icon: muted == previousMuted ? "speaker.badge.exclamationmark" : "")
    }

    func refresh() { fetchCurrentVolume() }

    @MainActor func adjustableOutputVolume(deviceID: AudioObjectID) -> Float32? {
        guard systemOutputDeviceID() == deviceID else { return nil }
        let elements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2, 3, 4]
        guard elements.contains(where: { element in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var writable: DarwinBoolean = false
            return AudioObjectIsPropertySettable(deviceID, &address, &writable) == noErr && writable.boolValue
        }) else { return nil }
        return readVolumeInternal(deviceID: deviceID)
    }

    @MainActor func stepOutputVolume(deviceID: AudioObjectID, direction: Float32) {
        guard let current = adjustableOutputVolume(deviceID: deviceID) else { return }
        let target = max(0, min(1, current + direction * step))
        guard target != current, writeVolumeInternal(target, deviceID: deviceID) else { return }
        fetchCurrentVolume()
    }

    func adjustRelative(delta: Float32) {
        if isMutedInternal() { toggleMuteInternal() }
        guard let current = readVolumeInternal() else {
            fetchCurrentVolume()
            return
        }
        let target = max(0, min(1, current + delta))
        guard writeVolumeInternal(target) else { fetchCurrentVolume(); return }
        publish(volume: readVolumeInternal() ?? target, muted: isMutedInternal(), touchDate: true)
    }

    @MainActor func setAbsolute(_ value: Float32) {
        let clamped = max(0, min(1, value))
        let currentlyMuted = isMutedInternal()
        if currentlyMuted && clamped > 0 {
            toggleMuteInternal()
        }

        guard writeVolumeInternal(clamped) else {
            fetchCurrentVolume()
            BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume,
                value: CGFloat(isMutedInternal() ? 0 : (readVolumeInternal() ?? rawVolume)), icon: "speaker.badge.exclamationmark")
            return
        }

        if clamped == 0 && !currentlyMuted {
            toggleMuteInternal()
        }

        let actual = readVolumeInternal() ?? clamped
        let muted = isMutedInternal()
        publish(volume: actual, muted: muted, touchDate: true)
        BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(muted ? 0 : actual))
    }

    // MARK: - CoreAudio Helpers
    private func systemOutputDeviceID() -> AudioObjectID {
        var defaultDeviceID = kAudioObjectUnknown
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &defaultDeviceID
        )
        if status != noErr { return kAudioObjectUnknown }
        return defaultDeviceID
    }

    private func fetchCurrentVolume() {
        let deviceID = systemOutputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return }
        var volumes: [Float32] = []
        let candidateElements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2, 3, 4]
        for element in candidateElements {
            if let v = readValidatedScalar(deviceID: deviceID, element: element) {
                volumes.append(v)
            }
        }
        let volume = volumes.isEmpty ? nil : max(0, min(1, volumes.reduce(0, +) / Float32(volumes.count)))
        var muted = softwareMuted
        var muteAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var muteValue: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(deviceID, &muteAddr),
           AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &muteSize, &muteValue) == noErr {
            muted = muteValue != 0
        }
        let generation = outputGeneration
        DispatchQueue.main.async {
            guard self.outputGeneration == generation, self.systemOutputDeviceID() == deviceID else { return }
            // Publish one coherent snapshot; initial device state must not act like a key press.
            let changed = self.didInitialFetch && ((volume.map { self.rawVolume != $0 } ?? false) || self.isMuted != muted)
            if let volume { self.rawVolume = volume }
            self.isMuted = muted
            self.didInitialFetch = true
            if changed { self.lastChangeAt = Date() }
        }
    }

    private func setupAudioListener() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.bindOutputListeners()
            self?.fetchCurrentVolume()
        }
        bindOutputListeners()
    }

    private func bindOutputListeners() {
        let device = systemOutputDeviceID()
        guard device != observedDevice else { return }
        for (saved, block) in deviceListeners {
            var address = saved
            AudioObjectRemovePropertyListenerBlock(observedDevice, &address, .main, block)
        }
        deviceListeners.removeAll()
        observedDevice = device
        outputGeneration = UUID()
        didInitialFetch = false
        softwareMuted = false
        previousVolumeBeforeMute = 0.2
        guard device != kAudioObjectUnknown else { return }
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
                var address = AudioObjectPropertyAddress(mSelector: selector,
                    mScope: kAudioDevicePropertyScopeOutput, mElement: element)
                guard AudioObjectHasProperty(device, &address) else { continue }
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.fetchCurrentVolume() }
                if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
                    deviceListeners.append((address, block))
                }
            }
        }
    }

    private func readVolumeInternal(deviceID: AudioObjectID? = nil) -> Float32? {
        let deviceID = deviceID ?? systemOutputDeviceID()
        if deviceID == kAudioObjectUnknown { return nil }
        var collected: [Float32] = []
        for el in [kAudioObjectPropertyElementMain, 1, 2, 3, 4] {
            if let v = readValidatedScalar(deviceID: deviceID, element: el) { collected.append(v) }
        }
        guard !collected.isEmpty else { return nil }
        return collected.reduce(0, +) / Float32(collected.count)
    }

    @discardableResult
    private func writeVolumeInternal(_ value: Float32, deviceID: AudioObjectID? = nil) -> Bool {
        let deviceID = deviceID ?? systemOutputDeviceID()
        if deviceID == kAudioObjectUnknown { return false }
        let newVal = max(0, min(1, value))

        var written = false
        if writeValidatedScalar(
            deviceID: deviceID, element: kAudioObjectPropertyElementMain, value: newVal)
        {
            written = true
        } else {
            var any = false
            for el in [UInt32](1...4) {
                if writeValidatedScalar(deviceID: deviceID, element: el, value: newVal) {
                    any = true
                }
            }
            written = any
        }
        return written
    }

    private func isMutedInternal() -> Bool {
        let deviceID = systemOutputDeviceID()
        if deviceID == kAudioObjectUnknown { return softwareMuted }
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &muteAddr) else { return softwareMuted }
        var sizeNeeded: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &muteAddr, 0, nil, &sizeNeeded) == noErr,
            sizeNeeded == UInt32(MemoryLayout<UInt32>.size)
        else { return softwareMuted }
        var muted: UInt32 = 0
        var size = sizeNeeded
        if AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &size, &muted) == noErr {
            return muted != 0
        }
        return softwareMuted
    }

    private func toggleMuteInternal() {
        let deviceID = systemOutputDeviceID()
        if deviceID == kAudioObjectUnknown {
            performSoftwareMuteToggle(currentVolume: rawVolume)
            return
        }
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if !AudioObjectHasProperty(deviceID, &muteAddr) {
            let currentVol = readVolumeInternal() ?? rawVolume
            performSoftwareMuteToggle(currentVolume: currentVol)
            return
        }
        var sizeNeeded: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &muteAddr, 0, nil, &sizeNeeded) == noErr,
            sizeNeeded == UInt32(MemoryLayout<UInt32>.size)
        else {
            let currentVol = readVolumeInternal() ?? rawVolume
            performSoftwareMuteToggle(currentVolume: currentVol)
            return
        }
        var muted: UInt32 = 0
        var size = sizeNeeded
        if AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &size, &muted) == noErr {
            var newVal: UInt32 = muted == 0 ? 1 : 0
            guard AudioObjectSetPropertyData(deviceID, &muteAddr, 0, nil, size, &newVal) == noErr else { fetchCurrentVolume(); return }
            let vol = readVolumeInternal() ?? rawVolume
            publish(volume: vol, muted: newVal != 0, touchDate: true)
        } else {
            let currentVol = readVolumeInternal() ?? rawVolume
            performSoftwareMuteToggle(currentVolume: currentVol)
        }
    }

    private func performSoftwareMuteToggle(currentVolume: Float32) {
        if softwareMuted {
            let restore = max(0, min(1, previousVolumeBeforeMute))
            guard writeVolumeInternal(restore) else { fetchCurrentVolume(); return }
            softwareMuted = false
            publish(volume: restore, muted: false, touchDate: true)
        } else {
            if currentVolume > 0.001 { previousVolumeBeforeMute = currentVolume }
            guard writeVolumeInternal(0) else { fetchCurrentVolume(); return }
            softwareMuted = true
            publish(volume: 0, muted: true, touchDate: true)
        }
    }

    private func readValidatedScalar(deviceID: AudioObjectID, element: UInt32) -> Float32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return nil }
        var sizeNeeded: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &sizeNeeded) == noErr,
            sizeNeeded == UInt32(MemoryLayout<Float32>.size)
        else { return nil }
        var vol = Float32(0)
        var size = sizeNeeded
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &vol)
        return status == noErr ? vol : nil
    }

    private func writeValidatedScalar(deviceID: AudioObjectID, element: UInt32, value: Float32)
        -> Bool
    {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return false }
        var sizeNeeded: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &sizeNeeded) == noErr,
            sizeNeeded == UInt32(MemoryLayout<Float32>.size)
        else { return false }
        var val = value
        return AudioObjectSetPropertyData(deviceID, &addr, 0, nil, sizeNeeded, &val) == noErr
    }

    private func publish(volume: Float32, muted: Bool, touchDate: Bool) {
        let device = systemOutputDeviceID()
        let generation = outputGeneration
        DispatchQueue.main.async {
            guard self.systemOutputDeviceID() == device, self.outputGeneration == generation else { return }
            self.rawVolume = volume
            self.isMuted = muted
            if touchDate { self.lastChangeAt = Date() }
        }
    }
}

extension Array where Element == Float32 {
    fileprivate var average: Float32? { isEmpty ? nil : reduce(0, +) / Float32(count) }
}


