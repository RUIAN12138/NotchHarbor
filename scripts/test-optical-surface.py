#!/usr/bin/env python3
"""Production regression for the notch optical surface.

The geometry test compiles the real geometry model sliced out of
NotchOpticalSurface.swift. The GPU test compiles the production .metal file
and drives its stitchable entry point through a small compute probe, then
checks the returned pixels.

Exit codes:
  0  all verification passed
  1  a production assertion failed
  2  the environment cannot run a required stage (explicitly unverified)
"""

from __future__ import annotations

import array
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
GEOMETRY_SOURCE = ROOT / "boringNotch/components/Notch/NotchOpticalSurface.swift"
METAL_SOURCE = ROOT / "boringNotch/components/Notch/NotchOpticalSurface.metal"

BEGIN_MARKER = "// === OPTICAL_GEOMETRY_MODEL_BEGIN ==="
END_MARKER = "// === OPTICAL_GEOMETRY_MODEL_END ==="

FAILURES: list[str] = []


def check(condition: bool, name: str) -> None:
    print(("PASS " if condition else "FAIL ") + name)
    if not condition:
        FAILURES.append(name)


def run(command: list[str], cwd: pathlib.Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(command, cwd=cwd, capture_output=True, text=True)


def geometry_slice() -> str:
    source = GEOMETRY_SOURCE.read_text()
    start = source.find(BEGIN_MARKER)
    end = source.find(END_MARKER)
    if start < 0 or end < 0 or end <= start:
        raise SystemExit("FAIL geometry markers are missing from NotchOpticalSurface.swift")
    # The production file's imports live above the marker; the slice is meant
    # to be compiled on its own, so provide the same CoreGraphics surface.
    return (
        "import CoreGraphics\nimport Foundation\n\n"
        + source[start:end + len(END_MARKER)]
    )


GEOMETRY_MAIN = r"""
import CoreGraphics
import Foundation

var failures = 0

func check(_ condition: Bool, _ name: String) {
    if condition { print("PASS " + name) } else { failures += 1; print("FAIL " + name) }
}

func nearly(_ a: CGFloat, _ b: CGFloat, _ epsilon: CGFloat = 1e-7) -> Bool {
    a.isFinite && b.isFinite && abs(a - b) <= epsilon
}

enum Element {
    case move(CGPoint)
    case line(CGPoint)
    case quad(CGPoint, CGPoint)
    case close
}

func elements(_ path: CGPath) -> [Element] {
    var output: [Element] = []
    path.applyWithBlock { pointer in
        let element = pointer.pointee
        switch element.type {
        case .moveToPoint:
            output.append(.move(element.points[0]))
        case .addLineToPoint:
            output.append(.line(element.points[0]))
        case .addQuadCurveToPoint:
            output.append(.quad(element.points[0], element.points[1]))
        case .closeSubpath:
            output.append(.close)
        @unknown default:
            break
        }
    }
    return output
}

@discardableResult
func validate(
    _ label: String,
    _ rect: CGRect,
    _ top: CGFloat,
    _ bottom: CGFloat,
    expectClamp: Bool
) -> NotchSurfaceGeometry {
    let geometry = NotchSurfaceGeometry(
        rect: rect, topCornerRadius: top, bottomCornerRadius: bottom
    )
    let width = max(0, rect.width)
    let height = max(0, rect.height)
    let limit = min(width / 2, height)
    let path = geometry.makePath()
    let list = elements(path)

    check(geometry.topCornerRadius.isFinite && geometry.bottomCornerRadius.isFinite,
          label + ": resolved radii are finite")
    check(geometry.topCornerRadius >= 0 && geometry.bottomCornerRadius >= 0,
          label + ": resolved radii are non-negative")
    check(geometry.topCornerRadius + geometry.bottomCornerRadius <= limit + 1e-7,
          label + ": radii stay within the available space")
    check(!list.isEmpty, label + ": path has elements")

    if width > 0 && height > 0 {
        let startsAtOrigin: Bool = {
            guard case .move(let point) = list.first else { return false }
            return nearly(point.x, rect.minX) && nearly(point.y, rect.minY)
        }()
        let endsClosed: Bool = {
            guard case .close = list.last else { return false }
            return true
        }()
        let bounds = path.boundingBoxOfPath
        check(startsAtOrigin, label + ": path starts at the rect origin")
        check(endsClosed, label + ": path is explicitly closed")
        check(
            nearly(bounds.minX, rect.minX) && nearly(bounds.minY, rect.minY)
                && nearly(bounds.width, rect.width) && nearly(bounds.height, rect.height),
            label + ": path bounds match the rect"
        )
        check(
            nearly(path.currentPoint.x, rect.minX) && nearly(path.currentPoint.y, rect.minY),
            label + ": current point returns to the origin"
        )
        check(
            path.contains(CGPoint(x: rect.midX, y: rect.midY)),
            label + ": center is inside the shape"
        )
        if geometry.topCornerRadius > 0.5 {
            check(
                !path.contains(CGPoint(x: rect.minX + 0.25, y: rect.minY + 0.25)),
                label + ": concave top corner is outside the shape"
            )
        }
        if height > geometry.bottomCornerRadius + 1 && geometry.bottomCornerRadius > 0.5 {
            check(
                !path.contains(CGPoint(x: rect.minX + 0.25, y: rect.maxY - 0.25)),
                label + ": rounded bottom corner is outside the shape"
            )
        }
    }

    if expectClamp {
        check(
            nearly(
                geometry.topCornerRadius + geometry.bottomCornerRadius,
                limit,
                1e-7
            ),
            label + ": clamping uses the full available radius"
        )
    }
    return geometry
}

let closed = validate(
    "closed 185x32", CGRect(x: 0, y: 0, width: 185, height: 32),
    6, 14, expectClamp: false
)
check(nearly(closed.topCornerRadius, 6) && nearly(closed.bottomCornerRadius, 14),
      "closed 185x32: normal radii are unchanged")

validate(
    "expanded 560x190", CGRect(x: 0, y: 0, width: 560, height: 190),
    19, 24, expectClamp: false
)
validate(
    "page 640x240", CGRect(x: 0, y: 0, width: 640, height: 240),
    19, 24, expectClamp: false
)

let short = validate(
    "short transition 24x8", CGRect(x: 0, y: 0, width: 24, height: 8),
    19, 24, expectClamp: true
)
check(
    nearly(short.topCornerRadius / max(short.bottomCornerRadius, 1e-9), 19.0 / 24.0, 1e-6),
    "short transition: radius ratio is preserved"
)
validate(
    "narrow transition 6x120", CGRect(x: 0, y: 0, width: 6, height: 120),
    19, 24, expectClamp: true
)

validate(
    "non-zero rect origin", CGRect(x: 120, y: -48, width: 185, height: 32),
    6, 14, expectClamp: false
)

let sanitized = validate(
    "non-finite radii", CGRect(x: 0, y: 0, width: 185, height: 32),
    .nan, .infinity, expectClamp: false
)
check(nearly(sanitized.topCornerRadius, 0) && nearly(sanitized.bottomCornerRadius, 0),
      "non-finite radii: sanitized to zero")

let negative = validate(
    "negative radii", CGRect(x: 0, y: 0, width: 185, height: 32),
    -20, -6, expectClamp: false
)
check(nearly(negative.topCornerRadius, 0) && nearly(negative.bottomCornerRadius, 0),
      "negative radii: clamped to zero")

let zero = validate(
    "zero frame", CGRect(x: 0, y: 0, width: 0, height: 0),
    19, 24, expectClamp: true
)
check(nearly(zero.topCornerRadius, 0) && nearly(zero.bottomCornerRadius, 0),
      "zero frame: radii collapse to zero")

let curve = NotchSurfaceGeometry(
    rect: CGRect(x: 0, y: 0, width: 185, height: 32),
    topCornerRadius: 6, bottomCornerRadius: 14
)
var quadratics: [(control: CGPoint, to: CGPoint)] = []
for element in elements(curve.makePath()) {
    if case .quad(let control, let to) = element {
        quadratics.append((control, to))
    }
}
let hasTopLeft = quadratics.contains {
    nearly($0.control.x, 6) && nearly($0.control.y, 0)
        && nearly($0.to.x, 6) && nearly($0.to.y, 6)
}
let hasBottomLeft = quadratics.contains {
    nearly($0.control.x, 6) && nearly($0.control.y, 32)
        && nearly($0.to.x, 20) && nearly($0.to.y, 32)
}
let hasBottomRight = quadratics.contains {
    nearly($0.control.x, 179) && nearly($0.control.y, 32)
        && nearly($0.to.x, 179) && nearly($0.to.y, 18)
}
check(hasTopLeft, "top-left shoulder keeps the original quadratic control point")
check(hasBottomLeft, "bottom-left corner keeps the original quadratic Bezier control point")
check(hasBottomRight, "bottom-right corner keeps the original quadratic Bezier control point")

exit(failures == 0 ? 0 : 1)
"""

HARNESS_MAIN = r"""
import CoreGraphics
import Foundation
import Metal
import simd

func die(_ message: String) -> Never {
    FileHandle.standardError.write(("FAIL " + message + "\n").data(using: .utf8)!)
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 9 else { die("probe arguments") }
let metallibPath = arguments[1]
let outputPrefix = arguments[2]
guard
    let width = Int(arguments[3]), let height = Int(arguments[4]),
    let topRadius = Float(arguments[5]), let bottomRadius = Float(arguments[6]),
    let header = Float(arguments[7]), let hardware = Float(arguments[8])
else { die("probe numeric arguments") }
guard width > 8, height > 8 else { die("probe grid too small") }
guard let device = MTLCreateSystemDefaultDevice() else {
    print("NO_GPU")
    exit(2)
}

do {
    let library = try device.makeLibrary(URL: URL(fileURLWithPath: metallibPath))
    guard let function = library.makeFunction(name: "opticalProbe") else {
        die("opticalProbe is missing from the metallib")
    }
    guard let surface = library.makeFunction(name: "notchOpticalSurface") else {
        die("production notchOpticalSurface function is missing")
    }
    let linked = MTLLinkedFunctions()
    linked.functions = [surface]
    let descriptor = MTLComputePipelineDescriptor()
    descriptor.computeFunction = function
    descriptor.linkedFunctions = linked
    let pipeline = try device.makeComputePipelineState(descriptor: descriptor,
                                                       options: [], reflection: nil)
    guard let edgeFunction = library.makeFunction(name: "edgeProbe"),
          let edgeSurface = library.makeFunction(name: "notchEdgeOptics") else { die("edge function") }
    let edgeLinked = MTLLinkedFunctions()
    edgeLinked.functions = [edgeSurface]
    let edgeDescriptor = MTLComputePipelineDescriptor()
    edgeDescriptor.computeFunction = edgeFunction
    edgeDescriptor.linkedFunctions = edgeLinked
    let edgePipeline = try device.makeComputePipelineState(descriptor: edgeDescriptor, options: [], reflection: nil)
    guard let queue = device.makeCommandQueue() else { die("command queue") }
    guard let buffer = device.makeBuffer(
        length: width * height * 16, options: .storageModeShared
    ) else { die("probe buffer") }

    func render(time: Float, intensity: Float, motion: Float, path: String, edgeOnly: Bool = false, music: SIMD4<Float> = .zero) {
        var rect = simd_float4(0, 0, Float(width), Float(height))
        var radii = simd_float4(topRadius, bottomRadius, header, hardware)
        var params = simd_float4(time, intensity, 0, motion)
        var tint = simd_float4(0.85, 0.40, 0.25, 1)
        var dims = simd_uint2(UInt32(width), UInt32(height))

        guard
            let command = queue.makeCommandBuffer(),
            let encoder = command.makeComputeCommandEncoder()
        else { die("compute encoder") }

        encoder.setComputePipelineState(edgeOnly ? edgePipeline : pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        withUnsafeBytes(of: &rect) {
            encoder.setBytes($0.baseAddress!, length: 16, index: 1)
        }
        withUnsafeBytes(of: &radii) {
            encoder.setBytes($0.baseAddress!, length: 16, index: 2)
        }
        withUnsafeBytes(of: &params) {
            encoder.setBytes($0.baseAddress!, length: 16, index: 3)
        }
        withUnsafeBytes(of: &tint) {
            encoder.setBytes($0.baseAddress!, length: 16, index: 4)
        }
        withUnsafeBytes(of: &dims) {
            encoder.setBytes($0.baseAddress!, length: 8, index: 5)
        }

        var music = music
        withUnsafeBytes(of: &music) {
            encoder.setBytes($0.baseAddress!, length: 16, index: 6)
        }

        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(
            1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth
        )
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth, height: threadHeight, depth: 1
            )
        )
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error {
            die("GPU command failed: \(error)")
        }

        let pointer = buffer.contents().bindMemory(
            to: Float.self, capacity: width * height * 4
        )
        let values = Array(
            UnsafeBufferPointer(start: pointer, count: width * height * 4)
        )
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        do { try data.write(to: URL(fileURLWithPath: path)) }
        catch { die("cannot write " + path) }
    }

    render(time: 1.0, intensity: 1.0, motion: 0.0, path: outputPrefix + "-t1.bin")
    render(time: 9.0, intensity: 1.0, motion: 0.0, path: outputPrefix + "-t9.bin")
    render(time: 1.0, intensity: 0.0, motion: 1.0, path: outputPrefix + "-off.bin")
    render(time: 1.0, intensity: 0.0, motion: 0.0, path: outputPrefix + "-off-idle.bin")
    render(time: 1.0, intensity: 1.0, motion: 1.0, path: outputPrefix + "-active.bin")
    render(time: 1.0, intensity: 1.0, motion: 0.0, path: outputPrefix + "-edge.bin", edgeOnly: true)
    render(time: 1.0, intensity: 0.0, motion: 0.0, path: outputPrefix + "-edge-off.bin", edgeOnly: true)

    render(time: 1.0, intensity: 1.0, motion: 0.0, path: outputPrefix + "-music-silence.bin", music: .init(0, 0, 0, 1))
    render(time: 1.0, intensity: 1.0, motion: 0.0, path: outputPrefix + "-music-soft.bin", music: .init(0.22, 0.03, 0.01, 1))
    render(time: 1.0, intensity: 1.0, motion: 0.0, path: outputPrefix + "-music-mids.bin", music: .init(0, 0.8, 0, 1))
    render(time: 1.0, intensity: 1.0, motion: 0.0, path: outputPrefix + "-music-on.bin", music: .init(0.9, 0.55, 0.25, 1))

    let geometry = NotchSurfaceGeometry(
        rect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
        topCornerRadius: CGFloat(topRadius),
        bottomCornerRadius: CGFloat(bottomRadius)
    )
    let shapePath = geometry.makePath()
    var mask = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            if shapePath.contains(
                CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
            ) {
                mask[y * width + x] = 1
            }
        }
    }
    do {
        try Data(mask).write(to: URL(fileURLWithPath: outputPrefix + "-mask.bin"))
    } catch { die("cannot write mask") }
    // Use the production backdrop fragment on a grayscale ramp. A bend
    // moves actual pixels; dispersion separates channels of an achromatic input.
    let rampSize = 192
    let rampDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba32Float, width: rampSize, height: rampSize, mipmapped: false
    )
    rampDescriptor.storageMode = .shared
    rampDescriptor.usage = [.renderTarget, .shaderRead]
    guard let input = device.makeTexture(descriptor: rampDescriptor),
          let output = device.makeTexture(descriptor: rampDescriptor) else { die("backdrop textures") }
    let region = MTLRegionMake2D(0, 0, rampSize, rampSize)
    let ramp = (0..<(rampSize*rampSize)).map { i in
        let y = Float(i / rampSize) / Float(rampSize)
        return SIMD4<Float>(y, y, y, 1)
    }
    let renderDescriptor = MTLRenderPipelineDescriptor()
    renderDescriptor.vertexFunction = library.makeFunction(name: "notchBackdropVertex")
    renderDescriptor.fragmentFunction = library.makeFunction(name: "notchRefractedBackdrop")
    renderDescriptor.colorAttachments[0].pixelFormat = .rgba32Float
    let backdropPipeline = try device.makeRenderPipelineState(descriptor: renderDescriptor)
    func renderBackdrop(_ pixels: [SIMD4<Float>]) -> [SIMD4<Float>] {
        pixels.withUnsafeBytes { input.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: rampSize*16) }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else { die("backdrop encoder") }
        var uniforms: [SIMD4<Float>] = [
            SIMD4(192, 192, 8, 23), SIMD4(0, 0, 1.0/192, 1.0/192), SIMD4(1, 0, 0, 0)
        ]
        encoder.setRenderPipelineState(backdropPipeline)
        encoder.setFragmentTexture(input, index: 0)
        uniforms.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { die("backdrop render failed") }
        var result = [SIMD4<Float>](repeating: .zero, count: pixels.count)
        result.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: rampSize*16, from: region, mipmapLevel: 0) }
        return result
    }
    let result = renderBackdrop(ramp)
    let centerIndex = 96 * rampSize + 96
    let rimIndex = 187 * rampSize + 96
    let edge = result[rimIndex]
    guard result[centerIndex].w < 0.0005
        else { die("the clear center must show the live compositor") }
    guard edge.w > 0.2 && edge.w <= 0.49
        else { die("the refracted edge must blend with the compositor") }
    let rim = edge / edge.w
    let displacement = abs(rim.y - ramp[rimIndex].y) * Float(rampSize)
    let split = (rim.x - rim.z) * Float(rampSize)
    guard (4...11).contains(displacement)
        else { die("soft lens displacement out of range: \(displacement) pt") }
    guard (0.22...0.75).contains(split)
        else { die("subtle grayscale channel split out of range: \(split) pt") }
    let bars = ramp.indices.map { index -> SIMD4<Float> in
        let value: Float = (index % rampSize).isMultiple(of: 2) ? 1 : 0
        return SIMD4<Float>(value, value, value, 1)
    }
    let scattered = renderBackdrop(bars)
    let lightBar = scattered[rimIndex].y / scattered[rimIndex].w
    let darkBar = scattered[rimIndex + 1].y / scattered[rimIndex + 1].w
    guard lightBar < 0.97, darkBar > 0.03, lightBar - darkBar > 0.30,
          scattered[centerIndex].w < 0.0005
        else { die("bevel scattering must soften real one-pixel stripes and keep the centre clear: \(lightBar), \(darkBar)") }
    print("PASS production backdrop: scattering softens actual high-contrast stripes")
    print("PASS production backdrop: live centre, blended displaced rim and RGB separation")
    print("RENDERED \(width)x\(height)")
} catch {
    die("Metal setup failed: \(error)")
}
"""

PROBE_METAL = r"""
#include "NotchOpticalSurface.metal"

kernel void opticalProbe(
    device float4 *output [[buffer(0)]],
    constant float4 &rect [[buffer(1)]],
    constant float4 &radii [[buffer(2)]],
    constant float4 &params [[buffer(3)]],
    constant float4 &tint [[buffer(4)]],
    constant uint2 &dims [[buffer(5)]],
    constant float4 &music [[buffer(6)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }
    float2 uv = (float2(gid) + 0.5) / float2(dims);
    float2 position = rect.xy + uv * rect.zw;
    half4 result = notchOpticalSurface(
        position, half4(0.0), rect, radii, params, tint, music
    );
    output[gid.y * dims.x + gid.x] = float4(result);
}
kernel void edgeProbe(
    device float4 *output [[buffer(0)]],
    constant float4 &rect [[buffer(1)]],
    constant float4 &radii [[buffer(2)]],
    constant float4 &params [[buffer(3)]],
    constant float4 &tint [[buffer(4)]],
    constant uint2 &dims [[buffer(5)]],
    constant float4 &music [[buffer(6)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }
    float2 uv = (float2(gid) + 0.5) / float2(dims);
    float2 position = rect.xy + uv * rect.zw;
    half4 result = notchEdgeOptics(
        position, half4(0.0), rect, radii, params, tint, music
    );
    output[gid.y * dims.x + gid.x] = float4(result);
}
"""


def run_geometry_tests(tmp: pathlib.Path) -> None:
    print("== production geometry ==")
    (tmp / "geometry-model.swift").write_text(geometry_slice())
    (tmp / "main.swift").write_text(GEOMETRY_MAIN)
    build = run(
        [
            "swiftc",
            str(tmp / "geometry-model.swift"),
            str(tmp / "main.swift"),
            "-o",
            str(tmp / "geometry-tests"),
        ]
    )
    if build.returncode != 0:
        print(build.stdout)
        print(build.stderr)
        check(False, "geometry model compiles")
        return
    check(True, "geometry model compiles")

    result = run([str(tmp / "geometry-tests")])
    print(result.stdout.rstrip())
    if result.stderr.strip():
        print(result.stderr.rstrip())
    check(result.returncode == 0, "production geometry assertions")


def metal_unavailable_reason() -> str | None:
    probe = run(["xcrun", "-sdk", "macosx", "metal", "--version"])
    output = (probe.stdout + probe.stderr).lower()
    if probe.returncode != 0:
        return "xcrun metal exited with %d: %s" % (
            probe.returncode, output.strip()
        )
    if "missing metal toolchain" in output or "cannot execute tool" in output:
        return output.strip()
    return None


def read_floats(path: pathlib.Path) -> array.array:
    data = path.read_bytes()
    values = array.array("f")
    values.frombytes(data)
    if sys.byteorder != "little":
        values.byteswap()
    return values


def run_metal_tests(tmp: pathlib.Path) -> int:
    print("== production metal ==")
    reason = metal_unavailable_reason()
    if reason is not None:
        print("NOT VERIFIED: Metal toolchain is unavailable on this machine.")
        print("NOT VERIFIED: " + reason)
        print("NOT VERIFIED: GPU pixel assertions were not executed; no fallback assertion was substituted.")
        return 2

    shutil.copy2(METAL_SOURCE, tmp / "NotchOpticalSurface.metal")
    (tmp / "probe.metal").write_text(PROBE_METAL)

    air = tmp / "probe.air"
    metallib = tmp / "optical.metallib"
    compile_metal = run(
        [
            "xcrun", "-sdk", "macosx", "metal",
            "-mmacosx-version-min=14.0",
            "-I", str(tmp),
            "-c", str(tmp / "probe.metal"),
            "-o", str(air),
        ]
    )
    if compile_metal.returncode != 0:
        print(compile_metal.stdout)
        print(compile_metal.stderr)
        check(False, "production .metal compiles")
        return 1
    check(True, "production .metal compiles")

    link = run(
        [
            "xcrun", "-sdk", "macosx", "metallib",
            str(air), "-o", str(metallib),
        ]
    )
    if link.returncode != 0:
        print(link.stdout)
        print(link.stderr)
        check(False, "production metal library links")
        return 1
    check(True, "production metal library links")

    (tmp / "geometry-model.swift").write_text(geometry_slice())
    (tmp / "main.swift").write_text(HARNESS_MAIN)
    build = run(
        [
            "swiftc",
            str(tmp / "geometry-model.swift"),
            str(tmp / "main.swift"),
            "-O",
            "-o",
            str(tmp / "optical-probe"),
        ]
    )
    if build.returncode != 0:
        print(build.stdout)
        print(build.stderr)
        check(False, "compute probe compiles")
        return 1
    check(True, "compute probe compiles")

    width, height = 560, 190
    top_radius, bottom_radius = 19.0, 24.0
    header_height, hardware_width = 32.0, 185.0
    prefix = tmp / "probe"
    probe = run(
        [
            str(tmp / "optical-probe"),
            str(metallib),
            str(prefix),
            str(width),
            str(height),
            str(top_radius),
            str(bottom_radius),
            str(header_height),
            str(hardware_width),
        ]
    )
    print(probe.stdout.rstrip())
    if probe.stderr.strip():
        print(probe.stderr.rstrip())
    if probe.returncode == 2:
        print("NOT VERIFIED: no Metal device is available.")
        return 2
    if probe.returncode != 0:
        check(False, "compute probe executes")
        return 1
    check(True, "compute probe executes")

    t1 = read_floats(tmp / "probe-t1.bin")
    t9 = read_floats(tmp / "probe-t9.bin")
    off = read_floats(tmp / "probe-off.bin")
    off_idle = read_floats(tmp / "probe-off-idle.bin")
    active = read_floats(tmp / "probe-active.bin")
    music_silence = read_floats(tmp / "probe-music-silence.bin")
    music_soft = read_floats(tmp / "probe-music-soft.bin")
    music_on = read_floats(tmp / "probe-music-on.bin")
    music_mids = read_floats(tmp / "probe-music-mids.bin")
    mask = (tmp / "probe-mask.bin").read_bytes()
    edge = read_floats(tmp / "probe-edge.bin")
    edge_off = read_floats(tmp / "probe-edge-off.bin")
    import math
    check(all(math.isfinite(v) for v in edge), "native-material edge output stays finite")
    check(max(edge[3::4]) <= 0.621, "edge reflection alpha stays bounded")
    check(max(abs(v) for v in edge_off) < 1e-6, "zero intensity fully disables extra edge")
    check(all(edge[i + channel] <= edge[i + 3] + 1e-4 for i in range(0, len(edge), 4) for channel in range(3)),
          "edge reflection remains premultiplied")
    check(max(edge[(y * width + width // 2) * 4 + 3] for y in range(height - 32)) < 1e-5,
          "edge-only pass never darkens central content or hardware header")
    check(max(edge[(y * width + width // 2) * 4 + 3] for y in range(height - 20, height)) > 0.003,
          "curvature-driven reflection is present inside lower optical edge")
    expected = width * height * 4
    if (
        len(t1) != expected or len(t9) != expected
        or len(off) != expected or len(off_idle) != expected
        or len(active) != expected
    ):
        check(False, "probe returned %dx%d RGBA pixels" % (width, height))
        return 1
    check(True, "probe returned %dx%d RGBA pixels" % (width, height))

    def index(x: int, y: int) -> int:
        return (y * width + x) * 4

    def inside(x: int, y: int) -> bool:
        return mask[y * width + x] == 1

    # Premultiplied validity and finiteness across every rendered pixel.
    valid = True
    for values in (t1, t9, off, active):
        for offset in range(0, expected, 4):
            r, g, b, a = values[offset:offset + 4]
            if not all(v == v and abs(v) != float("inf") for v in (r, g, b, a)):
                valid = False
                break
            if a < -1e-6 or a > 1 + 1e-6:
                valid = False
                break
            if r < -1e-6 or g < -1e-6 or b < -1e-6:
                valid = False
                break
            if r > a + 1e-5 or g > a + 1e-5 or b > a + 1e-5:
                valid = False
                break
        if not valid:
            break
    check(valid, "all pixels are finite with valid premultiplied alpha")

    check(all(max(abs(values[i] - values[i+1]), abs(values[i] - values[i+2])) < 1e-5
              for values in (t1, t9)
              for i in range(0, expected, 4)), "animated reflection is achromatic")
    # Header: real cutout height, fully opaque black.
    header_ok = True
    header_alpha = 0.0
    for y in range(2, int(header_height) - 2):
        for x in range(int(width * 0.30), int(width * 0.70)):
            if not inside(x, y):
                continue
            offset = index(x, y)
            r, g, b, a = t1[offset:offset + 4]
            header_alpha += a
            if a < 0.97 or max(r, g, b) > 0.02:
                header_ok = False
    check(header_ok, "header stays opaque black")

    # The lower body must release the absorption instead of keeping a mask.
    lower_ok = True
    for y in range(int(height * 0.72), int(height * 0.90)):
        for x in range(int(width * 0.25), int(width * 0.75)):
            if not inside(x, y):
                continue
            if t1[index(x, y) + 3] >= 0.38:
                lower_ok = False
    check(lower_ok, "lower body is not a large black mask")

    # The spatial release must actually make the lower lip clearer than the
    # belly that still carries foreground contrast. This is the pixel guard
    # for the black-to-glass retreat; it does not relax the upper threshold.
    def mean_alpha(rows: range, xs: range) -> float:
        total = 0.0
        count = 0
        for y in rows:
            for x in xs:
                if not inside(x, y):
                    continue
                total += t1[index(x, y) + 3]
                count += 1
        return total / max(1, count)

    centre_band = range(int(width * 0.35), int(width * 0.65))
    belly_alpha = mean_alpha(
        range(int(height * 0.58), int(height * 0.68)), centre_band
    )
    lip_alpha = mean_alpha(
        range(int(height * 0.82), int(height * 0.92)), centre_band
    )
    print(
        "  belly alpha %.4f, lip alpha %.4f"
        % (belly_alpha, lip_alpha)
    )
    check(
        belly_alpha - lip_alpha > 0.12,
        "lower lip releases absorption ahead of the belly",
    )

    # Regression from the actual window review: a hardware-width-only mask
    # made a dark vertical column and left the side labels unreadable. The
    # shoulder must instead be continuous across the content area.
    shoulder_continuous = True
    upper_content_readable = True
    for y in range(int(header_height) + 14, int(height * 0.62)):
        alphas = [t1[index(int(width * x), y) + 3] for x in (0.22, 0.5, 0.78)]
        if max(alphas) - min(alphas) > 0.08:
            shoulder_continuous = False
        if min(alphas) < 0.54:
            upper_content_readable = False
    check(shoulder_continuous, "shoulder has no vertical camera-width black column")
    check(upper_content_readable, "upper content retains contrast on a light backdrop")

    # Bottom strip carries a visible specular ridge when intensity is on.
    # Comparing against the same pixels at intensity zero isolates the light
    # from the remaining Beer-Lambert absorption.
    ridge_delta = 0.0
    ridge_rgb = 0.0
    for y in range(height - 12, height):
        for x in range(0, width):
            if not inside(x, y):
                continue
            offset = index(x, y)
            r, g, b, a = t1[offset:offset + 4]
            ridge_delta = max(ridge_delta, a - off[offset + 3])
            ridge_rgb = max(ridge_rgb, max(r, g, b))
    check(
        ridge_delta > 0.02 and ridge_rgb > 0.01,
        "bottom optical strip produces a local specular ridge",
    )

    # Convex bevel regression: the real straight bottom segment must carry one
    # continuous reflection. Compare against zero intensity to isolate the
    # light, then require neither a large dead run nor an overexposed band.
    edge_row = height - 3
    straight_left = int(top_radius + bottom_radius) + 8
    straight_right = int(width - top_radius - bottom_radius) - 8
    sample_x = list(range(straight_left, straight_right, 4))
    lit_samples = 0
    dead_run = 0
    longest_dead = 0
    edge_peak = 0.0
    for x in sample_x:
        if not inside(x, edge_row):
            continue
        offset = index(x, edge_row)
        off_rgb = max(off[offset:offset + 3])
        delta_t1 = max(0.0, max(t1[offset:offset + 3]) - off_rgb)
        delta_t9 = max(0.0, max(t9[offset:offset + 3]) - off_rgb)
        # Continuity must survive both time samples, not just the first one.
        delta = min(delta_t1, delta_t9)
        edge_peak = max(edge_peak, t1[offset + 3], t9[offset + 3])
        if delta > 0.003:
            lit_samples += 1
            dead_run = 0
        else:
            dead_run += 1
            longest_dead = max(longest_dead, dead_run)
    sample_count = max(1, len(sample_x))
    check(
        lit_samples / sample_count > 0.90 and longest_dead <= 4,
        "bottom straight segment keeps a continuous low-intensity reflection",
    )
    check(
        edge_peak < 0.80,
        "bottom reflection stays below overexposure",
    )

    # The convex section must differ measurably between the steep lip and the
    # flatter interior. A flat edge ramp would leave almost no difference.
    def mean_reflection(rows: range) -> float:
        total = 0.0
        count = 0
        centre_x = width // 2
        for y in rows:
            if not inside(centre_x, y):
                continue
            offset = index(centre_x, y)
            # The dark slot is black, so RGB isolates the reflection itself
            # instead of counting the intensity-scaled absorption.
            total += max(
                0.0,
                max(t1[offset:offset + 3]) - max(off[offset:offset + 3]),
            )
            count += 1
        return total / max(1, count)

    lip_mean = mean_reflection(range(height - 4, height - 1))
    interior_mean = mean_reflection(range(height - 22, height - 17))
    print(
        "  lip reflection %.5f, interior reflection %.5f"
        % (lip_mean, interior_mean)
    )
    check(
        lip_mean - interior_mean > 0.005,
        "convex bevel separates lip reflection from the flat interior",
    )

    # Time may only move the specular surface, never the content core.
    centre_delta = 0.0
    for y in range(int(header_height) + 8, height - 40):
        for x in range(int(width * 0.25), int(width * 0.75)):
            if not inside(x, y):
                continue
            offset = index(x, y)
            centre_delta = max(centre_delta, abs(t1[offset + 3] - t9[offset + 3]))
    check(centre_delta < 1e-4, "centre content domain is time invariant")

    optical_delta = 0.0
    for y in range(height - 20, height - 1):
        for x in range(0, width):
            if not inside(x, y):
                continue
            offset = index(x, y)
            optical_delta = max(
                optical_delta, abs(t1[offset + 3] - t9[offset + 3])
            )
    check(optical_delta > 0.002, "reflection varies with time only in the optical region")

    # Intensity zero removes the reflection but never the black header.
    off_header_ok = True
    for y in range(2, int(header_height) - 2):
        for x in range(int(width * 0.30), int(width * 0.70)):
            if not inside(x, y):
                continue
            offset = index(x, y)
            if abs(t1[offset + 3] - off[offset + 3]) > 1e-4:
                off_header_ok = False
            if max(off[offset:offset + 3]) > 0.02:
                off_header_ok = False
    check(off_header_ok, "zero intensity keeps the opaque black header")

    off_ridge = 0.0
    for y in range(height - 6, height):
        for x in range(0, width):
            if not inside(x, y):
                continue
            off_ridge = max(off_ridge, off[index(x, y) + 3])
    check(off_ridge < 0.02, "zero intensity removes the bottom reflection")

    # SiriGlass rim ink retreat: the shell stays clear just inside the real
    # left/right sides, while the centre keeps its continuous absorption. The
    # sample row is above the waterline so this isolates the ink retreat from
    # the voice field.
    body_row = int(height * 0.42)
    left_x = int(top_radius) + 2
    right_x = width - int(top_radius) - 3
    centre_x = width // 2
    sides_inside = (
        inside(left_x, body_row) and inside(right_x, body_row)
        and inside(centre_x, body_row)
    )
    check(sides_inside, "side-retreat sample points are inside the clipped shape")
    left_alpha = t1[index(left_x, body_row) + 3]
    right_alpha = t1[index(right_x, body_row) + 3]
    centre_alpha = t1[index(centre_x, body_row) + 3]
    print(
        "  body alpha: left %.4f centre %.4f right %.4f"
        % (left_alpha, centre_alpha, right_alpha)
    )
    check(
        max(left_alpha, right_alpha) < centre_alpha - 0.05,
        "body side edges let more shell through than the centre",
    )
    check(
        abs(left_alpha - right_alpha) < 0.05,
        "left and right ink retreat are symmetric",
    )

    # The added motion parameter may never move the header or the content
    # area; the voice field lives only in the lowest 24pt.
    header_motion_ok = True
    for y in range(2, int(header_height) - 2):
        for x in range(int(width * 0.30), int(width * 0.70)):
            if not inside(x, y):
                continue
            offset = index(x, y)
            if any(
                abs(t1[offset + channel] - active[offset + channel]) > 1e-6
                for channel in range(4)
            ):
                header_motion_ok = False
    check(header_motion_ok, "motion state leaves the black header unchanged")

    motion_above = 0.0
    for y in range(int(header_height), int(height) - 25):
        for x in range(int(width * 0.20), int(width * 0.80)):
            if not inside(x, y):
                continue
            offset = index(x, y)
            motion_above = max(
                motion_above,
                max(
                    abs(active[offset + channel] - t1[offset + channel])
                    for channel in range(4)
                ),
            )
    check(motion_above < 1e-6, "motion state never touches the content area")

    motion_bottom = 0.0
    for y in range(int(height) - 20, int(height) - 1):
        for x in range(int(width * 0.20), int(width * 0.80)):
            if not inside(x, y):
                continue
            offset = index(x, y)
            motion_bottom = max(
                motion_bottom,
                max(
                    abs(active[offset + channel] - t1[offset + channel])
                    for channel in range(4)
                ),
            )
    check(
        motion_bottom > 0.002,
        "active and idle differ only in the bottom optical strip",
    )

    body_end = (height - 37) * width * 4
    check(music_on[:body_end] == music_silence[:body_end],
          "music energy does not alter the controls, header or glass above the bottom strip")
    music_lift = max(on - off for on, off in zip(music_on[body_end:], music_silence[body_end:]))
    check(music_lift > 0.08, "real music levels visibly brighten the bottom field")

    def crest_row(pixels):
        columns = range(width // 2 - 12, width // 2 + 13)
        return max(range(height - 37, height - 2), key=lambda y: sum(
            pixels[(y * width + x) * 4] - music_silence[(y * width + x) * 4]
            for x in columns
        ))

    quiet_crest = crest_row(music_soft)
    strong_crest = crest_row(music_on)
    print(f"  music crest: quiet y={quiet_crest}, strong y={strong_crest}, vertical travel={quiet_crest - strong_crest}px")
    check(quiet_crest - strong_crest >= 12,
          "a strong musical accent physically raises the optical crest")
    centre_x = width // 2
    row_response = [
        music_on[(y * width + centre_x) * 4] - music_silence[(y * width + centre_x) * 4]
        for y in range(height - 37, height - 2)
    ]
    check(sum(value >= max(row_response) * 0.5 for value in row_response) >= 8,
          "the audio crest keeps a broad white core and halo")
    check(max(t1[i] - music_silence[i] for i in range(body_end, len(t1), 4)) >= 0.035,
          "idle glass retains its visible layered white light")

    def midrange_delta(x):
        return max(
            music_mids[index(x, y)] - music_silence[index(x, y)]
            for y in range(height - 37, height - 2)
        )

    check(min(midrange_delta(int(width * 0.26)), midrange_delta(int(width * 0.74)))
          > midrange_delta(width // 2) + 0.08,
          "midrange spreads two separate pools of white light out to the sides")

    # Intensity zero must erase the voice field and its shadow even when the
    # motion state is active: the two zero-intensity renders are identical.
    off_motion_delta = 0.0
    for offset in range(0, expected, 4):
        off_motion_delta = max(
            off_motion_delta,
            max(
                abs(off[offset + channel] - off_idle[offset + channel])
                for channel in range(4)
            ),
        )
    check(
        off_motion_delta < 1e-6,
        "zero intensity removes the voice field and shadow when motion is active",
    )

    # Clipping corners come from the production outline, not the shader rect.
    check(mask[0] == 0, "top-left rect corner is outside the clipped shape")
    check(mask[(height - 1) * width] == 0, "bottom-left rect corner is outside the clipped shape")
    check(mask[height * width - 1] == 0, "bottom-right rect corner is outside the clipped shape")
    check(
        sum(mask) > (width * height) // 2,
        "clipped shape still covers the majority of the grid",
    )

    return 0


def main() -> int:
    if not GEOMETRY_SOURCE.is_file():
        print("FAIL missing " + str(GEOMETRY_SOURCE))
        return 1
    if not METAL_SOURCE.is_file():
        print("FAIL missing " + str(METAL_SOURCE))
        return 1
    if shutil.which("swiftc") is None:
        print("NOT VERIFIED: swiftc is unavailable")
        return 2

    with tempfile.TemporaryDirectory(prefix="notch-optical-") as directory:
        tmp = pathlib.Path(directory)
        run_geometry_tests(tmp)
        if FAILURES:
            print("RESULT: FAIL (%d assertion(s))" % len(FAILURES))
            return 1
        metal_result = run_metal_tests(tmp)
        if metal_result == 2:
            print("RESULT: NOT VERIFIED (geometry passed, GPU stage not run)")
            return 2
        if metal_result != 0 or FAILURES:
            print("RESULT: FAIL (%d assertion(s))" % len(FAILURES))
            return 1

    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
