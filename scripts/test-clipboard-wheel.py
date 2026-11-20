"""Production wheel offset plus native clip-view behavior, without event injection."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'boringNotch/components/Clipboard/ClipboardHistoryView.swift').read_text()
geometry = source[source.index('enum ClipboardWheelNavigation {'):source.index('\nprivate struct ClipboardWheelScrollBridge:')]
harness = 'import AppKit\n' + geometry + '''
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 92))
scroll.hasHorizontalScroller = false
scroll.hasVerticalScroller = false
let document = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 92))
scroll.documentView = document
let marker = NSView(frame: document.bounds)
document.addSubview(marker)
assert(marker.enclosingScrollView === scroll)
let clip = scroll.contentView
let maximum = document.bounds.maxX - clip.bounds.width
func move(_ delta: CGFloat, precise: Bool) -> CGFloat {
    let x = ClipboardWheelNavigation.targetX(current: clip.bounds.minX, deltaY: delta,
        precise: precise, minimum: document.bounds.minX, maximum: maximum)!
    clip.scroll(to: NSPoint(x: x, y: clip.bounds.minY))
    scroll.reflectScrolledClipView(clip)
    return clip.bounds.minX
}
assert(move(-3, precise: false) == 36)
assert(move(1, precise: false) == 24)
assert(move(-0.5, precise: true) == 24.5)
assert(ClipboardWheelNavigation.targetX(current: 590, deltaY: -10, precise: false, minimum: 0, maximum: 600) == 600)
assert(ClipboardWheelNavigation.targetX(current: 4, deltaY: 10, precise: false, minimum: 0, maximum: 600) == 0)
assert(ClipboardWheelNavigation.targetX(current: 0, deltaY: .nan, precise: false, minimum: 0, maximum: 600) == nil)
assert(ClipboardWheelNavigation.targetX(current: 0, deltaY: -1, precise: false, minimum: 0, maximum: 0) == nil)
assert(ClipboardWheelNavigation.targetX(current: 0, deltaY: 0, precise: true, minimum: 0, maximum: 600) == nil)
print("PASS: native clip scrolling, wheel directions, precise deltas, bounds, invalid inputs and enclosing scroll view; no pasteboard writes or events posted")
'''
with tempfile.TemporaryDirectory(prefix='notch-clipboard-wheel-') as directory:
    directory = Path(directory)
    (directory / 'main.swift').write_text(harness)
    subprocess.run(['xcrun', 'swiftc', str(directory / 'main.swift'), '-o', str(directory / 'test')], check=True)
    subprocess.run([str(directory / 'test')], check=True)
