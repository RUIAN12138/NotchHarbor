import Accelerate
import CoreAudio
import Foundation
import OSLog

/// Holds only display levels. Core Audio's PCM buffers stay on the I/O queue.
final class MusicSpectrumSignal: @unchecked Sendable {
    static let enabledKey = "musicAudioSpectrumEnabled"
    static let bandCount = 32
    private static let logger = Logger(subsystem: "app.notchharbor", category: "MusicLight")
    private let lock = NSLock()
    private let control = DispatchQueue(label: "app.notchharbor.spectrum.control")
    private var requested = false
    private var envelope = MusicLightEnvelope()
    private var hasReportedSignal = false
    private var updatedAt = 0.0
    private var session: AnyObject?

    func setActive(_ active: Bool) {
        lock.lock()
        requested = active
        if !active {
            envelope = MusicLightEnvelope()
            hasReportedSignal = false
            updatedAt = 0
        }
        lock.unlock()
        control.async { self.reconcile() }
    }

    func lightResponse() -> SIMD3<Float> {
        lock.lock()
        defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - updatedAt < 0.4 ? envelope.light : .zero
    }

    private var wantsAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    private func reconcile() {
        if #available(macOS 14.4, *) {
            if wantsAudio {
                guard session == nil else { return }
                do {
                    session = try MusicSpectrumTap { [weak self] levels in self?.receive(levels) }
                    if !wantsAudio { session = nil }
                } catch {
                    Self.logger.error("System audio tap could not start (\((error as NSError).code, privacy: .public))")
                }
            } else {
                session = nil
            }
        }
    }

    private func receive(_ levels: [CGFloat]) {
        let bands = SIMD3(
            Float(levels[0..<9].max() ?? 0),
            Float(levels[9..<23].max() ?? 0),
            Float(levels[23..<32].max() ?? 0)
        )
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let firstSignal = requested && !hasReportedSignal && max(bands.x, bands.y, bands.z) > 0.055
        if requested {
            envelope.update(bands, interval: updatedAt == 0 ? 1.0 / 48 : now - updatedAt)
            updatedAt = now
            hasReportedSignal = hasReportedSignal || firstSignal
        }
        lock.unlock()
        if firstSignal { Self.logger.notice("Received live audio for the music light") }
    }
}

/// Tracks short peaks against a slow reference, then applies independent
/// attack and release times so the response is consistent at different I/O rates.
struct MusicLightEnvelope {
    private(set) var light: SIMD3<Float> = .zero
    private var reference: SIMD3<Float> = .zero
    private var peaks: SIMD3<Float> = .zero

    mutating func update(_ bands: SIMD3<Float>, interval: Double) {
        let dt = Float(min(0.12, max(0.001, interval)))
        let peakDecay = exp(-dt / 1.7)
        let referenceStep = 1 - exp(-dt / 0.36)
        let rise = 1 - exp(-dt / 0.018)
        let fall = 1 - exp(-dt / 0.14)
        for band in 0..<3 {
            let level = max(0, bands[band] - 0.055)
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
    private static let sampleCount = 1024
    private static let order: vDSP_Length = 10
    private let setup: FFTSetup
    private let bands: [Range<Int>]
    private var input = [Float](repeating: 0, count: sampleCount)
    private var hann = [Float](repeating: 0, count: sampleCount)
    private var real = [Float](repeating: 0, count: sampleCount / 2)
    private var imaginary = [Float](repeating: 0, count: sampleCount / 2)
    private var levels = [CGFloat](repeating: 0, count: MusicSpectrumSignal.bandCount)
    private var position = 0

    init?(sampleRate: Double) {
        guard sampleRate >= 8000, let setup = vDSP_create_fftsetup(Self.order, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup
        let bandCount = MusicSpectrumSignal.bandCount
        let binWidth = sampleRate / Double(Self.sampleCount)
        let highest = min(12_000, sampleRate * 0.46)
        bands = (0..<bandCount).map { index in
            let lower = 62 * pow(highest / 62, Double(index) / Double(bandCount))
            let upper = 62 * pow(highest / 62, Double(index + 1) / Double(bandCount))
            let start = max(1, Int(lower / binWidth))
            return start..<min(Self.sampleCount / 2, max(start + 1, Int(ceil(upper / binWidth))))
        }
        vDSP_hann_window(&hann, vDSP_Length(Self.sampleCount), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func append(_ samples: UnsafePointer<Float>, count: Int, stride: Int) -> [CGFloat]? {
        var computed = false
        for index in Swift.stride(from: 0, to: count, by: stride) {
            input[position] = samples[index]
            position += 1
            if position == Self.sampleCount {
                analyze()
                position = 0
                computed = true
            }
        }
        return computed ? levels : nil
    }

    private func analyze() {
        for index in real.indices {
            real[index] = input[2 * index] * hann[2 * index]
            imaginary[index] = input[2 * index + 1] * hann[2 * index + 1]
        }
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, Self.order, FFTDirection(FFT_FORWARD))
            }
        }
        for (index, band) in bands.enumerated() {
            let peak = band.reduce(Float.zero) { peak, bin in
                max(peak, real[bin] * real[bin] + imaginary[bin] * imaginary[bin])
            }
            let amplitude = sqrt(peak) / Float(Self.sampleCount)
            let decibels = 20 * log10(max(0.000_001, amplitude))
            let target = CGFloat(min(1, max(0, (decibels + 59) / 48)))
            let previous = levels[index]
            levels[index] = previous + (target - previous) * (target > previous ? 0.74 : 0.26)
        }
    }
}
