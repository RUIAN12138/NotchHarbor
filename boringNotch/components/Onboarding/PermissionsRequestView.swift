//
//  PermissionsRequestView.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-23.
//

import Defaults
import SwiftUI

struct PermissionRequestView: View {
    @Default(.settingsLanguage) private var settingsLanguage
    let icon: Image
    let title: String
    let description: String
    let privacyNote: String?
    let onAllow: () -> Void
    let onSkip: () -> Void

    private var isEnglish: Bool {
        settingsLanguage.lowercased().hasPrefix("en")
    }

    var body: some View {
        VStack(spacing: 24) {
            icon
                .resizable()
                .scaledToFit()
                .frame(width: 68, height: 54)
                .foregroundColor(.effectiveAccent)
                .padding(.top, 32)

            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text(description)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if let privacyNote = privacyNote {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundColor(.secondary)
                    Text(privacyNote)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .padding(.bottom, 6)
                .padding(.horizontal, 24)
            }

            HStack(spacing: 12) {
                Button(isEnglish ? "Not Now" : "稍后再说") { onSkip() }
                    .buttonStyle(.bordered)
                Button(isEnglish ? "Allow Access" : "授予权限") { onAllow() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }
}
