//
//  sizeMatters.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 05/08/24.
//

import Defaults
import Foundation
import SwiftUI

let downloadSneakSize: CGSize = .init(width: 65, height: 1)
let batterySneakSize: CGSize = .init(width: 160, height: 1)

let shadowPadding: CGFloat = 20
let openNotchSize: CGSize = .init(width: 640, height: 210)
let windowSize: CGSize = .init(width: openNotchSize.width, height: openNotchSize.height + shadowPadding)
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))

/// AppKit screen coordinates; the trigger never includes the system island.
enum SystemIslandHoverGeometry {
    static let gap: CGFloat = 4
    static let height: CGFloat = 14
    struct AgentWings {
        var left: CGRect
        var right: CGRect
        var frame: CGRect { left.union(right) }
        func contains(_ point: CGPoint) -> Bool {
            [left, right].contains { rect in
                !rect.isNull && point.x >= rect.minX && point.x < rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
            }
        }
    }
    static let agentWingWidth: CGFloat = 34
    static func capsuleContains(_ point: CGPoint, screen: CGRect, width: CGFloat, height: CGFloat) -> Bool {
        guard width.isFinite, height.isFinite, height > 0, width >= height,
              screen.width >= width, screen.height >= height else { return false }
        let radius = height / 2
        let x = abs(point.x - screen.midX)
        let y = screen.maxY - point.y
        guard x < width / 2, y >= 0, y <= height else { return false }
        let curvedX = max(0, x - (width / 2 - radius))
        let centeredY = y - radius
        return curvedX * curvedX + centeredY * centeredY <= radius * radius
    }
    static func agentWings(screen: CGRect, centerWidth: CGFloat, height: CGFloat) -> AgentWings {
        guard screen.width.isFinite, screen.height.isFinite, screen.minX.isFinite, screen.minY.isFinite,
              centerWidth.isFinite, height.isFinite, centerWidth >= 0, height > 0,
              screen.height > height, screen.width > centerWidth + 2 * agentWingWidth else {
            return AgentWings(left: .null, right: .null)
        }
        return AgentWings(
            left: CGRect(x: screen.midX - centerWidth / 2 - agentWingWidth, y: screen.maxY - height,
                         width: agentWingWidth, height: height),
            right: CGRect(x: screen.midX + centerWidth / 2, y: screen.maxY - height,
                          width: agentWingWidth, height: height))
    }
    static func compactAlertWidth(reserved: CGFloat?, measured: CGFloat, fallback: CGFloat, available: CGFloat) -> CGFloat {
        let width = [reserved ?? 0, measured, fallback].first { $0.isFinite && $0 > 0 } ?? 240
        return min(width, available.isFinite && available > 0 ? available : width)
    }

    static func expandedWidth(island: CGFloat, available: CGFloat) -> CGFloat {
        guard island.isFinite, available.isFinite, island > 0, available > 0 else { return 500 }
        return min(available, island * 2)
    }

    static func expandedHeight(content: CGFloat) -> CGFloat? {
        guard content.isFinite, content > 0 else { return nil }
        return min(480, max(120, ceil(content)))
    }

    static func clearanceWidth(physical: CGFloat, observed: CGFloat) -> CGFloat {
        // Reserve the measured compact JD wings when Accessibility access is unavailable.
        let fallback = max(0, physical.isFinite ? physical : 185) + 108
        return observed.isFinite ? max(fallback, observed) : fallback
    }

    static func shelfDropFrame(screen: CGRect, width: CGFloat, height: CGFloat, topInset: CGFloat) -> CGRect {
        guard width > 0, height > topInset, topInset >= 0,
              screen.width > 0, screen.height > 0 else { return .null }
        let width = min(width, screen.width)
        let height = min(height, screen.height)
        guard height > topInset else { return .null }
        return CGRect(x: screen.midX - width / 2, y: screen.maxY - height,
                      width: width, height: height - topInset)
    }

    static func triggerFrame(screen: CGRect, islandHeight: CGFloat, width: CGFloat) -> CGRect {
        guard screen.width.isFinite, screen.height.isFinite, screen.minX.isFinite,
              screen.minY.isFinite, islandHeight.isFinite, width.isFinite,
              screen.width > 0, screen.height > islandHeight + gap + height,
              islandHeight > 0, width > 0 else { return .null }
        let width = min(width, screen.width)
        return CGRect(x: screen.midX - width / 2,
                      y: screen.maxY - islandHeight - gap - height,
                      width: width, height: height)
    }
}

struct ShelfDropLayout {
    let size: CGSize
    static let tileInset: CGFloat = 5

    var shareSize: CGFloat { min(104, size.height, size.width * 0.30) }
    var shelfLeading: CGFloat { min(size.width, shareSize + 5) }

    var shelf: CGRect {
        CGRect(x: shelfLeading, y: 0, width: max(0, size.width - shelfLeading - 4), height: size.height)
    }
}

/// Accessibility may briefly return an empty island while its compact contents are being mounted.
struct SystemIslandVacancy {
    private var emptySince: TimeInterval?
    private(set) var awaitingConfirmation = false

    static func requiresConfirmationOnClose(at now: TimeInterval, lastVacantSample: TimeInterval?,
                                            nativePresentationActive: Bool) -> Bool {
        guard !nativePresentationActive, let lastVacantSample else { return true }
        return !(0...0.30).contains(now - lastVacantSample)
    }

    mutating func observe(width: CGFloat?, expanded: Bool, at now: TimeInterval,
                          since latestClose: TimeInterval?) -> Bool {
        guard width == 0, !expanded else {
            emptySince = nil
            awaitingConfirmation = false
            return false
        }
        if emptySince == nil { emptySince = now }
        let start = max(emptySince ?? now, latestClose ?? -Double.infinity)
        awaitingConfirmation = now - start < 0.65
        return !awaitingConfirmation
    }
}

enum MusicPlayerImageSizes {
    static let cornerRadiusInset: (opened: CGFloat, closed: CGFloat) = (opened: 13.0, closed: 4.0)
    static let size = (opened: CGSize(width: 90, height: 90), closed: CGSize(width: 20, height: 20))
}

@MainActor func getScreenFrame(_ screenUUID: String? = nil) -> CGRect? {
    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }
    
    if let screen = selectedScreen {
        return screen.frame
    }
    
    return nil
}

/// Physical camera clearance in AppKit points, independent of the preferred
/// height of the closed software notch.
@MainActor func getPhysicalNotchSize(screenUUID: String?) -> CGSize? {
    let screen = screenUUID.map { NSScreen.screen(withUUID: $0) } ?? NSScreen.main
    guard let screen, screen.safeAreaInsets.top > 0,
          let left = screen.auxiliaryTopLeftArea,
          let right = screen.auxiliaryTopRightArea else { return nil }

    let width = right.minX - left.maxX
    guard width > 0, width < screen.frame.width else { return nil }
    return CGSize(width: width, height: screen.safeAreaInsets.top)
}

@MainActor func getClosedNotchSize(screenUUID: String? = nil) -> CGSize {
    // Default notch size, to avoid using optionals
    var notchHeight: CGFloat = Defaults[.nonNotchHeight]
    var notchWidth: CGFloat = 185

    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }

    // Check if the screen is available
    if let screen = selectedScreen {
        // Calculate and set the exact width of the notch
        if let topLeftNotchpadding: CGFloat = screen.auxiliaryTopLeftArea?.width,
           let topRightNotchpadding: CGFloat = screen.auxiliaryTopRightArea?.width
        {
            notchWidth = screen.frame.width - topLeftNotchpadding - topRightNotchpadding + 4
        }

        // Check if the Mac has a notch
        if screen.safeAreaInsets.top > 0 {
            // This is a display WITH a notch - use notch height settings
            notchHeight = Defaults[.notchHeight]
            if Defaults[.notchHeightMode] == .matchRealNotchSize {
                notchHeight = screen.safeAreaInsets.top
            } else if Defaults[.notchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        } else {
            // This is a display WITHOUT a notch - use non-notch height settings
            notchHeight = Defaults[.nonNotchHeight]
            if Defaults[.nonNotchHeightMode] == .matchRealNotchSize {
                notchHeight = 32
            } else if Defaults[.nonNotchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        }
    }

    return .init(width: notchWidth, height: notchHeight)
}
