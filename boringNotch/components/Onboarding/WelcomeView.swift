//
//  WelcomeView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 2024. 09. 26..
//

import Defaults
import SwiftUI
import SwiftUIIntrospect

struct WelcomeView: View {
    @Default(.settingsLanguage) private var settingsLanguage
    var onGetStarted: (() -> Void)? = nil

    private var isEnglish: Bool {
        settingsLanguage.lowercased().hasPrefix("en")
    }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                Image("spotlight")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(.bottom)
                    .blur(radius: 3)
                    .offset(y: -5)
                    .background(SparkleView().opacity(0.6))
                VStack(spacing: 8) {
                    Image("NotchHarborBrand")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                        .padding(.bottom, 8)
                    Text("Notch Harbor")
                        .font(.system(.largeTitle, design: .default))
                        .fontWeight(.semibold)
                    Text(isEnglish ? "Turn your MacBook notch into a workspace hub" : "把整座工作台，收进屏幕顶端")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 28)

                    Button {
                        onGetStarted?()
                    } label: {
                        Text(isEnglish ? "Get Started" : "开始配置")
                            .padding(.horizontal, 22)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                }
                .padding(.top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        }
    }
}

#Preview {
    WelcomeView()
}
