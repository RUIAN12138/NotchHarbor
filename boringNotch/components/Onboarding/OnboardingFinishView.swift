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
    let onSkipGuide: (() -> Void)?
    let onOpenSettings: () -> Void

    init(
        onFinish: @escaping () -> Void,
        onSkipGuide: (() -> Void)? = nil,
        onOpenSettings: @escaping () -> Void
    ) {
        self.onFinish = onFinish
        self.onSkipGuide = onSkipGuide
        self.onOpenSettings = onOpenSettings
    }

    private var isEnglish: Bool {
        settingsLanguage.lowercased().hasPrefix("en")
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundColor(.effectiveAccent)
                .padding(.bottom, 4)

            Text(isEnglish ? "You're All Set!" : "一切就绪！")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(
                isEnglish
                    ? "Start a 30-second interactive spotlight tour right inside the notch to explore all 5 hubs, or customize further in Settings."
                    : "接下来可在顶部刘海内开启 30 秒高光交互引导，快速体验五大核心工作台；您也可以随时在岛内菜单或设置中重新打开引导。"
            )
            .font(.body)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 34)

            Spacer()

            VStack(spacing: 10) {
                Button(action: onFinish) {
                    Label(
                        isEnglish ? "Start Spotlight Guide" : "开始高光使用引导",
                        systemImage: "sparkles.rectangle.stack"
                    )
                    .frame(maxWidth: 230)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                HStack(spacing: 12) {
                    Button(action: onOpenSettings) {
                        Label(isEnglish ? "Settings" : "偏好设置", systemImage: "gear")
                    }
                    .controlSize(.regular)

                    if let onSkipGuide {
                        Button(isEnglish ? "Skip Tour" : "直接开始使用", action: onSkipGuide)
                            .controlSize(.regular)
                    }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }
}

#Preview {
    OnboardingFinishView(onFinish: {}, onSkipGuide: {}, onOpenSettings: {})
}
