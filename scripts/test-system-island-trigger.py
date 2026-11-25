"""Test the production trigger geometry with real AppKit coordinate conventions."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'boringNotch/sizing/matters.swift').read_text()
geometry = source[source.index('enum SystemIslandHoverGeometry {'):source.index('\nenum MusicPlayerImageSizes')]
harness = 'import Foundation\nimport CoreGraphics\n' + geometry + '''
for screen in [CGRect(x: 0, y: 0, width: 1512, height: 982),
               CGRect(x: -1920, y: -1080, width: 1920, height: 1080),
               CGRect(x: 1512, y: 400, width: 1728, height: 1117)] {
    for reserved in [185.0, 293, 420, 540] {
        let wings = SystemIslandHoverGeometry.agentWings(screen: screen, centerWidth: reserved, height: 32)
        assert(wings.left.maxY == screen.maxY && wings.right.maxY == screen.maxY)
        assert(wings.left.height == 32 && wings.right.height == 32)
        assert(wings.frame.midX == screen.midX)
        assert(wings.left.maxX == screen.midX - reserved / 2)
        assert(wings.right.minX == screen.midX + reserved / 2)
        assert(wings.contains(CGPoint(x: wings.left.midX, y: screen.maxY)))
        assert(wings.contains(CGPoint(x: wings.left.midX, y: wings.left.midY)))
        assert(wings.contains(CGPoint(x: wings.right.midX, y: wings.right.midY)))
        assert(!wings.contains(CGPoint(x: screen.midX, y: screen.maxY - 16)))
        assert(!wings.contains(CGPoint(x: screen.midX + reserved / 2 - 1, y: screen.maxY - 16)))
        assert(!wings.contains(CGPoint(x: wings.left.minX - 1, y: wings.left.midY)))
        assert(!wings.contains(CGPoint(x: wings.right.midX, y: screen.maxY - 33)))
    }
    let frame = SystemIslandHoverGeometry.triggerFrame(screen: screen, islandHeight: 32, width: 249)
    let islandWidth: CGFloat = 411
    func island(_ horizontal: CGFloat, _ depth: CGFloat) -> Bool {
        SystemIslandHoverGeometry.capsuleContains(
            CGPoint(x: screen.midX + horizontal, y: screen.maxY - depth),
            screen: screen, width: islandWidth, height: 32)
    }
    assert(island(0, 0) && island(200, 16) && island(-200, 16))
    assert(!island(200, 1) && !island(-200, 31))
    assert(!island(207, 16) && !island(0, 43) && !island(0, 400))
    assert(frame.midX == screen.midX)
    assert(frame.maxY == screen.maxY - 36)
    assert(frame.height == 14)
    assert(frame.contains(CGPoint(x: screen.midX, y: screen.maxY - 43)))
    for depth in [0.0, 16, 31, 33, 35, 51, 80, 190] {
        assert(!frame.contains(CGPoint(x: screen.midX, y: screen.maxY - depth)))
    }
    assert(!frame.contains(CGPoint(x: frame.maxX + 1, y: frame.midY)))
    let wide = SystemIslandHoverGeometry.triggerFrame(screen: screen, islandHeight: 32, width: 99999)
    assert(wide.width == screen.width)
    let clearance = SystemIslandHoverGeometry.clearanceWidth(physical: 185, observed: 250)
    assert(clearance == 293)
    assert(SystemIslandHoverGeometry.clearanceWidth(physical: 185, observed: 420) == 420)
    assert(SystemIslandHoverGeometry.clearanceWidth(physical: 185, observed: .nan) == 293)
}
let dropScreen = CGRect(x: -900, y: -300, width: 1512, height: 982)
let drop = SystemIslandHoverGeometry.shelfDropFrame(screen: dropScreen, width: 420, height: 215, topInset: 36)
assert(drop.width == 420 && drop.height == 179 && drop.midX == dropScreen.midX)
assert(drop.maxY == dropScreen.maxY - 36)
assert(drop.contains(CGPoint(x: drop.minX + 1, y: drop.minY + 1)))
assert(drop.contains(CGPoint(x: drop.maxX - 1, y: drop.maxY - 1)))
assert(!drop.contains(CGPoint(x: drop.midX, y: drop.maxY + 1)))
assert(!drop.contains(CGPoint(x: drop.midX, y: drop.minY - 1)))
assert(SystemIslandHoverGeometry.shelfDropFrame(screen: dropScreen, width: 100, height: 30, topInset: 36).isNull)
for size in [CGSize(width: 180, height: 72), CGSize(width: 510, height: 96), CGSize(width: 940, height: 160)] {
    let layout = ShelfDropLayout(size: size)
    let share = CGRect(x: 0, y: (size.height - layout.shareSize) / 2,
                       width: layout.shareSize, height: layout.shareSize)
    let shelf = layout.shelf
    let tile = shelf.insetBy(dx: ShelfDropLayout.tileInset, dy: ShelfDropLayout.tileInset)
    assert(shelf.contains(tile) && shelf.width > tile.width && shelf.height > tile.height)
    assert(shelf.contains(CGPoint(x: shelf.minX + 1, y: shelf.midY)))
    assert(shelf.contains(CGPoint(x: shelf.midX, y: 1)))
    assert(!shelf.intersects(share) && !shelf.contains(CGPoint(x: share.midX, y: share.midY)))
    assert(!shelf.contains(CGPoint(x: size.width + 1, y: shelf.midY)))
    assert(!shelf.contains(CGPoint(x: shelf.midX, y: size.height + 1)))
    assert(!shelf.contains(CGPoint(x: shelf.midX, y: -1)))
}
print("PASS: shelf drop target includes surrounding padding and stays outside share and panel exterior")
assert(SystemIslandHoverGeometry.expandedWidth(island: 250, available: 1472) == 500)
assert(SystemIslandHoverGeometry.expandedWidth(island: 420, available: 1472) == 840)
assert(SystemIslandHoverGeometry.expandedWidth(island: 1200, available: 1472) == 1472)
assert(SystemIslandHoverGeometry.expandedHeight(content: 231.2) == 232)
assert(SystemIslandHoverGeometry.expandedHeight(content: 10000) == 480)
assert(SystemIslandHoverGeometry.expandedHeight(content: .nan) == nil)
assert(SystemIslandHoverGeometry.expandedHeight(content: -1) == nil)
let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
assert(SystemIslandHoverGeometry.triggerFrame(screen: screen, islandHeight: 0, width: 189).isNull)
assert(SystemIslandHoverGeometry.triggerFrame(screen: screen, islandHeight: 32, width: .infinity).isNull)
assert(SystemIslandHoverGeometry.triggerFrame(screen: .zero, islandHeight: 32, width: 189).isNull)
assert(SystemIslandHoverGeometry.agentWings(screen: .zero, centerWidth: 185, height: 32).frame.isNull)
assert(SystemIslandHoverGeometry.agentWings(screen: screen, centerWidth: .nan, height: 32).frame.isNull)
var vacancy = SystemIslandVacancy()
assert(!vacancy.observe(width: 0, expanded: false, at: 10, since: nil))
assert(vacancy.awaitingConfirmation)
assert(!vacancy.observe(width: nil, expanded: false, at: 10.3, since: nil))
assert(!vacancy.observe(width: 0, expanded: false, at: 10.4, since: nil))
assert(!vacancy.observe(width: 280, expanded: false, at: 10.6, since: nil))
assert(!vacancy.observe(width: 0, expanded: true, at: 10.7, since: nil))
assert(!vacancy.observe(width: 0, expanded: false, at: 10.8, since: nil))
assert(vacancy.observe(width: 0, expanded: false, at: 11.6, since: nil))
assert(!vacancy.observe(width: 0, expanded: false, at: 11.7, since: 11.65))
assert(!vacancy.observe(width: 280, expanded: false, at: 12.2, since: 11.65))
assert(!vacancy.observe(width: 0, expanded: false, at: 12.3, since: 11.65))
assert(vacancy.observe(width: 0, expanded: false, at: 13.1, since: 11.65))
assert(!SystemIslandVacancy.requiresConfirmationOnClose(at: 20.2, lastVacantSample: 20, nativePresentationActive: false))
assert(SystemIslandVacancy.requiresConfirmationOnClose(at: 20.5, lastVacantSample: 20, nativePresentationActive: false))
assert(SystemIslandVacancy.requiresConfirmationOnClose(at: 20.2, lastVacantSample: 20, nativePresentationActive: true))
assert(SystemIslandVacancy.requiresConfirmationOnClose(at: 20.2, lastVacantSample: nil, nativePresentationActive: false))
assert(SystemIslandVacancy.requiresConfirmationOnClose(at: 20, lastVacantSample: 20.1, nativePresentationActive: false))
print("PASS: native presence debouncing and post-collapse protection, agent wings at real notch height, native center excluded, expanded reservations, below-island trigger, negative coordinates")
'''
with tempfile.TemporaryDirectory(prefix='boringnotch-trigger-') as directory:
    directory = Path(directory)
    (directory / 'main.swift').write_text(harness)
    subprocess.run(['xcrun', 'swiftc', str(directory / 'main.swift'), '-o', str(directory / 'test')], check=True)
    subprocess.run([str(directory / 'test')], check=True)
