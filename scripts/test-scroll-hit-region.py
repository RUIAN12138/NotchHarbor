"""Exercise the production AppKit hit region without posting mouse/scroll events."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'boringNotch/extensions/PanGesture.swift').read_text()
region = source[source.index('enum NotchScrollHitRegion {'):source.index('\nprivate struct ScrollMonitor:')]
swipe = source[source.index('struct NotchPageSwipe {'):source.index('\nprivate struct NotchPageSwipeMonitor:')]
activity = (root / 'boringNotch/components/Notch/UnifiedActivities.swift').read_text()
edges = activity.split('// === AGENT_TRANSCRIPT_EDGES_BEGIN ===', 1)[1].split('private struct AgentTranscriptEdgeFade:', 1)[0]
harness = 'import AppKit\n' + region + '\n' + swipe + edges + '''
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let detached = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 32))
// Regression: two nil window references must never qualify.
assert(!NotchScrollHitRegion.contains(eventWindow: nil, locationInWindow: .zero, in: detached))
let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 538, height: 520),
                      styleMask: [.borderless], backing: .buffered, defer: false)
let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 538, height: 520),
                     styleMask: [.borderless], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
other.isReleasedWhenClosed = false
let container = NSView(frame: CGRect(x: 0, y: 0, width: 538, height: 520))
window.contentView = container
let strip = NSView(frame: CGRect(x: 19, y: 470, width: 500, height: 14))
container.addSubview(strip)
assert(NotchScrollHitRegion.contains(eventWindow: window, locationInWindow: CGPoint(x: 269, y: 477), in: strip))
assert(!NotchScrollHitRegion.contains(eventWindow: nil, locationInWindow: CGPoint(x: 269, y: 477), in: strip))
assert(!NotchScrollHitRegion.contains(eventWindow: other, locationInWindow: CGPoint(x: 269, y: 477), in: strip))
for depth in [0.0, 16, 31, 33, 35, 51, 200, 400, 500] {
    assert(!NotchScrollHitRegion.contains(eventWindow: window, locationInWindow: CGPoint(x: 269, y: 520 - depth), in: strip))
}
assert(!NotchScrollHitRegion.contains(eventWindow: window, locationInWindow: CGPoint(x: 10, y: 477), in: strip))
// Relocating the view must use its current coordinates, not stale bounds.
strip.frame.origin.y = 430
assert(!NotchScrollHitRegion.contains(eventWindow: window, locationInWindow: CGPoint(x: 269, y: 477), in: strip))
assert(NotchScrollHitRegion.contains(eventWindow: window, locationInWindow: CGPoint(x: 269, y: 437), in: strip))
strip.removeFromSuperview()
assert(!NotchScrollHitRegion.contains(eventWindow: window, locationInWindow: CGPoint(x: 269, y: 437), in: strip))
window.close()
other.close()
var nested = NotchScrollOwnership()
assert(!nested.update(phase: .began, momentum: [], inside: false))
assert(!nested.update(phase: .changed, momentum: [], inside: true))
assert(!nested.update(phase: .ended, momentum: [], inside: true))
assert(!nested.update(phase: [], momentum: .changed, inside: true))
assert(nested.update(phase: .began, momentum: [], inside: true))
assert(nested.update(phase: .changed, momentum: [], inside: false))
assert(nested.update(phase: .ended, momentum: [], inside: false))
assert(nested.update(phase: [], momentum: .changed, inside: false))
assert(nested.update(phase: [], momentum: .ended, inside: false))
assert(!nested.update(phase: [], momentum: .changed, inside: true))
assert(nested.update(phase: [], momentum: [], inside: true))
assert(!nested.update(phase: [], momentum: [], inside: false))
assert(nested.update(phase: .began, momentum: [], inside: true))
assert(nested.update(phase: .cancelled, momentum: [], inside: false))
assert(!nested.update(phase: .changed, momentum: [], inside: true))
print("PASS: nested scrollers retain ownership through boundary crossing and momentum")
assert(AgentTranscriptEdges.visible(offset: -4, contentHeight: 50, viewportHeight: 100,
                                    topInset: 4, bottomInset: 8) == .init(top: false, bottom: false))
assert(AgentTranscriptEdges.visible(offset: -4, contentHeight: 300, viewportHeight: 100,
                                    topInset: 4, bottomInset: 8) == .init(top: false, bottom: true))
assert(AgentTranscriptEdges.visible(offset: 72, contentHeight: 300, viewportHeight: 100,
                                    topInset: 4, bottomInset: 8) == .init(top: true, bottom: true))
assert(AgentTranscriptEdges.visible(offset: 208, contentHeight: 300, viewportHeight: 100,
                                    topInset: 4, bottomInset: 8) == .init(top: true, bottom: false))
print("PASS: transcript fades only the overflowing edge; fully visible lines keep their contrast")

var gesture = NotchPageSwipe()
assert(gesture.update(phase: .began, momentum: [], fingerX: 0, deltaY: 0, canStart: true) == .forward)
assert(gesture.update(phase: .changed, momentum: [], fingerX: -40, deltaY: 1, canStart: true) == .switchPage(1))
assert(gesture.update(phase: .changed, momentum: [], fingerX: -40, deltaY: 0, canStart: true) == .consume)
assert(gesture.update(phase: .ended, momentum: [], fingerX: 0, deltaY: 0, canStart: true) == .consume)
assert(gesture.update(phase: [], momentum: .changed, fingerX: -60, deltaY: 0, canStart: true) == .consume)
assert(gesture.update(phase: [], momentum: .ended, fingerX: 0, deltaY: 0, canStart: true) == .consume)
assert(gesture.update(phase: .began, momentum: [], fingerX: 0, deltaY: 11, canStart: true) == .forward)
assert(gesture.update(phase: .changed, momentum: [], fingerX: 60, deltaY: 1, canStart: true) == .forward)
assert(gesture.update(phase: .began, momentum: [], fingerX: 60, deltaY: 0, canStart: false) == .forward)
assert(gesture.update(phase: .changed, momentum: [], fingerX: 60, deltaY: 0, canStart: true) == .forward)
print("PASS: one page per gesture, momentum consumption, vertical rejection and blocked starts")
print("PASS: nil/detached/foreign windows, lower-screen scroll rejection, local bounds and relocated views; no events posted")
'''
with tempfile.TemporaryDirectory(prefix='boringnotch-scroll-') as directory:
    directory = Path(directory)
    (directory / 'main.swift').write_text(harness)
    subprocess.run(['xcrun', 'swiftc', str(directory / 'main.swift'), '-o', str(directory / 'test')], check=True)
    subprocess.run([str(directory / 'test')], check=True)
