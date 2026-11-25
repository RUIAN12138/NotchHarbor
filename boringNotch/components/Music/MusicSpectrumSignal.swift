import Accelerate
import Combine
import CoreAudio
import Foundation
import OSLog

/// Holds only display levels. Core Audio's PCM buffers stay on the I/O queue.
final class MusicSpectrumSignal: ObservableObject, @unchecked Sendable {
    @Published private(set) var audible = false
    static let enabledKey = "musicAudioSpectrumEnabled"
    static let bandCount = 32
    static let lightBandCount = 16
    private static let logger = Logger(subsystem: "app.notchharbor", category: "MusicLight")
    private let lock = NSLock()
    private let control = DispatchQueue(label: "app.notchharbor.spectrum.control")
    private var requested = false
    private var envelope = MusicLightEnvelope()
    private var hasReportedSignal = false
    private var lastAudibleAt = 0.0
    private var hasAudibleAudio = false
    private var updatedAt = 0.0
    private var session: AnyObject?
    private var checkingForStall = false // Accessed on the control queue.

    func setActive(_ active: Bool) {
        lock.lock()
        requested = active
        if !active {
            envelope = MusicLightEnvelope()
            hasReportedSignal = false
            updatedAt = 0
            lastAudibleAt = 0
            hasAudibleAudio = false
        }
        lock.unlock()
        if !active { publishAudibility() }
        control.async { self.reconcile() }
    }

    func lightResponse() -> SIMD16<Float> {
        lock.lock()
        defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - updatedAt < 0.4 ? envelope.light : .zero
    }

    private var wantsAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    private func publishAudibility() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let current = self.lock.withLock { self.hasAudibleAudio }
            if self.audible != current { self.audible = current }
        }
    }

    private func reconcile(retrying: Bool = false) {
        if #available(macOS 14.4, *) {
            if wantsAudio {
                guard session == nil else { return }
                do {
                    session = try MusicSpectrumTap { [weak self] levels in self?.receive(levels) }
                    if !wantsAudio { session = nil }
                } catch {
                    if !retrying {
                        control.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                            self?.reconcile(retrying: true)
                        }
                    }
                    Self.logger.error("System audio tap could not start (\((error as NSError).code, privacy: .public))")
                }
            } else {
                session = nil
            }
        }
    }

    static func lightBands(_ levels: [CGFloat]) -> SIMD16<Float> {
        let binsPerBand = bandCount / lightBandCount
        var bands = SIMD16<Float>.zero
        for band in 0..<lightBandCount {
            let start = band * binsPerBand
            bands[band] = Float(levels[start..<(start + binsPerBand)].max() ?? 0)
        }
        return bands
    }

    private func scheduleStallCheck() {
        control.async { [weak self] in
            guard let self, !self.checkingForStall else { return }
            self.checkingForStall = true
            self.checkForStall()
        }
    }

    private func checkForStall() {
        control.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let status = self.lock.withLock {
                guard self.hasAudibleAudio else { return (ongoing: false, stalled: false) }
                let stale = ProcessInfo.processInfo.systemUptime - self.updatedAt >= 0.4
                if stale { self.hasAudibleAudio = false }
                return (ongoing: !stale, stalled: stale)
            }
            self.checkingForStall = status.ongoing
            if status.stalled { self.publishAudibility() }
            if status.ongoing { self.checkForStall() }
        }
    }

    private func receive(_ levels: [CGFloat]) {
        let bands = Self.lightBands(levels)
        let now = ProcessInfo.processInfo.systemUptime
        let aboveFloor = bands.max() > MusicLightEnvelope.noiseFloor
        lock.lock()
        let firstSignal = requested && !hasReportedSignal && aboveFloor
        let previouslyAudible = hasAudibleAudio
        if requested {
            envelope.update(bands, interval: updatedAt == 0 ? 1.0 / 48 : now - updatedAt)
            updatedAt = now
            if aboveFloor { lastAudibleAt = now }
            hasAudibleAudio = lastAudibleAt > 0 && (aboveFloor || now - lastAudibleAt < 0.42)
            hasReportedSignal = hasReportedSignal || firstSignal
        }
        let changed = previouslyAudible != hasAudibleAudio
        lock.unlock()
        if changed {
            publishAudibility()
            if aboveFloor { scheduleStallCheck() }
        }
        if firstSignal { Self.logger.notice("Received live audio for the music light") }
    }
}

/// Tracks short peaks against a slow reference, then applies independent
/// attack and release times so the response is consistent at different I/O rates.
struct MusicLightEnvelope {
    static let noiseFloor: Float = 0.055
    private(set) var light: SIMD16<Float> = .zero
    private var reference: SIMD16<Float> = .zero
    private var peaks: SIMD16<Float> = .zero

    mutating func update(_ bands: SIMD16<Float>, interval: Double) {
        let dt = Float(min(0.12, max(0.001, interval)))
        let peakDecay = exp(-dt / 1.7)
        let referenceStep = 1 - exp(-dt / 0.36)
        let rise = 1 - exp(-dt / 0.027)
        let fall = 1 - exp(-dt / 0.16)
        for band in 0..<MusicSpectrumSignal.lightBandCount {
            let level = max(0, bands[band] - Self.noiseFloor)
            peaks[band] = max(level, peaks[band] * peakDecay)
            let normalized = level / max(0.38, peaks[band])
            reference[band] += (normalized - reference[band]) * referenceStep
            let accent = max(0, normalized - reference[band])
            let target = min(1, normalized * 0.24 + accent * 1.9)
            light[band] += (target - light[band]) * (target > light[band] ? rise : fall)
        }
    }
}

@available(macOS 14.4, *)
private final class MusicSpectrumTap {
    private let ioQueue = DispatchQueue(label: "app.notchharbor.spectrum.audio", qos: .userInteractive)
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var started = false

    init(receive: @escaping ([CGFloat]) -> Void) throws {
        do {
            try start(receive: receive)
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    private func start(receive: @escaping ([CGFloat]) -> Void) throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "Notch Harbor music spectrum"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try Self.check(AudioHardwareCreateProcessTap(description, &tap))

        var format = AudioStreamBasicDescription()
        var address = Self.address(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format))
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, let analyzer = MusicSpectrumAnalyzer(sampleRate: format.mSampleRate) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioHardwareUnsupportedOperationError))
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Notch Harbor spectrum input",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device))
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, ioQueue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let buffer = buffers.first, let data = buffer.mData else { return }
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { return }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
            if let levels = analyzer.append(samples, count: count, stride: channels) { receive(levels) }
        })
        try Self.check(AudioDeviceStart(device, proc))
        started = true
    }

    private func stop() {
        if let proc {
            if started { AudioDeviceStop(device, proc) }
            AudioDeviceDestroyIOProcID(device, proc)
            self.proc = nil
        }
        if device != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(device)
            device = kAudioObjectUnknown
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = kAudioObjectUnknown
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

/// Hann window, real FFT and logarithmic frequency bands. Fast attack and
/// slower decay let peaks read clearly without flickering between buffers.
final class MusicSpectrumAnalyzer {
    private let sampleCount: Int
    private let order: vDSP_Length
    private let setup: FFTSetup
    private let bands: [Range<Int>]
    private var input: [Float]
    private var hann: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var levels = [CGFloat](repeating: 0, count: MusicSpectrumSignal.bandCount)
    private var position = 0

    init?(sampleRate: Double) {
        let order: vDSP_Length = sampleRate > 120_000 ? 13 : sampleRate > 60_000 ? 12 : 11
        guard sampleRate.isFinite, sampleRate >= 8000,
              let setup = vDSP_create_fftsetup(order, FFTRadix(kFFTRadix2)) else { return nil }
        let sampleCount = 1 << Int(order)
        self.sampleCount = sampleCount
        self.order = order
        self.setup = setup
        input = [Float](repeating: 0, count: sampleCount)
        hann = [Float](repeating: 0, count: sampleCount)
        real = [Float](repeating: 0, count: sampleCount / 2)
        imaginary = [Float](repeating: 0, count: sampleCount / 2)
        let bandCount = MusicSpectrumSignal.bandCount
        let binWidth = sampleRate / Double(sampleCount)
        let highest = min(12_000, sampleRate * 0.46)
        bands = (0..<bandCount).map { index in
            let lower = 62 * pow(highest / 62, Double(index) / Double(bandCount))
            let upper = 62 * pow(highest / 62, Double(index + 1) / Double(bandCount))
            let start = max(1, Int(lower / binWidth))
            return start..<min(sampleCount / 2, max(start + 1, Int(ceil(upper / binWidth))))
        }
        vDSP_hann_window(&hann, vDSP_Length(sampleCount), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func append(_ samples: UnsafePointer<Float>, count: Int, stride: Int) -> [CGFloat]? {
        var computed = false
        for index in Swift.stride(from: 0, to: count, by: stride) {
            input[position] = samples[index]
            position += 1
            if position == sampleCount {
                analyze()
                position = 0
                computed = true
            }
        }
        return computed ? levels : nil
    }

    private func analyze() {
        var peakSample: Float = 0
        vDSP_maxmgv(input, 1, &peakSample, vDSP_Length(sampleCount))
        if peakSample < 0.0001 {
            for index in levels.indices { levels[index] *= 0.74 }
            return
        }
        for index in real.indices {
            real[index] = input[2 * index] * hann[2 * index]
            imaginary[index] = input[2 * index + 1] * hann[2 * index + 1]
        }
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, order, FFTDirection(FFT_FORWARD))
            }
        }
        for (index, band) in bands.enumerated() {
            let peak = band.reduce(Float.zero) { peak, bin in
                max(peak, real[bin] * real[bin] + imaginary[bin] * imaginary[bin])
            }
            let amplitude = sqrt(peak) / Float(sampleCount)
            let decibels = 20 * log10(max(0.000_001, amplitude))
            let target = CGFloat(min(1, max(0, (decibels + 59) / 48)))
            let previous = levels[index]
            levels[index] = previous + (target - previous) * (target > previous ? 0.74 : 0.26)
        }
    }
}
