//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit

struct ShelfView: View {
    @EnvironmentObject var vm: BoringViewModel
    @Environment(\.usesSharedGlassShell) private var usesSharedGlassShell
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    private let spacing: CGFloat = 8

    private var isPanelTargeted: Bool {
        vm.dragDetectorTargeting || vm.windowDropTargeting || vm.generalDropTargeting
    }

    /// An internal item drag is rejected by `handleDrop`, so it must not read as
    /// a file-receiving hit.
    private var isReceivingDrop: Bool {
        isPanelTargeted && !vm.dropZoneTargeting && !selection.isDragging
    }

    private enum ShelfHint: Equatable {
        case empty
        case receiving
        case loading
    }

    /// One source of truth for the hint layer. An active hover/drag hit wins
    /// over the import that is still running, matching the stronger border.
    private var hint: ShelfHint? {
        if isReceivingDrop { return .receiving }
        if tvm.isLoading { return .loading }
        if tvm.isEmpty { return .empty }
        return nil
    }

    private var hintAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    private var hintTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96))
    }

    private var hintText: String {
        guard let hint else { return "拖入文件到这里" }
        switch hint {
        case .loading: return "正在加入…"
        case .receiving: return "松开即可加入"
        case .empty: return "拖入文件到这里"
        }
    }

    private var isLoadingHint: Bool {
        guard let hint else { return false }
        return hint == .loading
    }

    private var isReceivingHint: Bool {
        guard let hint else { return false }
        return hint == .receiving
    }

    private var emptyStateTint: Color {
        if isReceivingHint { return .accentColor }
        return usesSharedGlassShell ? Color.primary.opacity(0.85) : Color.secondary
    }

    var body: some View {
        GeometryReader { layout in
            let regions = ShelfDropLayout(size: layout.size)
            HStack(spacing: 5) {
                FileShareView()
                    .frame(width: regions.shareSize, height: regions.shareSize)
                panel
                    .padding(ShelfDropLayout.tileInset)
                    .frame(width: regions.shelf.width, height: regions.shelf.height)
                    .contentShape(Rectangle())
                    .onDrop(of: GeneralDropTargetDelegate.types,
                            delegate: GeneralDropTargetDelegate(isTargeted: $vm.dragDetectorTargeting,
                                enabled: !selection.isDragging, receive: handleDrop))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .onDisappear { vm.dragDetectorTargeting = false }
        // Bind Quick Look to shelf selection
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .quickLookPresenter(using: quickLookService)
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !selection.isDragging, !providers.isEmpty else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }
    
    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen && !selection.selectedIDs.isEmpty else { return }
        
        let selectedItems = selection.selectedItems(in: tvm.items)
        let urls: [URL] = selectedItems.compactMap { item in
            if let fileURL = item.fileURL {
                return fileURL
            }
            if case .link(let url) = item.kind {
                return url
            }
            return nil
        }
        
        if !urls.isEmpty {
            quickLookService.updateSelection(urls: urls)
        }
    }

    var panel: some View {
        ShelfTileSurface(targeted: isReceivingDrop, highlighted: tvm.isLoading)
            .animation(hintAnimation, value: isReceivingDrop)
            .animation(hintAnimation, value: tvm.isLoading)
            .overlay {
                content
                    .padding(8)
            }
            .overlay(alignment: .bottom) {
                hintPill
            }
            .contentShape(Rectangle())
            .onTapGesture { selection.clear() }
    }

    /// A light hint inside the existing glass boundary. It never intercepts
    /// drags, scrolls, taps or drops intended for the shelf content.
    private var hintPill: some View {
        ZStack {
            if !tvm.isEmpty, let hint, hint != .empty {
                HStack(spacing: 6) {
                    if isLoadingHint {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .imageScale(.small)
                    }

                    if !vm.externalFileDragActive {
                        Text(hintText)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    NotchControlSurface(shape: Capsule(), emphasized: true)
                }
                .shadow(color: .black.opacity(usesSharedGlassShell ? 0.18 : 0), radius: 4, y: 1)
                .padding(8)
                .transition(hintTransition)
            }
        }
        .animation(hintAnimation, value: hint)
        .allowsHitTesting(false)
    }

    var content: some View {
        Group {
            if tvm.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: spacing) {
                        ForEach(tvm.items) { item in
                            ShelfItemView(item: item)
                                .environmentObject(quickLookService)
                        }
                    }
                }
                .reservesHorizontalNotchScrolling()
                .padding(-spacing)
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

            }
        }
        .onAppear {
            ShelfStateViewModel.shared.cleanupInvalidItems()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            if isLoadingHint {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 20)
            } else {
                Image(systemName: isReceivingHint ? "arrow.down.doc.fill" : "tray.and.arrow.down")
                    .font(.system(size: 19, weight: .medium))
            }

            if !vm.externalFileDragActive {
                Text(hintText)
                    .font(.system(size: 12, weight: .semibold))
                if hint == .empty {
                    Text("任意文件、链接或文字")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(emptyStateTint)
        .sharedGlassForeground()
    }
}


// Matching surfaces for the storage and direct-sharing targets.
struct ShelfTileSurface: View {
    let targeted: Bool
    let highlighted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 13)
            .fill(targeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(highlighted ? 0.09 : 0.052))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(targeted ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.15),
                                  lineWidth: targeted ? 1.6 : 0.8)
            }
    }
}
