//
//  FileShareView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct FileShareView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @StateObject private var quickShare = QuickShareService.shared
    @Default(.quickShareProvider) var quickShareProvider: String

    @State private var hostView: NSView?
    @State private var isProcessing = false
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    private var selectedProvider: QuickShareProvider {
        if let provider = quickShare.availableProviders.first(where: { $0.id == quickShareProvider }) {
            return provider
        }
        let airDrop = NSSharingService(named: .sendViaAirDrop)
        if quickShareProvider == "AirDrop" || quickShareProvider == airDrop?.title {
            return QuickShareProvider(id: "AirDrop", imageData: nil, supportsRawText: false)
        }
        return QuickShareProvider(id: "System Share Menu", imageData: nil, supportsRawText: true)
    }

    var body: some View {
        dropArea
            .background(NSViewHost(view: $hostView))
            .onDrop(of: [.fileURL], isTargeted: $vm.dropZoneTargeting) { providers in
                let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
                guard !ShelfSelectionModel.shared.isDragging, !files.isEmpty, !isProcessing else { return false }
                vm.dropEvent = true
                isProcessing = true
                SharingStateManager.shared.beginInteraction()
                Task { await handleDrop(files) }
                return true
            }
            .onTapGesture { Task { await handleClick() } }
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovering)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { Task { await handleClick() } }
            .help("选取文件并分享")
    }

    private var dropArea: some View {
        ShelfTileSurface(targeted: vm.dropZoneTargeting, highlighted: isHovering || isProcessing)
            .overlay {
                VStack(spacing: 5) {
                    if isProcessing || quickShare.isPickerOpen {
                        ProgressView().controlSize(.small).frame(height: 48)
                    } else {
                        ZStack {
                            Circle().fill(.white.opacity(vm.dropZoneTargeting ? 0.11 : 0.09))
                            Image(systemName: "square.and.arrow.up")
                            Group {
                                if let data = selectedProvider.imageData, let artwork = NSImage(data: data) {
                                    Image(nsImage: artwork).resizable().scaledToFit()
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                            .frame(width: 34, height: 34)
                            .foregroundStyle(vm.dropZoneTargeting ? Color.accentColor : .gray)
                            .scaleEffect(vm.dropZoneTargeting ? 1.06 : 1)
                            .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.7),
                                       value: vm.dropZoneTargeting)
                        }
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    }
                    if selectedProvider.isAirDrop {
                        Text("隔空投送").font(.system(size: 12, weight: .semibold))
                    } else {
                        Text(LocalizedStringKey(selectedProvider.id == "System Share Menu" ? "分享文件" : selectedProvider.id))
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .lineLimit(1)
                .foregroundStyle(vm.dropZoneTargeting ? Color.accentColor : .primary)
                .sharedGlassForeground()
                .padding(.horizontal, 4)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13))
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) async {
        defer {
            isProcessing = false
            SharingStateManager.shared.endInteraction()
        }
        await quickShare.shareDroppedFiles(providers, using: selectedProvider, from: hostView)
    }
    
    private func handleClick() async {
        await quickShare.showFilePicker(for: selectedProvider, from: hostView)
    }
}

// MARK: - Host NSView extractor for anchoring share sheet

private struct NSViewHost: NSViewRepresentable {
    @Binding var view: NSView?
    
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { self.view = v }
        return v
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        guard view !== nsView else { return }
        DispatchQueue.main.async { if self.view !== nsView { self.view = nsView } }
    }
}
