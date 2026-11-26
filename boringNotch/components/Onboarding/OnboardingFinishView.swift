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
    let onOpenSettings: () -> Void

    init(
        onFinish: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.onFinish = onFinish
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

            Spacer()

            VStack(spacing: 10) {
                Button(action: onFinish) {
                    Label(
                        isEnglish ? "Get Started" : "开始使用",
                        systemImage: "checkmark"
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
    OnboardingFinishView(onFinish: {}, onOpenSettings: {})
}
