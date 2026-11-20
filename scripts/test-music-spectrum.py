"""Verify frequency bands from generated PCM, without accessing system audio."""

from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
analyzer = root / "boringNotch/components/Music/MusicSpectrumSignal.swift"
test = r'''
import Foundation
@main struct Verify {
    static func run(_ frequency: Double, volume: Double, rate: Double) -> [CGFloat] {
        let analyzer = MusicSpectrumAnalyzer(sampleRate: rate)!
        let input = (0..<2048).map { index in Float(volume * sin(2 * .pi * frequency * Double(index) / rate)) }
        return input.withUnsafeBufferPointer { analyzer.append($0.baseAddress!, count: $0.count, stride: 1)! }
    }
    static func main() {
        for rate in [44_100.0, 48_000, 96_000] {
            let quiet = run(94, volume: 0.03, rate: rate)
            let bass = run(94, volume: 0.4, rate: rate)
            let treble = run(5000, volume: 0.4, rate: rate)
            let silence = run(0, volume: 0, rate: rate)
            precondition(silence.allSatisfy { $0 == 0 })
            precondition(bass.max()! > quiet.max()! && bass.prefix(8).max()! > 0.65)
            precondition(treble.suffix(10).max()! > 0.65 && treble.prefix(8).max()! < 0.15)
            precondition([bass, treble].flatMap { $0 }.allSatisfy { $0.isFinite && (0...1).contains($0) })
        }
        print("PASS real PCM: silence, bass vs treble, volume response, and three sample rates")
        for hz in [24.0, 48.0, 96.0] {
            let step = 1 / hz
            var envelope = MusicLightEnvelope()
            for _ in 0..<Int(hz) { envelope.update(.init(repeating: 0.04), interval: step) }
            precondition(envelope.light == .zero)
            for _ in 0..<Int(hz * 0.13) { envelope.update(.init(0.41, 0, 0), interval: step) }
            let accent = envelope.light.x
            precondition(accent > 0.6 && envelope.light.y == 0 && envelope.light.z == 0)
            for _ in 0..<Int(hz * 2) { envelope.update(.init(0.41, 0, 0), interval: step) }
            precondition((0.20...0.28).contains(envelope.light.x))
            for _ in 0..<Int(hz * 0.12) { envelope.update(.zero, interval: step) }
            precondition((0.09...0.15).contains(envelope.light.x))
            for _ in 0..<Int(hz * 0.57) { envelope.update(.zero, interval: step) }
            precondition(envelope.light.x < 0.006)
        }
        print("PASS music light: noise floor, distinct onset, steady-note restraint, silence and three callback rates")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="harbor-music-spectrum-") as temporary:
    source = Path(temporary) / "Verify.swift"
    output = Path(temporary) / "test"
    source.write_text(test)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(analyzer), str(source), "-o", str(output)], check=True)
    subprocess.run([str(output)], check=True)
