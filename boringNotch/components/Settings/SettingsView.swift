//
//  SettingsView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import AVFoundation
import Defaults
import EventKit
import KeyboardShortcuts
import ServiceManagement
import Sparkle
import SwiftUI
import SwiftUIIntrospect

private enum HarborSettingsPage: String, CaseIterable {
    case general, appearance, media, agent, calendar, hud, battery, shelf, shortcuts, advanced, about

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .media: "Media"
        case .agent: "Agent"
        case .calendar: "Calendar"
        case .hud: "Device alerts"
        case .battery: "Battery"
        case .shelf: "Shelf"
        case .shortcuts: "Shortcuts"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .appearance: "circle.lefthalf.filled"
        case .media: "music.note"
        case .agent: "terminal"
        case .calendar: "calendar"
        case .hud: "dial.medium"
        case .battery: "battery.100.bolt"
        case .shelf: "tray"
        case .shortcuts: "command"
        case .advanced: "gearshape.2"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @Default(.settingsLanguage) private var settingsLanguage
    @State private var page: HarborSettingsPage = .general
    @State private var hoveredPage: HarborSettingsPage?
    @State private var accent = Color.effectiveAccent
    @Namespace private var sidebarSelection
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var updaterController: SPUStandardUpdaterController? = nil
    var onLanguageChanged: (String) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 207)

            VStack(alignment: .leading, spacing: 0) {
                heading
                if page == .general {
                    languagePreference
                } else if page == .appearance {
                    HarborNotchPreview()
                        .padding(.horizontal, 23)
                        .padding(.bottom, 4)
                }
                ZStack {
                    pageContent
                        .id(page)
                        .transition(.opacity)
                }
                .scrollContentBackground(.hidden)
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: page)
            }
            .padding(.vertical, 8)
            .background {
                let surface = RoundedRectangle(cornerRadius: 21, style: .continuous)
                surface.fill(Color(nsColor: .windowBackgroundColor))
                    .overlay {
                        surface.strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.07), radius: 12, y: 4)
            }
            .padding(.top, 12)
            .padding([.trailing, .bottom], 12)
        }
        .frame(minWidth: 650, minHeight: 465)
        .background {
            if reduceTransparency {
                Color(nsColor: .underPageBackgroundColor)
            } else {
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                LinearGradient(colors: [accent.opacity(colorScheme == .dark ? 0.17 : 0.10), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .environment(\.locale, Locale(identifier: settingsLanguage))
        .tint(accent)
        .onChange(of: settingsLanguage, initial: true) { _, language in onLanguageChanged(language) }
        .onReceive(NotificationCenter.default.publisher(for: .init("AccentColorChanged"))) { _ in
            accent = .effectiveAccent
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Image("NotchHarborBrand").resizable().frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                Text("Notch Harbor")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .padding(.horizontal, 21)
            .padding(.top, 40)

            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    pageGroup("应用", [.general, .appearance, .shortcuts])
                    pageGroup("功能", [.media, .agent, .calendar, .shelf, .hud, .battery])
                    pageGroup("更多", [.advanced, .about])
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 15)
            }
            .scrollIndicators(.never)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
    }

    private func pageGroup(_ title: LocalizedStringKey, _ items: [HarborSettingsPage]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 11)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(items, id: \.self) { item in
                Button {
                    guard item != page else { return }
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) { page = item }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 22)
                            .foregroundStyle(item == page && colorScheme == .dark ? Color.white : .secondary)
                        Text(item.title).font(.system(size: 13, weight: item == page ? .semibold : .medium))
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .background {
                        let shape = RoundedRectangle(cornerRadius: 10)
                        if item == page {
                            NotchControlSurface(shape: shape, emphasized: true)
                                .overlay { shape.strokeBorder(accent.opacity(0.34), lineWidth: 0.75) }
                                .environment(\.usesSharedGlassShell, colorScheme == .dark)
                                .matchedGeometryEffect(id: "selected-page", in: sidebarSelection)
                        } else if hoveredPage == item {
                            shape.fill(.primary.opacity(0.065))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == page ? .isSelected : [])
                .accessibilityIdentifier("harbor-settings-\(item.rawValue)")
                .onHover { inside in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                        if inside { hoveredPage = item }
                        else if hoveredPage == item { hoveredPage = nil }
                    }
                }
            }
        }
    }

    private var heading: some View {
        HStack(spacing: 13) {
            Image(systemName: page.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 40, height: 40)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            Text(page.title)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if page == .general {
                Button("Quit app") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 23)
        .padding(.top, 17)
        .padding(.bottom, 15)
    }

    private var languagePreference: some View {
        HStack(spacing: 12) {
            Label("Settings language", systemImage: "globe")
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            Picker("Settings language", selection: $settingsLanguage) {
                Text(verbatim: "简体中文").tag("zh-Hans")
                Text(verbatim: "English").tag("en")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 155)
        }
        .padding(12)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 13))
        .padding(.horizontal, 23)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .general: GeneralSettings()
        case .appearance: Appearance(accent: accent)
        case .media: Media()
        case .agent: AgentSuggestionSettings()
        case .calendar: CalendarSettings()
        case .hud: HUD()
        case .battery: Charge()
        case .shelf: Shelf()
        case .shortcuts: Shortcuts()
        case .advanced: Advanced()
        case .about: About(updaterController: updaterController)
        }
    }
}

enum HarborLoginItem {
    static let managedKey = "harborManagedLoginEnabled"
    static var isManaged: Bool {
        Bundle.main.object(forInfoDictionaryKey: "HarborManagedLoginItem") as? Bool == true
    }
    static var managedEnabled: Bool {
        UserDefaults.standard.object(forKey: managedKey) as? Bool ?? true
    }
}

private struct HarborLoginItemControls: View {
    @AppStorage(HarborLoginItem.managedKey) private var managed = true
    @State private var status = SMAppService.mainApp.status
    @State private var failed = false

    var body: some View {
        if HarborLoginItem.isManaged {
            Toggle("Launch at login", isOn: $managed)
        } else {
            nativeControl
        }
    }

    @ViewBuilder
    private var nativeControl: some View {
        Toggle("Launch at login", isOn: Binding(
            get: { status == .enabled },
            set: { setEnabled($0) }
        ))
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        if status == .requiresApproval {
            Button("Review login item in System Settings") { SMAppService.openSystemSettingsLoginItems() }
        } else if failed {
            Text("Could not change login item.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refresh() { status = SMAppService.mainApp.status }

    private func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        failed = false
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
        } catch {
            failed = true
        }
        refresh()
    }
}

struct GeneralSettings: View {
    @State private var screens: [(uuid: String, name: String)] = NSScreen.screens.compactMap { screen in
        guard let uuid = screen.displayUUID else { return nil }
        return (uuid, screen.localizedName)
    }
    @ObservedObject var coordinator = BoringViewCoordinator.shared

    @Default(.minimumHoverDuration) var minimumHoverDuration
    @Default(.notchWeatherCity) private var notchWeatherCity
    @Default(.showIslandSideActivities) private var showIslandSideActivities
    @Default(.expandNotchForAlerts) private var expandNotchForAlerts
    @State private var weatherCityInput = ""
    @Default(.gestureSensitivity) var gestureSensitivity
    @Default(.nonNotchHeight) var nonNotchHeight
    @Default(.nonNotchHeightMode) var nonNotchHeightMode
    @Default(.notchHeight) var notchHeight
    @Default(.notchHeightMode) var notchHeightMode
    @Default(.showOnAllDisplays) var showOnAllDisplays
    @Default(.automaticallySwitchDisplay) var automaticallySwitchDisplay
    @Default(.enableGestures) var enableGestures
    @Default(.openNotchOnHover) var openNotchOnHover
    

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .menubarIcon) {
                    Text("Show menu bar icon")
                }
                .tint(.effectiveAccent)
                HarborLoginItemControls()
                Defaults.Toggle(key: .showOnAllDisplays) {
                    Text("Show on all displays")
                }
                .onChange(of: showOnAllDisplays) {
                    NotificationCenter.default.post(
                        name: Notification.Name.showOnAllDisplaysChanged, object: nil)
                }
                Picker("Preferred display", selection: $coordinator.preferredScreenUUID) {
                    ForEach(screens, id: \.uuid) { screen in
                        Text(screen.name).tag(screen.uuid as String?)
                    }
                }
                .onChange(of: NSScreen.screens) {
                    screens = NSScreen.screens.compactMap { screen in
                        guard let uuid = screen.displayUUID else { return nil }
                        return (uuid, screen.localizedName)
                    }
                }
                .disabled(showOnAllDisplays)
                
                Defaults.Toggle(key: .automaticallySwitchDisplay) {
                    Text("Automatically switch displays")
                }
                    .onChange(of: automaticallySwitchDisplay) {
                        NotificationCenter.default.post(
                            name: Notification.Name.automaticallySwitchDisplayChanged, object: nil)
                    }
                    .disabled(showOnAllDisplays)
            } header: {
                Text("System features")
            }

            Section {
                Picker(
                    selection: $notchHeightMode,
                    label:
                        Text("Notch height on notch displays")
                ) {
                    Text("Match real notch height")
                        .tag(WindowHeightMode.matchRealNotchSize)
                    Text("Match menu bar height")
                        .tag(WindowHeightMode.matchMenuBar)
                    Text("Custom height")
                        .tag(WindowHeightMode.custom)
                }
                .onChange(of: notchHeightMode) {
                    NotificationCenter.default.post(
                        name: Notification.Name.notchHeightChanged, object: nil)
                }
                if notchHeightMode == .custom {
                    Slider(value: $notchHeight, in: 15...45, step: 1) {
                        Text("Custom notch size - \(notchHeight, specifier: "%.0f")")
                    }
                    .onChange(of: notchHeight) {
                        NotificationCenter.default.post(
                            name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
                Picker("Notch height on non-notch displays", selection: $nonNotchHeightMode) {
                    Text("Match menubar height")
                        .tag(WindowHeightMode.matchMenuBar)
                    Text("Standard height (32 pt)")
                        .tag(WindowHeightMode.matchRealNotchSize)
                    Text("Custom height")
                        .tag(WindowHeightMode.custom)
                }
                .onChange(of: nonNotchHeightMode) {
                    NotificationCenter.default.post(
                        name: Notification.Name.notchHeightChanged, object: nil)
                }
                if nonNotchHeightMode == .custom {
                    Slider(value: $nonNotchHeight, in: 0...40, step: 1) {
                        Text("Custom notch size - \(nonNotchHeight, specifier: "%.0f")")
                    }
                    .onChange(of: nonNotchHeight) {
                        NotificationCenter.default.post(
                            name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
            } header: {
                Text("Notch sizing")
            }

            NotchBehaviour()

            Section {
                Defaults.Toggle(key: .clipboardHistoryEnabled) {
                    Text("记录剪贴板历史")
                }
            } header: {
                Text("剪贴板")
            } footer: {
                Text("最近 50 条，保存在本机，重启恢复。关闭或暂停后不记录新的复制内容，已有历史仍可使用；清空历史才会删除本机记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            gestureControls()
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("General")
        .onChange(of: openNotchOnHover) {
            if !openNotchOnHover {
                enableGestures = true
            }
        }
    }

    @ViewBuilder
    func gestureControls() -> some View {
        Section {
            Defaults.Toggle(key: .enableGestures) {
                Text("Enable gestures")
            }
                .disabled(!openNotchOnHover)
            if enableGestures {
                Defaults.Toggle(key: .closeGestureEnabled) {
                    Text("Close gesture")
                }
                Slider(value: $gestureSensitivity, in: 100...300, step: 100) {
                    HStack {
                        Text("Gesture sensitivity")
                        Spacer()
                        Text(LocalizedStringKey(
                            Defaults[.gestureSensitivity] == 100
                                ? "High" : Defaults[.gestureSensitivity] == 200 ? "Medium" : "Low"
                        ))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            HStack {
                Text("Gesture control")
                customBadge(text: "Beta")
            }
        } footer: {
            Text(
                "展开后，在导航栏或面板空白处用双指左右滑动切页。启用收起手势后可双指上滑收起；关闭悬停展开时可双指下滑打开。"
            )
            .multilineTextAlignment(.trailing)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
    }

    @ViewBuilder
    func NotchBehaviour() -> some View {
        Section {
            Defaults.Toggle(key: .showIslandSideActivities) {
                Text("显示刘海两侧的小灵动岛")
            }
            .help("包括 Agent 工作状态和耳机等侧翼提示。")

            Defaults.Toggle(key: .openNotchOnHover) {
                Text("Open notch on hover")
            }
            Defaults.Toggle(key: .enableHaptics) {
                    Text("Enable haptic feedback")
            }
            Toggle("Remember last notch page", isOn: $coordinator.openLastTabByDefault)
                .help("Resume the last page when opening the notch")
            if showIslandSideActivities {
                Picker("Agent 审批提醒", selection: $expandNotchForAlerts) {
                    Text("刘海两侧").tag(false)
                    Text("弹出提醒").tag(true)
                }
            } else {
                LabeledContent("Agent 审批提醒", value: String(localized: "弹出提醒"))
            }
            Defaults.Toggle(key: .notchCalendarAlerts) { Text("日程与提醒事项") }
            HStack {
                TextField("天气城市（例如：北京）", text: $weatherCityInput)
                    .onSubmit { notchWeatherCity = weatherCityInput.trimmingCharacters(in: .whitespacesAndNewlines) }
                Button("保存") {
                    notchWeatherCity = weatherCityInput.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            .onAppear { weatherCityInput = notchWeatherCity }
            Text("日常天气显示在日历页。中国大陆城市收到新的官方气象预警时会弹出提醒。留空关闭天气。")
                .font(.caption).foregroundStyle(.secondary)
            if openNotchOnHover {
                Slider(value: $minimumHoverDuration, in: 0...1, step: 0.1) {
                    HStack {
                        Text("Hover delay")
                        Spacer()
                        Text("\(minimumHoverDuration, specifier: "%.1f")s")
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: minimumHoverDuration) {
                    NotificationCenter.default.post(
                        name: Notification.Name.notchHeightChanged, object: nil)
                }
            }
        } header: {
            Text("Notch behavior")
        }
    }
}

struct Charge: View {
    @Default(.showBatteryIndicator) private var showBatteryIndicator

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showBatteryIndicator) {
                    Text("Show battery indicator")
                }
            } header: {
                Text("General")
            }
            Section {
                Defaults.Toggle(key: .showBatteryPercentage) {
                    Text("Show battery percentage")
                }
                Defaults.Toggle(key: .showPowerStatusIcons) {
                    Text("Show power status icons")
                }
            } header: {
                Text("Battery Information")
            }
            .disabled(!showBatteryIndicator)
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Battery")
    }
}

//struct Downloads: View {
//    @Default(.selectedDownloadIndicatorStyle) var selectedDownloadIndicatorStyle
//    @Default(.selectedDownloadIconStyle) var selectedDownloadIconStyle
//    var body: some View {
//        Form {
//            warningBadge("We don't support downloads yet", "It will be supported later on.")
//            Section {
//                Defaults.Toggle(key: .enableDownloadListener) {
//                    Text("Show download progress")
//                }
//                    .disabled(true)
//                Defaults.Toggle(key: .enableSafariDownloads) {
//                    Text("Enable Safari Downloads")
//                }
//                    .disabled(!Defaults[.enableDownloadListener])
//                Picker("Download indicator style", selection: $selectedDownloadIndicatorStyle) {
//                    Text("Progress bar")
//                        .tag(DownloadIndicatorStyle.progress)
//                    Text("Percentage")
//                        .tag(DownloadIndicatorStyle.percentage)
//                }
//                Picker("Download icon style", selection: $selectedDownloadIconStyle) {
//                    Text("Only app icon")
//                        .tag(DownloadIconStyle.onlyAppIcon)
//                    Text("Only download icon")
//                        .tag(DownloadIconStyle.onlyIcon)
//                    Text("Both")
//                        .tag(DownloadIconStyle.iconAndAppIcon)
//                }
//
//            } header: {
//                HStack {
//                    Text("Download indicators")
//                    comingSoonTag()
//                }
//            }
//            Section {
//                List {
//                    ForEach([].indices, id: \.self) { index in
//                        Text("\(index)")
//                    }
//                }
//                .frame(minHeight: 96)
//                .overlay {
//                    if true {
//                        Text("No excluded apps")
//                            .foregroundStyle(Color(.secondaryLabelColor))
//                    }
//                }
//                .actionBar(padding: 0) {
//                    Group {
//                        Button {
//                        } label: {
//                            Image(systemName: "plus")
//                                .frame(width: 25, height: 16, alignment: .center)
//                                .contentShape(Rectangle())
//                                .foregroundStyle(.secondary)
//                        }
//
//                        Divider()
//                        Button {
//                        } label: {
//                            Image(systemName: "minus")
//                                .frame(width: 20, height: 16, alignment: .center)
//                                .contentShape(Rectangle())
//                                .foregroundStyle(.secondary)
//                        }
//                    }
//                }
//            } header: {
//                HStack(spacing: 4) {
//                    Text("Exclude apps")
//                    comingSoonTag()
//                }
//            }
//        }
//        .navigationTitle("Downloads")
//    }
//}

struct HUD: View {
    @ObservedObject private var activities = UnifiedActivities.shared

    var body: some View {
        Form {
            Section {
                Toggle("AirPods 开盖提示", isOn: $activities.lidDetectionEnabled)
                Text(LocalizedStringKey(activities.lidDetectionStatus))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("AirPods")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Device alerts")
    }
}

struct Media: View {
    @AppStorage(MusicSpectrumSignal.enabledKey) private var audioSpectrumEnabled = true
    @Default(.waitInterval) var waitInterval
    @Default(.mediaController) var mediaController
    @ObservedObject private var musicManager = MusicManager.shared
    @Default(.hideNotchOption) var hideNotchOption

    @Default(.enableLyrics) var enableLyrics

    var body: some View {
        Form {
            Section {
                Picker("Music Source", selection: Binding(
                    get: { mediaController == .nowPlaying && musicManager.isNowPlayingDeprecated ? .appleMusic : mediaController },
                    set: { mediaController = $0 }
                )) {
                    ForEach(availableMediaControllers) { controller in
                        Text(LocalizedStringKey(controller.rawValue)).tag(controller)
                    }
                }
                .onChange(of: mediaController) { _, _ in
                    NotificationCenter.default.post(
                        name: Notification.Name.mediaControllerChanged,
                        object: nil
                    )
                }
            } header: {
                Text("Media Source")
            } footer: {
                if musicManager.isNowPlayingDeprecated {
                    HStack {
                        Text("YouTube Music requires this third-party app to be installed: ")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Link(
                            "https://github.com/pear-devs/pear-desktop",
                            destination: URL(string: "https://github.com/pear-devs/pear-desktop")!
                        )
                        .font(.caption)
                        .foregroundColor(.blue)  // Ensures it's visibly a link
                    }
                } else {
                    Text(
                        "'Now Playing' was the only option on previous versions and works with all media apps."
                    )
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
            }
            
            Section {
                HStack {
                    Stepper(value: $waitInterval, in: 0...10, step: 1) {
                        HStack {
                            Text("Media inactivity timeout")
                            Spacer()
                            Text("\(Defaults[.waitInterval], specifier: "%.0f") seconds")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Picker(
                    selection: $hideNotchOption,
                    label:
                        HStack {
                            Text("Full screen behavior")
                            customBadge(text: "Beta")
                        }
                ) {
                    Text("Hide for all apps").tag(HideNotchOption.always)
                    Text("Hide for media app only").tag(
                        HideNotchOption.nowPlayingOnly)
                    Text("Never hide").tag(HideNotchOption.never)
                }
            } header: {
                Text("Media playback")
            }
            
            if #available(macOS 14.4, *) {
                Section {
                    Toggle("底部呼吸光跟随音乐", isOn: $audioSpectrumEnabled)
                } footer: {
                    Text("音乐页展开且正在播放时读取系统音频，首次使用会请求系统音频权限。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                MusicSlotConfigurationView()
                Defaults.Toggle(key: .enableLyrics) {
                    Text("Show lyrics in music panel")
                }
            } header: {
                Text("Media controls")
            }  footer: {
                Text("Customize which controls appear in the music player. Volume expands when active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Media")
    }

    // Only show controller options that are available on this macOS version
    private var availableMediaControllers: [MediaControllerType] {
        if musicManager.isNowPlayingDeprecated {
            return MediaControllerType.allCases.filter { $0 != .nowPlaying }
        } else {
            return MediaControllerType.allCases
        }
    }
}

struct CalendarSettings: View {
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.hideCompletedReminders) var hideCompletedReminders
    @Default(.hideAllDayEvents) var hideAllDayEvents
    @Default(.autoScrollToNextEvent) var autoScrollToNextEvent

    var body: some View {
        Form {
            Defaults.Toggle(key: .hideCompletedReminders) {
                Text("Hide completed reminders")
            }
            Defaults.Toggle(key: .hideAllDayEvents) {
                Text("Hide all-day events")
            }
            Defaults.Toggle(key: .autoScrollToNextEvent) {
                Text("Auto-scroll to next event")
            }
            Defaults.Toggle(key: .showFullEventTitles) {
                Text("Always show full event titles")
            }
            Section(header: Text("Calendars")) {
                if calendarManager.calendarAuthorizationStatus != .fullAccess {
                    Button("连接系统日历") {
                        Task { await calendarManager.checkCalendarAuthorization() }
                    }
                    Text("查看日程需要允许读取系统日历。")
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                    Button("Open Calendar Settings") {
                        if let settingsURL = URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                        ) {
                            NSWorkspace.shared.open(settingsURL)
                        }
                    }
                } else {
                    List {
                        ForEach(calendarManager.eventCalendars, id: \.id) { calendar in
                            Toggle(
                                isOn: Binding(
                                    get: { calendarManager.getCalendarSelected(calendar) },
                                    set: { isSelected in
                                        Task {
                                            await calendarManager.setCalendarSelected(
                                                calendar, isSelected: isSelected)
                                        }
                                    }
                                )
                            ) {
                                Text(calendar.title)
                            }
                            .accentColor(lighterColor(from: calendar.color))
                        }
                    }
                }
            }
            Section(header: Text("Reminders")) {
                if calendarManager.reminderAuthorizationStatus != .fullAccess {
                    Button("连接提醒事项") {
                        Task { await calendarManager.checkReminderAuthorization() }
                    }
                    Text("可选：允许读取所选提醒事项列表。")
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                    Button("Open Reminder Settings") {
                        if let settingsURL = URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
                        ) {
                            NSWorkspace.shared.open(settingsURL)
                        }
                    }
                } else {
                    List {
                        ForEach(calendarManager.reminderLists, id: \.id) { calendar in
                            Toggle(
                                isOn: Binding(
                                    get: { calendarManager.getCalendarSelected(calendar) },
                                    set: { isSelected in
                                        Task {
                                            await calendarManager.setCalendarSelected(
                                                calendar, isSelected: isSelected)
                                        }
                                    }
                                )
                            ) {
                                Text(calendar.title)
                            }
                            .accentColor(lighterColor(from: calendar.color))
                        }
                    }
                }
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Calendar")
        .onAppear {
            Task {
                await calendarManager.reloadCalendarAndReminderLists()
            }
        }
    }
}

func lighterColor(from nsColor: NSColor, amount: CGFloat = 0.14) -> Color {
    let srgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
    var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0,0,0,0)
    srgb.getRed(&r, green: &g, blue: &b, alpha: &a)

    func lighten(_ c: CGFloat) -> CGFloat {
        let increased = c + (1.0 - c) * amount
        return min(max(increased, 0), 1)
    }

    let nr = lighten(r)
    let ng = lighten(g)
    let nb = lighten(b)

    return Color(red: Double(nr), green: Double(ng), blue: Double(nb), opacity: Double(a))
}

struct About: View {
    @State private var showBuildNumber: Bool = false
    let updaterController: SPUStandardUpdaterController?
    var body: some View {
        VStack {
            Form {
                HStack(spacing: 12) {
                    Image("NotchHarborBrand").resizable().frame(width: 52, height: 52)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notch Harbor").font(.title2.weight(.semibold))
                        Text("macOS 灵动岛").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        if showBuildNumber {
                            Text("(\(Bundle.main.buildVersionNumber ?? ""))")
                                .foregroundStyle(.secondary)
                        }
                        Text(Bundle.main.releaseVersionNumber ?? "—")
                            .foregroundStyle(.secondary)
                    }
                    .onTapGesture {
                        withAnimation {
                            showBuildNumber.toggle()
                        }
                    }
                } header: {
                    Text("Version info")
                }

                if let updaterController {
                    UpdaterSettingsView(updater: updaterController.updater)
                    CheckForUpdatesView(updater: updaterController.updater)
                }

                Section {
                    DisclosureGroup("开源许可与致谢") {
                        Text("基于 The Bored Team 的 Boring Notch · GPL-3.0")
                            .foregroundStyle(.secondary)
                        Link("上游源码", destination: upstreamProjectPage)
                        Link("支持上游项目", destination: sponsorPage)
                        if let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
                           let notices = Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: nil) {
                            Link("GPL-3.0 许可", destination: license)
                            Link("第三方许可", destination: notices)
                        }
                    }
                }
            }
        }
        .navigationTitle("关于 Notch Harbor")
    }
}

struct Shelf: View {
    @Default(.boringShelf) private var shelfEnabled
    @Default(.quickShareProvider) var quickShareProvider
    @Default(.expandedDragDetection) var expandedDragDetection: Bool
    @StateObject private var quickShareService = QuickShareService.shared

    private var selectedProvider: QuickShareProvider? {
        quickShareService.availableProviders.first(where: { $0.id == quickShareProvider })
    }
    
    init() {
        Task { await QuickShareService.shared.discoverAvailableProviders() }
    }
    
    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .boringShelf) {
                    Text("Enable shelf")
                }
                Defaults.Toggle(key: .openShelfByDefault) {
                    Text("Open shelf by default if items are present")
                }
                .disabled(!shelfEnabled)
                Defaults.Toggle(key: .expandedDragDetection) {
                    Text("Expanded drag detection area")
                }
                .onChange(of: expandedDragDetection) {
                    NotificationCenter.default.post(
                        name: Notification.Name.expandedDragDetectionChanged,
                        object: nil
                    )
                }
                Defaults.Toggle(key: .copyOnDrag) {
                    Text("Copy items on drag")
                }
                .disabled(!shelfEnabled)
                Defaults.Toggle(key: .autoRemoveShelfItems) {
                    Text("Remove from shelf after dragging")
                }
                .disabled(!shelfEnabled)

            } header: {
                HStack {
                    Text("General")
                }
            }
            
            Section {
                Picker("Quick Share Service", selection: $quickShareProvider) {
                    ForEach(quickShareService.availableProviders, id: \.id) { provider in
                        HStack {
                            Group {
                                if let imgData = provider.imageData, let nsImg = NSImage(data: imgData) {
                                    Image(nsImage: nsImg)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                            .frame(width: 16, height: 16)
                            .foregroundColor(.accentColor)
                            Text(LocalizedStringKey(provider.id))
                        }
                        .tag(provider.id)
                    }
                }
                .pickerStyle(.menu)
                
                if let selectedProvider = selectedProvider {
                    HStack {
                        Group {
                            if let imgData = selectedProvider.imageData, let nsImg = NSImage(data: imgData) {
                                Image(nsImage: nsImg)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .frame(width: 16, height: 16)
                        .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Currently selected: \(Text(LocalizedStringKey(selectedProvider.id)))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Files dropped on the shelf will be shared via this service")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // Providers are always enabled; user can pick default service above.
                
            } header: {
                HStack {
                    Text("Quick Share")
                }
            } footer: {
                Text("Choose which service to use when sharing files from the shelf. Click the shelf button to select files, or drag files onto it to share immediately.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Shelf")
    }
}

//struct Extensions: View {
//    @State private var effectTrigger: Bool = false
//    var body: some View {
//        Form {
//            Section {
//                List {
//                    ForEach(extensionManager.installedExtensions.indices, id: \.self) { index in
//                        let item = extensionManager.installedExtensions[index]
//                        HStack {
//                            AppIcon(for: item.bundleIdentifier)
//                                .resizable()
//                                .frame(width: 24, height: 24)
//                            Text(item.name)
//                            ListItemPopover {
//                                Text("Description")
//                            }
//                            Spacer(minLength: 0)
//                            HStack(spacing: 6) {
//                                Circle()
//                                    .frame(width: 6, height: 6)
//                                    .foregroundColor(
//                                        isExtensionRunning(item.bundleIdentifier)
//                                            ? .green : item.status == .disabled ? .gray : .red
//                                    )
//                                    .conditionalModifier(isExtensionRunning(item.bundleIdentifier))
//                                { view in
//                                    view
//                                        .shadow(color: .green, radius: 3)
//                                }
//                                Text(
//                                    isExtensionRunning(item.bundleIdentifier)
//                                        ? "Running"
//                                        : item.status == .disabled ? "Disabled" : "Stopped"
//                                )
//                                .contentTransition(.numericText())
//                                .foregroundStyle(.secondary)
//                                .font(.footnote)
//                            }
//                            .frame(width: 60, alignment: .leading)
//
//                            Menu(
//                                content: {
//                                    Button("Restart") {
//                                        let ws = NSWorkspace.shared
//
//                                        if let ext = ws.runningApplications.first(where: {
//                                            $0.bundleIdentifier == item.bundleIdentifier
//                                        }) {
//                                            ext.terminate()
//                                        }
//
//                                        if let appURL = ws.urlForApplication(
//                                            withBundleIdentifier: item.bundleIdentifier)
//                                        {
//                                            ws.openApplication(
//                                                at: appURL, configuration: .init(),
//                                                completionHandler: nil)
//                                        }
//                                    }
//                                    .keyboardShortcut("R", modifiers: .command)
//                                    Button("Disable") {
//                                        if let ext = NSWorkspace.shared.runningApplications.first(
//                                            where: { $0.bundleIdentifier == item.bundleIdentifier })
//                                        {
//                                            ext.terminate()
//                                        }
//                                        extensionManager.installedExtensions[index].status =
//                                            .disabled
//                                    }
//                                    .keyboardShortcut("D", modifiers: .command)
//                                    Divider()
//                                    Button("Uninstall", role: .destructive) {
//                                        //
//                                    }
//                                },
//                                label: {
//                                    Image(systemName: "ellipsis.circle")
//                                        .foregroundStyle(.secondary)
//                                }
//                            )
//                            .controlSize(.regular)
//                        }
//                        .buttonStyle(PlainButtonStyle())
//                        .padding(.vertical, 5)
//                    }
//                }
//                .frame(minHeight: 120)
//                .actionBar {
//                    Button {
//                    } label: {
//                        HStack(spacing: 3) {
//                            Image(systemName: "plus")
//                            Text("Add manually")
//                        }
//                        .foregroundStyle(.secondary)
//                    }
//                    .disabled(true)
//                    Spacer()
//                    Button {
//                        withAnimation(.linear(duration: 1)) {
//                            effectTrigger.toggle()
//                        } completion: {
//                            effectTrigger.toggle()
//                        }
//                        extensionManager.checkIfExtensionsAreInstalled()
//                    } label: {
//                        HStack(spacing: 3) {
//                            Image(systemName: "arrow.triangle.2.circlepath")
//                                .rotationEffect(effectTrigger ? .degrees(360) : .zero)
//                        }
//                        .foregroundStyle(.secondary)
//                    }
//                }
//                .controlSize(.small)
//                .buttonStyle(PlainButtonStyle())
//                .overlay {
//                    if extensionManager.installedExtensions.isEmpty {
//                        Text("No extension installed")
//                            .foregroundStyle(Color(.secondaryLabelColor))
//                            .padding(.bottom, 22)
//                    }
//                }
//            } header: {
//                HStack(spacing: 0) {
//                    Text("Installed extensions")
//                    if !extensionManager.installedExtensions.isEmpty {
//                        Text(" – \(extensionManager.installedExtensions.count)")
//                            .foregroundStyle(.secondary)
//                    }
//                }
//            }
//        }
//        .accentColor(.effectiveAccent)
//        .navigationTitle("Extensions")
//        // TipsView()
//        // .padding(.horizontal, 19)
//    }
//}

private struct HarborNotchPreview: View {
    @Default(.siriGlassEnabled) private var glassEnabled
    @Default(.siriGlassIntensity) private var lightIntensity
    @Default(.enableShadow) private var enableShadow
    @Default(.desktopRefractionEnabled) private var desktopRefractionEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Live notch preview").font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Picker("Live notch preview", selection: $expanded) {
                    Text("Collapsed").tag(false)
                    Text("Expanded").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 148)
            }

            GeometryReader { geometry in
                let shape = NotchShape.panel(expanded: expanded)
                let usesGlass = glassEnabled && !reduceTransparency
                let hardwareWidth = min(110, geometry.size.width * 0.36)
                ZStack(alignment: .top) {
                    LinearGradient(colors: [Color(red: 0.20, green: 0.26, blue: 0.46),
                                            Color(red: 0.47, green: 0.40, blue: 0.57),
                                            Color(red: 0.54, green: 0.69, blue: 0.75)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    NotchGlassBackground(
                        shape: shape,
                        isExpanded: expanded,
                        reduceTransparency: reduceTransparency,
                        headerHeight: 23,
                        hardwareWidth: hardwareWidth,
                        usesSharedGlassShell: usesGlass,
                        glassEnabled: glassEnabled,
                        lightIntensity: lightIntensity,
                        usesDarkGlassAppearance: colorScheme == .dark
                    )
                    .environment(\.colorScheme, .dark)
                    .frame(width: expanded ? min(294, geometry.size.width - 24) : hardwareWidth,
                           height: expanded ? 82 : 24)
                    .shadow(color: .black.opacity(enableShadow && !(usesGlass && NotchOpticalSupport.isAvailable) ? 0.18 : 0),
                            radius: 6, y: 3)
                    .overlay(alignment: .top) {
                        if expanded {
                            HStack(spacing: 10) {
                                Image(systemName: "music.note").font(.system(size: 15, weight: .medium))
                                Capsule().fill(.white.opacity(0.26)).frame(width: 52, height: 3)
                                Image(systemName: "play.fill").font(.system(size: 10, weight: .semibold))
                                    .padding(7)
                                    .background {
                                        NotchControlSurface(shape: Circle(), emphasized: true)
                                            .environment(\.usesSharedGlassShell, usesGlass)
                                    }
                            }
                            .foregroundStyle(.white)
                            .padding(.top, 37)
                            .transition(.opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.27), value: expanded)

                    RoundedRectangle(cornerRadius: 11)
                        .fill(.black)
                        .frame(width: hardwareWidth, height: 21)
                }
            }
            .frame(height: 94)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
            if desktopRefractionEnabled {
                Text("Desktop refraction is shown on the actual notch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.08)) }
    }
}

struct Appearance: View {
    var accent = Color.effectiveAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Default(.appAppearance) private var appearance
    @Default(.mirrorShape) var mirrorShape
    @Default(.showMirror) private var showMirror
    @Default(.sliderColor) var sliderColor
    @Default(.siriGlassEnabled) var siriGlassEnabled
    @Default(.siriGlassIntensity) var siriGlassIntensity
    @Default(.desktopRefractionEnabled) private var desktopRefractionEnabled
    @State private var requestingRefractionAccess = false
    @State private var refractionNeedsPermission = false

    private var glassUsesLightIntensity: Bool {
        if #available(macOS 26, *) { return NotchOpticalSupport.isAvailable }
        return true
    }

    private var themeOptions: some View {
        HStack(spacing: 8) {
            ForEach(HarborAppearance.allCases, id: \.self) { mode in
                Button { appearance = mode } label: {
                    appearanceTile(mode)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(appearanceTitle(mode))
                .accessibilityAddTraits(appearance == mode ? .isSelected : [])
                .accessibilityIdentifier("harbor-appearance-\(mode.rawValue)")
            }
        }
    }

    private func appearanceTitle(_ mode: HarborAppearance) -> LocalizedStringKey {
        switch mode {
        case .system: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private func appearanceTile(_ mode: HarborAppearance) -> some View {
        let selected = appearance == mode
        let shape = RoundedRectangle(cornerRadius: 9)
        return VStack(spacing: 5) {
            HStack(spacing: 0) {
                if mode != .dark { appearanceSwatch(dark: false) }
                if mode != .light { appearanceSwatch(dark: true) }
            }
            .frame(height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
            Text(appearanceTitle(mode))
                .font(.caption.weight(selected ? .semibold : .medium))
                .lineLimit(1)
        }
        .padding(5)
        .frame(maxWidth: .infinity)
        .background(selected ? accent.opacity(0.14) : .clear, in: shape)
        .overlay { shape.strokeBorder(selected ? accent.opacity(0.65) : .primary.opacity(0.10)) }
        .contentShape(shape)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selected)
    }

    private func appearanceSwatch(dark: Bool) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: dark ? [Color(white: 0.24), Color(white: 0.10)]
                                        : [Color(white: 0.82), Color(white: 0.97)],
                           startPoint: .top, endPoint: .bottom)
            UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
                .fill(dark ? Color(white: 0.07) : Color(white: 0.25))
                .frame(width: 20, height: 5)
            Capsule()
                .fill(dark ? .white.opacity(0.20) : .black.opacity(0.20))
                .frame(width: 30, height: 2)
                .padding(.top, 13)
        }
    }

    var body: some View {
        Form {
            Section("Color theme") { themeOptions }


            Section {
                Defaults.Toggle(key: .settingsIconInNotch) {
                    Text("Show settings icon in notch")
                }

            } header: {
                Text("Notch navigation")
            }

            Section {
                Toggle("液态玻璃", isOn: $siriGlassEnabled)
                if !siriGlassEnabled {
                    Text("使用经典黑色刘海")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Slider(value: $siriGlassIntensity, in: 0...1, step: 0.05) {
                    HStack {
                        Text("光效强度")
                        Spacer()
                        Text(siriGlassIntensity, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!siriGlassEnabled || !glassUsesLightIntensity)
                if #available(macOS 14.0, *) {
                    Toggle("实时背景折射与色散", isOn: Binding(
                        get: { desktopRefractionEnabled || requestingRefractionAccess },
                        set: { enabled in
                            refractionNeedsPermission = false
                            guard enabled else {
                                desktopRefractionEnabled = false
                                return
                            }
                            requestingRefractionAccess = true
                            // Settings is the sole permission request entry point.
                            Task { @MainActor in
                                let allowed = await Task.detached(priority: .userInitiated) {
                                    CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
                                }.value
                                desktopRefractionEnabled = allowed
                                refractionNeedsPermission = !allowed
                                requestingRefractionAccess = false
                            }
                        }
                    ))
                    .disabled(!siriGlassEnabled || requestingRefractionAccess)
                    if refractionNeedsPermission {
                        Text("可在系统设置的「屏幕与系统音频录制」中允许本应用，再重新打开并启用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("刘海玻璃")
            } footer: {
                Text("默认使用系统液态玻璃。真实桌面折射开启后，只在展开时取样刘海周围的画面，并在内存中处理。")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                Defaults
                    .Toggle("Player tinting", key: .playerColorTinting)
                Defaults.Toggle(key: .lightingEffect) {
                    Text("Enable blur effect behind album art")
                }
                Picker("Slider color", selection: $sliderColor) {
                    ForEach(SliderColorEnum.allCases, id: \.self) { option in
                        Text(LocalizedStringKey(option.rawValue)).tag(option)
                    }
                }
            } header: {
                Text("Media")
            }

            Section {
                Defaults.Toggle(key: .showMirror) {
                    Text("Enable mirror")
                }
                    .disabled(!checkVideoInput() && !showMirror)
                if showMirror && checkVideoInput() {
                    Picker("Mirror shape", selection: $mirrorShape) {
                        Text("Circle").tag(MirrorShapeEnum.circle)
                        Text("Square").tag(MirrorShapeEnum.rectangle)
                    }
                }
            } header: {
                HStack {
                    Text("Additional features")
                }
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Appearance")
    }

    func checkVideoInput() -> Bool {
        if AVCaptureDevice.default(for: .video) != nil {
            return true
        }

        return false
    }
}

struct Advanced: View {
    @Default(.useCustomAccentColor) var useCustomAccentColor
    @Default(.customAccentColorData) var customAccentColorData
    @Default(.showOnLockScreen) var showOnLockScreen
    @Default(.hideFromScreenRecording) var hideFromScreenRecording
    
    @State private var customAccentColor: Color = .accentColor
    @State private var selectedPresetColor: PresetAccentColor? = nil
    
    // macOS accent colors
    enum PresetAccentColor: String, CaseIterable, Identifiable {
        case blue = "Blue"
        case purple = "Purple"
        case pink = "Pink"
        case red = "Red"
        case orange = "Orange"
        case yellow = "Yellow"
        case green = "Green"
        case graphite = "Graphite"
        
        var id: String { self.rawValue }
        
        var color: Color {
            switch self {
            case .blue: return Color(red: 0.0, green: 0.478, blue: 1.0)
            case .purple: return Color(red: 0.686, green: 0.322, blue: 0.871)
            case .pink: return Color(red: 1.0, green: 0.176, blue: 0.333)
            case .red: return Color(red: 1.0, green: 0.271, blue: 0.227)
            case .orange: return Color(red: 1.0, green: 0.584, blue: 0.0)
            case .yellow: return Color(red: 1.0, green: 0.8, blue: 0.0)
            case .green: return Color(red: 0.4, green: 0.824, blue: 0.176)
            case .graphite: return Color(red: 0.557, green: 0.557, blue: 0.576)
            }
        }
    }
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    // Toggle between system and custom
                    Picker("Accent color", selection: $useCustomAccentColor) {
                        Text("System").tag(false)
                        Text("Custom").tag(true)
                    }
                    .pickerStyle(.segmented)
                    
                    if !useCustomAccentColor {
                        // System accent info
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                AccentCircleButton(
                                    isSelected: true,
                                    color: .accentColor,
                                    isSystemDefault: true
                                ) {}
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Using System Accent")
                                        .font(.body)
                                    Text("Your macOS system accent color")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    } else {
                        // Custom color options
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Color Presets")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            
                            HStack(spacing: 12) {
                                ForEach(PresetAccentColor.allCases) { preset in
                                    AccentCircleButton(
                                        isSelected: selectedPresetColor == preset,
                                        color: preset.color,
                                        isMulticolor: false
                                    ) {
                                        selectedPresetColor = preset
                                        customAccentColor = preset.color
                                        saveCustomColor(preset.color)
                                        forceUiUpdate()
                                    }
                                }
                                Spacer()
                            }
                            
                            Divider()
                                .padding(.vertical, 4)
                            
                            // Custom color picker
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Pick a Color")
                                        .font(.body)
                                    Text("Choose any color")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                ColorPicker(selection: Binding(
                                    get: { customAccentColor },
                                    set: { newColor in
                                        customAccentColor = newColor
                                        selectedPresetColor = nil
                                        saveCustomColor(newColor)
                                        forceUiUpdate()
                                    }
                                ), supportsOpacity: false) {
                                    ZStack {
                                        Circle()
                                            .fill(customAccentColor)
                                            .frame(width: 32, height: 32)
                                        
                                        if selectedPresetColor == nil {
                                            Circle()
                                                .strokeBorder(.primary.opacity(0.3), lineWidth: 2)
                                                .frame(width: 32, height: 32)
                                        }
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Accent color")
            } footer: {
                Text("Choose between your system accent color or customize it with your own selection.")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .onAppear {
                initializeAccentColorState()
            }
            
            Section {
                Defaults.Toggle(key: .enableShadow) {
                    Text("Enable window shadow")
                }
                Defaults.Toggle(key: .cornerRadiusScaling) {
                    Text("Corner radius scaling")
                }
            } header: {
                Text("Window Appearance")
            }
            
            Section {
                Defaults.Toggle(key: .showOnLockScreen) {
                    Text("Show notch on lock screen")
                }
                Defaults.Toggle(key: .hideFromScreenRecording) {
                    Text("Hide from screen recording")
                }
            } header: {
                Text("Window Behavior")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Advanced")
        .onAppear {
            loadCustomColor()
        }
    }
    
    private func forceUiUpdate() {
        // Force refresh the UI
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("AccentColorChanged"), object: nil)
        }
    }
    
    private func saveCustomColor(_ color: Color) {
        let nsColor = NSColor(color)
        if let colorData = try? NSKeyedArchiver.archivedData(withRootObject: nsColor, requiringSecureCoding: false) {
            Defaults[.customAccentColorData] = colorData
            forceUiUpdate()
        }
    }
    
    private func loadCustomColor() {
        if let colorData = Defaults[.customAccentColorData],
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            customAccentColor = Color(nsColor: nsColor)
            
            // Check if loaded color matches a preset
            selectedPresetColor = nil
            for preset in PresetAccentColor.allCases {
                if colorsAreEqual(Color(nsColor: nsColor), preset.color) {
                    selectedPresetColor = preset
                    break
                }
            }
        }
    }
    
    private func colorsAreEqual(_ color1: Color, _ color2: Color) -> Bool {
        let nsColor1 = NSColor(color1).usingColorSpace(.sRGB) ?? NSColor(color1)
        let nsColor2 = NSColor(color2).usingColorSpace(.sRGB) ?? NSColor(color2)
        
        return abs(nsColor1.redComponent - nsColor2.redComponent) < 0.01 &&
               abs(nsColor1.greenComponent - nsColor2.greenComponent) < 0.01 &&
               abs(nsColor1.blueComponent - nsColor2.blueComponent) < 0.01
    }
    
    private func initializeAccentColorState() {
        if !useCustomAccentColor {
            selectedPresetColor = nil // Multicolor is selected when useCustomAccentColor is false
        } else {
            loadCustomColor()
        }
    }
}

// MARK: - Accent Circle Button Component
struct AccentCircleButton: View {
    let isSelected: Bool
    let color: Color
    var isSystemDefault: Bool = false
    var isMulticolor: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            ZStack {
                // Color circle
                Circle()
                    .fill(color)
                    .frame(width: 32, height: 32)
                
                // Subtle border
                Circle()
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    .frame(width: 32, height: 32)
                
                // Apple-style highlight ring around the middle when selected
                if isSelected {
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(0.5),
                            lineWidth: 2
                        )
                        .frame(width: 28, height: 28)
                }
            }
        }
        .buttonStyle(.plain)
        .help(isSystemDefault ? "Use your macOS system accent color" : "")
    }
}

struct Shortcuts: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Toggle Notch Open:", name: .toggleNotchOpen)
                KeyboardShortcuts.Recorder("Agent 语音回复", name: .agentVoiceReply)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Shortcuts")
    }
}

func proFeatureBadge() -> some View {
    Text("Upgrade to Pro")
        .foregroundStyle(Color(red: 0.545, green: 0.196, blue: 0.98))
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4).stroke(
                Color(red: 0.545, green: 0.196, blue: 0.98), lineWidth: 1))
}

func comingSoonTag() -> some View {
    Text("Coming soon")
        .foregroundStyle(.secondary)
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color(nsColor: .secondarySystemFill))
        .clipShape(.capsule)
}

func customBadge(text: LocalizedStringKey) -> some View {
    Text(text)
        .foregroundStyle(.secondary)
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color(nsColor: .secondarySystemFill))
        .clipShape(.capsule)
}

func warningBadge(_ text: LocalizedStringKey, _ description: LocalizedStringKey) -> some View {
    Section {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading) {
                Text(text)
                    .font(.headline)
                Text(description)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

#Preview {
    HUD()
}

private struct AgentSuggestionSettings: View {
    @AppStorage(AgentVoiceEngine.preferenceKey) private var voiceEngine = AgentVoiceEngine.onDevice
    @AppStorage(AgentReplyMotionSettings.enabledKey) private var headReplies = false
    @AppStorage(AgentReplyMotionSettings.testedKey) private var headRepliesTested = false
    @AppStorage(AgentSuggestionAPI.enabledKey) private var useAPI = false
    @AppStorage(AgentSuggestionAPI.endpointKey) private var savedEndpoint = ""
    @AppStorage(AgentSuggestionAPI.modelKey) private var savedModel = ""
    @AppStorage(AgentSuggestionAPI.autoGenerateKey) private var autoGenerate = false
    @State private var endpoint = ""
    @State private var model = ""
    @State private var newKey = ""
    @State private var hasKey = false
    @State private var status: String?

    var body: some View {
        Form {
            Section("快捷回复建议") {
                Picker("建议来源", selection: $useAPI) {
                    Text("本机 Agent").tag(false)
                    Text("兼容 API").tag(true)
                }
                if useAPI {
                    TextField("API 地址", text: $endpoint, prompt: Text(verbatim: "https://api.openai.com/v1"))
                    TextField("模型名称", text: $model)
                    SecureField("API 密钥", text: $newKey, prompt: Text(LocalizedStringKey(hasKey ? "已保存，留空保留" : "输入密钥")))
                    HStack {
                        Button("保存", action: save)
                        if hasKey {
                            Button("删除密钥", role: .destructive) {
                                if AgentSuggestionAPI.removeKey() { hasKey = false; status = "密钥已删除" }
                                else { status = "钥匙串未能删除密钥" }
                            }
                        }
                    }
                    Toggle("任务完成时自动生成建议", isOn: $autoGenerate)
                        .disabled(!hasKey || savedEndpoint.isEmpty || savedModel.isEmpty)
                    Text("生成建议时会把当前会话的最近 6 条可见消息发送给所选 API。密钥存储在钥匙串中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let status {
                        Text(LocalizedStringKey(status)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Agent 语音回复") {
                Picker("语音转文字", selection: $voiceEngine) {
                    Text("本机听写").tag(AgentVoiceEngine.onDevice)
                    Text("豆包输入法").tag(AgentVoiceEngine.doubao)
                }
                Text(voiceEngine == .onDevice
                     ? "按快捷键开始听写，再按一次结束。文字留在草稿里。"
                     : "按快捷键打开草稿，再按豆包设置的语音键。离开草稿时恢复原输入法。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AirPods 头动快捷回复") {
                Toggle("用转头选择、点头确认", isOn: $headReplies)
                if headReplies {
                    HStack(spacing: 11) {
                        Image(systemName: "airpodspro")
                            .font(.system(size: 19, weight: .medium))
                            .frame(width: 35, height: 35)
                            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("头动测试").font(.subheadline.weight(.semibold))
                            if headRepliesTested {
                                Label("已通过", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("查看实时角度并完成三项动作")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 5)
                        Button(LocalizedStringKey(headRepliesTested ? "重新测试" : "开始测试")) {
                            UnifiedActivities.shared.previewAgentReplyMotion()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .onChange(of: headReplies) { _, enabled in
            if enabled && !headRepliesTested { UnifiedActivities.shared.previewAgentReplyMotion() }
        }
        .formStyle(.grouped)
        .navigationTitle("Agent")
        .onAppear {
            endpoint = savedEndpoint
            model = savedModel
            hasKey = AgentSuggestionAPI.key() != nil
        }
    }

    private func save() {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentSuggestionAPI.endpoint(endpoint) != nil, !value.isEmpty else {
            status = "请输入 HTTPS API 地址和模型名称"
            return
        }
        let trimmedKey = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty || hasKey else { status = "请输入 API 密钥"; return }
        if !trimmedKey.isEmpty {
            guard AgentSuggestionAPI.saveKey(trimmedKey) else { status = "钥匙串未能保存密钥"; return }
            hasKey = true
        }
        savedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        savedModel = value
        newKey = ""
        status = "已保存"
    }
}
