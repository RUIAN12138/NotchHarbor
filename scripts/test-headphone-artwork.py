#!/usr/bin/env python3
"""Compile the production audio/artwork path and exercise its pure model without touching devices."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
model = (root / 'boringNotch/components/Notch/UnifiedActivities.swift').read_text().split('private enum AgentActivityFilter:')[0]
tests = r'''
func json(_ text: String) -> Data { Data(text.utf8) }

@main struct Check {
 @MainActor static func main() async {
  // 1. Custom name whose connected record omits the PID; the model is in the disconnected list
  //    at the same address. Live battery stays connected-only.
  let coldJSON = """
  {"SPBluetoothDataType":[{"device_connected":[{"Renamed Buds":{"device_address":"AA:BB:CC:DD:EE:01","device_batteryLevelLeft":"55%","device_batteryLevelRight":"65%"}}],"device_not_connected":[{"Renamed Buds":{"device_address":"AA:BB:CC:DD:EE:01","device_productID":"0x200E","device_batteryLevelLeft":"9%","device_batteryLevelRight":"8%","device_batteryLevelCase":"7%"}}]}]}
  """
  let coldReport = BluetoothInfo.parseReport(json(coldJSON))
  precondition(coldReport.connected.count == 1)
  let connected = coldReport.connected[0]
  precondition(connected.productID == 0x200e)
  precondition(connected.level == 55 && connected.left == 55 && connected.right == 65)
  let coldCache = BluetoothArtworkCache()
  let cold = BluetoothInfo.resolve(coldReport, address: "AA:BB:CC:DD:EE:01", name: "Renamed Buds", cache: coldCache)!
  precondition(cold.productID == 0x200e && cold.level == 55 && cold.spin != nil)
  precondition(BluetoothInfo.symbol(forProductID: cold.productID!) == "airpodspro")

  // 2. Disconnected-only model: metadata keeps the model but never the old battery.
  let disconnectedJSON = """
  {"SPBluetoothDataType":[{"device_connected":[],"device_not_connected":[{"Renamed Pro":{"device_address":"AA:BB:CC:DD:EE:02","device_productID":"0x200E","device_batteryLevelMain":"77%","device_batteryLevelLeft":"76%","device_batteryLevelRight":"75%"}}]}]}
  """
  let disconnected = BluetoothInfo.parseReport(json(disconnectedJSON))
  precondition(disconnected.connected.isEmpty && disconnected.metadata.count == 1)
  let stale = disconnected.metadata[0]
  precondition(stale.productID == 0x200e)
  precondition(stale.level == nil && stale.left == nil && stale.right == nil && stale.caseLevel == nil)
  let metadataOnly = BluetoothInfo.resolve(disconnected, address: "AA:BB:CC:DD:EE:02", name: "Renamed Pro", cache: coldCache)!
  precondition(metadataOnly.level == nil && metadataOnly.left == nil && metadataOnly.right == nil && metadataOnly.caseLevel == nil)
  precondition(metadataOnly.productID == 0x200e && metadataOnly.spin != nil)
  // Even a metadata record carrying levels is cleared by resolve.
  let bogus = BluetoothInfo.Report(connected: [], metadata: [BluetoothInfo.Device(name: "Renamed Pro", address: "AA:BB:CC:DD:EE:03", level: 99, left: 99, right: 99, caseLevel: 99, productID: 0x200e)])
  let cleared = BluetoothInfo.resolve(bogus, address: "AA:BB:CC:DD:EE:03", name: "Renamed Pro", cache: coldCache)!
  precondition(cleared.level == nil && cleared.left == nil && cleared.right == nil && cleared.caseLevel == nil)

  // 3. Cold connected record resolved through the warm cache: model/artwork from identity,
  //    battery still only from the connected record.
  let warm = BluetoothArtworkCache()
  warm.store([BluetoothInfo.Device(name: "Cold Cache", address: "AA:BB:CC:DD:EE:04", level: 88, left: 88, right: 80, caseLevel: 70, productID: 0x201b)])
  let cacheReport = BluetoothInfo.Report(connected: [BluetoothInfo.Device(name: "Cold Cache", address: "AA:BB:CC:DD:EE:04", level: 41, left: 41, right: 42, caseLevel: nil, productID: nil)], metadata: [])
  let cached = BluetoothInfo.resolve(cacheReport, address: "AA:BB:CC:DD:EE:04", name: "Cold Cache", cache: warm)!
  precondition(cached.productID == 0x201b && cached.level == 41 && cached.left == 41 && cached.right == 42)
  precondition(cached.spin != nil)
  let snapshot = warm.snapshot()
  precondition(snapshot.count == 1)
  precondition(snapshot[0].level == nil && snapshot[0].left == nil && snapshot[0].right == nil && snapshot[0].caseLevel == nil)

  // 4. A usable address is authoritative; a mismatch never falls back to the same name.
  let sameName = [
   BluetoothInfo.Device(name: "Shared", address: "AA:BB:CC:DD:EE:11", level: nil, left: nil, right: nil, caseLevel: nil, productID: 0x200e),
   BluetoothInfo.Device(name: "Shared", address: "AA:BB:CC:DD:EE:12", level: nil, left: nil, right: nil, caseLevel: nil, productID: 0x201b)]
  precondition(BluetoothInfo.matchingDevice(sameName, address: "AA:BB:CC:DD:EE:12", name: "Shared")?.productID == 0x201b)
  precondition(BluetoothInfo.matchingDevice(sameName, address: "AA:BB:CC:DD:EE:13", name: "Shared") == nil)
  precondition(BluetoothInfo.matchingDevice(sameName, address: nil, name: "Shared") == nil)
  let uniqueName = [BluetoothInfo.Device(name: "Only One", address: nil, level: nil, left: nil, right: nil, caseLevel: nil, productID: 0x200e)]
  precondition(BluetoothInfo.matchingDevice(uniqueName, address: nil, name: "only one")?.productID == 0x200e)

  // 5. Dedupe only by a usable address: same-named address-less records stay ambiguous.
  let ambiguous = BluetoothInfo.deduplicated([
   BluetoothInfo.Device(name: "Twins", address: nil, level: nil, left: nil, right: nil, caseLevel: nil, productID: 0x200e),
   BluetoothInfo.Device(name: "Twins", address: nil, level: nil, left: nil, right: nil, caseLevel: nil, productID: 0x201b)])
  precondition(ambiguous.count == 2)
  precondition(BluetoothInfo.matchingDevice(ambiguous, address: nil, name: "Twins") == nil)
  let merged = BluetoothInfo.deduplicated([
   BluetoothInfo.Device(name: "Merged", address: "AA:BB:CC:DD:EE:21", level: 10, left: nil, right: nil, caseLevel: nil, productID: nil),
   BluetoothInfo.Device(name: "Merged", address: "aa-bb-cc-dd-ee-21", level: 20, left: nil, right: nil, caseLevel: nil, productID: 0x201b)])
  precondition(merged.count == 1 && merged[0].level == 10 && merged[0].productID == 0x201b)
  // Address-less records are not cached and cannot pollute a unique name match.
  let boundary = BluetoothArtworkCache()
  boundary.store(ambiguous)
  precondition(boundary.snapshot().isEmpty)
  precondition(boundary.match(address: nil, name: "Twins") == nil)

  // 6. Model/artwork lookups: direct resource, 0x201B alias, and case artwork.
  precondition(BluetoothInfo.symbol(named: "My Headphones") == "headphones")
  precondition(BluetoothInfo.symbol(forProductID: 0x200e) == "airpodspro")
  precondition(BluetoothInfo.symbol(forProductID: 0x201b) == "airpods")
  precondition(ProductSpin.url(productID: 0x200e)?.path.contains("Banner-PID-8206") == true)
  precondition(ProductSpin.url(productID: 0x201b)?.path.contains("Banner-PID-8217") == true)
  precondition(ProductSpin.url(productID: 0x201b, caseArtwork: true)?.path.contains("Banner-PID-8217-Case") == true)

  // 7. The production audio path takes the cached spin and PID, and stays compact.
  BluetoothArtworkCache.shared.store([BluetoothInfo.Device(name: "Cached User Name", address: "AA:BB:CC:DD:EE:31", level: 90, left: 90, right: 80, caseLevel: 70, productID: 0x200e)])
  let hub = UnifiedActivities(observeSystem: false)
  hub.announceHeadphones(name: "Cached User Name", address: "AA:BB:CC:DD:EE:31")
  let alert = hub.headphoneAlert!
  precondition(alert.symbol == "airpodspro")
  precondition(alert.spin != nil && alert.caseSpin != nil)
  precondition(alert.awaitingBattery == false && alert.artworkLoading == false)
  precondition(alert.battery == nil)
  precondition(alert.isBanner == false)
  precondition(hub.primary?.detail == "已连接 · 正在用于音频输出")

  // 8. A verified wear cue keeps its ID and spin when audio connects.
  let wearHub = UnifiedActivities(observeSystem: false)
  let worn = AirPodsProximity(productID: 0x2014, left: 80, right: 70, caseLevel: 60, lidOpen: false, lidCounter: 0, leftInEar: true, rightInEar: true)
  wearHub.announceWearing(worn, name: "Worn Test")
  let wearID = wearHub.headphoneAlert!.id
  let wearSpin = wearHub.headphoneAlert!.spin
  precondition(wearSpin != nil)
  wearHub.announceHeadphones(name: "Worn Test")
  precondition(wearHub.headphoneAlert?.id == wearID)
  precondition(wearHub.headphoneAlert?.spin == wearSpin)
  precondition(wearHub.headphoneAlert?.isBanner == false)
  precondition(wearHub.headphoneAlert?.isWearing == true)

  // 9. Stale lookup results and finish signals are rejected; the current cue still accepts them.
  let staleHub = UnifiedActivities(observeSystem: false)
  staleHub.announceHeadphones(name: "Old Cue")
  let old = staleHub.headphoneAlert!
  staleHub.announceHeadphones(name: "New Cue")
  let new = staleHub.headphoneAlert!
  precondition(old.id != new.id)
  let staleResult = BluetoothInfo.Device(name: "Old Cue", address: "AA:BB:CC:DD:EE:41", level: 42, left: 42, right: 43, caseLevel: nil, productID: 0x200e)
  precondition(staleHub.applyHeadphoneLookup(staleResult, spin: ProductSpin.url(productID: 0x200e), cueID: old.id) == false)
  precondition(staleHub.headphoneAlert?.battery == nil && staleHub.headphoneAlert?.symbol == "headphones")
  precondition(staleHub.finishHeadphoneLookup(cueID: old.id) == false)
  precondition(staleHub.headphoneAlert?.awaitingBattery == false && staleHub.headphoneAlert?.artworkLoading == false)
  precondition(staleHub.applyHeadphoneLookup(staleResult, spin: ProductSpin.url(productID: 0x200e), cueID: new.id) == true)
  precondition(staleHub.headphoneAlert?.battery == 42 && staleHub.headphoneAlert?.symbol == "airpodspro")
  precondition(staleHub.headphoneAlert?.spin != nil)
  precondition(staleHub.finishHeadphoneLookup(cueID: new.id) == true)

  print("PASS: custom names, disconnected model without stale battery, same-address model backfill, address-authoritative matching, address-less ambiguity, cache without battery, cold/cache artwork, 0x201B alias, cached compact audio cue, wear identity/spin, stale result/finish rejection")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='boring-headphone-artwork-') as folder:
    path = Path(folder)
    (path / 'Check.swift').write_text(model + tests)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(path / 'Check.swift'),
                    str(root / 'boringNotch/components/Notch/DeviceActivity.swift'),
                    str(root / 'boringNotch/components/Notch/AgentConversationHistory.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
