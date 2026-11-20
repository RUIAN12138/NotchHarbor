"""Verify the clipboard card in an off-screen AppKit panel without posting mouse events."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'boringNotch/components/Clipboard/ClipboardHistoryView.swift').read_text()
drag = source[source.index('private struct ClipboardCardDragSource<'):source.index('\nprivate struct ClipboardExpandedPreview:')]
swift = '''import SwiftUI
import AppKit
final class ClipboardFileAccessLease { func release() {} }
@MainActor final class ShelfSelectionModel {
    static let shared = ShelfSelectionModel()
    func beginDrag() {}
    func endDrag() {}
}
final class BoringNotchSkyLightWindow: NSPanel { func refreshMouseRouting() {} }
''' + drag + r'''
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let panel = NSPanel(contentRect: NSRect(x: -5000, y: -5000, width: 170, height: 56),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
private typealias CardView = ClipboardCardDragSource<Text>.DragView
private let view = CardView(frame: NSRect(x: 0, y: 0, width: 170, height: 56))
panel.contentView = view
var prepared = 0
var clicks = 0
view.prepareDrag = { whole in
    precondition(whole)
    prepared += 1
    return nil
}
view.onClick = { whole in
    precondition(!whole)
    clicks += 1
}
func event(_ type: NSEvent.EventType, x: CGFloat, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 25), modifierFlags: flags,
                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                     context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
}
precondition(view.hitTest(NSPoint(x: 6, y: 25)) === view)
precondition(view.acceptsFirstMouse(for: event(.leftMouseDown, x: 6)))
view.updatePreview(Text("Test clipboard preview"), animates: false)
let popover = Mirror(reflecting: view).children.first(where: { $0.label == "hoverPopover" })?.value as? NSPopover
precondition(popover?.behavior == .applicationDefined)
panel.orderFrontRegardless()
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
precondition(popover?.isShown == true)
panel.sendEvent(event(.leftMouseDown, x: 6))
panel.sendEvent(event(.leftMouseDragged, x: 7, flags: .option))
precondition(prepared == 0 && clicks == 0)
panel.sendEvent(event(.leftMouseDragged, x: 25, flags: .option))
panel.sendEvent(event(.leftMouseUp, x: 25, flags: .option))
precondition(prepared == 1 && clicks == 0, "first press should prepare one drag and never click")
panel.sendEvent(event(.leftMouseDown, x: 6))
panel.sendEvent(event(.leftMouseUp, x: 6))
precondition(prepared == 1 && clicks == 1, "click should still copy")
view.updatePreview(nil, animates: false)
print("PASS first-press drag and click in a non-key AppKit panel, app-managed hover preview, no pointer injection")
'''
with tempfile.TemporaryDirectory(prefix='harbor-first-press-') as directory:
    src = Path(directory) / 'main.swift'
    executable = Path(directory) / 'test'
    src.write_text(swift)
    subprocess.run(['xcrun', 'swiftc', str(src), '-o', str(executable)], check=True)
    subprocess.run([str(executable)],check=True)
