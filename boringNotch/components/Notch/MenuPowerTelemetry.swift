import Foundation
import IOKit

// SMC reader adapted from PowerFlow by Dylan (MIT). See THIRD_PARTY/PowerFlow.
private final class MenuSMCReader {
    private var connection: io_connect_t = 0

    init?() {
        guard Self.open(&connection) else { return nil }
    }

    private static func open(_ conn: inout io_connect_t) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        var handle: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &handle) == kIOReturnSuccess else { return false }
        conn = handle
        return true
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// Read a four-character key as a Double, or nil if the key is absent or
    /// carries a type this reader does not decode.
    func double(_ key: String) -> Double? {
        guard let info = keyInfo(key) else { return nil }
        var input = ParamStruct()
        input.key = Self.code(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Self.readBytes
        guard var output = call(input) else { return nil }
        return Self.decode(&output, type: info.dataType, size: Int(info.dataSize))
    }

    private static let readBytes: UInt8 = 5
    private static let readKeyInfo: UInt8 = 9

    private func keyInfo(_ key: String) -> KeyInfo? {
        var input = ParamStruct()
        input.key = Self.code(key)
        input.data8 = Self.readKeyInfo
        guard let out = call(input), out.result == 0 else { return nil }
        return out.keyInfo
    }

    private func call(_ input: ParamStruct) -> ParamStruct? {
        var input = input
        // A fresh, zeroed output every time: reusing a buffer here is how a
        // failed read silently returns the previous key's payload.
        var output = ParamStruct()
        var outSize = MemoryLayout<ParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection, 2, &input, MemoryLayout<ParamStruct>.stride, &output, &outSize
        )
        // The SMC zeroes the key field in its reply, so there is nothing to
        // echo-check; a non-zero `result` is the only failure signal.
        guard result == kIOReturnSuccess,
              output.result == 0,
              outSize == MemoryLayout<ParamStruct>.stride
        else { return nil }
        return output
    }

    /// Four-character codes are packed big-endian into a UInt32.
    private static func code(_ key: String) -> UInt32 {
        var v: UInt32 = 0
        for ch in key.utf8.prefix(4) { v = (v << 8) | UInt32(ch) }
        return v
    }

    private static func typeName(_ type: UInt32) -> String {
        String(bytes: [
            UInt8((type >> 24) & 0xFF), UInt8((type >> 16) & 0xFF),
            UInt8((type >> 8) & 0xFF), UInt8(type & 0xFF),
        ], encoding: .ascii) ?? ""
    }

    private static func decode(_ out: inout ParamStruct, type: UInt32, size: Int) -> Double? {
        let bytes: [UInt8] = withUnsafeBytes(of: &out.bytes) { raw in
            let b = raw.bindMemory(to: UInt8.self)
            return (0..<min(size, 32)).map { b[$0] }
        }
        return decode(bytes: bytes, type: typeName(type))
    }

    /// Decodes one SMC payload.
    ///
    /// Split out as a pure function partly so it can be tested, and partly
    /// because the chained shift-and-or expressions it replaces took the
    /// type checker past its limit on some toolchains. Each step is now
    /// explicitly typed.
    ///
    /// Integer types are **little-endian** on Apple silicon, established by
    /// cross-checking two keys against IORegistry: `B0AV` reads 13227 mV that
    /// way against a pack voltage of 13228, and `B0CT` reads 23 against a cycle
    /// count of 23. Big-endian gives nonsense for both.
    static func decode(bytes b: [UInt8], type: String) -> Double? {
        switch type {
        case "flt ":
            guard b.count >= 4 else { return nil }
            var bits = UInt32(b[3])
            bits = (bits << 8) | UInt32(b[2])
            bits = (bits << 8) | UInt32(b[1])
            bits = (bits << 8) | UInt32(b[0])
            return Double(Float(bitPattern: bits))

        case "ui8 ":
            guard let first = b.first else { return nil }
            return Double(first)

        case "ui16":
            guard b.count >= 2 else { return nil }
            let low = UInt16(b[0])
            let high = UInt16(b[1]) << 8
            return Double(low | high)

        case "si16":
            guard b.count >= 2 else { return nil }
            let low = UInt16(b[0])
            let high = UInt16(b[1]) << 8
            return Double(Int16(bitPattern: low | high))

        case "ui32":
            guard b.count >= 4 else { return nil }
            var value = UInt32(b[3])
            value = (value << 8) | UInt32(b[2])
            value = (value << 8) | UInt32(b[1])
            value = (value << 8) | UInt32(b[0])
            return Double(value)

        case "sp78":
            // Signed fixed point, big-endian: 7 integer bits and 8 fractional.
            guard b.count >= 2 else { return nil }
            let high = UInt16(b[0]) << 8
            let raw = Int16(bitPattern: high | UInt16(b[1]))
            return Double(raw) / 256

        default:
            return nil
        }
    }

    // MARK: - the AppleSMC user-client structures

    private struct Version {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimitData {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
    }

    fileprivate struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private struct ParamStruct {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }
}

struct MenuPowerSample: Equatable, Sendable {
    let adapter: Double?
    let battery: Double?
    let system: Double?
    let pluggedIn: Bool
    let isLive: Bool

    struct Flow: Equatable {
        let fromAdapter: Double
        let toSystem: Double
        let toBattery: Double

        var hasFlow: Bool { fromAdapter > 0 || toSystem > 0 || toBattery != 0 }
    }

    var flow: Flow {
        func activeWatts(_ value: Double?) -> Double {
            guard let value, value.isFinite, abs(value) >= 0.15 else { return 0 }
            return value
        }
        let batteryFlow = activeWatts(battery)
        return Flow(fromAdapter: pluggedIn ? max(0, activeWatts(adapter)) : 0,
                    toSystem: max(0, activeWatts(system)),
                    toBattery: pluggedIn ? batteryFlow : min(0, batteryFlow))
    }
}

actor MenuPowerTelemetry {
    private let smc = MenuSMCReader()

    func read() -> MenuPowerSample? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        guard let pluggedIn = property("ExternalConnected") as? Bool else { return nil }
        if let smc,
           let current = smc.double("B0AC"), current.isFinite, abs(current) < 30_000,
           let voltage = smc.double("B0AV"), (5_000...25_000).contains(voltage) {
            let battery = abs(current) < 10 ? 0 : current * voltage / 1_000_000
            let input = pluggedIn ? smc.double("PDTR") : 0
            if let input, (0...300).contains(input), input - battery >= -0.5 {
                return MenuPowerSample(adapter: input, battery: battery,
                                       system: max(0, input - battery), pluggedIn: pluggedIn, isLive: true)
            }
        }

        let telemetry = property("PowerTelemetryData") as? [String: NSNumber] ?? [:]
        func watts(_ key: String) -> Double? {
            guard let raw = telemetry[key] else { return nil }
            // IOKit can expose signed milliwatts as an unsigned 64-bit CFNumber.
            let value = Double(raw.int64Value) / 1_000
            return (-300...300).contains(value) ? value : nil
        }
        let adapter = pluggedIn ? watts("SystemPowerIn").flatMap { $0 >= 0 ? $0 : nil } : 0
        let system = watts("SystemLoad").flatMap { $0 >= 0 ? $0 : nil }
        return MenuPowerSample(adapter: adapter, battery: watts("BatteryPower"), system: system,
                               pluggedIn: pluggedIn, isLive: false)
    }
}

struct MenuMemorySnapshot: Identifiable {
    enum Pressure: Int32 {
        case normal = 1, warning = 2, critical = 4, unknown = 0

        var label: String {
            switch self {
            case .normal: "压力正常"
            case .warning: "压力偏高"
            case .critical: "压力过高"
            case .unknown: "压力未知"
            }
        }
    }

    var id: Date { date }
    let date: Date
    let used: Double
    let total: Double
    let pressure: Pressure

    static func read() -> Self? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { buffer in
            buffer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard status == KERN_SUCCESS, total > 0 else { return nil }

        // Anonymous resident pages, wired memory and physical compressor pages.
        // Purgeable pages can be reclaimed, so exclude them from used memory.
        let anonymous = max(0, Double(info.internal_page_count) - Double(info.purgeable_count))
        let pages = anonymous + Double(info.wire_count) + Double(info.compressor_page_count)
        let used = min(total, pages * Double(vm_kernel_page_size))

        var pressure: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let pressureStatus = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
        return Self(date: Date(), used: used, total: total,
                    pressure: pressureStatus == 0 ? Pressure(rawValue: pressure) ?? .unknown : .unknown)
    }
}
