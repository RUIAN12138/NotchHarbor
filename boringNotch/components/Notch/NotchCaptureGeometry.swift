import Foundation
import CoreGraphics

/// Geometry only: Quartz screen coordinates, in points, with top-left origin.
/// Pure coordinate conversion, independent of screen access.
struct NotchCaptureGeometry {
    struct Plan: Equatable {
        let displayID: UInt32
        let captureRect: CGRect
        let sourceRect: CGRect
        let pixelWidth: Int
        let pixelHeight: Int
        let glassOriginUV: CGPoint
        let glassSizeUV: CGSize
    }

    struct Display: Equatable {
        let id: UInt32
        let frame: CGRect
        let pixelsPerPoint: CGFloat
    }

    /// Intersects the sampling margin with the selected display. The notch
    /// itself must be fully on one display: crossing displays requires separate
    /// captures and is deliberately rejected rather than sampled incorrectly.
    static func plan(glassRect: CGRect, display: Display, margin: CGFloat) -> Plan? {
        let values = [glassRect.minX, glassRect.minY, glassRect.width, glassRect.height,
                      display.frame.minX, display.frame.minY, display.frame.width,
                      display.frame.height, display.pixelsPerPoint, margin]
        guard values.allSatisfy(\.isFinite), glassRect.width > 0, glassRect.height > 0,
              display.frame.width > 0, display.frame.height > 0,
              display.pixelsPerPoint > 0, margin >= 0,
              display.frame.contains(glassRect) else { return nil }
        let desired = glassRect.insetBy(dx: -margin, dy: -margin)
        let clipped = desired.intersection(display.frame)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }

        // Align to physical pixels without sampling outside the display.
        let scale = display.pixelsPerPoint
        let minX = max(display.frame.minX, floor((clipped.minX - display.frame.minX) * scale) / scale + display.frame.minX)
        let minY = max(display.frame.minY, floor((clipped.minY - display.frame.minY) * scale) / scale + display.frame.minY)
        let maxX = min(display.frame.maxX, ceil((clipped.maxX - display.frame.minX) * scale) / scale + display.frame.minX)
        let maxY = min(display.frame.maxY, ceil((clipped.maxY - display.frame.minY) * scale) / scale + display.frame.minY)
        let capture = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard capture.width > 0, capture.height > 0 else { return nil }
        let pixelWidth = capture.width * scale
        let pixelHeight = capture.height * scale
        // Reject nonsensical values before converting to Int or allocating a texture.
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth >= 1, pixelHeight >= 1,
              pixelWidth <= 16384, pixelHeight <= 16384 else { return nil }
        return Plan(displayID: display.id,
                    captureRect: capture,
                    sourceRect: capture.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY),
                    pixelWidth: Int(pixelWidth.rounded()),
                    pixelHeight: Int(pixelHeight.rounded()),
                    glassOriginUV: CGPoint(x: (glassRect.minX - capture.minX) / capture.width,
                                           y: (glassRect.minY - capture.minY) / capture.height),
                    glassSizeUV: CGSize(width: glassRect.width / capture.width,
                                        height: glassRect.height / capture.height))
    }
}
