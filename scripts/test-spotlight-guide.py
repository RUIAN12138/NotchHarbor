#!/usr/bin/env python3
"""Production regression for NotchSpotlightGuide geometry and step routing.

Compiles the real SpotlightGuideStepKind and SpotlightGuideGeometry slice out
of NotchSpotlightGuide.swift and verifies step filtering, page mapping,
viewport clamping, non-negative dimensions, and NaN/Inf resilience.
"""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
GUIDE_SOURCE = ROOT / "boringNotch/components/Notch/NotchSpotlightGuide.swift"

BEGIN_MARKER = "// === SPOTLIGHT_GUIDE_MODEL_BEGIN ==="
END_MARKER = "// === SPOTLIGHT_GUIDE_MODEL_END ==="


def model_slice() -> str:
    source = GUIDE_SOURCE.read_text(encoding="utf-8")
    start = source.find(BEGIN_MARKER)
    end = source.find(END_MARKER)
    if start < 0 or end < 0 or end <= start:
        raise SystemExit("FAIL spotlight guide markers missing from NotchSpotlightGuide.swift")
    return "import CoreGraphics\nimport Foundation\n\n" + source[start : end + len(END_MARKER)]


HARNESS = r"""
var failures = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS " + name)
    } else {
        failures += 1
        print("FAIL " + name)
    }
}

let fullSteps = SpotlightGuideGeometry.availableSteps(shelfEnabled: true)
check(fullSteps.count == 6, "shelfEnabled=true exposes all 6 guided steps")
check(fullSteps.first == .navHubs && fullSteps.last == .calendarWeather, "step sequence starts at navHubs and ends at calendarWeather")

let noShelfSteps = SpotlightGuideGeometry.availableSteps(shelfEnabled: false)
check(noShelfSteps.count == 5 && !noShelfSteps.contains(.shelfAirDrop), "shelfEnabled=false omits shelfAirDrop cleanly")

let expectedPages = [0, 0, 1, 2, 3, 4]
check(fullSteps.map(\.pageRawValue) == expectedPages, "each spotlight step maps to expected NotchPage rawValue")

for step in SpotlightGuideStepKind.allCases {
    check(!step.title(english: false).isEmpty && !step.title(english: true).isEmpty, "bilingual title non-empty for \(step)")
    check(!step.detail(english: false).isEmpty && !step.detail(english: true).isEmpty, "bilingual detail non-empty for \(step)")
    check(!step.symbolName.isEmpty, "symbolName non-empty for \(step)")
}

let configs: [(String, SpotlightGuideGeometry)] = [
    ("standard-notch-530", SpotlightGuideGeometry(
        panelWidth: 482, headerHeight: 32, cameraClearanceWidth: 205,
        topInset: 6, pageWidth: 482, pageHeight: 95, shelfEnabled: true
    )),
    ("system-island-compact", SpotlightGuideGeometry(
        panelWidth: 380, headerHeight: 37, cameraClearanceWidth: 212,
        topInset: 6, pageWidth: 380, pageHeight: 90, shelfEnabled: false
    )),
    ("non-notch-external", SpotlightGuideGeometry(
        panelWidth: 482, headerHeight: 24, cameraClearanceWidth: 180,
        topInset: 6, pageWidth: 482, pageHeight: 103, shelfEnabled: true
    )),
    ("degenerate-tiny-nan", SpotlightGuideGeometry(
        panelWidth: .nan, headerHeight: -5, cameraClearanceWidth: .infinity,
        topInset: 0, pageWidth: 0, pageHeight: -10, shelfEnabled: true
    )),
]

for (label, geo) in configs {
    let bounds = geo.upperBounds
    check(bounds.width >= 1 && bounds.height >= 1 && bounds.width.isFinite && bounds.height.isFinite,
          "\(label): upperBounds finite and positive")

    for step in geo.availableSteps() {
        let rect = geo.spotlightRect(for: step)
        let r = geo.cornerRadius(for: step)
        check(rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite,
              "\(label)-\(step): spotlightRect is finite")
        check(rect.width >= 1 && rect.height >= 1,
              "\(label)-\(step): spotlightRect has positive area")
        check(rect.minX >= bounds.minX - 1e-6 && rect.minY >= bounds.minY - 1e-6
              && rect.maxX <= bounds.maxX + 1e-6 && rect.maxY <= bounds.maxY + 1e-6,
              "\(label)-\(step): spotlightRect stays strictly within upperBounds")
        check(r >= 0 && r <= min(rect.width, rect.height) / 2 + 1e-6,
              "\(label)-\(step): cornerRadius valid")
    }
}

check(SpotlightGuideGeometry.reservedExtraHeight == 72, "reservedExtraHeight matches coachBar + topSpacing")
exit(failures == 0 ? 0 : 1)
"""


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = pathlib.Path(tmp)
        swift_file = tmp_dir / "test_spotlight.swift"
        bin_file = tmp_dir / "test_spotlight"
        swift_file.write_text(model_slice() + "\n" + HARNESS, encoding="utf-8")

        comp = subprocess.run(
            ["swiftc", "-O", str(swift_file), "-o", str(bin_file)],
            capture_output=True,
            text=True,
        )
        if comp.returncode != 0:
            sys.stderr.write(comp.stderr)
            print("FAIL swiftc compilation failed")
            return 1

        run_res = subprocess.run([str(bin_file)], capture_output=True, text=True)
        sys.stdout.write(run_res.stdout)
        if run_res.stderr:
            sys.stderr.write(run_res.stderr)
        return run_res.returncode


if __name__ == "__main__":
    raise SystemExit(main())
