import AppKit
import CoreMedia
import CoreVideo
import MetalKit
import OSLog
import ScreenCaptureKit
import SwiftUI

/// Refraction samples the desktop below the existing optical surface. The
/// parent shell owns the visible outline and leaves the system material behind
/// this layer until the first usable frame arrives.
struct NotchDesktopRefraction: NSViewRepresentable {
    var shape: NotchShape
    var intensity: Double
    var previewCaptureSize: CGSize? = nil
    var textContrastChanged: ((Bool?) -> Void)? = nil

    func makeNSView(context: Context) -> RefractionHost {
        let host = RefractionHost()
        host.previewCaptureSize = previewCaptureSize
        return host
    }

    func updateNSView(_ host: RefractionHost, context: Context) {
        let level = Float(intensity.isFinite ? min(1, max(0, intensity)) : 1)
        host.textContrastChanged = textContrastChanged
        host.previewCaptureSize = previewCaptureSize
        guard host.shape.animatableData != shape.animatableData || host.intensity != level else { return }
        host.shape = shape
        host.intensity = level
        host.invalidateSurface()
    }

    static func dismantleNSView(_ host: RefractionHost, coordinator: ()) {
        host.disconnect()
    }
}

/// Uses the Lab's ScreenCaptureKit → CVMetalTexture path. A frame retains both
/// objects through completion of the GPU command that consumes it.
private struct RefractionFrame: @unchecked Sendable {
    let backing: CVMetalTexture
    let texture: MTLTexture
    let pixels: CVPixelBuffer
}

private final class RefractionStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let cache: CVMetalTextureCache
    private let onFrame: (SCStream, RefractionFrame) -> Void
    private let onStop: (SCStream) -> Void

    init(cache: CVMetalTextureCache, onFrame: @escaping (SCStream, RefractionFrame) -> Void,
         onStop: @escaping (SCStream) -> Void) {
        self.cache = cache
        self.onFrame = onFrame
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, let buffer = sampleBuffer.imageBuffer,
              let info = (CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]])?.first,
              (info[.status] as? Int) == SCFrameStatus.complete.rawValue else { return }

        var backing: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &backing
        )
        guard result == kCVReturnSuccess, let backing,
              let texture = CVMetalTextureGetTexture(backing) else { return }
        onFrame(stream, RefractionFrame(backing: backing, texture: texture, pixels: buffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(stream)
    }
}

final class RefractionHost: NSView {
    private static let log = Logger(subsystem: "com.notchharbor.app", category: "DesktopRefraction")
    var shape = NotchShape()
    var intensity: Float = 1
    var previewCaptureSize: CGSize? {
        didSet {
            if previewCaptureSize != oldValue { needsLayout = true }
        }
    }

    private struct Location: Equatable {
        let windowNumber: Int
        let displayID: CGDirectDisplayID
        let windowRect: CGRect
        let samplingRect: CGRect
        let backingScale: CGFloat

        init?(window: NSWindow, previewRegion: CGRect?) {
            guard let screen = window.screen,
                  let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let main = NSScreen.screens.first(where: {
                      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                          == CGMainDisplayID()
                  }) else { return nil }
            self.windowNumber = window.windowNumber
            displayID = id.uint32Value
            backingScale = window.backingScaleFactor
            let rect = CGRect(x: window.frame.minX, y: main.frame.maxY - window.frame.maxY,
                              width: window.frame.width, height: window.frame.height)
            windowRect = rect
            samplingRect = previewRegion.map { region in
                RefractionHost.rectForCapture(region, window: window, windowRect: rect).integral
            } ?? rect
        }
    }

    private static func rectForCapture(_ rect: CGRect, window: NSWindow, windowRect: CGRect) -> CGRect {
        let screenRect = window.convertToScreen(rect)
        let desktopTop = windowRect.minY + window.frame.maxY
        return CGRect(x: screenRect.minX, y: desktopTop - screenRect.maxY,
                      width: screenRect.width, height: screenRect.height)
    }

    private var previewRegion: CGRect? {
        guard let size = previewCaptureSize, bounds.width > 0, bounds.height > 0 else { return nil }
        let rect = convert(bounds, to: nil)
        return CGRect(x: (rect.midX - size.width / 2).rounded(), y: rect.maxY.rounded() - size.height,
                      width: size.width, height: size.height)
    }

    private let surface: MTKView
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var cache: CVMetalTextureCache?
    private let sampleQueue = DispatchQueue(label: "boringNotch.refraction.frames", qos: .userInitiated)
    private var output: RefractionStreamOutput?
    private var stream: SCStream?
    private var startup: Task<Void, Never>?
    private var generation = 0
    private var location: Location?
    private var captureRect: CGRect?
    private var latestFrame: RefractionFrame?
    private var drawScheduled = false
    private var inFlight = false
    private var dirty = false
    var textContrastChanged: ((Bool?) -> Void)?
    private var brightBackdrop: Bool?
    private var contrastSampleAfter = ContinuousClock.Instant.now
    private var screenLocked = false
    private var displayAsleep = false

    override init(frame frameRect: NSRect) {
        let device = MTLCreateSystemDefaultDevice()
        surface = MTKView(frame: .zero, device: device)
        super.init(frame: frameRect)
        wantsLayer = true
        surface.wantsLayer = true
        surface.layer?.isOpaque = false
        surface.layer?.opacity = 0
        surface.autoresizingMask = [.width, .height]
        surface.colorPixelFormat = .bgra8Unorm
        surface.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        surface.clearColor = MTLClearColorMake(0, 0, 0, 0)
        surface.isPaused = true
        surface.enableSetNeedsDisplay = false
        surface.autoResizeDrawable = false
        addSubview(surface)

        if let device, let library = try? device.makeDefaultLibrary(bundle: .main) {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "notchBackdropVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "notchRefractedBackdrop")
            descriptor.colorAttachments[0].pixelFormat = surface.colorPixelFormat
            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
            queue = device.makeCommandQueue()
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        }

        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        screenLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(didLock), name: .init("com.apple.screenIsLocked"), object: nil)
        center.addObserver(self, selector: #selector(didUnlock), name: .init("com.apple.screenIsUnlocked"), object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(displaysSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(displaysWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: nil, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                         NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
                         NSWindow.didChangeOcclusionStateNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowChanged), name: name, object: window
                )
            }
        }
        updateCapture()
    }

    override func layout() {
        super.layout()
        // AppKit autoresizes the child. Only request a draw after layout,
        // and leave drawable updates to that draw pass.
        if previewCaptureSize != nil { updateCapture() }
        if surface.drawableSize != bounds.size { invalidateSurface() }
    }

    @objc private func didLock() { screenLocked = true; updateCapture() }
    @objc private func didUnlock() { screenLocked = false; updateCapture() }
    @objc private func displaysSleep() { displayAsleep = true; updateCapture() }
    @objc private func displaysWake() { displayAsleep = false; updateCapture() }
    @objc private func windowChanged() { updateCapture() }

    func disconnect() {
        location = nil
        stopCapture()
    }

    private func stopCapture() {
        generation += 1
        startup?.cancel()
        startup = nil
        latestFrame = nil
        dirty = false
        captureRect = nil
        surface.layer?.opacity = 0
        if brightBackdrop != nil {
            brightBackdrop = nil
            let notify = textContrastChanged
            DispatchQueue.main.async { notify?(nil) }
        }
        if let stream { stream.stopCapture { _ in } }
        stream = nil
        output = nil
    }

    private func updateCapture() {
        guard !screenLocked, !displayAsleep, let window, window.isVisible,
              window.occlusionState.contains(.visible), !window.isMiniaturized,
              previewCaptureSize == nil || previewRegion != nil,
              let location = Location(window: window, previewRegion: previewRegion) else {
            disconnect()
            return
        }
        guard self.location != location else { return }
        stopCapture()
        self.location = location
        guard pipeline != nil, let cache, CGPreflightScreenCaptureAccess() else { return }

        let token = generation
        startup = Task { [weak self] in
            // ScreenCaptureKit completes on its own queue; do not hold the NSView
            // alive across an open/close or a display move.
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            ), let self, !Task.isCancelled, token == self.generation,
                let display = content.displays.first(where: { $0.displayID == location.displayID }) else { return }
            let applications = content.applications.filter { $0.processID == getpid() }
            let windows = content.windows.filter {
                $0.owningApplication?.processID == getpid() || $0.windowID == CGWindowID(location.windowNumber)
            }

            // Fail closed if ScreenCaptureKit cannot identify either the owning
            // application or this exact panel. Never feed the glass back into itself.
            guard !applications.isEmpty ||
                    windows.contains(where: { $0.windowID == CGWindowID(location.windowNumber) }) else { return }
            let filter = windows.contains(where: { $0.windowID == CGWindowID(location.windowNumber) })
                ? SCContentFilter(display: display, excludingWindows: windows)
                : SCContentFilter(display: display, excludingApplications: applications, exceptingWindows: [])
            if #available(macOS 14.2, *) { filter.includeMenuBar = true }
            let glassRect = location.samplingRect.intersection(display.frame)
            guard let plan = NotchCaptureGeometry.plan(
                glassRect: glassRect, display: .init(id: display.displayID, frame: display.frame,
                                                     pixelsPerPoint: min(1, CGFloat(filter.pointPixelScale))),
                margin: 28
            ), plan.pixelWidth <= 4096, plan.pixelHeight <= 1536 else { return }

            let configuration = SCStreamConfiguration()
            configuration.sourceRect = plan.sourceRect
            configuration.width = plan.pixelWidth
            configuration.height = plan.pixelHeight
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 8)
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.shouldBeOpaque = true
            configuration.scalesToFit = true
            configuration.queueDepth = 3

            let output = RefractionStreamOutput(cache: cache) { [weak self] source, frame in
                DispatchQueue.main.async {
                    guard let self, self.stream === source, token == self.generation,
                          frame.texture.width == plan.pixelWidth,
                          frame.texture.height == plan.pixelHeight else { return }
                    self.latestFrame = frame
                    self.invalidateSurface()
                }
            } onStop: { [weak self] source in
                DispatchQueue.main.async {
                    guard let self, self.stream === source, token == self.generation else { return }
                    self.stopCapture()
                }
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
            do {
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: self.sampleQueue)
                self.stream = stream
                self.output = output
                self.captureRect = plan.captureRect
                try await stream.startCapture()
                if Task.isCancelled || token != self.generation { try? await stream.stopCapture() }
            } catch {
                if token == self.generation { self.stopCapture() }
            }
        }
    }

    func invalidateSurface() {
        dirty = true
        guard latestFrame != nil, !inFlight, !drawScheduled else { return }
        drawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.drawScheduled = false
            self.drawFrame()
        }
    }

    private func sampleTextContrast(frame: RefractionFrame, local: CGRect, capture: CGRect) {
        let now = ContinuousClock.now
        guard textContrastChanged != nil, now >= contrastSampleAfter, local.height >= 28 else { return }
        contrastSampleAfter = now + .milliseconds(500)
        // Match the visible panel, rather than the full transparent window or the capture margin.
        let area = CGRect(x: (local.minX - capture.minX) / capture.width,
                          y: (local.minY - capture.minY) / capture.height,
                          width: local.width / capture.width, height: local.height / capture.height)
        let pixels = frame.pixels
        let token = generation
        sampleQueue.async { [weak self] in
            guard let coverage = Self.brightCoverage(pixels, area: area) else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                let bright = coverage >= (self.brightBackdrop == true ? 0.23 : 0.38)
                guard bright != self.brightBackdrop else { return }
                self.brightBackdrop = bright
                self.textContrastChanged?(bright)
            }
        }
    }

    private nonisolated static func brightCoverage(_ pixels: CVPixelBuffer, area: CGRect) -> Double? {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        var samples = 0
        var bright = 0
        var brightestRow = 0.0
        for row in 0..<5 {
            var rowBright = 0
            var rowSamples = 0
            let y = area.minY + area.height * (0.24 + Double(row) * 0.15)
            for column in 0..<7 {
                let x = area.minX + area.width * (0.13 + Double(column) * 0.122)
                guard (0..<1).contains(x), (0..<1).contains(y) else { continue }
                let offset = Int(y * Double(height)) * stride + Int(x * Double(width)) * 4
                let blue = Double(base.load(fromByteOffset: offset, as: UInt8.self))
                let green = Double(base.load(fromByteOffset: offset + 1, as: UInt8.self))
                let red = Double(base.load(fromByteOffset: offset + 2, as: UInt8.self))
                if red * 0.2126 + green * 0.7152 + blue * 0.0722 >= 180 { rowBright += 1 }
                rowSamples += 1
            }
            bright += rowBright
            samples += rowSamples
            // One bright band can sit under a whole line of text on mixed backgrounds.
            if rowSamples >= 4 { brightestRow = max(brightestRow, Double(rowBright) / Double(rowSamples)) }
        }
        return samples > 0 ? max(brightestRow, Double(bright) / Double(samples)) : nil
    }

    private func drawFrame() {
        guard dirty, !inFlight, let captureRect, let frame = latestFrame, let location, let window,
              let queue, let pipeline, bounds.width > 0, bounds.height > 0 else { return }
        let windowRect = convert(bounds, to: nil)
        let local = Self.rectForCapture(windowRect, window: window, windowRect: location.windowRect)
        sampleTextContrast(frame: frame, local: local, capture: captureRect)
        // The desktop input uses a point-sized drawable. Updating it on
        // the deferred draw path avoids changing the layer during layout.
        if surface.drawableSize != bounds.size { surface.drawableSize = bounds.size }
        guard let descriptor = surface.currentRenderPassDescriptor, let drawable = surface.currentDrawable,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }
        let geometry = shape.surfaceGeometry(in: CGRect(origin: .zero, size: local.size))
        var uniforms = [
            SIMD4<Float>(Float(local.width), Float(local.height), Float(geometry.encodedTopRadius),
                         Float(geometry.bottomCornerRadius)),
            SIMD4<Float>(Float((local.minX - captureRect.minX) / captureRect.width),
                         Float((local.minY - captureRect.minY) / captureRect.height),
                         Float(1 / captureRect.width), Float(1 / captureRect.height)),
            SIMD4<Float>(intensity, 0, 0, 0),
        ]
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(frame.texture, index: 0)
        uniforms.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            encoder.setFragmentBytes(base, length: bytes.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        let token = generation
        inFlight = true
        dirty = false
        command.addCompletedHandler { [weak self, frame] command in
            withExtendedLifetime(frame) {}
            let rendered = command.status == .completed
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                if rendered, token == self.generation, self.surface.layer?.opacity != 1 {
                    self.surface.layer?.opacity = 1
                    Self.log.info("Displayed the first live desktop refraction frame")
                }
                if self.dirty { self.invalidateSurface() }
            }
        }
        command.commit()
    }
}
