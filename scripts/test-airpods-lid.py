#!/usr/bin/env python3
"""Compile and exercise the production parser/gate without Bluetooth hardware."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'boringNotch/components/Notch/DeviceActivity.swift').read_text()
production = source[source.index('struct AirPodsProximity {'):source.index('import CoreBluetooth')]
tests = r'''
func bytes(_ text: String) -> Data {
    let s = Array(text); return Data(stride(from: 0, to: s.count, by: 2).map { UInt8(String(s[$0...$0+1]), radix: 16)! })
}
// Upstream real-device regression sample (Pro 2, out of case).
let real = bytes("4c0007190114200b538f10000848273aff815e50000000261e7bfab684")
let p = AirPodsProximity.parse(real)!
precondition(p.productID == 0x2014 && p.left == 50 && p.right == 30 && p.caseLevel == nil && p.lidOpen == nil)
var frame = Array(real)
frame[7] = 0x74; frame[8] = 0xa9; frame[9] = 0x36; frame[10] = 0x01
let opened = AirPodsProximity.parse(Data(frame))!
precondition(opened.left == 90 && opened.right == 100 && opened.caseLevel == 60 && opened.lidOpen == true)
precondition(opened.leftCharging == true && opened.rightCharging == true && opened.caseCharging == false)
frame[7] = 0x44; frame[9] = 0x16
let flipped = AirPodsProximity.parse(Data(frame))!
precondition(flipped.leftCharging == false && flipped.rightCharging == true)
frame[9] = 0x4f
let missingCase = AirPodsProximity.parse(Data(frame))!
precondition(missingCase.caseCharging == nil)
frame[7] = 0x74; frame[9] = 0x36
frame[10] = 0x09
let closed = AirPodsProximity.parse(Data(frame))!
precondition(closed.lidOpen == false)
for n in 0..<29 { precondition(AirPodsProximity.parse(real.prefix(n)) == nil) }
frame[0] = 0xff; precondition(AirPodsProximity.parse(Data(frame)) == nil)
// Upstream hardware captures: status/battery/lid/color, after model bytes.
let fixtures: [(String, Bool, Bool)] = [("0b878f1100", true, true), ("03878f1100", false, true),
    ("73789f5100", false, true), ("1587b75200", false, false)]
for (clear, left, right) in fixtures {
    let packet = AirPodsProximity.parse(bytes("4c000719011420" + clear + "04" + String(repeating: "00", count: 16)))!
    precondition(packet.leftInEar == left && packet.rightInEar == right)
}
let resting = AirPodsProximity.parse(bytes("4c0007190114201587b7520004" + String(repeating: "00", count: 16)))!
let wearing = AirPodsProximity.parse(bytes("4c0007190114200b878f110004" + String(repeating: "00", count: 16)))!
var wearGate = AirPodsWearGate()
let identity = UUID(), other = UUID()
precondition(!wearGate.accept(wearing, identity: identity, now: 0))
precondition(!wearGate.accept(resting, identity: identity, now: 1))
precondition(!wearGate.accept(wearing, identity: identity, now: 2))
precondition(!wearGate.accept(wearing, identity: other, now: 2.2))
precondition(wearGate.accept(wearing, identity: identity, now: 2.2))
precondition(!wearGate.accept(wearing, identity: identity, now: 3))
precondition(!wearGate.accept(resting, identity: identity, now: 4))
precondition(!wearGate.accept(wearing, identity: identity, now: 5))
precondition(wearGate.accept(wearing, identity: identity, now: 5.2))
var gate = AirPodsLidGate()
precondition(!gate.accept(opened, rssi: -80, now: 0))
precondition(!gate.accept(opened, rssi: 127, now: 0))
precondition(!gate.accept(opened, rssi: -40, now: 1))
precondition(!gate.accept(opened, rssi: -40, now: 1.05))
precondition(gate.accept(opened, rssi: -40, now: 1.2))
precondition(!gate.accept(opened, rssi: -40, now: 20))
precondition(!gate.accept(closed, rssi: -40, now: 21))
precondition(!gate.accept(opened, rssi: -40, now: 22))
precondition(gate.accept(opened, rssi: -40, now: 22.2))
precondition(!gate.accept(p, rssi: -40, now: 23))
print("PASS: upstream real sample, battery orientation, charging flags and unknown charging, lid validity, truncation, company ID, RSSI, repeated adverts, close/reopen, hardware in-ear samples and wear edges")
'''
with tempfile.TemporaryDirectory(prefix='boring-lid-test-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text('import Foundation\n' + production + tests)
    subprocess.run(['xcrun', 'swiftc', str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
