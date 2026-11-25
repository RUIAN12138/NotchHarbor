//
//  SettingsWindowController.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-14.
//

import AppKit
import SwiftUI
import Defaults
import Sparkle

@MainActor
final class SettingsPreviewSession: ObservableObject {
    @Published var liveModel: BoringViewModel?
}

private final class AppearanceTransitionCover: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private let previewSession = SettingsPreviewSession()
    private weak var themeCover: AppearanceTransitionCover?
    var previewModel: (() -> BoringViewModel?)?
    private var updaterController: SPUStandardUpdaterController?
    
    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 872, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        super.init(window: window)
        
        setupWindow()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setUpdaterController(_ controller: SPUStandardUpdaterController?) {
        self.updaterController = controller
        // Recreate the content view with the proper updater controller
        setupWindow()
    }
    
    private func setupWindow() {
        guard let window = window else { return }
        
        window.title = "Notch Harbor 设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentMinSize = NSSize(width: 770, height: 510)
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        
        window.collectionBehavior = [.moveToActiveSpace, .participatesInCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        
        // Ensure proper window behavior
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = false
        
        // Configure window to be a standard document-style window
        window.isRestorable = false
        window.identifier = NSUserInterfaceItemIdentifier("BoringNotchSettingsWindow")
        
        // Create the SwiftUI content
        let settingsView = SettingsView(previewSession: previewSession, updaterController: updaterController) { [weak window] language in
            window?.title = language == "en" ? "Notch Harbor Settings" : "Notch Harbor 设置"
        }
        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.sizingOptions = []
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        window.contentView = container
        
        // Handle window closing
        window.delegate = self
    }
    
    func switchAppearance(to mode: HarborAppearance, animated: Bool) {
        guard Defaults[.appAppearance] != mode else { return }
        let appearance = mode.name.flatMap { NSAppearance(named: $0) }
        let choices: [NSAppearance.Name] = [.aqua, .darkAqua]
        let previousPalette = window?.effectiveAppearance.bestMatch(from: choices)
        let cover = animated ? makeThemeCover() : nil

        Defaults[.appAppearance] = mode
        NSApp.appearance = appearance

        guard let cover else { return }
        // Let AppKit and SwiftUI resolve the new appearance under the cover.
        DispatchQueue.main.async { [weak self, weak cover] in
            guard let self, let cover, self.themeCover === cover else { return }
            if self.window?.effectiveAppearance.bestMatch(from: choices) == previousPalette {
                cover.removeFromSuperview()
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                cover.animator().alphaValue = 0
            } completionHandler: { [weak cover] in
                cover?.removeFromSuperview()
            }
        }
    }

    private func makeThemeCover() -> AppearanceTransitionCover? {
        guard let window, window.isVisible, !window.isMiniaturized, let content = window.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        themeCover?.removeFromSuperview()
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(bitmap)
        let cover = AppearanceTransitionCover(frame: content.bounds)
        cover.image = image
        cover.imageScaling = .scaleAxesIndependently
        cover.autoresizingMask = [.width, .height]
        cover.setAccessibilityElement(false)
        content.addSubview(cover, positioned: .above, relativeTo: nil)
        themeCover = cover
        return cover
    }

    func showWindow() {
        guard let window else { return }
        previewSession.liveModel = previewModel?()
        NSApp.setActivationPolicy(.regular)
        // Run after the notch panel's non-activating mouse event has finished.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            if NSApp.isHidden { NSApp.unhide(nil) }
            NSApp.activate(ignoringOtherApps: true)
            if window.isMiniaturized { window.deminiaturize(nil) }
            if !window.isVisible { window.center() }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
    
    override func close() {
        super.close()
        relinquishFocus()
    }
    
    private func relinquishFocus() {
        themeCover?.removeFromSuperview()
        previewSession.liveModel = nil
        window?.orderOut(nil)
        
        // Set app back to accessory mode immediately
        NSApp.setActivationPolicy(.accessory)
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        relinquishFocus()
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return true
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        // Ensure app is in regular mode when window becomes key
        NSApp.setActivationPolicy(.regular)
    }
    
    func windowDidResignKey(_ notification: Notification) {
    }
    
}
