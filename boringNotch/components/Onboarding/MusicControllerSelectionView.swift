//
//  MusicControllerSelectionView.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-23.
//

import Defaults
import SwiftUI

struct MusicControllerSelectionView: View {
    @Default(.settingsLanguage) private var settingsLanguage
    let onContinue: () -> Void

    @Default(.mediaController) var mediaController

    private var isEnglish: Bool {
        settingsLanguage.lowercased().hasPrefix("en")
    }

    private var availableMediaControllers: [MediaControllerType] {
        if MusicManager.shared.isNowPlayingDeprecated {
            return MediaControllerType.allCases.filter { $0 != .nowPlaying }
        } else {
            return MediaControllerType.allCases
        }
    }

    @State private var selectedMediaController: MediaControllerType = Defaults[.mediaController]

    var body: some View {
        VStack(spacing: 18) {
            Text(isEnglish ? "Choose a Music Source" : "选择音乐播放源")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.top, 24)

            Text(
                isEnglish
                    ? "Select the media source for artwork and live lyrics. You can change this anytime in Settings."
                    : "选择用于同步专辑封面与 Folia 逐词歌词的播放源，后续可随时在设置中切换。"
            )
            .multilineTextAlignment(.center)
            .font(.body)
            .foregroundColor(.secondary)
            .padding(.horizontal, 20)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(availableMediaControllers) { controller in
                        ControllerOptionView(
                            controller: controller,
                            isSelected: self.selectedMediaController == controller,
                            isEnglish: isEnglish
                        )
                        .onTapGesture {
                            self.selectedMediaController = controller
                        }
                    }
                }
                .padding()
            }
            .scrollDisabled(availableMediaControllers.count <= 4)

            Button(isEnglish ? "Continue" : "下一步", action: {
                self.mediaController = self.selectedMediaController
                NotificationCenter.default.post(
                    name: Notification.Name.mediaControllerChanged,
                    object: nil
                )
                onContinue()
            })
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }
}

struct ControllerOptionView: View {
    let controller: MediaControllerType
    let isSelected: Bool
    var isEnglish: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundColor(isSelected ? .effectiveAccent : .secondary.opacity(0.5))
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)

            VStack(alignment: .leading, spacing: 4) {
                Text(controller.rawValue)
                    .font(.headline)
                    .fontWeight(.semibold)

                Text(controller.localizedSummary(english: isEnglish))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if controller == .youtubeMusic, let url = URL(string: "https://github.com/pear-devs/pear-desktop") {
                    Link("GitHub: pear-devs/pear-desktop", destination: url)
                        .font(.subheadline)
                        .padding(.top, 2)
                }
            }

            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.effectiveAccent.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? Color.effectiveAccent : Color.secondary.opacity(0.3), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
    }
}

extension MediaControllerType {
    var description: String {
        localizedSummary(english: false)
    }

    func localizedSummary(english: Bool) -> String {
        switch self {
        case .nowPlaying:
            return english
                ? "Works automatically with system media apps, NetEase Music, QQ Music, Spotify, Apple Music, and browsers."
                : "自动识别系统正在播放的媒体（支持 Apple Music、网易云音乐、QQ 音乐、Spotify 及浏览器）。"
        case .spotify:
            return english
                ? "Connects directly to the Spotify desktop app."
                : "直接连接 Spotify 桌面客户端。"
        case .appleMusic:
            return english
                ? "Connects directly to the macOS Music app."
                : "直接连接 macOS 原生「音乐」应用。"
        case .youtubeMusic:
            return english
                ? "Requires pear-desktop client with API plugin enabled."
                : "需配合启用了 API 插件的第三方客户端使用。"
        }
    }
}

#Preview {
    MusicControllerSelectionView(onContinue: {})
        .frame(width: 400, height: 600)
}
