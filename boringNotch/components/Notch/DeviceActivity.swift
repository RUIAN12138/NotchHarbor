// Adapted from VendavalSC/Shima, Sources/Shima/DeviceActivity.swift, GPL-3.0.
// See THIRD_PARTY/Shima/NOTICE.md and LICENSE.
import AVFoundation
import AppKit
import SwiftUI

/// An audio device cue or the latest battery report for the active audio route.
struct DeviceAlert: Equatable {
    /// Corrected from the product ID once the system lookup resolves it.
    var symbol: String
    let name: String
    var productID: Int?
    /// 0...100, once known. For AirPods, the lower of the two buds.
    var battery: Int?
    var leftBattery: Int?
    var rightBattery: Int?
    var caseBattery: Int?
    var leftCharging: Bool?
    var rightCharging: Bool?
    var caseCharging: Bool?
    /// Still asking for the battery level (Bluetooth devices report it a moment after connecting).
    var status = "已连接"
    var approximateBattery = false
    var awaitingBattery = false
    /// A lookup is running for the artwork. Keep the layout, but do not flash a stale SF symbol.
    var artworkLoading = false
    /// The system's own spinning video of the product, when it has one; otherwise `symbol` shows.
    var spin: URL?
    var caseSpin: URL?
    /// Showing the banner rather than the wings.
    var isBanner = true
    var isWearing = false
    var isPreview = false
    let id = UUID()

    var isAirPods: Bool { symbol.hasPrefix("airpods") }
}

/// What System Information knows about connected Bluetooth headphones: the battery level and the
/// product. Availability and response time depend on the device and system permissions.
enum BluetoothInfo {
    struct Device {
        let name: String
        let address: String?
        let level: Int?
        let left: Int?
        let right: Int?
        let caseLevel: Int?
        let productID: Int?
        /// Resolved off the main thread along with the rest.
        var spin: URL? { productID.flatMap { ProductSpin.url(productID: $0) } }
    }

    struct Report {
        /// Devices the system currently lists as connected. Only these may carry a battery level.
        let connected: [Device]
        /// Name, address and model from both lists, with every battery level cleared. Some
        /// custom-named headphones report their model only while disconnected.
        let metadata: [Device]
    }

    /// Parses a `system_profiler SPBluetoothDataType -json` report. Pure, so the production
    /// path and the regression tests share exactly the same rules.
    static func parseReport(_ data: Data) -> Report {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else {
            return Report(connected: [], metadata: [])
        }
        let connectedRecords = controllers.flatMap { records($0["device_connected"]) }
        let disconnectedRecords = controllers.flatMap { records($0["device_not_connected"]) }

        // A connected record can omit the product ID while the same address reports it in the
        // disconnected list. The model may be shared; the battery level may not.
        var modelByAddress: [String: Int] = [:]
        for record in disconnectedRecords + connectedRecords {
            guard let key = normalizedAddress(record.address), let product = productID(record.info) else { continue }
            modelByAddress[key] = modelByAddress[key] ?? product
        }

        let connected = deduplicated(connectedRecords.map { record in
            Device(name: record.name, address: record.address, level: level(record.info),
                   left: percent(record.info["device_batteryLevelLeft"]),
                   right: percent(record.info["device_batteryLevelRight"]),
                   caseLevel: percent(record.info["device_batteryLevelCase"]),
                   productID: productID(record.info)
                       ?? normalizedAddress(record.address).flatMap { modelByAddress[$0] })
        })
        let metadata = deduplicated((connectedRecords + disconnectedRecords).map { record in
            Device(name: record.name, address: record.address, level: nil, left: nil, right: nil, caseLevel: nil,
                   productID: productID(record.info)
                       ?? normalizedAddress(record.address).flatMap { modelByAddress[$0] })
        })
        return Report(connected: connected, metadata: metadata)
    }

    /// Picks the device for a lookup. A usable address is authoritative and never falls back to
    /// a name; without one only an unambiguous name match is accepted.
    static func matchingDevice(_ devices: [Device], address: String?, name: String) -> Device? {
        if let address = normalizedAddress(address) {
            return devices.first { normalizedAddress($0.address) == address }
        }
        let matches = devices.filter {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Resolves a lookup from a fresh report and the artwork cache. Battery levels come only from
    /// the connected list; the model, and with it the artwork, may also come from the metadata
    /// list or the cache. A cold start therefore still finds the model of a custom-named device
    /// that the system reports only while disconnected.
    static func resolve(_ report: Report, address: String?, name: String,
                        cache: BluetoothArtworkCache = .shared) -> Device? {
        if let connected = matchingDevice(report.connected, address: address, name: name) {
            guard connected.productID == nil else { return connected }
            let model = matchingDevice(report.metadata, address: address, name: name)?.productID
                ?? cache.match(address: address, name: name)?.productID
            guard let model else { return connected }
            return Device(name: connected.name, address: connected.address, level: connected.level,
                          left: connected.left, right: connected.right, caseLevel: connected.caseLevel,
                          productID: model)
        }
        guard let match = matchingDevice(report.metadata, address: address, name: name)
                ?? cache.match(address: address, name: name) else { return nil }
        // Metadata and cache describe identity and artwork only; their battery levels are stale.
        return metadataOnly([match])[0]
    }

    /// Name-based classification, used until a reliable product ID arrives.
    static func symbol(named name: String) -> String {
        let lower = name.lowercased()
        guard lower.contains("airpods") else { return "headphones" }
        return lower.contains("max") ? "airpodsmax" : lower.contains("pro") ? "airpodspro" : "airpods"
    }

    /// Model classification from the system's product ID, which also works after a rename.
    static func symbol(forProductID productID: Int) -> String? {
        switch productID {
        case 0x200e, 0x2014, 0x2024, 0x2027: return "airpodspro"
        case 0x2002, 0x200f, 0x2013, 0x2019, 0x201b: return "airpods"
        default: return nil
        }
    }

    /// Reads the report and refreshes the metadata cache; `completion` runs on the main thread.
    /// The same `resolve` as the tests drives this path, including metadata-only cold starts.
    static func lookup(address: String?, name: String, completion: @escaping (Device?, URL?) -> Void) {
        reportQueue.async {
            let report = readReport()
            BluetoothArtworkCache.shared.store(report.metadata)
            let device = resolve(report, address: address, name: name)
            // Resolve the movie off the main thread along with the report.
            let spin = device?.spin
            DispatchQueue.main.async { completion(device, spin) }
        }
    }

    /// Warms the artwork metadata once, in the background, when system observation starts.
    static func warmArtworkCacheOnce() {
        warmLock.lock()
        let shouldWarm = !warmedCache
        warmedCache = true
        warmLock.unlock()
        guard shouldWarm else { return }
        reportQueue.async {
            BluetoothArtworkCache.shared.store(readReport().metadata)
        }
    }

    // Serial: system_profiler is expensive, so warming and real lookups never overlap.
    private static let reportQueue = DispatchQueue(label: "local.boringnotch.bluetooth-report", qos: .utility)
    private static let warmLock = NSLock()
    private static var warmedCache = false

    private static func readReport() -> Report {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        // The full report: the quicker "mini" one leaves out connected devices' product IDs.
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return Report(connected: [], metadata: []) }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseReport(data)
    }

    private static func records(_ value: Any?) -> [(name: String, address: String?, info: [String: Any])] {
        guard let groups = value as? [[String: Any]] else { return [] }
        return groups.flatMap { group in
            group.compactMap { name, raw -> (name: String, address: String?, info: [String: Any])? in
                guard let info = raw as? [String: Any] else { return nil }
                return (name: name, address: (info["device_address"] as? String)?.uppercased(), info: info)
            }
        }
    }

    /// Drops duplicate addresses, keeping the first record's battery and the first known model.
    /// A missing address is not an identity: same-named devices stay separate so that name
    /// matching remains ambiguous instead of silently picking one of them.
    static func deduplicated(_ devices: [Device]) -> [Device] {
        var result: [Device] = []
        var indexByAddress: [String: Int] = [:]
        for device in devices {
            guard let key = normalizedAddress(device.address) else {
                result.append(device)
                continue
            }
            if let index = indexByAddress[key] {
                let existing = result[index]
                result[index] = Device(name: existing.name, address: existing.address,
                                       level: existing.level, left: existing.left, right: existing.right,
                                       caseLevel: existing.caseLevel, productID: existing.productID ?? device.productID)
            } else {
                indexByAddress[key] = result.count
                result.append(device)
            }
        }
        return result
    }

    static func metadataOnly(_ devices: [Device]) -> [Device] {
        devices.map {
            Device(name: $0.name, address: $0.address, level: nil, left: nil, right: nil, caseLevel: nil,
                   productID: $0.productID)
        }
    }

    static func normalizeAddress(_ value: String) -> String {
        value.uppercased().filter { $0.isHexDigit }
    }
    /// A usable address is exactly one 12-digit hardware address.
    static func normalizedAddress(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalizeAddress(value)
        return normalized.count == 12 ? normalized : nil
    }
    static func productID(_ info: [String: Any]) -> Int? {
        (info["device_productID"] as? String).flatMap(hex) ?? (info["device_productID"] as? NSNumber)?.intValue
    }
    static func address(fromAudioUID uid: String?) -> String? {
        guard let uid else { return nil }
        let pattern = #"^[0-9A-Fa-f]{2}(?:[-:][0-9A-Fa-f]{2}){5}|^[0-9A-Fa-f]{12}(?=[:_\-]|$)"#
        guard let range = uid.range(of: pattern, options: .regularExpression) else { return nil }
        return normalizeAddress(String(uid[range]))
    }

    static func percent(_ value: Any?) -> Int? {
        let result: Int?
        if let text = value as? String { result = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
        else { result = (value as? NSNumber)?.intValue }
        return result.flatMap { (0...100).contains($0) ? $0 : nil }
    }
    private static func level(_ info: [String: Any]) -> Int? {
        let buds = [percent(info["device_batteryLevelLeft"]), percent(info["device_batteryLevelRight"])].compactMap { $0 }
        return buds.min() ?? percent(info["device_batteryLevelMain"])
    }

    static func hex(_ string: String) -> Int? {
        Int(string.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16)
    }
}

/// Bounded, in-memory artwork metadata. It keeps names, addresses and product IDs only; a cached
/// battery level could be stale, so every level is cleared before storing.
final class BluetoothArtworkCache {
    static let shared = BluetoothArtworkCache()
    private let lock = NSLock()
    private var entries: [BluetoothInfo.Device] = []
    private let limit = 16

    func store(_ devices: [BluetoothInfo.Device]) {
        // Without a usable address a name is not a reliable identity. Dropping those records
        // keeps the bounded cache from piling up duplicates or making a unique name look ambiguous.
        let addressed = devices.filter { BluetoothInfo.normalizedAddress($0.address) != nil }
        let incoming = BluetoothInfo.metadataOnly(addressed)
        lock.lock()
        defer { lock.unlock() }
        entries = Array(BluetoothInfo.deduplicated(incoming + entries).prefix(limit))
    }

    func match(address: String?, name: String) -> BluetoothInfo.Device? {
        lock.lock()
        defer { lock.unlock() }
        return BluetoothInfo.matchingDevice(entries, address: address, name: name)
    }

    func snapshot() -> [BluetoothInfo.Device] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

/// The spinning product videos macOS shows when AirPods or Beats connect: one transparent loop per
/// model, part of the system. Shima plays them from where they are; nothing is copied.
enum ProductSpin {
    private static let movies = URL(fileURLWithPath: "/System/Library/CoreServices/BluetoothUIService.app/Contents/Resources")
    private static let assetPaths = URL(fileURLWithPath:
        "/System/Library/PrivateFrameworks/CoreBluetoothUI.framework/Versions/A/Resources")

    static func url(productID: Int, caseArtwork: Bool = false) -> URL? {
        if let url = loop(for: productID, caseArtwork: caseArtwork) { return url }
        // A newer revision (USB-C rather than Lightning, say) may share an older one's artwork,
        // and with it the loop.
        guard let image = imageNames[productID] else { return nil }
        for (other, name) in imageNames.sorted(by: { $0.key < $1.key }) where name == image && other != productID {
            if let url = loop(for: other, caseArtwork: caseArtwork) { return url }
        }
        return nil
    }

    private static func loop(for productID: Int, caseArtwork: Bool) -> URL? {
        let suffix = caseArtwork ? "-Case" : ""
        let folder = movies.appendingPathComponent("Banner-PID-\(productID)\(suffix)-mov")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let preferred = ["Banner-PID-\(productID)\(suffix)-Loop.mov", "Banner-PID-\(productID)-default\(suffix)-Loop.mov"]
        let name = preferred.first(where: files.contains) ?? files.sorted().first { $0.hasSuffix("-Loop.mov") }
        return name.map { folder.appendingPathComponent($0) }
    }

    /// Product ID → artwork name, from the system's table of Bluetooth product images.
    private static let imageNames: [Int: String] = {
        var names: [Int: String] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: assetPaths.path)) ?? []
        for file in files where file.hasPrefix("AssetPaths") && file.hasSuffix(".plist") {
            guard let table = NSDictionary(contentsOf: assetPaths.appendingPathComponent(file)) as? [String: Any] else { continue }
            for (key, value) in table {
                guard let id = BluetoothInfo.hex(key), let image = (value as? [String: Any])?["ImageName"] as? String else { continue }
                names[id] = names[id] ?? image
            }
        }
        return names
    }()
}

/// The product: its spinning video when the system has one, its symbol otherwise.
struct DeviceArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let alert: DeviceAlert
    let size: CGFloat
    var caseArtwork = false

    var body: some View {
        if let spin = caseArtwork ? alert.caseSpin : alert.spin, !reduceMotion {
            LoopingVideo(url: spin)
                .frame(width: size, height: size)
        } else if alert.artworkLoading && !reduceMotion {
            // Keep the footprint while the system lookup runs, without flashing a stale glyph.
            Color.clear.frame(width: size, height: size)
        } else {
            Image(systemName: caseArtwork ? "airpods.chargingcase" : alert.symbol)
                .font(.system(size: size * 0.55, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
        }
    }
}

/// A silent, transparent video on a loop, decoded by the hardware; it stops when it leaves the screen.
struct LoopingVideo: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LoopingVideoView { LoopingVideoView(url: url) }
    func updateNSView(_ view: LoopingVideoView, context: Context) { view.update(url: url) }
    static func dismantleNSView(_ view: LoopingVideoView, coordinator: ()) { view.stop() }
}

final class LoopingVideoView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var currentURL: URL?

    init(url: URL) {
        super.init(frame: .zero)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = .clear
        self.layer = layer
        wantsLayer = true
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        update(url: url)
    }

    func update(url: URL) {
        guard currentURL != url else { return }
        stop()
        currentURL = url
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }

    required init?(coder: NSCoder) { nil }

    func stop() {
        currentURL = nil
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}


/// iOS-style device glyph inside the ring, with a separate value beneath it.
// Ring geometry adapted from Shima/IslandViews.swift BatteryRing (GPL-3.0).
// User reference: blank center except for a centered charging bolt; value below.
struct HeadphoneBatteryRing: View {
    let level: Int?
    var approximate = false
    var size: CGFloat = 48
    var label = "耳机"
    var showsValue = true
    var charging: Bool? = nil
    private var value: String { level.map { "\($0)%" } ?? "—" }
    private var stroke: CGFloat { size * 0.09 }
    var body: some View {
        VStack(spacing: size * 0.18) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.16), lineWidth: stroke)
                if let level {
                    Circle().trim(from: 0, to: CGFloat(min(100, max(0, level))) / 100)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if charging == true {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: size * 0.40, weight: .regular))
                        .foregroundStyle(.green)
                }
            }.padding(stroke / 2).frame(width: size, height: size)
            if showsValue {
                Text(value).font(.system(size: size * 0.43, weight: .regular))
                    .monospacedDigit().foregroundStyle(.primary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)，" + (level.map { "电量\(approximate ? "约" : "")\($0)%" } ?? "电量暂不可用") + (charging == true ? "，正在充电" : ""))
    }
}

/// Two distinct system product movies: earbuds on the left, case on the right.
struct HeadphoneConnectionCard: View {
    let alert: DeviceAlert
    var compact = false
    private var artSize: CGFloat { compact ? 50 : 30 }
    private var hasCase: Bool { ["airpods", "airpodspro"].contains(alert.symbol) }
    var body: some View {
        VStack(spacing: 4) {
            Text(alert.name).font(.headline).lineLimit(1).frame(maxWidth: .infinity)
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 4) {
                    DeviceArt(alert: alert, size: artSize)
                    HeadphoneBatteryRing(level: alert.battery, approximate: alert.approximateBattery,
                                         size: compact ? 30 : 26, label: "耳机",
                                         charging: alert.leftCharging == true || alert.rightCharging == true)
                }.frame(maxWidth: .infinity)
                if hasCase {
                    VStack(spacing: 4) {
                        DeviceArt(alert: alert, size: artSize, caseArtwork: true)
                        HeadphoneBatteryRing(level: alert.caseBattery, approximate: alert.approximateBattery,
                                             size: compact ? 30 : 26, label: "充电盒", charging: alert.caseCharging)
                    }.frame(maxWidth: .infinity)
                }
            }
            if alert.isPreview {
                Text("模拟预览").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
    }
}

// Proximity decoding adapted from apple-ble, MIT; see THIRD_PARTY/apple-ble.
struct AirPodsProximity {
    let productID: Int
    let left: Int?
    let right: Int?
    let caseLevel: Int?
    let lidOpen: Bool?
    let lidCounter: UInt8
    var leftCharging: Bool? = nil
    var rightCharging: Bool? = nil
    var caseCharging: Bool? = nil
    var leftInEar = false
    var rightInEar = false
    var modelName: String {
        [0x2002: "AirPods", 0x200f: "AirPods 2", 0x2013: "AirPods 3",
         0x200e: "AirPods Pro", 0x2014: "AirPods Pro 2", 0x2024: "AirPods Pro 2",
         0x2019: "AirPods 4", 0x201b: "AirPods 4", 0x2027: "AirPods Pro 3"][productID] ?? "AirPods"
    }
    static func parse(_ manufacturerData: Data) -> Self? {
        let bytes = Array(manufacturerData)
        guard bytes.count >= 29, bytes[0] == 0x4c, bytes[1] == 0,
              bytes[2] == 0x07, bytes[3] == 0x19 else { return nil }
        let d = Array(bytes.dropFirst(2))
        // Pairing-mode packets have a different layout. Do not interpret them as status.
        guard d[2] == 1 || d[2] == 7 else { return nil }
        let product = Int(d[3]) | Int(d[4]) << 8
        guard [0x2002, 0x200f, 0x2013, 0x200e, 0x2014, 0x2024, 0x2019, 0x201b, 0x2027].contains(product) else { return nil }
        func battery(_ nibble: UInt8) -> Int? { nibble <= 10 ? Int(nibble) * 10 : nil }
        let flipped = d[5] & 0x20 == 0
        let low = battery(d[6] & 0x0f), high = battery(d[6] >> 4)
        let inCase = d[5] & 0x14 != 0
        let swap = flipped != (d[5] & 0x40 != 0)
        return Self(productID: product, left: flipped ? high : low, right: flipped ? low : high,
                    caseLevel: battery(d[7] & 0x0f), lidOpen: inCase ? d[8] & 0x08 == 0 : nil,
                    lidCounter: d[8] & 7,
                    leftCharging: (flipped ? high : low) == nil ? nil : (d[7] >> 4) & (flipped ? 2 : 1) != 0,
                    rightCharging: (flipped ? low : high) == nil ? nil : (d[7] >> 4) & (flipped ? 1 : 2) != 0,
                    caseCharging: battery(d[7] & 0x0f) == nil ? nil : d[7] & 0x40 != 0,
                    leftInEar: d[5] & (swap ? 0x08 : 0x02) != 0,
                    rightInEar: d[5] & (swap ? 0x02 : 0x08) != 0)
    }
}

/// Require two nearby open packets; suppress repeated open states for at least 120 seconds of silence.
struct AirPodsLidGate {
    private struct Seen { var first: TimeInterval; var last: TimeInterval; var emitted: Bool }
    private var states: [String: Seen] = [:]
    mutating func accept(_ packet: AirPodsProximity, rssi: Int, now: TimeInterval, identity: String = "") -> Bool {
        guard (-60 ... -1).contains(rssi), let open = packet.lidOpen else { return false }
        states = states.filter { now - $0.value.last < 120 }
        let key = "\(identity)-\(packet.productID)-\(packet.lidCounter)"
        guard open else { states.removeValue(forKey: key); return false }
        guard var state = states[key] else {
            if states.count >= 128, let oldest = states.min(by: { $0.value.last < $1.value.last })?.key { states.removeValue(forKey: oldest) }
            states[key] = Seen(first: now, last: now, emitted: false)
            return false
        }
        let gap = now - state.last
        state.last = now
        if !state.emitted && gap > 2 { state.first = now }
        let emit = !state.emitted && now - state.first >= 0.15
        if emit { state.emitted = true }
        states[key] = state
        return emit
    }
}

/// Recognize an unworn-to-worn edge only after seeing this peripheral's open case.
/// Initial advertisements from people already wearing earbuds never trigger a cue.
struct AirPodsWearGate {
    private struct State { var last: TimeInterval; var candidate: TimeInterval?; var emitted = false }
    private var states: [UUID: State] = [:]
    mutating func accept(_ packet: AirPodsProximity, identity: UUID, now: TimeInterval) -> Bool {
        states = states.filter { now - $0.value.last < 120 }
        let worn = packet.leftInEar || packet.rightInEar
        guard var state = states[identity] else {
            if packet.lidOpen == true && !worn {
                if states.count >= 64, let oldest = states.min(by: { $0.value.last < $1.value.last })?.key { states.removeValue(forKey: oldest) }
                states[identity] = State(last: now)
            }
            return false
        }
        let gap = now - state.last
        state.last = now
        if !worn { state.candidate = nil; state.emitted = false }
        else if !state.emitted {
            if state.candidate == nil || gap > 2 { state.candidate = now }
            else if now - state.candidate! >= 0.15 {
                state.emitted = true
                states[identity] = state
                return true
            }
        }
        states[identity] = state
        return false
    }
}

import CoreBluetooth

@MainActor
final class AirPodsLidMonitor: NSObject, @preconcurrency CBCentralManagerDelegate {
    private var central: CBCentralManager?
    private var gate = AirPodsLidGate()
    private var wearGate = AirPodsWearGate()
    private var enabled = false
    var onOpen: ((AirPodsProximity, String?, UUID) -> Void)?
    var onUpdate: ((AirPodsProximity, UUID) -> Void)?
    var onWear: ((AirPodsProximity, String?, UUID) -> Void)?
    var onStatus: ((String) -> Void)?

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { wearGate = AirPodsWearGate(); central?.stopScan(); onStatus?("开盖检测已关闭"); return }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else { refresh() }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { refresh() }
    private func refresh() {
        guard enabled, let central else { return }
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            onStatus?("正在检测附近 AirPods 开盖")
        case .unauthorized: onStatus?("请在系统设置 → 隐私与安全性 → 蓝牙中允许 Notch Harbor")
        case .poweredOff: onStatus?("蓝牙已关闭")
        case .unsupported: onStatus?("此设备不支持蓝牙开盖检测")
        default: onStatus?("正在准备蓝牙检测")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard enabled, let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let packet = AirPodsProximity.parse(data), (-60 ... -1).contains(RSSI.intValue) else { return }
        let identity = peripheral.identifier
        let opens = gate.accept(packet, rssi: RSSI.intValue, now: ProcessInfo.processInfo.systemUptime,
                                identity: identity.uuidString)
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        if wearGate.accept(packet, identity: identity, now: ProcessInfo.processInfo.systemUptime) {
            onWear?(packet, name, identity)
        } else if opens {
            onOpen?(packet, name, identity)
        } else {
            onUpdate?(packet, identity)
        }
    }
}
