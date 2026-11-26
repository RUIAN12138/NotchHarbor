//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import Darwin
import ApplicationServices
import IOKit
import CoreGraphics

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {
    @objc func agentInteraction(_ request: Data, with reply: @escaping (Data) -> Void) {
        AgentMessagingService.shared.perform(request, reply: reply)
    }
    
    @objc func pendingCodexApprovals(with reply: @escaping (Data) -> Void) {
        let folder = CodexApprovalPacket.directory
        let pending = CodexApprovalPacket.pending(in: folder)
        for request in pending { request.acknowledge(in: folder) }
        let desktop = CodexDesktopApprovals.shared.pending(home: FileManager.default.homeDirectoryForCurrentUser)
        let online = CodexServerApprovals.shared.pending()
        let panel = CodexDesktopApprovalPanel.shared.pending()
        // Show the actionable panel first while retaining log-only approvals for other sessions.
        reply((try? JSONEncoder().encode(pending + online + panel + desktop)) ?? Data())
    }

    @objc func submitCodexApproval(_ requestID: String, sessionID: String, choice: String,
                                   with reply: @escaping (String) -> Void) {
        let folder = CodexApprovalPacket.directory
        func finish(_ status: CodexApprovalSubmission) { reply(status.rawValue) }
        guard let id = UUID(uuidString: requestID), let session = UUID(uuidString: sessionID),
              let decision = CodexApprovalPacket.Choice(rawValue: choice) else { finish(.notSent); return }
        let live = CodexServerApprovals.shared
        if live.choose(decision, id: id, sessionID: session, onReceipt: { finish($0 ? .confirmed : .unconfirmed) }) {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(5)) {
                live.expireReceipt(id)
            }
            return
        }
        guard let request = CodexApprovalPacket.pending(in: folder).first(where: { $0.id == id && $0.sessionID == session })
        else {
            DispatchQueue.global(qos: .userInitiated).async {
                finish(CodexDesktopApprovalPanel.shared.submit(decision, id: id, session: session,
                    home: FileManager.default.homeDirectoryForCurrentUser))
            }
            return
        }
        do {
            try request.submit(decision, in: folder)
            DispatchQueue.global(qos: .utility).async {
                let deadline = ContinuousClock.now + .seconds(3)
                while ContinuousClock.now < deadline {
                    if request.consumeReceipt(decision, in: folder) { finish(.confirmed); return }
                    Thread.sleep(forTimeInterval: 0.08)
                }
                finish(.unconfirmed)
            }
        } catch {
            finish(.notSent)
        }
    }

    @objc func appMemoryRanking(with reply: @escaping (Data) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            struct Usage: Encodable {
                let path: String
                let bytes: UInt64
            }
            let limit = proc_listallpids(nil, 0)
            guard limit > 0 else { reply(Data()); return }
            var pids = [pid_t](repeating: 0, count: Int(limit) + 128)
            let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            var totals: [String: UInt64] = [:]
            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            for pid in pids.prefix(max(0, Int(count))) where pid > 0 {
                guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0,
                      let path = String(validatingCString: pathBuffer),
                      let bundleEnd = path.range(of: ".app/")?.upperBound else { continue }
                var usage = rusage_info_v4()
                let status = withUnsafeMutablePointer(to: &usage) { pointer in
                    pointer.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                    }
                }
                guard status == 0, usage.ri_phys_footprint > 0 else { continue }
                totals[String(path[..<path.index(before: bundleEnd)]), default: 0] += usage.ri_phys_footprint
            }
            let rows = totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(4)
                .map { Usage(path: $0.key, bytes: $0.value) }
            reply((try? JSONEncoder().encode(rows)) ?? Data())
        }
    }

    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    @objc func requestAccessibilityAuthorization() {
        let options: CFDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        if promptIfNeeded {
            let options: CFDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reply(AXIsProcessTrusted())
        }
    }
    
    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        var isAvailable: Bool { clientInstance != nil }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.isAvailable)
    }

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    @objc func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        var b: Float = 0
        reply(displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) || ioServiceFor(displayID: CGMainDisplayID()) != nil)
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        var b: Float = 0
        if displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        if displayServicesSetBrightness(displayID: CGMainDisplayID(), value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }
}
