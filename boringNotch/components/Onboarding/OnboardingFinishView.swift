//
//  OnboardingFinishView.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-23.
//

import Defaults
import SwiftUI

struct OnboardingFinishView: View {
    @Default(.settingsLanguage) private var settingsLanguage
    let onFinish: () -> Void
    var onSkipGuide: (() -> Void)? = nil
    let onOpenSettings: () -> Void

    private var isEnglish: Bool {
        settingsLanguage.lowercased().hasPrefix("en")
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.04, green: 0.52, blue: 1.0), Color(red: 0.36, green: 0.36, blue: 0.96)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 68, height: 68)
                    .shadow(color: Color(red: 0.04, green: 0.52, blue: 1.0).opacity(0.35), radius: 14, y: 6)

                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 4)

            Text(isEnglish ? "You're All Set!" : "一切准备就绪")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(
                isEnglish
                    ? "Take a 20-second localized spotlight tour right inside your real MacBook notch, or jump straight in."
                    : "接下来将在屏幕顶端的真实灵动岛内开启局部高光导览，逐一为你点亮歌词舞台、底部控件、文件暂存与岛内审批。"
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 10) {
                Button(action: onFinish) {
                    Label(
                        isEnglish ? "Start Island Spotlight Tour" : "开启灵动岛局部高光导览",
                        systemImage: "viewfinder"
                    )
                    .frame(maxWidth: 240)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                HStack(spacing: 16) {
                    if let onSkipGuide {
                        Button(isEnglish ? "Skip Tour" : "直接开始使用", action: onSkipGuide)
                            .buttonStyle(.plain)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Button(action: onOpenSettings) {
                        Label(isEnglish ? "Settings" : "偏好设置", systemImage: "gear")
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }
}

#Preview {
    OnboardingFinishView(onFinish: {}, onOpenSettings: {})
}
