"""Exercise the drop delegate and Finder drag detection with deterministic inputs."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = (root/'boringNotch/ContentView.swift').read_text()
delegate = source[source.index('struct GeneralDropTargetDelegate:'):source.index('\n#Preview')]
detector = (root/'boringNotch/observers/DragDetector.swift').read_text()
file_drag = detector[detector.index('enum ShelfFileDrag {'):detector.index('final class DragDetector')]
monitor = detector[detector.index('final class DragDetector'):]
harness = '''
import SwiftUI
import AppKit
import UniformTypeIdentifiers
protocol DropDelegate {}
struct DropProposal {
    enum Operation { case copy, cancel }
    var operation: Operation
}
struct DropInfo {
    var supported: Bool
    var providers: [NSItemProvider]
    func hasItemsConforming(to types: [UTType]) -> Bool { supported }
    func itemProviders(for types: [UTType]) -> [NSItemProvider] { providers }
}
'''+delegate+file_drag+'''
var targeting = false
var received = 0
let binding = Binding<Bool>(get: { targeting }, set: { targeting = $0 })
let supported = DropInfo(supported: true, providers: [NSItemProvider()])
let unsupported = DropInfo(supported: false, providers: [])
var target = GeneralDropTargetDelegate(isTargeted: binding, enabled: true, receive: { received += $0.count; return !$0.isEmpty })
assert(target.validateDrop(info: supported))
target.dropEntered(info: supported)
assert(targeting)
assert(target.dropUpdated(info: supported)?.operation == .copy)
assert(target.performDrop(info: supported))
assert(received == 1 && !targeting)
assert(!target.performDrop(info: unsupported))
assert(received == 1)
target.enabled = false
target.dropEntered(info: supported)
assert(!targeting)
assert(target.dropUpdated(info: supported)?.operation == .cancel)
assert(!target.performDrop(info: supported))
assert(received == 1)
let testPasteboard = NSPasteboard.withUniqueName()
defer { testPasteboard.releaseGlobally() }
assert(!ShelfFileDrag.containsFiles(testPasteboard))
let sample = URL(fileURLWithPath: "/tmp/潮屿 drag fixture")
assert(testPasteboard.writeObjects([sample as NSURL]))
assert(ShelfFileDrag.containsFiles(testPasteboard))
assert(ShelfFileDrag.fileURLs(from: testPasteboard).map(\\.path) == [sample.path])
testPasteboard.clearContents()
assert(testPasteboard.setPropertyList([sample.path, "relative-name"], forType: ShelfFileDrag.legacyFileNames))
assert(ShelfFileDrag.containsFiles(testPasteboard))
assert(ShelfFileDrag.fileURLs(from: testPasteboard).map(\\.path) == [sample.path])
print("PASS: drop delegate and read-only modern/legacy Finder formats")

enum DragMonitorTest {
    enum EventType: Hashable { case leftMouseDown, leftMouseDragged, leftMouseUp }
    struct NSEvent {
        static var mouseLocation = CGPoint(x: 20, y: 20)
        static var monitors: [EventType: (Self) -> Void] = [:]
        static func addGlobalMonitorForEvents(matching types: [EventType],
                                              handler: @escaping (Self) -> Void) -> Any? {
            for type in types { monitors[type] = handler }
            return types
        }
        static func removeMonitor(_ token: Any) {
            for type in token as! [EventType] { monitors.removeValue(forKey: type) }
        }
        static func send(_ type: EventType) { monitors[type]?(Self()) }
    }
    final class NSPasteboard {
        enum Name { case drag }
        typealias PasteboardType = AppKit.NSPasteboard.PasteboardType
        static let shared = NSPasteboard(name: .drag)
        var changeCount = 0
        var types: [PasteboardType]?
        init(name: Name) {}
    }
    enum ShelfFileDrag {
        static let types: [NSPasteboard.PasteboardType] = [.fileURL]
        static func containsFiles(_ pasteboard: NSPasteboard) -> Bool {
            pasteboard.types?.contains(.fileURL) == true
        }
    }
''' + monitor.replace('NSPasteboard(name: .drag)', 'NSPasteboard.shared') + '''
    static func run() {
        let detector = DragDetector(notchRegion: CGRect(x: 0, y: 0, width: 50, height: 50))
        var changes: [Bool] = []
        detector.onFileDragChanged = { changes.append($0) }
        detector.startMonitoring()
        NSEvent.send(.leftMouseDown)
        NSEvent.send(.leftMouseDragged)
        assert(changes.isEmpty)
        NSPasteboard.shared.changeCount += 1
        NSPasteboard.shared.types = [.fileURL]
        NSEvent.send(.leftMouseDragged)
        assert(changes == [true])
        NSEvent.mouseLocation = CGPoint(x: 100, y: 100)
        NSPasteboard.shared.changeCount += 1
        NSPasteboard.shared.types = nil
        NSEvent.send(.leftMouseDragged)
        NSPasteboard.shared.types = [.fileURL]
        NSEvent.send(.leftMouseDragged)
        assert(changes == [true])
        NSEvent.send(.leftMouseUp)
        NSEvent.send(.leftMouseDragged)
        assert(changes == [true, false])
        NSEvent.send(.leftMouseDown)
        NSPasteboard.shared.changeCount += 1
        NSEvent.send(.leftMouseDragged)
        NSEvent.send(.leftMouseUp)
        assert(changes == [true, false, true, false])
        detector.stopMonitoring()
    }
}
DragMonitorTest.run()
print("PASS: Finder drag stays active across pasteboard changes and ends once on mouse-up")
'''
with tempfile.TemporaryDirectory() as d:
    p=Path(d); (p/'check.swift').write_text(harness)
    subprocess.run(['xcrun','swiftc',str(p/'check.swift'),'-o',str(p/'check')],check=True)
    subprocess.run([str(p/'check')],check=True)
