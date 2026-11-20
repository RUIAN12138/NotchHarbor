//
//  HoverButton.swift
//  boringNotch
//
//  Created by Kraigo on 04.09.2024.
//

import SwiftUI

struct HoverButton: View {
    var icon: String
    var iconColor: Color = .primary;
    var scale: Image.Scale = .medium
    var action: () -> Void
    var contentTransition: ContentTransition = .symbolEffect;

    @Environment(\.usesSharedGlassShell) private var usesSharedGlassShell
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        let size = CGFloat(scale == .large ? 40 : 30)

        Button(action: action) {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: size, height: size)
                .overlay {
                    Group {
                        if usesSharedGlassShell {
                            NotchControlSurface(
                                shape: Capsule(), emphasized: scale == .large, isHovered: isHovering
                            )
                        } else {
                            Capsule().fill(isHovering ? Color.primary.opacity(0.09) : .clear)
                        }
                    }
                        .frame(width: size, height: size)
                        .overlay {
                            Image(systemName: icon)
                                .foregroundColor(iconColor)
                                .contentTransition(contentTransition)
                                .font(scale == .large ? .largeTitle : .body)
                                .sharedGlassForeground(opacity: 0.38)
                        }
                }
        }
        .buttonStyle(NotchControlStyle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                isHovering = hovering
            }
        }
    }

}
