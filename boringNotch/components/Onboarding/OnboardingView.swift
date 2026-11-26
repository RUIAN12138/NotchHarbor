//
//  OnboardingView.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-23.
//

import AVFoundation
import Defaults
import SwiftUI

enum OnboardingStep {
    case welcome
    case cameraPermission
    case calendarPermission
    case remindersPermission
    case accessibilityPermission
    case musicPermission
    case finished
}

@MainActor private let calendarService = CalendarService()

struct OnboardingView: View {
    @Default(.settingsLanguage) private var settingsLanguage
    @State var step: OnboardingStep = .welcome
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    private var isEnglish: Bool {
        settingsLanguage.lowercased().hasPrefix("en")
    }

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeView {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        step = .cameraPermission
                    }
                }
                .transition(.opacity)

            case .cameraPermission:
                PermissionRequestView(
                    icon: Image(systemName: "camera.fill"),
                    title: isEnglish ? "Enable Camera Access" : "开启摄像头权限",
                    description: isEnglish
                        ? "Notch Harbor includes an optional in-notch mirror preview and head-gesture reply control. You can turn camera features on or off anytime."
                        : "Notch Harbor 支持可选的岛内随身镜预览与点头/摇头快捷回复功能。仅在您主动启用相关功能时使用实时画面。",
                    privacyNote: isEnglish
                        ? "Your camera is never used without your consent, and nothing is recorded or stored."
                        : "未经您开启绝不调用摄像头，所有画面均在本地实时处理，绝不录制或上传。",
                    onAllow: {
                        Task {
                            await requestCameraPermission()
                            withAnimation(.easeInOut(duration: 0.45)) {
                                step = .calendarPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.45)) {
                            step = .calendarPermission
                        }
                    }
                )
                .transition(.opacity)

            case .calendarPermission:
                PermissionRequestView(
                    icon: Image(systemName: "calendar"),
                    title: isEnglish ? "Enable Calendar Access" : "开启日历权限",
                    description: isEnglish
                        ? "Notch Harbor displays upcoming meetings and your 7-day schedule right inside the notch."
                        : "授权日历后，您可以在顶部刘海七日滚轮中直接查看近期会议与日程安排。",
                    privacyNote: isEnglish
                        ? "Your calendar data is only read locally and is never shared."
                        : "日程数据仅在本地用于界面展示，绝不会外传。",
                    onAllow: {
                        Task {
                            await requestCalendarPermission()
                            withAnimation(.easeInOut(duration: 0.45)) {
                                step = .remindersPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.45)) {
                            step = .remindersPermission
                        }
                    }
                )
                .transition(.opacity)

            case .remindersPermission:
                PermissionRequestView(
                    icon: Image(systemName: "checklist"),
                    title: isEnglish ? "Enable Reminders Access" : "开启提醒事项权限",
                    description: isEnglish
                        ? "Show scheduled reminders alongside your calendar events inside the notch."
                        : "将待办提醒与日历事件同屏聚合展示，抬眼即可核对今日事项。",
                    privacyNote: isEnglish
                        ? "Your reminders data stays strictly on your Mac."
                        : "提醒事项仅在本机读取展示，绝不上传或共享。",
                    onAllow: {
                        Task {
                            await requestRemindersPermission()
                            withAnimation(.easeInOut(duration: 0.45)) {
                                step = .accessibilityPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.45)) {
                            step = .accessibilityPermission
                        }
                    }
                )
                .transition(.opacity)

            case .accessibilityPermission:
                PermissionRequestView(
                    icon: Image(systemName: "hand.raised.fill"),
                    title: isEnglish ? "Enable Accessibility Access" : "开启辅助功能权限",
                    description: isEnglish
                        ? "Used to intercept media, volume, and brightness keys for the custom in-notch HUD and System Island coordination."
                        : "用于接管音量、亮度与媒体键岛内 HUD 提示，并与系统灵动岛平滑避让协同。",
                    privacyNote: isEnglish
                        ? "Used strictly for HUD key events and window geometry. No keystrokes or personal data are collected."
                        : "仅用于 HUD 按键反馈与窗口几何检测，绝不记录任何键盘输入或隐私数据。",
                    onAllow: {
                        Task {
                            await requestAccessibilityPermission()
                            withAnimation(.easeInOut(duration: 0.45)) {
                                step = .musicPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.45)) {
                            step = .musicPermission
                        }
                    }
                )
                .transition(.opacity)

            case .musicPermission:
                MusicControllerSelectionView(
                    onContinue: {
                        withAnimation(.easeInOut(duration: 0.45)) {
                            step = .finished
                        }
                    }
                )
                .transition(.opacity)

            case .finished:
                OnboardingFinishView(
                    onFinish: onFinish,
                    onOpenSettings: onOpenSettings
                )
            }
        }
        .frame(width: 400, height: 600)
    }

    func requestCameraPermission() async {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func requestCalendarPermission() async {
        _ = try? await calendarService.requestAccess(to: .event)
    }

    func requestRemindersPermission() async {
        _ = try? await calendarService.requestAccess(to: .reminder)
    }

    func requestAccessibilityPermission() async {
        await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
    }
}
