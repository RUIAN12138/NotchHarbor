#!/usr/bin/env python3
"""Exercise the production activity model without scanning Bluetooth."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
model = (root / 'boringNotch/components/Notch/UnifiedActivities.swift').read_text().split('private enum AgentActivityFilter:')[0]
test = r'''
@MainActor final class XPCHelperClient {
    static let shared = XPCHelperClient()
    func pendingCodexApprovals() async -> Data { Data() }
    func submitCodexApproval(id: UUID, sessionID: UUID, choice: String) async -> String { "notSent" }
}

@main struct Check {
 @MainActor static func main() async {
  let hub = UnifiedActivities(observeSystem: false)
  let device = UUID(), other = UUID()
  let opened = AirPodsProximity(productID: 0x2014, left: 80, right: 70, caseLevel: 60, lidOpen: true, lidCounter: 1)
  let updated = AirPodsProximity(productID: 0x2014, left: 90, right: 80, caseLevel: 70, lidOpen: true, lidCounter: 1, leftCharging: true)
  let closed = AirPodsProximity(productID: 0x2014, left: 90, right: 80, caseLevel: 70, lidOpen: false, lidCounter: 1)
  hub.announceLid(opened, name: "AirPods", identity: device)
  let initial = hub.headphoneAlert!, expires = hub.primary!.expires
  precondition(hub.proactiveAlerts.first?.kind == "headphone-lid")
  precondition(hub.wingActivity == nil)
  hub.updateLid(updated, identity: other)
  precondition(hub.headphoneAlert == initial)
  hub.updateLid(updated, identity: device)
  precondition(hub.headphoneAlert?.id == initial.id && hub.headphoneAlert?.battery == 80)
  precondition(hub.headphoneAlert?.leftCharging == true && hub.primary?.expires == expires)
  hub.updateLid(closed, identity: other)
  precondition(hub.headphoneAlert != nil)
  hub.updateLid(closed, identity: device)
  precondition(hub.headphoneAlert == nil)
  hub.updateLid(updated, identity: device)
  precondition(hub.headphoneAlert == nil)
  hub.announceLid(opened, name: "AirPods", identity: device)
  hub.announceHeadphones(name: "AirPods")
  let connected = hub.headphoneAlert!
  precondition(hub.proactiveAlerts.isEmpty && hub.wingActivity?.kind == "headphones")
  hub.updateLid(closed, identity: device)
  precondition(hub.headphoneAlert == connected && connected.status == "已连接")
  hub.previewHeadphones(wearing: true)
  precondition(hub.headphoneAlert?.isWearing == true && hub.headphoneAlert?.isBanner == false)
  precondition(hub.headphoneAlert?.isPreview == true)
  precondition(hub.headphoneAlert?.spin?.lastPathComponent.contains("Case") == false)
  hub.previewHeadphones(wearing: false)
  precondition(hub.headphoneAlert?.isWearing == false && hub.headphoneAlert?.isBanner == true)
  precondition(hub.headphoneAlert?.spin?.lastPathComponent.contains("Case") == false)
  precondition(hub.headphoneAlert?.caseSpin?.lastPathComponent.contains("Case") == true)
  hub.dismiss("headphones")
  hub.announceHeadphones(name: "Another AirPods")
  precondition(hub.headphoneAlert?.isBanner == false && hub.headphoneAlert?.isWearing == false)
  hub.announceWearing(opened, name: "Wear Test", identity: device)
  let wearID = hub.headphoneAlert!.id
  hub.announceHeadphones(name: "Wear Test")
  precondition(hub.headphoneAlert?.id == wearID && hub.headphoneAlert?.isBanner == false)
  hub.announceLid(opened, name: "Wear Test", identity: device)
  precondition(hub.headphoneAlert?.id == wearID) // stale open cannot replace wear cue
  hub.audioOutputEnded()
  precondition(hub.headphoneAlert == nil)
  hub.announceHeadphones(name: "Wear Test")
  precondition(hub.headphoneAlert != nil) // rapid reconnect is not suppressed
  hub.audioOutputEnded()
  hub.announceLid(opened, name: "Case", identity: device)
  let caseID = hub.headphoneAlert?.id
  hub.audioOutputEnded()
  precondition(hub.headphoneAlert?.id == caseID) // route change must not dismiss a case
  hub.announceWearing(opened, name: "Case", identity: device)
  let reopened = AirPodsProximity(productID: 0x2014, left: 80, right: 70, caseLevel: 60, lidOpen: true, lidCounter: 2)
  hub.announceLid(reopened, name: "Case", identity: device)
  precondition(hub.headphoneAlert?.isBanner == true) // a genuinely new lid cycle is allowed
  let routeHub = UnifiedActivities(observeSystem: false)
  routeHub.announceHeadphones(name: "AirPods Pro", showCue: false)
  precondition(routeHub.headphoneAlert == nil && routeHub.connectedAirPods != nil)
  precondition(routeHub.proactiveAlerts.isEmpty && routeHub.wingActivity == nil)
  let startupID = routeHub.connectedAirPods!.id
  routeHub.announceWearing(opened, name: "AirPods Pro", identity: device)
  precondition(routeHub.headphoneAlert?.id == startupID && routeHub.headphoneAlert?.isWearing == true)
  precondition(routeHub.proactiveAlerts.isEmpty && routeHub.wingActivity?.kind == "headphones")
  routeHub.dismiss("headphones")
  let output = BluetoothInfo.Device(name: "AirPods Pro", address: nil,
                                    level: 75, left: 75, right: 82, caseLevel: 55, productID: 0x2014)
  precondition(routeHub.applyHeadphoneLookup(output, spin: nil, cueID: startupID))
  precondition(routeHub.connectedAirPods?.caseBattery == 55 && routeHub.headphoneAlert == nil)
  routeHub.audioOutputEnded()
  precondition(routeHub.connectedAirPods == nil)
  precondition(!routeHub.applyHeadphoneLookup(output, spin: nil, cueID: startupID))
  let twins = UnifiedActivities(observeSystem: false)
  twins.announceHeadphones(name: "AirPods Pro", address: "AA:BB:CC:DD:EE:91")
  twins.announceWearing(opened, name: "AirPods Pro", identity: device)
  let firstTwin = twins.headphoneAlert!.id
  twins.announceHeadphones(name: "AirPods Pro", address: "AA:BB:CC:DD:EE:92")
  precondition(twins.headphoneAlert?.id != firstTwin && twins.connectedAirPods?.battery == nil)
  var gate = AirPodsLidGate()
  precondition(!gate.accept(opened, rssi: -40, now: 0, identity: "a"))
  precondition(!gate.accept(opened, rssi: -40, now: 0.2, identity: "b"))
  precondition(gate.accept(opened, rssi: -40, now: 0.3, identity: "a"))
  precondition(gate.accept(opened, rssi: -40, now: 0.4, identity: "b"))
  print("PASS: lid-only cards, compact wear/routing, silent startup, live battery after cue expires, route cleanup, device isolation and stale update rejection")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='boring-lifecycle-') as folder:
    path = Path(folder)
    (path / 'Check.swift').write_text(model + test)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(path / 'Check.swift'),
                    str(root / 'boringNotch/components/Notch/DeviceActivity.swift'),
                    str(root / 'boringNotch/components/Notch/AgentConversationHistory.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
