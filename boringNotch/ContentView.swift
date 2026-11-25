//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import OSLog
import SwiftUI
import SwiftUIIntrospect
import UniformTypeIdentifiers

private enum NotchForecast {
    static let warningPopupWindow: TimeInterval = 3600
    static let warningCalendarWindow: TimeInterval = 24 * 3600

    struct Place: Decodable {
        let name: String
        let admin1: String?
        let country_code: String?
        let latitude: Double
        let longitude: Double
        let population: Int?
        let feature_code: String?
        var label: String { admin1.flatMap { $0 == name ? nil : $0 }.map { "\(name) · \($0)" } ?? name }
    }
    struct Current: Decodable {
        let temperature: Double
        let code: Int
        enum CodingKeys: String, CodingKey { case temperature = "temperature_2m", code = "weather_code" }

        var presentation: (String, String) {
            switch code {
            case 0: ("晴", "sun.max")
            case 1...2: ("少云", "cloud.sun")
            case 3: ("阴", "cloud")
            case 45, 48: ("雾", "cloud.fog")
            case 51...67, 80...82: ("有雨", "cloud.rain")
            case 71...77, 85...86: ("有雪", "cloud.snow")
            case 95...99: ("雷雨", "cloud.bolt.rain")
            default: ("当前天气", "cloud")
            }
        }
    }
    struct Warning: Decodable {
        let alertid: String
        let issuetime: String
        let title: String
        let url: String
        let starttime: String?
        let endtime: String?
        let expiretime: String?

        struct Message {
            let office: String
            let kind: String
            let cancelled: Bool

            var key: String {
                let hazard = kind.replacingOccurrences(of: "[蓝黄橙红]色(?=预警)", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "信号", with: "")
                return office + "|" + hazard
            }
        }

        var message: Message? {
            let actions = ["解除", "取消", "发布", "更新", "变更"]
            guard let action = actions.compactMap({ title.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound })
            else { return nil }
            let prefix = title[..<action.lowerBound]
            let officeEnd = ["气象台", "气象局", "气象中心"].compactMap { prefix.range(of: $0, options: .backwards)?.upperBound }.max()
            let office = String(prefix[..<(officeEnd ?? prefix.endIndex)])
            let kind = String(title[action.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let verb = title[action]
            guard kind.contains("预警"), !office.isEmpty else { return nil }
            return Message(office: office, kind: kind, cancelled: verb == "解除" || verb == "取消")
        }

        func matches(_ place: Place, office: String) -> Bool {
            let province = place.admin1.map(NotchForecast.provinceKey) ?? ""
            let city = place.name.hasSuffix("市") ? String(place.name.dropLast()) : place.name
            return city.count >= 2 && office.contains(city) &&
                (province.isEmpty || office.hasPrefix(province) || office.hasPrefix(place.name + "气象台"))
        }

        static func issuedDate(_ value: String) -> Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            for format in ["yyyy/MM/dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: value) { return date }
            }
            return ISO8601DateFormatter().date(from: value)
        }

        func expires(at issued: Date) -> Date {
            (expiretime ?? endtime).flatMap(Self.issuedDate)
                ?? issued.addingTimeInterval(NotchForecast.warningCalendarWindow)
        }

        func starts(at issued: Date) -> Date { starttime.flatMap(Self.issuedDate) ?? issued }

        func activity() -> IslandActivity? {
            guard let message, !message.cancelled, let date = Self.issuedDate(issuetime), let detailURL else { return nil }
            return IslandActivity(id: "weather-warning:" + alertid, kind: "weather-warning",
                                  title: message.kind, detail: title, symbol: "exclamationmark.triangle.fill",
                                  priority: 90, expires: expires(at: date).timeIntervalSince1970,
                                  source: detailURL.absoluteString, weatherStartsAt: starts(at: date).timeIntervalSince1970)
        }

        func canPopUp(now: Date) -> Bool {
            guard let issued = Self.issuedDate(issuetime) else { return false }
            return (0...NotchForecast.warningPopupWindow).contains(now.timeIntervalSince(starts(at: issued))) && expires(at: issued) > now
        }

        var detailURL: URL? {
            guard url.hasPrefix("/publish/alarm/"), !url.dropFirst().contains("//"),
                  let link = URL(string: "https://nmc.cn" + url), link.host == "nmc.cn" else { return nil }
            return link
        }
    }

    private struct WarningFeed: Decodable {
        let code: Int
        struct Results: Decodable {
            struct Page: Decodable {
                let list: [Warning]
                let totalPage: Int
            }
            let page: Page
        }
        let data: Results
    }

    private struct Province: Decodable { let name: String }

    private static func provinceKey(_ name: String) -> String {
        name.replacingOccurrences(of: "(壮族自治区|回族自治区|维吾尔自治区|特别行政区|自治区|省|市)$",
                                  with: "", options: .regularExpression)
    }

    static func warningProvince(for place: Place) async throws -> String {
        guard place.country_code == "CN", let region = place.admin1 else { return "" }
        let provinces: [Province] = try await fetch(host: "nmc.cn", path: "/rest/province/all", parameters: [:])
        let regionKey = provinceKey(region)
        return provinces.first { provinceKey($0.name) == regionKey }?.name ?? ""
    }

    static func warnings(at place: Place, province: String, now: Date = Date()) async throws -> [Warning] {
        guard place.country_code == "CN" else { return [] }

        // Use the same province filter and complete query as the official list.
        var bulletins: [Warning] = []
        var page = 1
        while page <= 30 {
            var endpoint = URLComponents()
            endpoint.scheme = "https"
            endpoint.host = "nmc.cn"
            endpoint.path = "/rest/findAlarm"
            endpoint.queryItems = [URLQueryItem(name: "pageNo", value: String(page)),
                                   URLQueryItem(name: "pageSize", value: "100"),
                                   URLQueryItem(name: "signaltype", value: ""),
                                   URLQueryItem(name: "signallevel", value: ""),
                                   URLQueryItem(name: "province", value: province)]
            guard let url = endpoint.url else { throw URLError(.badURL) }
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.setValue("https://nmc.cn/publish/alarm.html", forHTTPHeaderField: "Referer")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let feed = try JSONDecoder().decode(WarningFeed.self, from: data)
            guard feed.code == 0 else { throw URLError(.badServerResponse) }
            let result = feed.data.page
            bulletins.append(contentsOf: result.list)
            if page >= result.totalPage || result.list.isEmpty { break }
            if let oldest = result.list.last.flatMap({ Warning.issuedDate($0.issuetime) }),
               oldest < now.addingTimeInterval(-warningCalendarWindow * 2) { break }
            page += 1
        }
        return currentWarnings(bulletins, for: place, now: now)
    }

    static func currentWarnings(_ bulletins: [Warning], for place: Place, now: Date) -> [Warning] {
        var latest: [String: (Warning, Warning.Message, Date)] = [:]
        for bulletin in bulletins {
            guard let message = bulletin.message, bulletin.matches(place, office: message.office),
                  let issued = Warning.issuedDate(bulletin.issuetime),
                  issued <= now.addingTimeInterval(warningCalendarWindow) else { continue }
            if let existing = latest[message.key],
               existing.2 > issued || existing.2 == issued && (existing.1.cancelled || !message.cancelled) {
                continue
            }
            latest[message.key] = (bulletin, message, issued)
        }

        return latest.values.filter { !$0.1.cancelled && $0.0.detailURL != nil && $0.0.expires(at: $0.2) > now }
            .sorted { $0.2 == $1.2 ? $0.0.alertid < $1.0.alertid : $0.2 > $1.2 }
            .map { $0.0 }
    }

    private struct Places: Decodable { let results: [Place]? }
    private struct Report: Decodable { let current: Current }

    static func place(named city: String) async throws -> Place? {
        let places: Places = try await fetch(host: "geocoding-api.open-meteo.com", path: "/v1/search",
            parameters: ["name": city, "count": "15", "language": "zh"])
        let direct = places.results ?? []
        let isBareChineseName = city.unicodeScalars.allSatisfy { (0x3400...0x9fff).contains($0.value) }
            && !["市", "县", "区", "镇", "乡", "州", "旗", "省", "村"].contains { city.hasSuffix($0) }
        guard isBareChineseName else { return direct.first }
        let byCity: Places? = try? await fetch(host: "geocoding-api.open-meteo.com", path: "/v1/search",
            parameters: ["name": city + "市", "count": "10", "language": "zh"])
        let municipalities = (byCity?.results ?? []).filter { $0.name == city + "市" && $0.country_code == "CN" }
        return municipalities.max { ($0.population ?? 0) < ($1.population ?? 0) }
            ?? direct.max { ($0.population ?? 0) < ($1.population ?? 0) }
    }

    static func current(at place: Place) async throws -> Current {
        let report: Report = try await fetch(host: "api.open-meteo.com", path: "/v1/forecast", parameters: [
            "latitude": String(place.latitude), "longitude": String(place.longitude),
            "current": "temperature_2m,weather_code", "forecast_days": "1"
        ])
        return report.current
    }

    private static func fetch<Value: Decodable>(host: String, path: String, parameters: [String: String]) async throws -> Value {
        var address = URLComponents()
        address.scheme = "https"
        address.host = host
        address.path = path
        address.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = address.url else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 12))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

@MainActor
struct ContentView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var activities = UnifiedActivities.shared

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @AppStorage(MusicSpectrumSignal.enabledKey) private var musicLightEnabled = true
    @StateObject private var musicLightSignal = MusicSpectrumSignal()
    @ObservedObject private var spotlightGuide = NotchSpotlightGuideController.shared
    @State private var attentionGlow = false
    @State private var anyDropDebounceTask: Task<Void, Never>?
    @State private var menuIsTracking = false
    @State private var menuGraceUntil = Date.distantPast
    @State private var selectedRouteBeforeOpening = false
    @State private var recentHoverPage: (page: NotchPage, until: ContinuousClock.Instant, screen: String?)?

    @State private var gestureProgress: CGFloat = .zero

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    @Default(.showNotHumanFace) var showNotHumanFace
    @Default(.enableShadow) private var enableShadow
    @Default(.siriGlassEnabled) private var siriGlassEnabled
    @Default(.siriGlassTransparency) private var siriGlassTransparency
    @Default(.siriGlassIntensity) private var siriGlassIntensity
    @Default(.desktopRefractionEnabled) private var desktopRefractionEnabled
    @Default(.expandNotchForAlerts) private var expandNotchForAlerts
    @Default(.showIslandSideActivities) private var showIslandSideActivities
    @Default(.notchWeatherCity) private var notchWeatherCity
    @State private var alertDetail: IslandActivity?
    @State private var compactAlertCountdown: CompactAlertCountdown?
    @State private var compactHeadphoneSnapshot: DeviceAlert?
    @State private var inlineAgentCompletion: IslandActivity?
    @State private var inlineCountdown: CompactAlertCountdown?
    @State private var pointerOverInlineCompletion = false
    @State private var lastWingActivity: IslandActivity?
    @State private var wingHandoffUntil: ContinuousClock.Instant?
    @State private var wingsResumeAfterCompletion: ContinuousClock.Instant?
    @State private var weatherRefreshRevision = 0
    @State private var seenAutoAlerts: [String: Double] = [:]
    @State private var readyHeadphoneLidID: String?
    @State private var compactAlertMayPresentAt = Date.distantPast
    @State private var clipboardCopyReceipt: IslandActivity?
    private var isShowingClipboardReceipt: Bool { alertDetail?.kind == "clipboard-copy" }
    @AppStorage(AgentReplyMotionSettings.enabledKey) private var replyHeadControlEnabled = false
    @AppStorage(AgentReplyMotionSettings.testedKey) private var replyHeadControlTested = false
    @StateObject private var replyPopupMotion = AgentReplyMotionStream()
    @State private var replyMotionCommand: AgentReplyMotionCommand?
    @State private var headMotionWakingReply = false
    @State private var headReplayAllowedAt: ContinuousClock.Instant?
    @State private var playedCompletionReplayID: String?
    @State private var completionHoverResumeAt = Date.distantPast
    @State private var completionHoverReplay: AgentCompletionHoverReplay?
    @State private var completionReply: AgentInteraction.CompletionReply?
    @State private var replyPullOffset: CGFloat = 0
    private var isTestingAgentHeadMotion: Bool {
        alertDetail?.id.hasPrefix(AgentReplyMotionSettings.previewPrefix) == true
    }
    @AppStorage(AgentCompletionHaloSettings.durationKey) private var agentHaloDurationPreference = AgentCompletionHaloSettings.defaultDuration
    @State private var agentHaloAwaitingPopupID: String?
    @State private var agentHaloReadyAt: Date?
    @State private var agentRimStartedAt: Date?
    @State private var replyPullHint: CGFloat = 0
    @State private var seenAgentRequests: Set<String> = []

    private var compactCountdownID: String? {
        vm.notchState == .open && vm.compactAlertPresented && !vm.systemIslandPresentationActive
            ? alertDetail?.id : nil
    }

    private var pausesCompactCountdown: Bool {
        pointerWithinHoverArea || menuIsTracking || pageInteractionActive || replyPullOffset > 0
            || (completionReply != nil && replyPopupMotion.hasRecentHeadActivity)
    }

    private var activeAgentRequest: IslandActivity? {
        alertDetail.flatMap { $0.agentAttentionKey != nil ? $0 : nil }
    }

    private var activeTransientAgentPopupID: String? {
        activeAgentRequest?.agentAttentionKey ?? activeCompletionPopupID
    }

    private var pendingAgentPopup: IslandActivity? {
        activities.proactiveAlerts.first { alert in
            alert.agentAttentionKey.map {
                (alert.hasPendingAgentApproval || expandNotchForAlerts || !showIslandSideActivities) && !seenAgentRequests.contains($0)
            } ?? (alert.isCompletedAgentSession || (alert.kind == "agent-quota-reset" && seenAutoAlerts[alert.id] == nil))
        }
    }

    private func replayableAgentPopup(at time: ContinuousClock.Instant) -> IslandActivity? {
        guard let alert = completionHoverReplay?.activity(at: time) else { return nil }
        if let key = alert.agentAttentionKey { return activities.currentAgentAttention(for: key) }
        return alert
    }

    private var activeCompletionPopupID: String? {
        alertDetail?.isCompletedAgentSession == true ? alertDetail?.id : nil
    }

    private var agentHaloDuration: Double {
        AgentCompletionHaloSettings.normalizedDuration(agentHaloDurationPreference)
    }

    private var canShowAgentHalo: Bool {
        agentHaloDuration > 0 && vm.notchState == .closed && !vm.compactAlertPresented
            && !vm.systemIslandPresentationActive && !coordinator.firstLaunch
            && getPhysicalNotchSize(screenUUID: vm.screenUUID) != nil
    }

    private var replyMotionTrackingID: String? {
        guard replyHeadControlEnabled, replyHeadControlTested, !vm.systemIslandPresentationActive else { return nil }
        if completionReply != nil { return activeCompletionPopupID }
        guard vm.notchState == .closed, let replay = completionHoverReplay?.activity(at: .now),
              AgentInteraction.shared.completionReply(for: replay) != nil else { return nil }
        return replay.id
    }

    private var animationSpring: Animation { NotchPanelMotion.spring(reduceMotion: reduceMotion) }

    private var shellAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return NotchPanelMotion.presentation(compact: vm.compactAlertPresented || alertDetail != nil)
    }

    private struct ShellTarget: Equatable {
        var expanded: Bool
        var size: CGSize
    }

    private var shellTarget: ShellTarget {
        let expanded = vm.notchState == .open
        let restingSize = agentRestingFrame?.size
            ?? CGSize(width: vm.closedNotchSize.width, height: vm.effectiveClosedNotchHeight)
        return ShellTarget(expanded: expanded,
                           size: expanded ? CGSize(width: expandedWidth, height: vm.notchSize.height + replyPullHint) : restingSize)
    }

    /// The glass shell is mounted once at the layout root and used by every
    /// expanded page. First launch and Reduce Transparency keep the old
    /// fallback treatments.
    private var usesSharedGlassShell: Bool {
        siriGlassEnabled && !coordinator.firstLaunch && !reduceTransparency
    }

    private var expandedContentHorizontalInset: CGFloat {
        if vm.compactAlertPresented, alertDetail?.isCompactWeather == true { return 10 }
        return vm.usesSystemIslandTrigger ? vm.expandedShoulderInset + 8 : 24
    }

    private var shellShadowOpacity: Double {
        guard enableShadow else { return 0 }
        if vm.notchState == .open {
            // A shadow blurred from the entire translucent view darkens its
            // inside as well as its outside.
            return usesSharedGlassShell && NotchOpticalSupport.isAvailable ? 0 : 0.18
        }
        return isHovering ? 0.7 : 0
    }

    /// Album colour only feeds the shell on the plain music home page.
    private var isMusicHomePage: Bool {
        !vm.compactAlertPresented && coordinator.currentView == .home && !activities.showPanel && !activities.showDashboard
    }

    private var isAgentConversationPage: Bool {
        !vm.compactAlertPresented && expandedPageRoute == .agent && (vm.agentDetailExpanded || vm.agentConversationPreviewID != nil || vm.agentListPreviewHeightHeld)
    }

    private var glassTint: Color? {
        guard isMusicHomePage, musicManager.isPlaying else { return nil }
        return Color(nsColor: musicManager.avgColor)
    }

    /// The black shoulder always needs light icons. Scoped to the header only.
    private var glassHeaderScheme: ColorScheme {
        usesSharedGlassShell || !siriGlassEnabled ? .dark : systemColorScheme
    }

    /// The shared optical shoulder keeps light foreground ink in both
    /// capture modes, so switching the backdrop cannot flip the palette.
    private var glassContentScheme: ColorScheme { isAgentConversationPage ? .dark : glassMaterialScheme }

    private var glassMaterialScheme: ColorScheme {
        usesSharedGlassShell || !siriGlassEnabled ? .dark : systemColorScheme
    }

    private var musicLightActive: Bool {
        guard #available(macOS 14.4, *) else { return false }
        return musicLightEnabled && !vm.compactAlertPresented
            && vm.notchState == .open && !vm.systemIslandPresentationActive
            && usesSharedGlassShell && !reduceMotion && siriGlassIntensity > 0
            && !vm.openedForShelfDrag
    }

    private var monitorsMusicPageAudio: Bool {
        musicLightEnabled && vm.notchState == .open && expandedPageRoute == .music
            && !vm.compactAlertPresented && !vm.systemIslandPresentationActive
            && (!musicManager.hasPanelMedia || !musicManager.isPlaying)
    }

    private var expandedHeaderSize: CGSize { vm.expandedHeaderSize }
    private var expandedWidth: CGFloat { vm.expandedNotchSize.width }
    private let expandedBottomInset = BoringViewModel.expandedBottomInset
    private let expandedPageTopInset = BoringViewModel.expandedPageTopInset

    private var visibleWingActivity: IslandActivity? {
        showIslandSideActivities ? activities.wingActivity : nil
    }

    private var presentsSideWings: Bool {
        vm.notchState == .closed && agentRestingFrame != nil
            && wingHandoffUntil == nil && wingsResumeAfterCompletion == nil && visibleWingActivity != nil
    }

    private var agentRestingFrame: CGRect? {
        guard visibleWingActivity != nil || lastWingActivity != nil,
              vm.runningAgentVisible, !vm.runningAgentWings.frame.isNull else { return nil }
        return vm.runningAgentWings.frame
    }


    private var expandedHeaderHeight: CGFloat {
        expandedHeaderSize.height
    }

    // Buttons, swipe navigation and transitions share the same selection.
    private var expandedPageRoute: NotchPage {
        NotchPage.selection(coordinator: coordinator, activities: activities)
    }

    private var canSwipePages: Bool {
        Defaults[.enableGestures] && vm.notchState == .open && !vm.compactAlertPresented && !coordinator.firstLaunch
            && !vm.systemIslandPresentationActive && !pageInteractionActive && !menuIsTracking
            && !vm.anyDropZoneTargeting && !ShelfSelectionModel.shared.isDragging
            && !SharingStateManager.shared.preventNotchClose
    }

    private var pageInteractionActive: Bool {
        vm.isPanelPointerPressed || vm.isBatteryPopoverActive || vm.isMusicVolumePopoverActive
            || vm.isMusicScrubbing || vm.isShelfRenameEditing || vm.isAirPodsPopoverActive || vm.isClipboardPreviewActive || vm.agentConversationPreviewID != nil || vm.isWeatherWarningListOpen || vm.isAgentReplyEditing || vm.isAgentVoiceReplyActive || vm.isHeaderMenuActive || vm.isSpotlightGuideActive
    }

    private func swipePage(_ step: Int) -> Bool {
        guard canSwipePages,
              let next = expandedPageRoute.neighbor(step: step, shelfEnabled: Defaults[.boringShelf]) else { return false }
        next.activate(coordinator: coordinator, activities: activities)
        return true
    }

    private var pageViewportHeight: CGFloat {
        vm.expandedPageSize.height
    }

    private var expandedPageAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.10) : .smooth(duration: 0.21)
    }

    private var pageTransition: AnyTransition {
        return .asymmetric(
            insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)),
            removal: .modifier(
                active: OutgoingNotchPage(isLeaving: true),
                identity: OutgoingNotchPage(isLeaving: false)
            )
        )
    }

    // Only a resting hover on the closed notch feeds the glass edge highlight.
    private var closedHoverHighlight: CGFloat {
        guard vm.notchState == .closed,
              isHovering,
              !reduceMotion,
              gestureProgress == 0,
              !coordinator.expandingView.show,
              !activities.hasActivity,
              !vm.hideOnClosed
        else { return 0 }
        return 1
    }

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var currentNotchShape: NotchShape {
        .panel(expanded: vm.notchState == .open)
    }

    private var gestureScale: CGFloat {
        guard !reduceMotion, gestureProgress != 0 else { return 1 }
        return max(0.6, 1 + gestureProgress * 0.01)
    }

    private var notchSurface: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = ZStack(alignment: .top) {
                    if vm.notchState == .open {
                        ZStack(alignment: .top) {
                            if vm.compactAlertPresented, let alertDetail {
                                NotchLayout(presentedAlert: alertDetail)
                                    .transition(pageTransition)
                                    .zIndex(1)
                            } else {
                                NotchLayout(presentedAlert: nil)
                                    .transition(pageTransition)
                            }
                        }
                            .transition(reduceMotion ? .opacity : .modifier(
                                active: NotchContentReveal(progress: 0),
                                identity: NotchContentReveal(progress: 1)
                            ))
                    }
                }
                    .environment(\.colorScheme, vm.notchState == .open ? glassContentScheme : .dark)
                    .foregroundStyle(.primary)
                    .frame(alignment: .top)
                    .padding(.horizontal, vm.notchState == .open ? expandedContentHorizontalInset : cornerRadiusInsets.closed.bottom)
                    .padding(.bottom, vm.notchState == .open ? expandedBottomInset : 0)
                    .frame(width: shellTarget.size.width, height: shellTarget.size.height, alignment: .top)
                    .notchPageSwipe(isEnabled: { canSwipePages }, acceptsPoint: { point, bounds in
                        currentNotchShape.path(in: bounds).contains(point)
                            && (!vm.usesSystemIslandTrigger || point.y >= expandedHeaderHeight
                                || abs(point.x - bounds.midX) > vm.systemIslandClearanceWidth / 2)
                    }, action: swipePage)
                    .clipShape(currentNotchShape)
                    .overlay {
                        if compactCountdownID != nil, let countdown = compactAlertCountdown {
                            CompactAlertEdgeLight(shape: currentNotchShape, countdown: countdown)
                        }
                    }
                    .background {
                        // A material can be visually clear while still needing
                        // an input-bearing surface over every empty panel area.
                        currentNotchShape.fill(Color.black.opacity(0.01))
                            .allowsHitTesting(false)
                        NotchGlassBackground(
                            shape: currentNotchShape, isExpanded: vm.notchState == .open,
                            reduceTransparency: reduceTransparency,
                            headerHeight: expandedHeaderSize.height, hardwareWidth: expandedHeaderSize.width,
                            attentionGlow: attentionGlow, hoverAmount: closedHoverHighlight,
                            usesSharedGlassShell: usesSharedGlassShell, tint: glassTint,
                            glassEnabled: siriGlassEnabled, lightIntensity: siriGlassIntensity,
                            musicSignal: musicLightActive && musicLightSignal.audible ? musicLightSignal : nil,
                            desktopRefractionEnabled: desktopRefractionEnabled && !vm.openedForShelfDrag,
                            keepsAgentConversationContrast: isAgentConversationPage,
                            usesDarkGlassAppearance: systemColorScheme == .dark, transparency: siriGlassTransparency
                        )
                            .environment(\.colorScheme, glassMaterialScheme)
                            .animation(reduceMotion ? nil : animationSpring, value: closedHoverHighlight)
                            .animation(reduceMotion ? nil : animationSpring, value: isMusicHomePage)
                            .shadow(
                                color: .black.opacity(shellShadowOpacity),
                                radius: vm.notchState == .open ? 8 : (Defaults[.cornerRadiusScaling] ? 6 : 4),
                                y: vm.notchState == .open ? 3 : 0
                            )
                    }
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    .offset(x: vm.notchState == .open ? 0 : (agentRestingFrame == nil ? 0 : vm.runningAgentOffset))
                    .modifier(NotchShellVisibility(
                        progress: vm.notchState == .open ? 1 : 0,
                        collapsedPresence: agentRestingFrame != nil ? 1 : 0,
                        allowsCollapsedShell: vm.runningAgentVisible
                    ))
                    .allowsHitTesting(vm.notchState == .open)
                    .accessibilityHidden(vm.notchState == .closed)
                    .animation(reduceMotion ? nil : animationSpring, value: activities.primary?.id)
                    .animation(reduceMotion ? nil : animationSpring, value: activities.headphoneAlert?.isBanner)
                    .animation(shellAnimation, value: shellTarget)
                    .animation(nil, value: vm.systemIslandPresentationActive)
                    .animation(reduceMotion ? nil : animationSpring, value: gestureProgress)
                    .contentShape(Rectangle())
                    .onDrop(of: GeneralDropTargetDelegate.types, delegate: shelfDropDelegate)
                    .onDisappear {
                        coordinator.setHUDHovered(false)
                        coordinator.setHUDDragging(false)
                        hoverTask?.cancel()
                        anyDropDebounceTask?.cancel()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                        menuIsTracking = true
                        hoverTask?.cancel()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
                        menuIsTracking = false
                        menuGraceUntil = max(menuGraceUntil, Date().addingTimeInterval(1.5))
                        scheduleAutoClose()
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        guard vm.notchState == .closed else { return }
                        guard !vm.usesSystemIslandTrigger || vm.isMouseHovering(width: autoCloseHitWidth) else { return }
                        openCollapsedTrigger()
                    })
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down, isEnabled: { canStartOpenGesture }) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .up, startsWithMomentum: false, requiresEligibleStart: true,
                                        isEnabled: { canStartCloseGesture }) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .onAppear {
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            await MainActor.run {
                                if coordinator.firstLaunch {
                                    withAnimation(vm.animation) {
                                        doOpen()
                                    }
                                }
                            }
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open {
                            scheduleAutoClose()
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        coordinator.setHUDHovered(newState == .open && vm.pointerWithinHitRegion)
                        if newState == .open {
                            if !selectedRouteBeforeOpening { applyOpenRoute() }
                            selectedRouteBeforeOpening = false
                        }
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    .onChange(of: pageInteractionActive) { _, active in
                        if !active && vm.notchState == .open {
                            scheduleAutoClose()
                        }
                    }
                    .onReceive(ShelfStateViewModel.shared.$isLoading.removeDuplicates().dropFirst()) { isLoading in
                        // A drop keeps the notch open while it imports, so the
                        // earlier close attempts bail out. Once importing stops,
                        // re-check the live pointer instead of leaving the notch
                        // open even though the mouse has already moved away.
                        guard !isLoading, vm.notchState == .open else { return }
                        scheduleAutoClose()
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        systemAppShortcut("录屏工具", icon: "record.circle", bundleID: "com.apple.screenshot.launcher")
                        systemAppShortcut("iPhone 镜像", icon: "iphone", bundleID: "com.apple.ScreenContinuity")
                        Divider()
                        Button("Settings") {
                            SettingsWindowController.shared.showWindow()
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: vm.requiredWindowWidth, maxHeight: vm.requiredWindowHeight, alignment: .top)
        .overlay(alignment: .top) {
            if vm.notchState == .closed && !vm.systemIslandPresentationActive {
                Rectangle().fill(Color.black.opacity(0.001))
                    .frame(width: vm.collapsedTriggerWidth, height: SystemIslandHoverGeometry.height)
                    .contentShape(Rectangle())
                    .onDrop(of: GeneralDropTargetDelegate.types, delegate: shelfDropDelegate)
                    .onTapGesture { openCollapsedTrigger() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("展开 Notch Harbor")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { openCollapsedTrigger() }
                    .conditionalModifier(Defaults[.enableGestures]) { strip in
                        strip.panGesture(direction: .down, isEnabled: { canStartOpenGesture }) { translation, phase in
                            handleDownGesture(translation: translation, phase: phase)
                        }
                    }
                    .padding(.top, vm.collapsedTriggerTopInset)
            }
        }
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                if vm.externalFileDragActive && vm.notchState == .closed && !vm.systemIslandPresentationActive {
                    ShelfDropGlassCue()
                        .frame(width: 32, height: 32)
                        .transition(reduceMotion ? .opacity : .modifier(
                            active: ShelfDropCueMotion(progress: 0),
                            identity: ShelfDropCueMotion(progress: 1)
                        ))
                }
            }
            .padding(.top, max(0, vm.collapsedTriggerTopInset - SystemIslandHoverGeometry.gap - 2))
            .animation(reduceMotion ? nil : .spring(response: 0.37, dampingFraction: 0.86),
                       value: vm.externalFileDragActive && vm.notchState == .closed && !vm.systemIslandPresentationActive)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .overlay(alignment: .top) {
            if !vm.runningAgentWings.frame.isNull, let activity = visibleWingActivity ?? lastWingActivity {
                NotchWingActivityView(activity: activity, headphone: activities.headphoneAlert,
                                      centerWidth: vm.runningAgentCenterWidth, height: vm.runningAgentHeight,
                                      reveal: presentsSideWings ? 1 : 0, open: { openActivity(activity) })
                    .offset(x: vm.runningAgentOffset)
                    .animation(vm.runningAgentVisible ? shellAnimation : nil, value: presentsSideWings)
                    .allowsHitTesting(presentsSideWings)
                    .accessibilityHidden(!presentsSideWings)
            }
        }
        .overlay(alignment: .top) {
            if let agentRimStartedAt, canShowAgentHalo,
               let physical = getPhysicalNotchSize(screenUUID: vm.screenUUID) {
                AgentCompletionHalo(startedAt: agentRimStartedAt, duration: agentHaloDuration, cutout: physical)
                    .id(agentRimStartedAt)
            }
        }
        .task(id: canShowAgentHalo && pendingAgentPopup == nil ? agentHaloReadyAt : nil) {
            guard let readyAt = agentHaloReadyAt, canShowAgentHalo, pendingAgentPopup == nil else { return }
            let delay = readyAt.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, agentHaloReadyAt == readyAt, canShowAgentHalo,
                  pendingAgentPopup == nil else { return }
            agentHaloReadyAt = nil
            agentRimStartedAt = .now
        }
        .task(id: agentRimStartedAt.map { $0.addingTimeInterval(agentHaloDuration) }) {
            guard let start = agentRimStartedAt else { return }
            let remaining = start.addingTimeInterval(agentHaloDuration).timeIntervalSinceNow
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            if !Task.isCancelled, agentRimStartedAt == start { agentRimStartedAt = nil }
        }
        .onChange(of: agentHaloDuration) { _, duration in
            if duration == 0 {
                agentHaloReadyAt = nil
                agentHaloAwaitingPopupID = nil
                agentRimStartedAt = nil
            }
        }
    }

    private var notchAlertSurface: some View {
        notchSurface
        .task(id: clipboardCopyReceipt?.id) {
            guard let receipt = clipboardCopyReceipt else { return }
            if vm.notchState == .closed && !reduceMotion {
                try? await Task.sleep(for: .milliseconds(240))
            }
            while !Task.isCancelled, receipt.expires > Date().timeIntervalSince1970 {
                if !vm.systemIslandPresentationActive, vm.notchState == .closed {
                    showCompactAlert(receipt)
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            if clipboardCopyReceipt?.id == receipt.id { clipboardCopyReceipt = nil }
        }
        .onReceive(vm.outsideCompactAlertClick) {
            guard activeTransientAgentPopupID != nil, vm.notchState == .open else { return }
            completionHoverReplay = nil
            headMotionWakingReply = false
            withAnimation(shellAnimationForClose) { vm.close() }
        }
        .task(id: compactCountdownID) {
            guard let id = compactCountdownID else { return }
            while !Task.isCancelled, id == compactCountdownID, var countdown = compactAlertCountdown {
                let now = ContinuousClock.now
                let paused = pausesCompactCountdown
                countdown.setPaused(paused, at: now)
                if countdown != compactAlertCountdown { compactAlertCountdown = countdown }
                let remaining = countdown.remaining(at: now)
                if !paused && remaining == .zero {
                    closeTimedCompactAlert()
                    return
                }
                try? await Task.sleep(for: paused ? .milliseconds(80) : min(remaining, .milliseconds(80)))
            }
        }
        .task(id: completionHoverReplay?.activity.id) {
            guard let replay = completionHoverReplay else { return }
            try? await Task.sleep(until: replay.dismissedAt.advanced(by: .seconds(15)), clock: .continuous)
            guard !Task.isCancelled, completionHoverReplay?.activity.id == replay.activity.id else { return }
            completionHoverReplay = nil
        }
        .task(id: replyMotionTrackingID) {
            guard replyMotionTrackingID != nil else {
                headMotionWakingReply = false
                return
            }
            await replyPopupMotion.run(allowsDismissal: true, onMotion: handleReplyHeadMotion,
                                       onGesture: handleReplyHeadGesture)
        }
        .allowsHitTesting(!vm.systemIslandPresentationActive)
        .onChange(of: visibleWingActivity?.id, initial: true) { _, id in
            vm.showsRunningAgent = id != nil
        }
        .task(id: visibleWingActivity?.id) {
            if let activity = visibleWingActivity {
                lastWingActivity = activity
            } else {
                if !reduceMotion { try? await Task.sleep(for: .milliseconds(180)) }
                if !Task.isCancelled, visibleWingActivity == nil { lastWingActivity = nil }
            }
        }
        .task(id: wingHandoffUntil) {
            guard let until = wingHandoffUntil else { return }
            try? await Task.sleep(until: until, clock: .continuous)
            if !Task.isCancelled { presentProactiveAlert() }
        }
        .task(id: wingsResumeAfterCompletion) {
            guard let until = wingsResumeAfterCompletion else { return }
            try? await Task.sleep(until: until, clock: .continuous)
            if !Task.isCancelled { wingsResumeAfterCompletion = nil }
        }
        .task(id: inlineAgentCompletion?.id) {
            guard let id = inlineAgentCompletion?.id else { return }
            while !Task.isCancelled, inlineAgentCompletion?.id == id, var clock = inlineCountdown {
                let now = ContinuousClock.now
                clock.setPaused(pointerOverInlineCompletion, at: now)
                if clock != inlineCountdown { inlineCountdown = clock }
                let remaining = clock.remaining(at: now)
                if !pointerOverInlineCompletion && remaining == .zero {
                    clearInlineCompletion()
                    presentProactiveAlert()
                    return
                }
                try? await Task.sleep(for: pointerOverInlineCompletion ? .milliseconds(80) : min(remaining, .milliseconds(80)))
            }
        }
        .onChange(of: activities.proactiveAlerts.map { $0.agentAttentionKey ?? $0.id }, initial: true) { _, ids in
            seenAgentRequests.formIntersection(Set(activities.proactiveAlerts.compactMap(\.agentAttentionKey)))
            if !activities.proactiveAlerts.contains(where: \.isCompletedAgentSession) {
                wingHandoffUntil = nil
            }
            if let request = activeAgentRequest?.agentAttentionKey, !ids.contains(request), vm.compactAlertPresented {
                completionHoverReplay = nil
                withAnimation(shellAnimationForClose) { vm.close() }
                return
            }
            presentProactiveAlert()
        }
        .task(id: pendingAgentPopup.map { $0.agentAttentionKey ?? $0.id }) {
            guard let pending = pendingAgentPopup,
                  !Defaults[.showOnAllDisplays] || vm.screenUUID == NSScreen.screens.first?.displayUUID else { return }
            let key = pending.agentAttentionKey ?? pending.id
            while !Task.isCancelled, pendingAgentPopup.map({ $0.agentAttentionKey ?? $0.id }) == key,
                  Date().timeIntervalSince1970 < (pending.agentAttentionKey.flatMap {
                    activities.currentAgentAttention(for: $0)?.expires
                  } ?? pending.expires) {
                presentProactiveAlert()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onChange(of: activities.headphoneAlert?.id) { _, id in
            if let id, alertDetail?.kind == "headphone-lid", vm.compactAlertPresented,
               id != compactHeadphoneSnapshot?.id {
                withAnimation(shellAnimationForClose) { vm.close() }
            }
        }
        .task(id: activities.proactiveAlerts.first(where: { $0.id.hasPrefix(AgentReplyMotionSettings.previewPrefix) })?.id) {
            guard activities.proactiveAlerts.contains(where: { $0.id.hasPrefix(AgentReplyMotionSettings.previewPrefix) }) else { return }
            try? await Task.sleep(for: .milliseconds(180))
            if !Task.isCancelled { presentProactiveAlert() }
        }
        .task(id: activities.proactiveAlerts.first(where: { $0.kind == "headphone-lid" })?.id) {
            readyHeadphoneLidID = nil
            guard let lid = activities.proactiveAlerts.first(where: { $0.kind == "headphone-lid" }) else { return }
            // Allow the routing or wear event from the same action to replace
            // the queued lid cue before a larger presentation starts.
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled else { return }
            readyHeadphoneLidID = lid.id
            presentProactiveAlert()
        }
    }

    var body: some View {
        notchAlertSurface
        .task(id: activeCompletionPopupID) {
            replyPullHint = 0
            guard activeCompletionPopupID != nil, Defaults[.enableGestures], !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, replyPullOffset == 0, NSEvent.pressedMouseButtons == 0 else { return }
            withAnimation(.easeOut(duration: 0.16)) { replyPullHint = 5 }
            try? await Task.sleep(for: .milliseconds(165))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.30, dampingFraction: 0.61)) { replyPullHint = 0 }
        }
        .onChange(of: vm.externalFileDragActive) { _, dragging in
            if !dragging {
                if vm.openedForShelfDrag && vm.notchState == .open { scheduleAutoClose() }
                presentProactiveAlert()
            }
        }
        .onChange(of: vm.systemIslandPresentationActive) { _, active in
            if active {
                compactAlertCountdown?.setPaused(true, at: .now)
            } else {
                presentProactiveAlert()
            }
        }
        .onChange(of: vm.runningAgentVisible) { _, visible in
            if visible { presentProactiveAlert() }
        }
        .onChange(of: vm.agentVoiceHotkey) { _, _ in openAgentVoiceReply() }
        .onChange(of: expandedPageRoute) { _, route in
            if route != .agent {
                vm.selectedAgentID = nil
                vm.agentListExtraHeight = 0
            }
            if route != .calendar { vm.isHoveringCalendar = false }
            if vm.notchState == .open && !vm.compactAlertPresented {
                if !vm.externalFileDragActive { coordinator.lastNotchPage = route.rawValue }
                holdAfterNavigation()
            }
        }
        .onChange(of: vm.notchState) { _, state in
            if state == .closed {
                clearInlineCompletion()
                if alertDetail?.isCompletedAgentSession == true, !reduceMotion {
                    wingsResumeAfterCompletion = .now.advanced(by: .milliseconds(200))
                }
                let pause: TimeInterval = alertDetail != nil && !reduceMotion ? 0.30 : 0
                compactAlertMayPresentAt = Date().addingTimeInterval(pause)
                if let id = agentHaloAwaitingPopupID, id == alertDetail?.id {
                    agentHaloAwaitingPopupID = nil
                    agentHaloReadyAt = AgentCompletionHaloSettings.readyTime(afterClosingAt: .now, reduceMotion: reduceMotion)
                }
                alertDetail = nil
                compactAlertCountdown = nil
                compactHeadphoneSnapshot = nil
                completionReply = nil
                replyPullOffset = 0
                if pause > 0 {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(pause + 0.02))
                        if !Task.isCancelled { presentProactiveAlert() }
                    }
                } else {
                    presentProactiveAlert()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchPreviewRefreshWeather)) { _ in weatherRefreshRevision += 1 }
        .task(id: "\(notchWeatherCity)|\(weatherRefreshRevision)") {
            guard !Defaults[.showOnAllDisplays] || vm.screenUUID == NSScreen.screens.first?.displayUUID else { return }
            await refreshNotchWeather(city: notchWeatherCity)
        }
        .onChange(of: vm.notchState == .closed && vm.usesSystemIslandTrigger
                  ? vm.pointerWithinIslandHoverTrigger : vm.pointerWithinHitRegion || vm.pointerWithinIslandHoverTrigger) { _, inside in
            coordinator.setHUDHovered(inside && vm.notchState == .open)
            handleHover(inside)
        }
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(reduceMotion ? nil : animationSpring, value: gestureProgress)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .onChange(of: musicLightActive || monitorsMusicPageAudio, initial: true) { _, active in musicLightSignal.setActive(active) }
        .onDisappear { musicLightSignal.setActive(false) }
        .onChange(of: vm.expandedNotchSize) { _, size in
            if vm.notchState == .open, vm.notchSize != size {
                withAnimation(reduceMotion ? nil : animationSpring) { vm.notchSize = size }
            }
        }
        .task(id: activities.primary.map { "\($0.id)-\($0.priority)" }) {
            guard !reduceMotion, activities.primary?.kind == "agent", (activities.primary?.priority ?? 0) >= 85 else {
                attentionGlow = false
                return
            }
            withAnimation(.easeOut(duration: 0.25)) { attentionGlow = true }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) { attentionGlow = false }
        }
        .environmentObject(vm)
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                hoverTask?.cancel()
                guard Defaults[.boringShelf], !ShelfSelectionModel.shared.isDragging else { return }
                coordinator.currentView = .shelf
                if vm.notchState == .closed { doOpen(preferShelf: true) }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if vm.dropEvent {
                    vm.dropEvent = false
                    return
                }

                if vm.notchState == .open {
                    scheduleAutoClose(minimumDelay: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func NotchLayout(presentedAlert: IslandActivity?) -> some View {
        if let presentedAlert {
            if presentedAlert.kind == "clipboard-copy" {
                HStack(spacing: 7) {
                    CompactAlertIcon(alert: presentedAlert, size: 22).id(presentedAlert.id)
                    Text(presentedAlert.title).font(.system(size: 13, weight: .semibold))
                }
                .frame(height: 38)
                .frame(maxWidth: .infinity)
                .padding(.top, vm.compactAlertTopInset)
                .allowsHitTesting(false)
            } else if presentedAlert.id.hasPrefix(AgentReplyMotionSettings.previewPrefix) {
                AgentReplyChoiceCard(title: presentedAlert.title,
                    options: [],
                    isPractice: true,
                    acceptsHeadMotion: !vm.systemIslandPresentationActive, submit: { _ in false }) {
                    activities.dismiss(presentedAlert.id)
                    withAnimation(shellAnimationForClose) { vm.close() }
                }
                .id(presentedAlert.id)
                .padding(.top, vm.compactAlertTopInset)
            } else if presentedAlert.isCompactWeather {
                weatherAlertCard(presentedAlert)
            } else if presentedAlert.kind == "agent-quota-reset" {
                quotaResetCard(presentedAlert)
            } else if let key = presentedAlert.agentAttentionKey {
                agentRequestCard(activities.currentAgentAttention(for: key) ?? presentedAlert)
                    .id(key)
                    .padding(.top, vm.compactAlertTopInset)
            } else if presentedAlert.isCompletedAgentSession {
                VStack(spacing: 1) {
                    if let completionReply {
                        AgentReplyChoiceCard(title: presentedAlert.title,
                            summary: activities.agentCompletionSummary(for: presentedAlert), options: completionReply.options, isPractice: false,
                            openSummary: { openTextReply(for: presentedAlert) },
                            acceptsHeadMotion: !vm.systemIslandPresentationActive,
                            motionCommand: replyMotionCommand) { index in
                            guard vm.compactAlertPresented, !vm.systemIslandPresentationActive,
                                  AgentInteraction.shared.sendCompletionReply(completionReply, choice: index, for: presentedAlert)
                            else { return false }
                            openAlertDestination(presentedAlert)
                            return true
                        } dismiss: {
                            headReplayAllowedAt = ContinuousClock.now.advanced(by: .milliseconds(650))
                            dismissAgentPopup(presentedAlert)
                        }
                    } else {
                        compactAlertCard(presentedAlert, includesTopInset: false)
                    }
                    if Defaults[.enableGestures] {
                        Capsule()
                            .fill(.primary.opacity(0.27))
                            .frame(width: 21, height: 3)
                            .scaleEffect(x: 1 - replyPullHint * 0.025, y: 1 + replyPullHint * 0.15)
                            .offset(y: replyPullHint * 0.7)
                            .padding(.vertical, 3)
                            .accessibilityHidden(true)
                    }
                }
                .offset(y: replyPullOffset)
                .contentShape(Rectangle())
                .conditionalModifier(Defaults[.enableGestures]) { card in
                    card.panGesture(direction: .down, threshold: 8, startsWithMomentum: false,
                                    isEnabled: { activeCompletionPopupID == presentedAlert.id }) { distance, phase in
                        handleTextReplyPull(distance, phase: phase, for: presentedAlert)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityAction(named: "打开文字回复") { openTextReply(for: presentedAlert) }
                .id(presentedAlert.id)
                .padding(.top, vm.compactAlertTopInset)
            } else if presentedAlert.kind == "headphone-lid", let headphone = compactHeadphoneSnapshot {
                let live = activities.headphoneAlert
                HeadphoneConnectionCard(alert: live?.id == headphone.id ? live ?? headphone : headphone, compact: true)
                    .padding(.top, vm.compactAlertTopInset)
            } else if presentedAlert.kind != "headphone-lid" {
                compactAlertCard(presentedAlert)
            }
        } else {
            // The parent owns insertion/removal. Keep the outgoing page
            // drawable while its reveal animates instead of swapping in
            // collapsed content as soon as the model changes state.
            let guideVisible = vm.isSpotlightGuideActive && spotlightGuide.isActive && !coordinator.firstLaunch && vm.notchState == .open
            let headerClearance = (vm.usesSystemIslandTrigger ? vm.systemIslandClearanceWidth : expandedHeaderSize.width) + 4
            let guideGeometry = SpotlightGuideGeometry(
                panelWidth: vm.expandedPageSize.width,
                headerHeight: expandedHeaderHeight,
                cameraClearanceWidth: headerClearance + (vm.usesSystemIslandTrigger ? 4 : 16),
                topInset: expandedPageTopInset,
                pageWidth: vm.expandedPageSize.width,
                pageHeight: pageViewportHeight,
                shelfEnabled: Defaults[.boringShelf]
            )

            VStack(alignment: .center, spacing: SpotlightGuideGeometry.coachBarTopSpacing) {
                VStack(alignment: .center, spacing: expandedPageTopInset) {
                    if coordinator.firstLaunch {
                        Spacer()
                        HelloAnimation()
                            .frame(width: getClosedNotchSize().width, height: 80)
                            .onAppear { vm.closeHello() }
                            .padding(.top, 40)
                        Spacer()
                    } else {
                        BoringHeader(
                            cameraClearanceWidth: headerClearance,
                            headerHeight: expandedHeaderHeight
                        )
                        .environment(\.colorScheme, glassHeaderScheme)
                        .environment(\.usesSharedGlassShell, usesSharedGlassShell)
                        .frame(height: expandedHeaderHeight)
                        .opacity(1 - min(abs(gestureProgress) * 0.1, 0.3))
                        .zIndex(2)
                    }
                    ZStack(alignment: .top) {
                        NotchPageContent(page: expandedPageRoute, albumArtNamespace: albumArtNamespace,
                                         viewportHeight: pageViewportHeight, previewColorScheme: systemColorScheme,
                                         selectedID: Binding(get: { vm.selectedAgentID }, set: selectAgentSession),
                                         agentHeightChanged: updateAgentListHeight,
                                         refreshWeather: { weatherRefreshRevision += 1 },
                                         onClipboardCopy: announceClipboardCopyReceipt,
                                         hasUnidentifiedAudio: musicLightSignal.audible)
                            .id(expandedPageRoute)
                            .transition(pageTransition)
                    }
                    .frame(width: vm.expandedPageSize.width, height: pageViewportHeight, alignment: .top)
                    .overlay(alignment: .topTrailing) {
                        if let alert = inlineAgentCompletion {
                            inlineCompletionBanner(alert)
                                .padding(.top, 4)
                                .padding(.trailing, 10)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -5)))
                        }
                    }
                    .animation(expandedPageAnimation, value: expandedPageRoute)
                    // Matched artwork and outgoing pages stay below the hardware
                    // header throughout an interrupted page transition.
                    .clipped()
                    .transition(.identity)
                    .zIndex(1)
                    .allowsHitTesting(vm.notchState == .open)
                    .environment(\.usesSharedGlassShell, usesSharedGlassShell)
                    .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                }
                .overlay(alignment: .topLeading) {
                    if guideVisible {
                        NotchSpotlightCutoutOverlay(
                            geometry: guideGeometry,
                            step: spotlightGuide.currentStep
                        )
                        .transition(.opacity)
                        .zIndex(10)
                    }
                }

                if guideVisible {
                    NotchSpotlightCoachBar()
                        .frame(width: vm.expandedPageSize.width)
                        .environment(\.colorScheme, .dark)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 12),
                        height: max(0, vm.effectiveClosedNotchHeight - 12)
                    )
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)
                MinimalFaceFeatures()
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        HStack {
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .clipped()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(
                    width: max(0, vm.effectiveClosedNotchHeight - 12),
                    height: max(0, vm.effectiveClosedNotchHeight - 12)
                )

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                textColor: Defaults[.coloredSpectrogram]
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                )
                .frame(
                    width: (coordinator.expandingView.show
                        && coordinator.expandingView.type == .music
                        && Defaults[.sneakPeekStyles] == .inline)
                        ? 380
                        : vm.closedNotchSize.width
                            + -cornerRadiusInsets.closed.top
                )

            HStack {
                if useMusicVisualizer {
                    Rectangle()
                        .fill(
                            Defaults[.coloredSpectrogram]
                                ? Color(nsColor: musicManager.avgColor).gradient
                                : Color.gray.gradient
                        )
                        .frame(width: 50, alignment: .center)
                        .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                        .mask {
                            AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                                .frame(width: 16, height: 12)
                        }
                } else {
                    LottieAnimationContainer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                        + gestureProgress / 2
                ),
                height: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                ),
                alignment: .center
            )
        }
        .frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    private var shelfDropDelegate: GeneralDropTargetDelegate {
        GeneralDropTargetDelegate(
            isTargeted: $vm.generalDropTargeting,
            enabled: Defaults[.boringShelf] && !ShelfSelectionModel.shared.isDragging,
            receive: { providers in
                guard !providers.isEmpty, !ShelfSelectionModel.shared.isDragging else { return false }
                vm.dropEvent = true
                coordinator.currentView = .shelf
                if vm.notchState == .closed { doOpen(preferShelf: true) }
                ShelfStateViewModel.shared.load(providers)
                return true
            })
    }

    private func holdAfterNavigation() {
        menuGraceUntil = Date().addingTimeInterval(2)
        scheduleAutoClose()
    }

    /// Hit width for the live pointer check matches the visible panel or hidden trigger.
    private var autoCloseHitWidth: CGFloat {
        vm.notchState == .open ? expandedWidth : vm.collapsedTriggerWidth
    }

    /// Shared deferred close path for hover exits, menus, navigation and popovers.
    private func scheduleAutoClose(minimumDelay: TimeInterval = 0.24) {
        hoverTask?.cancel()
        guard !vm.compactAlertPresented else { return }
        hoverTask = Task { @MainActor in
            let delay = max(minimumDelay, menuGraceUntil.timeIntervalSinceNow)
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, !vm.compactAlertPresented else { return }
            // SwiftUI hover callbacks can be stale; trust the live pointer instead.
            guard !menuIsTracking, !pointerWithinHoverArea else { return }
            let selection = expandedPageRoute == .clipboard ? vm.clipboardPendingSelectionID : nil
            withAnimation(shellAnimationForClose) {
                isHovering = false
                if vm.notchState == .open, canAutomaticallyClose {
                    if !vm.compactAlertPresented && !vm.openedForShelfDrag {
                        recentHoverPage = (expandedPageRoute, .now.advanced(by: .seconds(3)), vm.screenUUID)
                    }
                    vm.close()
                }
            }
            if vm.notchState == .closed, let selection,
               ClipboardHistoryStore.shared.copySelectedText(id: selection) {
                announceClipboardCopyReceipt()
            }
        }
    }

    private var canAutomaticallyClose: Bool {
        Date() >= menuGraceUntil && !vm.anyDropZoneTargeting && !pageInteractionActive
            && !(vm.openedForShelfDrag && vm.externalFileDragActive)
            && !ShelfSelectionModel.shared.isDragging && !ShelfStateViewModel.shared.isLoading
            && !SharingStateManager.shared.preventNotchClose
    }

    private var shellAnimationForClose: Animation? {
        reduceMotion ? nil : NotchPanelMotion.presentation(compact: vm.compactAlertPresented)
    }

    private func recentPage(at returnedAt: ContinuousClock.Instant) -> NotchPage? {
        guard let recentHoverPage, returnedAt <= recentHoverPage.until,
              recentHoverPage.screen == vm.screenUUID,
              NotchPage.available(shelfEnabled: Defaults[.boringShelf]).contains(recentHoverPage.page) else {
            return nil
        }
        return recentHoverPage.page
    }

    private var rememberedPage: NotchPage? {
        guard coordinator.openLastTabByDefault,
              let page = NotchPage(rawValue: coordinator.lastNotchPage),
              NotchPage.available(shelfEnabled: Defaults[.boringShelf]).contains(page) else { return nil }
        return page
    }

    /// Active drops take priority. A quick pointer return restores the last
    /// page before falling back to the usual file, agent and playback routes.
    private func applyOpenRoute(returnedAt: ContinuousClock.Instant? = nil) {
        let leaveEmptyShelf = ShelfStateViewModel.shared.consumeEmptyShelfFallback()
        let resumed = returnedAt.flatMap { recentPage(at: $0) }
        recentHoverPage = nil

        if Defaults[.boringShelf] && (vm.anyDropZoneTargeting || vm.externalFileDragActive) {
            coordinator.currentView = .shelf
        } else if let restored = rememberedPage ?? resumed, restored != .shelf || !leaveEmptyShelf {
            restored.activate(coordinator: coordinator, activities: activities)
        } else if Defaults[.boringShelf] && ShelfStateViewModel.shared.filePriorityActive {
            coordinator.currentView = .shelf
        } else if activities.runningAgent != nil,
                  vm.runningAgentVisible, vm.runningAgentWings.contains(NSEvent.mouseLocation) {
            coordinator.currentView = .home
            activities.showPanel = true
        } else if let primary = activities.primary,
                  primary.kind == "agent",
                  primary.priority >= 50 || !musicManager.isPlaying {
            coordinator.currentView = .home
            activities.showPanel = true
        } else if Defaults[.boringShelf], activities.primary?.kind == "airdrop" {
            coordinator.currentView = .shelf
        } else if musicManager.isPlaying {
            coordinator.currentView = .home
            activities.showPanel = false
            activities.showDashboard = false
        } else if leaveEmptyShelf,
                  coordinator.currentView == .shelf {
            // "Remember last tab" could otherwise pin the shelf after the
            // files that auto-opened it were removed. Text and links do not
            // extend this temporary priority.
            coordinator.currentView = .home
            activities.showPanel = false
            activities.showDashboard = false
        } else if activities.primary?.kind == "headphones" {
            activities.showPanel = false
        }
        vm.selectedAgentID = expandedPageRoute == .agent ? activities.resumableAgentDetailID : nil
    }

    @ViewBuilder
    private func systemAppShortcut(_ title: String, icon: String, bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Button(title, systemImage: icon) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        }
    }

    private func openCollapsedTrigger(returnedAt: ContinuousClock.Instant = .now) {
        if vm.notchState == .closed, !vm.systemIslandPresentationActive,
           let replay = replayableAgentPopup(at: .now) {
            showCompactAlert(replay)
            return
        }
        if rememberedPage != nil || recentPage(at: returnedAt) != nil || visibleWingActivity == nil {
            doOpen(returnedAt: returnedAt)
        } else if let active = visibleWingActivity {
            recentHoverPage = nil
            openActivity(active)
        }
    }

    private func canPresentAlert(_ alert: IslandActivity) -> Bool {
        if vm.notchState == .closed { return true }
        if alert.kind == "preview" { return !vm.isAgentReplyEditing }
        if alert.isCompletedAgentSession {
            return !vm.compactAlertPresented && inlineAgentCompletion == nil && !menuIsTracking
                && !vm.anyDropZoneTargeting && !SharingStateManager.shared.preventNotchClose
        }
        return (alert.agentAttentionKey != nil
                || alert.kind == "agent-quota-reset" || alert.kind == "calendar") && !vm.compactAlertPresented && !pageInteractionActive
            && !pointerWithinHoverArea && !menuIsTracking && !vm.anyDropZoneTargeting
            && !ShelfStateViewModel.shared.isLoading && !SharingStateManager.shared.preventNotchClose
    }

    private func presentProactiveAlert() {
        guard !vm.systemIslandPresentationActive, !coordinator.firstLaunch,
              Date() >= compactAlertMayPresentAt,
              !Defaults[.showOnAllDisplays] || vm.screenUUID == NSScreen.screens.first?.displayUUID,
              NSEvent.pressedMouseButtons == 0, !vm.externalFileDragActive else { return }
        let now = Date().timeIntervalSince1970
        seenAutoAlerts = seenAutoAlerts.filter { $0.value > now }
        guard let alert = activities.proactiveAlerts.first(where: {
            ($0.agentAttentionKey.map { !seenAgentRequests.contains($0) } ?? (seenAutoAlerts[$0.id] == nil))
                && $0.expires > now
                && ($0.kind != "headphone-lid" || $0.id == readyHeadphoneLidID)
                && canPresentAlert($0)
                && ($0.hasPendingAgentApproval || $0.agentAttentionKey == nil || expandNotchForAlerts || !showIslandSideActivities)
        }) else { return }
        openActivity(alert)
    }

    private func openActivity(_ active: IslandActivity) {
        guard !vm.systemIslandPresentationActive, canPresentAlert(active) else { return }
        if active.isGeneratingAgentReply {
            openAlertDestination(active)
            selectedRouteBeforeOpening = true
            withAnimation(reduceMotion ? nil : animationSpring) { vm.open() }
            return
        }
        if active.kind == "headphones" {
            withAnimation(reduceMotion ? nil : animationSpring) {
                NotchPage.music.activate(coordinator: coordinator, activities: activities)
                selectedRouteBeforeOpening = true
                vm.open()
            }
            holdAfterNavigation()
            return
        }
        if active.kind == "headphone-lid" {
            guard let headphone = activities.headphoneAlert, headphone.isBanner,
                  active.id == "headphone-lid:" + headphone.id.uuidString else { return }
        }
        if active.kind == "weather-warning", !activities.consumeWeatherPopup(active.id) { return }
        if let key = active.agentAttentionKey {
            guard let current = activities.currentAgentAttention(for: key) else { return }
            seenAgentRequests.insert(key)
            completionHoverReplay = nil
            playedCompletionReplayID = nil
            showCompactAlert(current)
            return
        }
        if active.isCompletedAgentSession {
            if vm.notchState == .open {
                guard activities.consumeAgentCompletionPopup(active.id) else { return }
                showInlineCompletion(active)
                return
            }
            if let until = wingHandoffUntil {
                guard ContinuousClock.now >= until else { return }
                wingHandoffUntil = nil
            } else if !reduceMotion, wingsResumeAfterCompletion == nil, agentRestingFrame != nil {
                withAnimation(.easeOut(duration: 0.14)) {
                    wingHandoffUntil = .now.advanced(by: .milliseconds(140))
                }
                return
            }
            guard activities.consumeAgentCompletionPopup(active.id) else { return }
            completionHoverReplay = nil
            playedCompletionReplayID = nil
            headReplayAllowedAt = nil
            agentHaloAwaitingPopupID = agentHaloDuration > 0 ? active.id : nil
            showCompactAlert(active)
            return
        }
        if active.kind != "agent" {
            seenAutoAlerts[active.id] = active.expires
            showCompactAlert(active)
            if active.kind == "preview" {
                Logger(subsystem: "theboringteam.boringnotch", category: "CompactAlert")
                    .notice("Preview presented: \(active.title, privacy: .public), \(Int(vm.notchSize.width), privacy: .public) × \(Int(vm.notchSize.height), privacy: .public)")
            }
        } else {
            openAlertDestination(active)
            selectedRouteBeforeOpening = true
            withAnimation(reduceMotion ? nil : animationSpring) { vm.open() }
        }
    }

    private func showInlineCompletion(_ alert: IslandActivity) {
        pointerOverInlineCompletion = false
        inlineCountdown = CompactAlertCountdown(duration: .seconds(3), now: .now, paused: false)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { inlineAgentCompletion = alert }
    }

    private func clearInlineCompletion() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { inlineAgentCompletion = nil }
        inlineCountdown = nil
        pointerOverInlineCompletion = false
    }

    private func inlineCompletionBanner(_ alert: IslandActivity) -> some View {
        let shape = NotchShape(topCornerRadius: 12, bottomCornerRadius: 12, topCornerIsConvex: true)
        return Button {
            clearInlineCompletion()
            openAlertDestination(alert)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: alert.symbol)
                    .font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(alert.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    AgentPopupSummary(markdown: activities.agentCompletionSummary(for: alert))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(width: min(252, vm.expandedPageSize.width - 20), height: 38)
            .foregroundStyle(.white)
            .background {
                shape.fill(.regularMaterial)
                    .overlay { shape.fill(.black.opacity(0.67)) }
            }
            .overlay {
                if let inlineCountdown { CompactAlertEdgeLight(shape: shape, countdown: inlineCountdown) }
            }
            .environment(\.colorScheme, .dark)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { pointerOverInlineCompletion = $0 }
        .accessibilityIdentifier("agent-inline-completion")
    }

    private func announceClipboardCopyReceipt() {
        if vm.notchState == .open, expandedPageRoute == .clipboard, !vm.compactAlertPresented {
            menuGraceUntil = max(menuGraceUntil, Date().addingTimeInterval(1.2))
            scheduleAutoClose()
            return
        }

        clipboardCopyReceipt = IslandActivity(id: "clipboard-copy:" + UUID().uuidString, kind: "clipboard-copy",
            title: "复制成功", detail: "", symbol: "checkmark.circle.fill", priority: 30,
            expires: Date().timeIntervalSince1970 + 6)
    }

    private func closeTimedCompactAlert() {
        guard let alert = alertDetail, compactCountdownID == alert.id else { return }
        if activeTransientAgentPopupID != nil {
            dismissAgentPopup(alert)
        } else {
            if isTestingAgentHeadMotion { activities.dismiss(alert.id) }
            withAnimation(shellAnimationForClose) {
                isHovering = false
                vm.close()
            }
        }
    }

    private func dismissAgentPopup(_ alert: IslandActivity) {
        let key = alert.agentAttentionKey ?? alert.id
        guard activeTransientAgentPopupID == key, vm.compactAlertPresented, vm.notchState == .open else { return }
        withAnimation(shellAnimationForClose) {
            isHovering = false
            vm.close()
        }
        guard vm.notchState == .closed else { return }
        if pointerWithinHoverArea {
            completionHoverResumeAt = Date().addingTimeInterval(reduceMotion ? 0.15 : 0.45)
        }
        if playedCompletionReplayID != key {
            playedCompletionReplayID = key
            completionHoverReplay = AgentCompletionHoverReplay(activity: alert, dismissedAt: .now)
        }
    }

    private func handleReplyHeadMotion(_ change: AgentReplyMotionExcursion.Change) {
        if change == .ended {
            headMotionWakingReply = false
            return
        }
        let now = ContinuousClock.now
        guard vm.notchState == .closed, !vm.systemIslandPresentationActive, !vm.externalFileDragActive,
              headReplayAllowedAt.map({ now >= $0 }) ?? true,
              let replay = completionHoverReplay?.activity(at: now),
              AgentInteraction.shared.completionReply(for: replay) != nil else { return }
        headMotionWakingReply = true
        showCompactAlert(replay)
    }

    private func handleReplyHeadGesture(_ gesture: AgentReplyHeadGesture.Action) {
        guard !headMotionWakingReply, vm.notchState == .open, !vm.systemIslandPresentationActive,
              completionReply != nil else { return }
        replyMotionCommand = AgentReplyMotionCommand(action: gesture)
    }

    private func showCompactAlert(_ alert: IslandActivity) {
        agentRimStartedAt = nil
        hoverTask?.cancel()
        alertDetail = alert
        completionReply = AgentInteraction.shared.completionReply(for: alert)
        compactHeadphoneSnapshot = alert.kind == "headphone-lid" ? activities.headphoneAlert : nil
        compactAlertCountdown = CompactAlertCountdown(
            duration: compactDuration(for: alert), now: .now, paused: pausesCompactCountdown
        )
        selectedRouteBeforeOpening = vm.notchState == .closed
        let extraWidth: CGFloat = isTestingAgentHeadMotion ? 60 : (completionReply != nil || alert.agentAttentionKey != nil ? 32 : 0)
        let height: CGFloat = alert.isCompactWeather ? 49 : isTestingAgentHeadMotion ? AgentReplyChoiceCard.practiceHeight
            : alert.agentAttentionKey != nil ? 100 : completionReply != nil ? 108 : alert.kind == "headphone-lid" ? 133 : isShowingClipboardReceipt ? 49 : alert.isCompletedAgentSession && Defaults[.enableGestures] ? 71 : 67
        let weatherClearance = alert.isCompactWeather
            ? getPhysicalNotchSize(screenUUID: vm.screenUUID).map { $0.height + 14 } ?? 0 : 0
        withAnimation(reduceMotion ? nil : NotchPanelMotion.presentation(compact: true)) {
            vm.setCompactAlertPresented(true, contentHeight: height, extraWidth: extraWidth,
                                        physicalWidth: alert.isCompactWeather, minimumTopInset: weatherClearance)
            vm.open()
        }
    }

    private func compactDuration(for alert: IslandActivity) -> Duration {
        if alert.agentAttentionKey != nil { return .seconds(5) }
        if alert.isCompletedAgentSession {
            if completionReply == nil { return AgentCompletionHoverReplay.popupDuration }
            return AgentCompletionHoverReplay.replyPopupDuration(
                headphonesConnected: activities.connectedAirPods != nil, headControlEnabled: replyHeadControlEnabled
            )
        }
        if isTestingAgentHeadMotion || alert.kind == "headphone-lid" {
            return .seconds(max(0.1, alert.expires - Date().timeIntervalSince1970))
        }
        if alert.kind == "clipboard-copy" { return .milliseconds(1800) }
        if alert.isCompactWeather || alert.kind == "agent-quota-reset" { return .seconds(4) }
        return .seconds(alert.kind == "preview" ? 10 : 6)
    }

    private func openAgentVoiceReply() {
        guard !coordinator.firstLaunch, !vm.systemIslandPresentationActive, !vm.externalFileDragActive,
              !ShelfSelectionModel.shared.isDragging, !SharingStateManager.shared.preventNotchClose else { return }
        let targets = activities.agentSessions.filter { item in
            item.source.flatMap(AgentConversationSource.init(rawValue:)) != nil &&
                (item.conversationID ?? item.sessionID).flatMap(UUID.init(uuidString:)) != nil
        }
        let preferred = vm.compactAlertPresented ? alertDetail?.destinationAgentID(in: targets) : vm.selectedAgentID
        let target = targets.first { $0.id == preferred } ?? (targets.count == 1 ? targets[0] : nil)
        hoverTask?.cancel()
        completionHoverReplay = nil
        completionReply = nil
        agentHaloAwaitingPopupID = nil
        agentHaloReadyAt = nil
        alertDetail = nil
        replyPullOffset = 0
        selectedRouteBeforeOpening = vm.notchState == .closed
        withAnimation(reduceMotion ? nil : animationSpring) {
            vm.setCompactAlertPresented(false)
            NotchPage.agent.activate(coordinator: coordinator, activities: activities)
            vm.selectedAgentID = target?.id
            if let id = target?.id { activities.lastViewedAgentID = id }
            if vm.notchState == .closed { vm.open() }
            else { vm.notchSize = vm.expandedNotchSize }
        }
        if let target, let id = (target.conversationID ?? target.sessionID).flatMap(UUID.init(uuidString:)) {
            vm.agentVoiceFocus = AgentVoiceFocus(sessionID: id)
        }
    }

    private func openTextReply(for alert: IslandActivity) {
        guard vm.notchState == .open, vm.compactAlertPresented, !vm.systemIslandPresentationActive,
              activeCompletionPopupID == alert.id else { return }
        openAlertDestination(alert)
    }

    private func handleTextReplyPull(_ distance: CGFloat, phase: NSEvent.Phase, for alert: IslandActivity) {
        guard activeCompletionPopupID == alert.id else { return }
        replyPullHint = 0
        if phase == .ended || phase == .cancelled {
            if replyPullOffset != 0 {
                withAnimation(.smooth(duration: 0.18)) { replyPullOffset = 0 }
            }
        } else if distance >= 24 {
            openTextReply(for: alert)
        } else if !reduceMotion {
            replyPullOffset = min(4, max(0, distance / 6))
        }
    }

    private func openAlertDestination(_ alert: IslandActivity) {
        if alert.kind == "agent-quota-reset" || alert.kind == "preview" {
            withAnimation(shellAnimationForClose) { vm.close() }
            return
        }
        withAnimation(reduceMotion ? nil : animationSpring) {
            if alert.isCompletedAgentSession || alert.agentAttentionKey != nil {
                agentHaloAwaitingPopupID = nil
                agentHaloReadyAt = nil
                completionHoverReplay = nil
                completionReply = nil
                replyPullOffset = 0
            }
            vm.setCompactAlertPresented(false)
            if alert.kind == "agent" || alert.isGeneratingAgentReply {
                NotchPage.agent.activate(coordinator: coordinator, activities: activities)
                vm.selectedAgentID = alert.destinationAgentID(in: activities.agentSessions)
                    ?? alert.destinationAgentID(in: activities.completedAgentSessions)
                activities.lastViewedAgentID = vm.selectedAgentID
            } else {
                NotchPage.calendar.activate(coordinator: coordinator, activities: activities)
                vm.selectedAgentID = nil
            }
            alertDetail = nil
            // Commit the route and shell size before the conversation is mounted.
            if vm.notchState == .open { vm.notchSize = vm.expandedNotchSize }
        }
        holdAfterNavigation()
    }

    private func updateAgentListHeight(_ height: CGFloat) {
        guard vm.notchState == .open, expandedPageRoute == .agent, !vm.compactAlertPresented else { return }
        let requiredHeight = expandedHeaderHeight + expandedPageTopInset + expandedBottomInset
            + AgentSessionListMetrics.height(for: AgentSessionListMetrics.compactCount) + height
        let compensated = height > 0 ? max(height, requiredHeight - BoringViewModel.regularPanelHeight) : 0
        guard vm.agentListExtraHeight != compensated else { return }
        withAnimation(reduceMotion ? nil : animationSpring) {
            vm.agentListExtraHeight = compensated
            vm.notchSize = vm.expandedNotchSize
        }
    }

    private func selectAgentSession(_ id: String?) {
        guard vm.notchState == .open, !vm.compactAlertPresented, expandedPageRoute == .agent else { return }
        withAnimation(reduceMotion ? nil : animationSpring) {
            vm.selectedAgentID = id
            activities.lastViewedAgentID = id
            vm.notchSize = vm.expandedNotchSize
        }
    }

    private func agentRequestCard(_ alert: IslandActivity) -> some View {
        let approval = alert.hasPendingAgentApproval
        let accent: Color = approval ? .orange : Color(red: 0.55, green: 0.75, blue: 1)
        let source = alert.title.components(separatedBy: " · ").first ?? "Agent"
        let subject = alert.sessionTitle ?? alert.detail
        let codexRequest = activities.codexApproval(for: alert)
        let requestAction = codexRequest?.reason.isEmpty == false ? codexRequest?.reason : alert.progress?.lastTool
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ActivityAvatar(activity: alert, size: 18).accessibilityHidden(true)
                Text(source).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Label(approval ? "待审批" : "等待回复",
                      systemImage: approval ? "hand.raised.fill" : "bubble.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(accent.opacity(0.12), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(subject).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let action = requestAction, action != subject {
                    Text(action).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                Button { dismissAgentPopup(alert) } label: {
                    Text("稍后").font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(.primary.opacity(0.08), in: Capsule())
                }
                Button {
                    guard let key = alert.agentAttentionKey, let current = activities.currentAgentAttention(for: key) else { return }
                    openAlertDestination(current)
                } label: {
                    Label(codexRequest?.command != nil ? "查看并审批" : approval ? "查看请求" : "查看并回复",
                          systemImage: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        .padding(.horizontal, 9).frame(height: 24)
                        .foregroundStyle(accent)
                        .background(accent.opacity(0.16), in: Capsule())
                }
            }
            .buttonStyle(NotchControlStyle())
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 85, alignment: .leading)
        .accessibilityIdentifier("agent-request-popup")
    }

    private func quotaResetCard(_ alert: IslandActivity) -> some View {
        HStack(spacing: 10) {
            AgentQuotaResetMark(alert: alert)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Text(alert.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 49)
        .padding(.top, vm.compactAlertTopInset)
        .accessibilityIdentifier("agent-quota-reset-popup")
    }

    private func weatherAlertCard(_ alert: IslandActivity) -> some View {
        Button { openAlertDestination(alert) } label: {
            HStack(spacing: 6) {
                CompactAlertIcon(alert: alert, size: 28, duration: 3.1)
                Text(alert.title.replacingOccurrences(of: "预警信号", with: "预警"))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, vm.compactAlertTopInset)
        .accessibilityIdentifier("weather-warning-compact")
    }

    private func compactAlertCard(_ alert: IslandActivity, includesTopInset: Bool = true) -> some View {
        Button { openAlertDestination(alert) } label: {
            HStack(spacing: 8) {
                CompactAlertIcon(alert: alert)
                    .id(alert.id)
                VStack(alignment: .leading, spacing: 3) {
                    Text(alert.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if alert.isCompletedAgentSession {
                        AgentPopupSummary(markdown: activities.agentCompletionSummary(for: alert))
                    } else {
                        Text(alert.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 14)
            }
            .padding(.horizontal, 4)
            .frame(height: 57)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, includesTopInset ? vm.compactAlertTopInset : 0)
        .accessibilityHint(alert.kind == "preview" ? "关闭测试提醒" : alert.kind == "agent" ? "打开对应会话" : "查看详情")
    }

    private func refreshNotchWeather(city rawCity: String) async {
        let city = String(rawCity.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !city.isEmpty else { activities.setWeather(city: nil); return }
        activities.beginWeatherRefresh(city: city)
        var location: NotchForecast.Place?
        var warningProvince: String?
        var nextConditionRefresh = Date.distantPast
        while !Task.isCancelled {
            do {
                if location == nil { location = try await NotchForecast.place(named: city) }
                guard let location else {
                    activities.endWeatherRefresh(message: "找不到该城市")
                    return
                }
                let refreshConditions = Date() >= nextConditionRefresh
                async let conditions = refreshConditions ? try? NotchForecast.current(at: location) : nil
                if warningProvince == nil { warningProvince = try? await NotchForecast.warningProvince(for: location) }
                if let warnings = try? await NotchForecast.warnings(at: location, province: warningProvince ?? ""), !Task.isCancelled {
                    let now = Date()
                    let popupIDs = Set(warnings.filter { $0.canPopUp(now: now) }.map { "weather-warning:" + $0.alertid })
                    activities.updateWeatherWarnings(warnings.compactMap { $0.activity() }, popupIDs: popupIDs)
                }
                if refreshConditions && !Task.isCancelled {
                    nextConditionRefresh = Date().addingTimeInterval(900)
                    if let weather = await conditions, !Task.isCancelled {
                        let (condition, symbol) = weather.presentation
                        let summary = "\(condition) · \(weather.temperature.formatted(.number.precision(.fractionLength(0)))) °C"
                        activities.setWeather(city: location.label, summary: summary, symbol: symbol)
                    } else if !Task.isCancelled {
                        activities.endWeatherRefresh(message: "天气更新失败")
                    }
                }
            } catch {
                if Task.isCancelled { return }
                activities.endWeatherRefresh(message: "天气更新失败")
            }
            try? await Task.sleep(for: .seconds(120))
        }
    }

    private func doOpen(preferShelf: Bool = false, returnedAt: ContinuousClock.Instant? = nil) {
        guard vm.notchState == .closed, !vm.systemIslandPresentationActive else { return }
        withAnimation(animationSpring) {
            if preferShelf {
                recentHoverPage = nil
                coordinator.currentView = .shelf
            } else {
                applyOpenRoute(returnedAt: returnedAt)
            }
            selectedRouteBeforeOpening = true
            vm.open(forShelfDrag: preferShelf && !vm.dropEvent)
        }
    }

    // MARK: - Hover Management

    private var pointerWithinHoverArea: Bool {
        if vm.notchState == .closed && vm.usesSystemIslandTrigger {
            return vm.acceptsIslandHover(at: NSEvent.mouseLocation)
        }
        return vm.isMouseHovering(width: autoCloseHitWidth) || vm.isOverNativeIsland(NSEvent.mouseLocation)
    }

    private func handleHover(_ hovering: Bool) {
        if hovering {
            guard vm.notchState == .open
                    || pointerWithinHoverArea else { return }
            // SwiftUI can deliver a stale enter after the pointer has already
            // left. A pending collapse must not be cancelled by that: only a
            // re-entry inside the live hit area may cancel it.
            if hoverTask != nil,
               vm.notchState == .open,
               !pointerWithinHoverArea {
                return
            }

            hoverTask?.cancel()

            withAnimation(animationSpring) {
                isHovering = true
            }
            
            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }
            
            guard vm.notchState == .closed, Defaults[.openNotchOnHover],
                  Date() >= completionHoverResumeAt else { return }

            let replay = replayableAgentPopup(at: .now)
            if replay == nil { completionHoverReplay = nil }
            let returnedAt = ContinuousClock.now
            hoverTask = Task {
                let delay = Defaults[.minimumHoverDuration]
                try? await Task.sleep(for: .seconds(vm.usesSystemIslandTrigger ? max(0.25, delay) : delay))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          self.pointerWithinHoverArea,
                          NSEvent.pressedMouseButtons == 0 else { return }
                    
                    if let replay, let latest = self.replayableAgentPopup(at: returnedAt), latest.id == replay.id,
                       !self.vm.systemIslandPresentationActive {
                        self.showCompactAlert(latest)
                    } else {
                        self.openCollapsedTrigger(returnedAt: returnedAt)
                    }
                }
            }
        } else {
            scheduleAutoClose()
        }
    }

    // MARK: - Gesture Handling

    private var canStartOpenGesture: Bool {
        vm.notchState == .closed && !vm.systemIslandPresentationActive
            && vm.isMouseHovering(width: autoCloseHitWidth)
    }

    private var canStartCloseGesture: Bool {
        guard vm.notchState == .open, !vm.systemIslandPresentationActive,
              vm.isMouseHovering(width: autoCloseHitWidth),
              let screen = getScreenFrame(vm.screenUUID) else { return false }
        return NSEvent.mouseLocation.y >= screen.maxY - expandedHeaderHeight
    }

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        if phase == .cancelled {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        if phase == .cancelled {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }
        guard vm.notchState == .open && !vm.isHoveringCalendar && !pageInteractionActive
                && !menuIsTracking && !vm.anyDropZoneTargeting && !ShelfSelectionModel.shared.isDragging else {
            if gestureProgress != 0 { withAnimation(animationSpring) { gestureProgress = .zero } }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
                if !SharingStateManager.shared.preventNotchClose {
                    gestureProgress = .zero
                    vm.close()
                }
            }

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }
}

private struct ShelfDropCueMotion: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let phase = min(1, max(0, progress))
        let stretch = sin(.pi * phase)
        content
            .scaleEffect(x: 0.67 + 0.33 * phase - 0.12 * stretch,
                         y: 0.48 + 0.52 * phase + 0.35 * stretch, anchor: .top)
            .offset(y: -12 + 17 * phase)
            .opacity(Double(notchPhase(phase, from: 0.02, to: 0.47)))
    }
}

private struct ShelfDropGlassCue: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let shape = Circle()

    var body: some View {
        ZStack {
            surface
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.50), .white.opacity(0.10), .black.opacity(0.18)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.7)
                }

            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                let travel = reduceMotion ? 0.0 : sin(context.date.timeIntervalSinceReferenceDate * 4.5) * 1.35
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.93))
                    .shadow(color: .black.opacity(0.44), radius: 1.5, y: 1)
                    .offset(y: -travel)
            }
        }
    }

    @ViewBuilder
    private var surface: some View {
        if reduceTransparency {
            shape.fill(Color(white: 0.17))
        } else if #available(macOS 26, *) {
            Color.clear.glassEffect(.clear.tint(.black.opacity(0.40)), in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
                .overlay { shape.fill(.black.opacity(0.34)) }
        }
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    static let types: [UTType] = [.fileURL, .url, .utf8PlainText, .plainText, .data, .image]
    @Binding var isTargeted: Bool
    var enabled: Bool
    var receive: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        enabled && info.hasItemsConforming(to: Self.types)
    }
    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { isTargeted = true }
    }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .copy : .cancel)
    }
    func performDrop(info: DropInfo) -> Bool {
        defer { isTargeted = false }
        guard validateDrop(info: info) else { return false }
        return receive(info.itemProviders(for: Self.types))
    }
}

#Preview {
    let vm = BoringViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}


extension Notification.Name {
    static let notchPreviewRefreshWeather = Notification.Name("NotchPreviewRefreshWeather")
}

enum NotchPanelMotion {
    static func spring(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .interactiveSpring(response: 0.43, dampingFraction: 0.9, blendDuration: 0.12)
    }

    /// A persistent spring carries the current velocity through a reversal.
    static func presentation(compact: Bool = false) -> Animation {
        .interactiveSpring(response: compact ? 0.36 : 0.40,
                           dampingFraction: compact ? 0.87 : 0.89, blendDuration: 0.10)
    }
}

struct NotchPageContent: View {
    var page: NotchPage
    var albumArtNamespace: Namespace.ID
    var viewportHeight: CGFloat
    var previewColorScheme: ColorScheme
    @Binding var selectedID: String?
    var agentHeightChanged: (CGFloat) -> Void
    var refreshWeather: () -> Void
    var onClipboardCopy: () -> Void
    var hasUnidentifiedAudio = false

    var body: some View {
        switch page {
        case .agent:
            UnifiedActivityPanel(selectedID: $selectedID, viewportHeight: viewportHeight,
                                 previewColorScheme: previewColorScheme, listHeightChanged: agentHeightChanged)
                .frame(maxWidth: .infinity)
        case .calendar:
            NotchHomeView(albumArtNamespace: albumArtNamespace, viewportHeight: viewportHeight,
                          refreshWeather: refreshWeather)
        case .music:
            NotchHomeView(albumArtNamespace: albumArtNamespace, compactMusic: true, viewportHeight: viewportHeight,
                          hasUnidentifiedAudio: hasUnidentifiedAudio)
        case .shelf:
            ShelfView()
        case .clipboard:
            ClipboardHistoryView(viewportHeight: viewportHeight, previewColorScheme: previewColorScheme,
                                 onCopied: onClipboardCopy)
        }
    }
}

private struct OutgoingNotchPage: ViewModifier {
    let isLeaving: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isLeaving ? 0 : 1)
            .allowsHitTesting(!isLeaving)
            .accessibilityHidden(isLeaving)
    }
}

private extension IslandActivity {
    var isCompactWeather: Bool {
        kind == "weather-warning" || id.hasPrefix("preview:rain:")
    }
}

private struct AgentQuotaResetMark: View {
    let alert: IslandActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .trim(from: 0, to: settled || reduceMotion ? 1 : 0.04)
                .stroke(.mint.opacity(0.80), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 29, height: 29)
            ActivityAvatar(activity: alert, size: 17)
                .frame(width: 29, height: 29)
                .scaleEffect(settled || reduceMotion ? 1 : 0.84)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.mint)
                .background(.black, in: Circle())
                .opacity(settled || reduceMotion ? 1 : 0)
                .scaleEffect(settled || reduceMotion ? 1 : 0.5, anchor: .bottomTrailing)
        }
        .accessibilityHidden(true)
        .task {
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.58, dampingFraction: 0.8)) { settled = true }
        }
    }
}

private enum CompactAlertMotion {
    case bell, calendar, warning
    case agent(AgentIslandPhase)
    case weather(WeatherAlertAnimation)

    init(alert: IslandActivity) {
        switch alert.kind {
        case "weather-warning":
            self = WeatherAlertAnimation.matching(alert.title + alert.detail).map(Self.weather) ?? .warning
        case "preview" where alert.id.hasPrefix("preview:rain:"):
            self = .weather(.rain)
        case "calendar": self = .calendar
        case "clipboard-copy": self = .agent(.finished)
        case "agent": self = alert.progress?.islandPhase.map(Self.agent) ?? .bell
        default: self = .bell
        }
    }
}

private struct CompactAlertIcon: View {
    let alert: IslandActivity
    var size: CGFloat = 28
    var duration: TimeInterval?
    var onFinished: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var began: Date?

    var body: some View {
        let motion = CompactAlertMotion(alert: alert)
        Group {
            if case let .weather(asset) = motion {
                WeatherAlertArtwork(asset: asset, duration: duration ?? WeatherAlertArtwork.popupPlayback, onFinished: onFinished)
                    .frame(width: size * 32 / 28, height: size * 32 / 28)
                    .frame(width: size, height: size * 32 / 28)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: began == nil || reduceMotion)) { timeline in
                    let t = reduceMotion ? 0 : began.map { max(0, timeline.date.timeIntervalSince($0)) } ?? 0
                    drawing(motion, time: t)
                        .frame(width: 28, height: 32)
                        .clipped()
                        .scaleEffect(size / 28)
                        .frame(width: size, height: size * 32 / 28)
                }
                .task(id: reduceMotion) {
                    began = nil
                    guard !reduceMotion else { return }
                    do {
                        try await Task.sleep(for: .milliseconds(200))
                        began = Date()
                        try await Task.sleep(for: .seconds(duration ?? 2.1))
                        began = nil
                    } catch { return }
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func drawing(_ motion: CompactAlertMotion, time t: Double) -> some View {
        switch motion {
        case .bell:
            symbol("bell.fill", tint: .accentColor)
                .rotationEffect(.degrees(13 * sin(t * 18) * exp(-t * 1.9)), anchor: .top)
        case .calendar:
            symbol("calendar.badge.clock", tint: .accentColor)
                .offset(y: -3 * sin(min(t / 0.45, 1) * .pi))
        case .agent(let phase):
            symbol(phase.symbol, tint: phase.tint)
                .scaleEffect(1 + 0.16 * sin(min(t / 0.5, 1) * .pi))
        case .weather:
            EmptyView()
        case .warning:
            symbol("exclamationmark.triangle.fill", tint: .orange)
                .scaleEffect(1 + 0.11 * sin(min(t / 0.42, 1) * .pi))
        }
    }

    private func symbol(_ name: String, tint: Color, size: CGFloat = 19) -> some View {
        Image(systemName: name).font(.system(size: size, weight: .medium)).foregroundStyle(tint)
    }
}
