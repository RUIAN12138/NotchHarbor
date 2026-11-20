// Unified activity presentation. See docs/ACTIVITY_SOURCES.md for design sources.
import SwiftUI
import AppKit
import Combine
import CoreAudio

// Adapted from Agent Notch's SessionRowPresentation / UsageLimitMonitor.
// Apache-2.0 attribution is retained in ThirdParty/AgentNotch.
struct AgentChildProgress: Codable, Equatable { var id: String; var active: Bool }
struct AgentToolStep: Codable, Equatable, Identifiable {
    var id: String
    var tool: String
    var returned: Bool
    var startedAt: Double?

    var isValid: Bool {
        id.count <= 32 && tool.count <= 96 && (startedAt.map { $0.isFinite && $0 > 0 } ?? true)
    }
}

struct AgentSessionTokens: Codable, Equatable {
    var total: Int
    var input: Int?
    var output: Int?

    var isValid: Bool {
        (1...10_000_000_000).contains(total)
            && [input, output].compactMap { $0 }.allSatisfy { (0...total).contains($0) }
    }
}

enum AgentIslandPhase: String, CaseIterable {
    case processing
    case runningTool = "running_tool"
    case compacting
    case waitingForApproval = "waiting_for_approval"
    case waitingForInput = "waiting_for_input"
    case finished
    case failed

    var isTerminal: Bool { self == .finished || self == .failed }

    var symbol: String {
        switch self {
        case .processing: "circle.dotted"
        case .runningTool: "terminal"
        case .compacting: "arrow.down.to.line"
        case .waitingForApproval: "hand.raised.fill"
        case .waitingForInput: "bubble.left.fill"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .processing: .white.opacity(0.9)
        case .runningTool: .cyan
        case .compacting: .purple
        case .waitingForApproval: .orange
        case .waitingForInput: .yellow
        case .finished: .green
        case .failed: .red
        }
    }

    var attentionPriority: Int {
        switch self {
        case .waitingForApproval: 2
        case .waitingForInput: 1
        default: 0
        }
    }
}

struct AgentProgress: Codable, Equatable {
    var phase: String
    var observedAt: Double
    var children: [AgentChildProgress]
    var lastTool: String? = nil
    var recentTools: [AgentToolStep]? = nil
    var tokenUsage: AgentSessionTokens? = nil

    var islandPhase: AgentIslandPhase? { AgentIslandPhase(rawValue: phase) }

    var isValid: Bool {
        islandPhase != nil
            && observedAt.isFinite && observedAt > 0 && children.count <= 16
            && children.allSatisfy { $0.id.count <= 64 }
            && (lastTool?.count ?? 0) <= 96
            && (recentTools.map { $0.count <= 6 && $0.allSatisfy(\.isValid) } ?? true)
            && (tokenUsage?.isValid ?? true)
    }
    var title: String {
        switch phase {
        case "running_tool": return "正在调用工具"
        case "compacting": return "正在整理上下文"
        case "waiting_for_approval": return "等待审批"
        case "waiting_for_input": return "等待输入"
        case "finished": return "本轮已完成"
        case "failed": return "本轮异常结束"
        default: return "正在处理"
        }
    }
}
struct AgentUsageWindow: Codable, Equatable {
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Double?
    var label: String?

    var isValid: Bool {
        usedPercent.isFinite && (0...100).contains(usedPercent)
            && (windowMinutes.map { (1...527040).contains($0) } ?? true)
            && (resetsAt.map { $0.isFinite && $0 > 0 && $0 < Date().timeIntervalSince1970 + 366 * 86400 } ?? true)
            && (label?.count ?? 0) <= 48
    }
    var remaining: Double { 100 - usedPercent }
    var cycle: String {
        switch windowMinutes {
        case 300: return "5 小时"
        case 10_080: return "每周"
        default: break
        }
        if let label { return label }
        guard let windowMinutes else { return "额度" }
        if windowMinutes.isMultiple(of: 1440) { return "\(windowMinutes / 1440) 天" }
        if windowMinutes.isMultiple(of: 60) { return "\(windowMinutes / 60) 小时" }
        return "\(windowMinutes) 分钟"
    }

    func isCurrent(at now: Double) -> Bool { resetsAt.map { $0 > now } ?? true }
}

struct AgentProviderUsage: Codable, Equatable, Identifiable {
    struct Billing: Codable, Equatable {
        let currencyCode: String
        let used: Double?
        let limit: Double?
        let balance: Double?

        var isValid: Bool {
            let amounts = [used, limit, balance].compactMap { $0 }
            return !amounts.isEmpty && amounts.allSatisfy { $0.isFinite && abs($0) <= 1e12 }
                && (1...12).contains(currencyCode.utf8.count)
                && currencyCode.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) }
        }
    }

    let id: String
    let updatedAt: Double
    let windows: [AgentUsageWindow]
    let billing: Billing?
    let localTokens30Days: Int?

    var isValid: Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
            && updatedAt.isFinite && updatedAt > 0 && updatedAt <= Date().timeIntervalSince1970 + 5
            && windows.count <= 6 && windows.allSatisfy(\.isValid)
            && (billing?.isValid ?? true) && (localTokens30Days.map { (0...100_000_000_000_000).contains($0) } ?? true)
            && (!windows.isEmpty || billing != nil || localTokens30Days != nil)
    }

    var name: String {
        switch id {
        case "codex": "Codex"
        case "claude": "Claude"
        case "antigravity": "Antigravity"
        case "gemini": "Gemini"
        case "openai": "OpenAI API"
        case "openrouter": "OpenRouter"
        case "doubao": "豆包"
        case "qwen-cloud": "通义千问"
        case "deepseek": "DeepSeek"
        case "minimax": "MiniMax"
        default: id.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    var showsQuotaRings: Bool {
        !windows.isEmpty && (billing == nil || windows.contains { $0.windowMinutes == 300 || $0.windowMinutes == 10_080 })
    }

    func window(minutes: Int, at now: Double) -> AgentUsageWindow? {
        windows.first { $0.windowMinutes == minutes && isCurrent($0, at: now) }
    }

    func isCurrent(_ window: AgentUsageWindow, at now: Double) -> Bool {
        now - updatedAt < 86400 && window.isCurrent(at: now)
    }

    enum Exhaustion: Equatable {
        case depleted
        case beforeReset(Date)
        case lastsUntilReset
        case unavailable
    }

    func exhaustion(for window: AgentUsageWindow, at now: Double) -> Exhaustion {
        guard isCurrent(window, at: now) else { return .unavailable }
        if window.usedPercent >= 100 { return .depleted }
        guard let reset = window.resetsAt, let minutes = window.windowMinutes,
              updatedAt < reset else { return .unavailable }
        let duration = Double(minutes) * 60
        let elapsed = updatedAt - (reset - duration)
        // Give the current cycle time to accumulate a meaningful observation.
        guard elapsed >= max(60, duration * 0.03) else { return .unavailable }
        if window.usedPercent == 0 { return .lastsUntilReset }
        let estimate = updatedAt + elapsed * window.remaining / window.usedPercent
        guard estimate > now else { return .unavailable }
        return estimate < reset ? .beforeReset(Date(timeIntervalSince1970: estimate)) : .lastsUntilReset
    }

    static func selected(from providers: [Self], preferred: String, active: String?) -> Self? {
        providers.first { $0.id == preferred }
            ?? providers.first { $0.id == active }
            ?? providers.first { $0.id == "codex" }
            ?? providers.first
    }
}

private struct AgentUsageSnapshot: Decodable {
    let primary: AgentUsageWindow?
    let secondary: AgentUsageWindow?
    let updatedAt: Double

    var provider: AgentProviderUsage {
        .init(id: "codex", updatedAt: updatedAt, windows: [primary, secondary].compactMap { $0 },
              billing: nil, localTokens30Days: nil)
    }
}


struct IslandActivity: Identifiable, Equatable, Codable {
    var id: String
    var kind: String
    var title: String
    var detail: String
    var symbol: String
    var priority: Int
    var expires: Double
    var source: String? = nil
    var sessionID: String? = nil
    var progress: AgentProgress? = nil
    var sessionTitle: String? = nil
    var conversationID: String? = nil
    enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, symbol, priority, expires, source, sessionID, progress, sessionTitle, conversationID
    }
}

extension IslandActivity {
    var weatherWarningURL: URL? {
        guard kind == "weather-warning", let source, let url = URL(string: source),
              url.scheme == "https", url.host == "nmc.cn", url.path.hasPrefix("/publish/alarm/") else { return nil }
        return url
    }

    var isGeneratingAgentReply: Bool { kind == "agent-reply-generating" }

    var agentCurrentAction: String {
        let fallback = title.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
        guard let progress = progress else { return fallback.isEmpty ? "状态尚未更新" : fallback }
        switch progress.phase {
        case "processing": return "思考中"
        case "running_tool":
            guard let tool = progress.lastTool?.lowercased() else { return progress.title }
            if tool.contains("apply_patch") || ["edit", "write", "multiedit"].contains(tool) { return "正在修改文件" }
            if tool.contains("exec_command") || tool == "bash" { return "正在运行命令" }
            if tool.contains("search") || ["grep", "glob"].contains(tool) { return "正在搜索" }
            if tool.contains("read_file") || tool == "read" { return "正在读取文件" }
            if tool.contains("spawn_agent") { return "正在启动子 Agent" }
            if tool.contains("wait_agent") { return "正在等待子 Agent" }
            return progress.title
        default: return progress.title
        }
    }

    var isCompletedAgentSession: Bool {
        kind == "agent" && progress?.islandPhase?.isTerminal == true
    }

    func destinationAgentID(in sessions: [IslandActivity]) -> String? {
        let conversation = conversationID ?? sessionID
        return sessions.first {
            if id == $0.id { return true }
            if isCompletedAgentSession, let stamp = progress?.observedAt,
               id == $0.id + ":completion:" + String(stamp) { return true }
            return conversation != nil && $0.source == source && ($0.conversationID ?? $0.sessionID) == conversation
        }?.id
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(String.self, forKey: .kind)
        title = try values.decode(String.self, forKey: .title)
        detail = try values.decode(String.self, forKey: .detail)
        symbol = try values.decode(String.self, forKey: .symbol)
        priority = try values.decode(Int.self, forKey: .priority)
        expires = try values.decode(Double.self, forKey: .expires)
        source = try? values.decode(String.self, forKey: .source)
        sessionID = try? values.decode(String.self, forKey: .sessionID)
        sessionTitle = try? values.decode(String.self, forKey: .sessionTitle)
        conversationID = try? values.decode(String.self, forKey: .conversationID)
        // A missing or malformed optional extension must not discard a valid
        // legacy session, or the other sessions in the same snapshot.
        progress = try? values.decode(AgentProgress.self, forKey: .progress)
    }
}

enum AgentReplyMotionSettings {
    static let enabledKey = "agentReplyHeadMotionEnabled"
    static let testedKey = "agentReplyHeadMotionTested"
    static let previewPrefix = "preview:agent-reply-motion:"
}

struct AgentCompletionHoverReplay {
    static let popupDuration: Duration = .seconds(2)

    static func replyPopupDuration(headphonesConnected: Bool, headControlEnabled: Bool) -> Duration {
        headphonesConnected || headControlEnabled ? .seconds(5) : popupDuration
    }

    static func canAutoDismiss(pointerInside: Bool, headActive: Bool) -> Bool {
        !pointerInside && !headActive
    }

    let activity: IslandActivity
    let dismissedAt: ContinuousClock.Instant

    func activity(at hoverStartedAt: ContinuousClock.Instant) -> IslandActivity? {
        let elapsed = dismissedAt.duration(to: hoverStartedAt)
        return elapsed >= .zero && elapsed < .seconds(15) ? activity : nil
    }
}

@MainActor
final class UnifiedActivities: ObservableObject {
    static let shared = UnifiedActivities()
    @Published private(set) var activities: [IslandActivity] = []
    @Published private(set) var completedAgentSessions: [IslandActivity] = []
    @Published private(set) var agentUsage: [AgentProviderUsage] = []
    @Published var showPanel = false
    @Published var showDashboard = false
    @Published var lidDetectionEnabled = UserDefaults.standard.object(forKey: "airPodsLidDetection") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(lidDetectionEnabled, forKey: "airPodsLidDetection")
            lidMonitor?.setEnabled(lidDetectionEnabled)
        }
    }
    @Published private(set) var lidDetectionStatus = "开盖检测未启动"
    private var lidMonitor: AirPodsLidMonitor?
    private var proximityIdentity: UUID?
    private var recentWear: (identity: UUID, counter: UInt8)?
    private var audioCueID: UUID?
    private var headphoneLookup: Task<Void, Never>?
    @Published private(set) var headphoneAlert: DeviceAlert?
    @Published private var audioDeviceSnapshot: DeviceAlert?
    private var audioDeviceAddress: String?
    private var audioLookupStartedAt = Date.distantPast
    var connectedAirPods: DeviceAlert? {
        audioDeviceSnapshot.flatMap { $0.isAirPods ? $0 : nil }
    }

    func airPodsOutputDevice(for snapshotID: UUID) -> AudioDeviceID? {
        guard connectedAirPods?.id == snapshotID, lastOutput != kAudioObjectUnknown,
              currentOutput() == lastOutput else { return nil }
        return lastOutput
    }
    private let observeDevices: Bool
    @Published private(set) var bridgeAvailable = false
    private var dismissed: [String: Double] = [:]
    private var expiry: Task<Void, Never>?
    private var agentObserver: NSObjectProtocol?
    private var usageObserver: NSObjectProtocol?
    private var watcher: DispatchSourceFileSystemObject?
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var lastOutput: AudioDeviceID = 0
    private var lastHeadphoneNotice = Date.distantPast
    private var lastHeadphoneName = ""
    private let directory: URL
    @Published private(set) var selectedActivityID: String?

    var primary: IslandActivity? {
        if let urgent = activities.first, urgent.priority >= 75 { return urgent }
        return activities.first(where: { $0.id == selectedActivityID }) ?? activities.first
    }
    func selectActivity(_ id: String) { selectedActivityID = selectedActivityID == id ? nil : id }

    var hasActivity: Bool { primary != nil }
    @Published private var completionNotices: [IslandActivity] = []
    @Published private var generatingReplyWings: [String: IslandActivity] = [:]
    private var completionExpiry: Task<Void, Never>?

    private var recentCompletionNotices: [String: Double] = [:]

    func beginAgentReplyGeneration(_ original: IslandActivity, turn: Double) -> String {
        var wing = original
        wing.id = original.id + ":reply-generation:" + String(turn)
        wing.kind = "agent-reply-generating"
        wing.detail = "正在生成快捷回复"
        wing.symbol = "sparkles"
        generatingReplyWings[wing.id] = wing
        return wing.id
    }

    func endAgentReplyGeneration(_ id: String) {
        generatingReplyWings.removeValue(forKey: id)
    }

    func announceAgentCompletion(_ original: IslandActivity, hasReplies: Bool) {
        let now = Date().timeIntervalSince1970
        guard original.isCompletedAgentSession, let finishedAt = original.progress?.observedAt else { return }
        var notice = original
        notice.id = original.id + ":completion:" + String(finishedAt)
        recentCompletionNotices = recentCompletionNotices.filter { $0.value > now - 300 }
        guard recentCompletionNotices[notice.id] == nil else { return }
        recentCompletionNotices[notice.id] = now
        notice.expires = now + 75
        let agent = original.title.components(separatedBy: " · ").first ?? "Agent"
        let failed = original.progress?.phase == "failed"
        notice.title = agent + (failed ? " 运行异常" : " 已完成")
        let task = original.sessionTitle ?? ""
        let summary = hasReplies ? "快捷回复已准备好" : (failed ? "查看会话详情" : "本轮已结束")
        notice.detail = task.isEmpty ? summary : task + " · " + summary
        notice.symbol = failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
        completionNotices.append(notice)
        scheduleNextCompletion()
    }

    func consumeAgentCompletionPopup(_ id: String) -> Bool {
        let now = Date().timeIntervalSince1970
        guard let index = completionNotices.firstIndex(where: { $0.id == id && $0.expires > now }) else {
            return false
        }
        completionNotices.remove(at: index)
        scheduleNextCompletion()
        return true
    }

    private func scheduleNextCompletion() {
        completionExpiry?.cancel()
        guard let next = completionNotices.first?.expires else { return }
        completionExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next - Date().timeIntervalSince1970)))
            guard !Task.isCancelled, let self else { return }
            let now = Date().timeIntervalSince1970
            self.completionNotices.removeAll { $0.expires <= now }
            self.scheduleNextCompletion()
        }
    }

    var proactiveAlerts: [IslandActivity] {
        activities.filter {
            $0.kind == "preview" || $0.kind == "calendar" || $0.kind == "weather-warning" || $0.progress?.phase == "waiting_for_approval"
        } + completionNotices + [headphoneLidNotice].compactMap { $0 }
    }

    var proactiveAlert: IslandActivity? { proactiveAlerts.first }
    var wingActivity: IslandActivity? {
        proactiveAlerts.first { $0.kind != "headphone-lid" && $0.kind != "weather-warning" && !$0.isCompletedAgentSession }
            ?? headphoneNotice
            ?? generatingReplyWings.values.max { ($0.progress?.observedAt ?? 0) < ($1.progress?.observedAt ?? 0) }
            ?? runningAgent
    }

    private var headphoneNotice: IslandActivity? {
        guard let alert = headphoneAlert, !alert.isBanner,
              var activity = activities.first(where: { $0.kind == "headphones" }) else { return nil }
        activity.id = "headphone-wings:" + alert.id.uuidString
        return activity
    }

    private var headphoneLidNotice: IslandActivity? {
        guard let alert = headphoneAlert, alert.isBanner,
              var activity = activities.first(where: { $0.kind == "headphones" }) else { return nil }
        activity.id = "headphone-lid:" + alert.id.uuidString
        activity.kind = "headphone-lid"
        return activity
    }
    @Published private(set) var currentWeather: IslandActivity?
    @Published private var latestWeatherWarning: IslandActivity?
    var currentWeatherWarning: IslandActivity? {
        guard let warning = latestWeatherWarning, warning.expires > Date().timeIntervalSince1970 else { return nil }
        return warning
    }
    @Published private(set) var weatherUpdatedAt: Date?
    @Published private(set) var weatherRefreshMessage: String?
    private var requestedWeatherCity: String?

    func beginWeatherRefresh(city: String) {
        if requestedWeatherCity != city {
            currentWeather = nil
            updateWeatherWarnings([])
            weatherUpdatedAt = nil
            requestedWeatherCity = city
        }
        weatherRefreshMessage = "正在更新"
    }

    func endWeatherRefresh(message: String) {
        weatherRefreshMessage = message
    }

    func previewAgentReplyMotion() {
        let prefix = AgentReplyMotionSettings.previewPrefix
        let preview = IslandActivity(id: prefix + UUID().uuidString, kind: "preview",
            title: "AirPods 头动测试", detail: "测试不会发送消息", symbol: "airpodspro",
            priority: 100, expires: Date().timeIntervalSince1970 + 90)
        publish(activities.filter { !$0.id.hasPrefix(prefix) } + [preview])
    }

    func previewCompactAlert(rain: Bool = false) {
        let prefix = rain ? "preview:rain:" : "preview:"
        publish(activities + [IslandActivity(id: prefix + UUID().uuidString, kind: "preview",
            title: rain ? "测试 · 暴雨橙色预警" : "测试提醒",
            detail: rain ? "这是一条模拟预警" : "这是普通灵动岛宽度的弹窗预览",
            symbol: rain ? "cloud.heavyrain" : "bell.badge",
            priority: 91, expires: Date().timeIntervalSince1970 + 45)])
    }

    func showCalendarAlert(id: String, title: String, date: Date) {
        let alert = IslandActivity(id: "agenda:" + id, kind: "calendar", title: title,
            detail: date.formatted(date: .omitted, time: .shortened), symbol: "calendar",
            priority: 70, expires: Date().timeIntervalSince1970 + 45)
        publish(activities.filter { $0.id != alert.id } + [alert])
    }

    private func recentlyPresentedWeatherWarnings(now: Double) -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: "seenNotchWeatherWarnings") as? [String: Double] ?? [:])
            .filter { $0.value > now - 6 * 3600 }
    }

    func updateWeatherWarnings(_ warnings: [IslandActivity], popupIDs: Set<String> = []) {
        let now = Date().timeIntervalSince1970
        let latest = warnings.filter { $0.expires > now }.sorted { $0.expires > $1.expires }
        if latestWeatherWarning != latest.first { latestWeatherWarning = latest.first }
        let warningIDs = Set(latest.map(\.id))
        let seen = recentlyPresentedWeatherWarnings(now: now)
        let retained = activities.filter {
            $0.kind != "weather-warning" || (warningIDs.contains($0.id) && seen[weatherReceiptKey($0.id)] == nil)
        }
        let retainedIDs = Set(retained.filter { $0.expires > now }.map(\.id))
        let additions = latest.compactMap { warning -> IslandActivity? in
            guard popupIDs.contains(warning.id),
                  seen[weatherReceiptKey(warning.id)] == nil,
                  !retainedIDs.contains(warning.id) else { return nil }
            var queued = warning
            queued.expires = min(warning.expires, now + 360)
            return queued
        }
        if retained != activities || !additions.isEmpty { publish(retained + additions) }
    }

    private func weatherReceiptKey(_ activityID: String) -> String {
        String(activityID.dropFirst("weather-warning:".count))
    }

    func consumeWeatherPopup(_ activityID: String) -> Bool {
        let now = Date().timeIntervalSince1970
        var seen = recentlyPresentedWeatherWarnings(now: now)
        let key = weatherReceiptKey(activityID)
        guard seen[key] == nil, activities.contains(where: {
            $0.id == activityID && $0.kind == "weather-warning" && $0.expires > now
        }) else { return false }
        seen[key] = now
        UserDefaults.standard.set(seen, forKey: "seenNotchWeatherWarnings")
        publish(activities.filter { $0.id != activityID })
        return true
    }

    func setWeather(city: String?, summary: String = "", symbol: String = "cloud") {
        guard let city else {
            currentWeather = nil
            updateWeatherWarnings([])
            weatherUpdatedAt = nil
            weatherRefreshMessage = nil
            requestedWeatherCity = nil
            return
        }
        let alert = IslandActivity(id: "weather:" + UUID().uuidString, kind: "weather", title: city,
            detail: summary, symbol: symbol, priority: 30, expires: Date().timeIntervalSince1970 + 20)
        currentWeather = alert
        weatherUpdatedAt = Date()
        weatherRefreshMessage = nil
    }
    var lastViewedAgentID: String?
    var resumableAgentDetailID: String? {
        agentSessions.first {
            $0.id == lastViewedAgentID
                && ["processing", "running_tool", "compacting"].contains($0.progress?.phase ?? "")
        }?.id
    }
    var runningAgent: IslandActivity? {
        activities.filter { $0.kind == "agent" && $0.progress?.islandPhase?.isTerminal == false }
            .max {
                let lhs = $0.progress
                let rhs = $1.progress
                return (lhs?.islandPhase?.attentionPriority ?? 0, lhs?.observedAt ?? 0)
                    < (rhs?.islandPhase?.attentionPriority ?? 0, rhs?.observedAt ?? 0)
            }
    }

    var agentSessions: [IslandActivity] {
        let current = activities.filter { $0.kind == "agent" && !$0.isCompletedAgentSession }
        let currentIDs = Set(current.map(\.id))
        return current + completedAgentSessions.filter { !currentIDs.contains($0.id) }
    }

    init(observeSystem: Bool = true, storageURL: URL? = nil) {
        observeDevices = observeSystem
        directory = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UnifiedActivities", isDirectory: true)
        if observeSystem || storageURL != nil {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: directory.appendingPathComponent("completed-agents.json")),
               let saved = try? JSONDecoder().decode([IslandActivity].self, from: data) {
                rememberCompletedAgents(saved)
            }
        }
        guard observeSystem else { return }
        // Warm artwork metadata once; later audio lookups refresh it.
        BluetoothInfo.warmArtworkCacheOnce()
        let fd = open(directory.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in self?.readBridge() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            watcher = source
        }
        agentObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.boringnotch.agent-state"), object: nil, queue: .main
        ) { [weak self] notification in
            guard let text = notification.object as? String, let data = text.data(using: .utf8) else { return }
            Task { @MainActor in self?.receiveAgents(data) }
        }
        readBridge()
        if let data = try? Data(contentsOf: directory.appendingPathComponent("agent-usage.json")) { receiveUsage(data) }
        usageObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.boringnotch.agent-usage"), object: nil, queue: .main
        ) { [weak self] notification in
            guard let text = notification.object as? String, let data = text.data(using: .utf8) else { return }
            Task { @MainActor in self?.receiveUsage(data) }
        }
        startAudioMonitoring()
        let monitor = AirPodsLidMonitor()
        monitor.onOpen = { [weak self] packet, name, identity in self?.announceLid(packet, name: name, identity: identity) }
        monitor.onWear = { [weak self] packet, name, identity in self?.announceWearing(packet, name: name, identity: identity) }
        monitor.onUpdate = { [weak self] packet, identity in self?.updateLid(packet, identity: identity) }
        monitor.onStatus = { [weak self] status in self?.lidDetectionStatus = status }
        lidMonitor = monitor
        monitor.setEnabled(lidDetectionEnabled)
    }

    private func publish(_ items: [IslandActivity]) {
        let now = Date().timeIntervalSince1970
        dismissed = dismissed.filter { $0.value > now }
        activities = items.filter { $0.expires > now && dismissed[$0.id] != $0.expires }.sorted {
            $0.priority == $1.priority ? $0.id < $1.id : $0.priority > $1.priority
        }
        if !activities.contains(where: { $0.id == selectedActivityID }) { selectedActivityID = nil }
        if !activities.contains(where: { $0.kind == "headphones" }) {
            headphoneAlert = nil
            proximityIdentity = nil
            recentWear = nil
            audioCueID = nil
        }
        expiry?.cancel()
        if let next = activities.map(\.expires).min() {
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0.1, next - now)))
                guard !Task.isCancelled, let self else { return }
                self.publish(self.activities)
            }
        }
    }

    private func readBridge() {
        let file = directory.appendingPathComponent("agents.json")
        guard let data = try? Data(contentsOf: file) else { return }
        receiveAgents(data)
    }

    private func receiveUsage(_ data: Data) {
        guard data.count < 65536 else { return }
        let decoder = JSONDecoder()
        let incoming: [AgentProviderUsage]
        if let providers = try? decoder.decode([AgentProviderUsage].self, from: data) {
            incoming = providers
        } else if let legacy = try? decoder.decode(AgentUsageSnapshot.self, from: data) {
            incoming = [legacy.provider]
        } else {
            return
        }
        var seen = Set<String>()
        let safe = incoming.prefix(32).filter { $0.isValid && seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard agentUsage != safe else { return }
        agentUsage = safe
        if let encoded = try? JSONEncoder().encode(safe) {
            try? encoded.write(to: directory.appendingPathComponent("agent-usage.json"), options: .atomic)
        }
    }

    private func receiveAgents(_ data: Data) {
        guard data.count < 131072,
              let incoming = try? JSONDecoder().decode([IslandActivity].self, from: data) else { return }
        bridgeAvailable = true
        let cached = directory.appendingPathComponent("agents.json")
        if (try? Data(contentsOf: cached)) != data { try? data.write(to: cached, options: .atomic) }
        // Only normalized agent metadata is accepted from the read-only helper.
        let valid = incoming.prefix(16).filter {
            $0.kind == "agent" && $0.title.count <= 80 && $0.detail.count <= 160 &&
            $0.expires.isFinite && $0.expires <= Date().timeIntervalSince1970 + 3600
        }.map { item -> IslandActivity in
            var result = item
            result.priority = min(90, max(10, item.priority))
            result.symbol = "terminal"
            result.sessionTitle = item.sessionTitle.map {
                String($0.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
            }
            if result.progress?.isValid != true { result.progress = nil }
            if item.source != "codex" || item.sessionID.flatMap(UUID.init(uuidString:)) == nil {
                result.sessionID = nil
            }
            if item.source.flatMap(AgentConversationSource.init(rawValue:)) == nil
                || item.conversationID.flatMap(UUID.init(uuidString:)) == nil {
                result.conversationID = nil
            }
            return result
        }
        rememberCompletedAgents(valid)
        publish(activities.filter { $0.kind != "agent" } + valid)
    }

    private func rememberCompletedAgents(_ incoming: [IslandActivity]) {
        var sessions = Dictionary(uniqueKeysWithValues: completedAgentSessions.map { ($0.id, $0) })
        for item in incoming where item.isCompletedAgentSession && item.progress?.isValid == true {
            if let previous = sessions[item.id],
               (previous.progress?.observedAt ?? 0) > (item.progress?.observedAt ?? 0) { continue }
            sessions[item.id] = item
        }
        let latest = Array(sessions.values.sorted {
            let left = $0.progress?.observedAt ?? 0
            let right = $1.progress?.observedAt ?? 0
            return left == right ? $0.id < $1.id : left > right
        }.prefix(3))
        guard latest != completedAgentSessions else { return }
        completedAgentSessions = latest
        let file = directory.appendingPathComponent("completed-agents.json")
        if let data = try? JSONEncoder().encode(latest) { try? data.write(to: file, options: .atomic) }
    }

    func announceAirDrop(success: Bool) {
        publish(activities.filter { $0.id != "airdrop" } + [IslandActivity(
            id: "airdrop", kind: "airdrop", title: success ? "已发送" : "未送达",
            detail: success ? "AirDrop 已发送" : "AirDrop 未送达",
            symbol: "airdrop", priority: 55, expires: Date().timeIntervalSince1970 + 7
        )])
    }

    func dismiss(_ id: String) {
        if let item = activities.first(where: { $0.id == id }) { dismissed[id] = item.expires }
        publish(activities.filter { $0.id != id })
    }

    private func startAudioMonitoring() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.outputChanged() }
        }
        audioListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        outputChanged(showCue: false)
    }
    private func currentOutput() -> AudioDeviceID {
        var result: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &result)
        return result
    }
    private func outputChanged(showCue: Bool = true) {
        let device = currentOutput()
        guard device != lastOutput else { return }
        lastOutput = device
        guard device != 0 else { audioOutputEnded(); return }
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { audioOutputEnded(); return }
        guard [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport) else {
            audioOutputEnded(); return
        }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { audioOutputEnded(); return }
        let deviceName = name.takeRetainedValue() as String
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        let raw = status == noErr ? uid?.takeRetainedValue() as String? : nil
        let bluetoothAddress = BluetoothInfo.address(fromAudioUID: raw)
        announceHeadphones(name: deviceName, address: bluetoothAddress, showCue: showCue)
    }

    func audioOutputEnded() {
        // Routing away is not proof that a nearby case closed. Clear only the audio cue.
        if let id = audioCueID, headphoneAlert?.id == id { dismiss("headphones") }
        audioCueID = nil
        headphoneLookup?.cancel()
        headphoneLookup = nil
        audioDeviceAddress = nil
        audioDeviceSnapshot = nil
        lastHeadphoneName = ""
        lastHeadphoneNotice = .distantPast
    }

    func announceLid(_ packet: AirPodsProximity, name: String?, identity: UUID? = nil) {
        if let identity, let recentWear, recentWear.identity == identity,
           recentWear.counter == packet.lidCounter, headphoneAlert?.isWearing == true,
           headphoneAlert?.isPreview == false { return }
        recentWear = nil
        let title = String((name?.isEmpty == false ? name! : packet.modelName).prefix(80))
        publish(activities.filter { $0.id != "headphones" } + [IslandActivity(
            id: "headphones", kind: "headphones", title: title, detail: "附近耳机 · 充电盒已打开",
            symbol: "airpodspro", priority: 75, expires: Date().timeIntervalSince1970 + 6)])
        let alert = DeviceAlert(symbol: packet.modelName.contains("Pro") ? "airpodspro" : "airpods",
            name: title, productID: packet.productID, battery: [packet.left, packet.right].compactMap { $0 }.min(),
            leftBattery: packet.left, rightBattery: packet.right, caseBattery: packet.caseLevel,
            leftCharging: packet.leftCharging, rightCharging: packet.rightCharging, caseCharging: packet.caseCharging,
            status: "附近 · 充电盒已打开", approximateBattery: true,
            spin: ProductSpin.url(productID: packet.productID),
            caseSpin: ProductSpin.url(productID: packet.productID, caseArtwork: true))
        headphoneAlert = alert
        proximityIdentity = identity
    }

    func announceWearing(_ packet: AirPodsProximity, name: String?, identity: UUID? = nil, preview: Bool = false) {
        let title = String((name?.isEmpty == false ? name! : packet.modelName).prefix(80))
        publish(activities.filter { $0.id != "headphones" } + [IslandActivity(
            id: "headphones", kind: "headphones", title: title, detail: preview ? "佩戴动画预览 · 模拟数据" : "检测到耳机佩戴",
            symbol: "airpodspro", priority: 75, expires: Date().timeIntervalSince1970 + 5)])
        if !preview, var connected = audioDeviceSnapshot, connected.name == title,
           connected.productID == nil || connected.productID == packet.productID {
            connected.symbol = packet.modelName.contains("Pro") ? "airpodspro" : "airpods"
            connected.productID = packet.productID
            connected.spin = ProductSpin.url(productID: packet.productID) ?? connected.spin
            connected.leftBattery = connected.leftBattery ?? packet.left
            connected.rightBattery = connected.rightBattery ?? packet.right
            connected.caseBattery = connected.caseBattery ?? packet.caseLevel
            if connected.battery == nil {
                connected.battery = [packet.left, packet.right].compactMap { $0 }.min()
                connected.approximateBattery = true
            }
            connected.isWearing = true
            audioDeviceSnapshot = connected
            headphoneAlert = connected
            audioCueID = connected.id
        } else {
            headphoneAlert = DeviceAlert(symbol: packet.modelName.contains("Pro") ? "airpodspro" : "airpods",
                name: title, productID: packet.productID, battery: [packet.left, packet.right].compactMap { $0 }.min(),
                leftBattery: packet.left, rightBattery: packet.right, caseBattery: packet.caseLevel,
                status: preview ? "佩戴动画预览 · 模拟数据" : "检测到耳机佩戴", approximateBattery: true,
                spin: ProductSpin.url(productID: packet.productID), isBanner: false, isWearing: true, isPreview: preview)
        }
        proximityIdentity = identity
        recentWear = preview ? nil : identity.map { ($0, packet.lidCounter) }
    }

    func previewHeadphones(wearing: Bool) {
        let packet = AirPodsProximity(productID: 0x2014, left: 80, right: 80, caseLevel: 60,
                                     lidOpen: !wearing, lidCounter: 0, leftInEar: wearing, rightInEar: wearing)
        if wearing { announceWearing(packet, name: "AirPods Pro · 预览", preview: true) }
        else {
            announceLid(packet, name: "AirPods Pro · 预览")
            headphoneAlert?.isPreview = true
            headphoneAlert?.status = "开盖动画预览 · 模拟数据"
        }
    }

    /// Update the existing card without changing its UUID or extending its lifetime.
    func updateLid(_ packet: AirPodsProximity, identity: UUID) {
        guard proximityIdentity == identity, var alert = headphoneAlert, alert.approximateBattery else { return }
        if alert.isWearing { return }
        if packet.lidOpen == false { dismiss("headphones"); return }
        guard packet.lidOpen == true else { return }
        alert.leftBattery = packet.left
        alert.rightBattery = packet.right
        alert.caseBattery = packet.caseLevel
        alert.battery = [packet.left, packet.right].compactMap { $0 }.min()
        alert.leftCharging = packet.leftCharging
        alert.rightCharging = packet.rightCharging
        alert.caseCharging = packet.caseCharging
        if headphoneAlert != alert { headphoneAlert = alert }
    }

    func announceHeadphones(name: String, address: String? = nil, showCue: Bool = true) {
        let title = String(name.prefix(80))
        let sameAddress = BluetoothInfo.normalizedAddress(address) == BluetoothInfo.normalizedAddress(audioDeviceAddress)
        guard title != lastHeadphoneName || !sameAddress || Date().timeIntervalSince(lastHeadphoneNotice) > 10 else { return }
        lastHeadphoneName = title
        lastHeadphoneNotice = Date()
        let cached = BluetoothArtworkCache.shared.match(address: address, name: title)
        let knownSymbol = cached?.productID.flatMap { BluetoothInfo.symbol(forProductID: $0) }
            ?? BluetoothInfo.symbol(named: title)
        let cachedSpin = cached?.spin

        // Convert the matching wear cue in place. Audio routing never creates an open-case card.
        let previous: DeviceAlert? = showCue ? headphoneAlert.flatMap {
            guard $0.isWearing, !$0.isPreview, $0.name == title,
                  $0.id != audioDeviceSnapshot?.id || sameAddress,
                  cached?.productID == nil || $0.productID == cached?.productID else { return nil }
            return $0
        } : nil
        var alert = previous ?? DeviceAlert(symbol: knownSymbol, name: title, productID: cached?.productID,
                    awaitingBattery: observeDevices, artworkLoading: observeDevices && cachedSpin == nil,
                    spin: cachedSpin, caseSpin: cached?.productID.flatMap { ProductSpin.url(productID: $0, caseArtwork: true) },
                    isBanner: false)
        alert.status = "已连接"
        audioDeviceAddress = address
        audioDeviceSnapshot = alert
        audioCueID = nil
        if showCue {
            if previous == nil { proximityIdentity = nil }
            publish(activities.filter { $0.id != "headphones" } + [IslandActivity(
                id: "headphones", kind: "headphones", title: title, detail: "已连接 · 正在用于音频输出",
                symbol: alert.symbol, priority: 75, expires: Date().timeIntervalSince1970 + 6)])
            headphoneAlert = alert
            audioCueID = alert.id
        }
        startHeadphoneLookup(retry: true)
    }

    func refreshConnectedAirPods() {
        guard connectedAirPods != nil, headphoneLookup == nil,
              Date().timeIntervalSince(audioLookupStartedAt) >= 12 else { return }
        startHeadphoneLookup(retry: false)
    }

    private func startHeadphoneLookup(retry: Bool) {
        headphoneLookup?.cancel()
        guard observeDevices, let alert = audioDeviceSnapshot else { headphoneLookup = nil; return }
        let address = audioDeviceAddress
        audioLookupStartedAt = Date()
        headphoneLookup = Task { [weak self] in
            for attempt in 0..<(retry ? 2 : 1) {
                if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                guard !Task.isCancelled, let self, self.audioDeviceSnapshot?.id == alert.id else { return }
                let result: (BluetoothInfo.Device?, URL?) = await withCheckedContinuation { continuation in
                    BluetoothInfo.lookup(address: address, name: alert.name) { continuation.resume(returning: ($0, $1)) }
                }
                guard !Task.isCancelled, self.audioDeviceSnapshot?.id == alert.id else { return }
                self.applyHeadphoneLookup(result.0, spin: result.1, cueID: alert.id)
                if self.audioDeviceSnapshot?.battery != nil && self.audioDeviceSnapshot?.spin != nil { break }
            }
            guard !Task.isCancelled, let self, self.finishHeadphoneLookup(cueID: alert.id) else { return }
            self.headphoneLookup = nil
        }
    }

    /// The audio snapshot outlives the cue. A result updates the cue only if it still matches.
    @discardableResult
    func applyHeadphoneLookup(_ device: BluetoothInfo.Device?, spin: URL?, cueID: UUID) -> Bool {
        guard var report = audioDeviceSnapshot, report.id == cueID else { return false }
        if let device {
            if let product = device.productID {
                report.productID = product
                if let corrected = BluetoothInfo.symbol(forProductID: product) { report.symbol = corrected }
                report.caseSpin = ProductSpin.url(productID: product, caseArtwork: true)
            }
            if let value = device.level {
                report.battery = value
                report.approximateBattery = false
            }
            if let value = device.left { report.leftBattery = value }
            if let value = device.right { report.rightBattery = value }
            if let value = device.caseLevel { report.caseBattery = value }
        }
        if let spin { report.spin = spin }
        updateAudioSnapshot(report)
        return true
    }

    @discardableResult
    func finishHeadphoneLookup(cueID: UUID) -> Bool {
        guard var report = audioDeviceSnapshot, report.id == cueID else { return false }
        report.awaitingBattery = false
        report.artworkLoading = false
        updateAudioSnapshot(report)
        return true
    }

    private func updateAudioSnapshot(_ report: DeviceAlert) {
        if audioDeviceSnapshot != report { audioDeviceSnapshot = report }
        if headphoneAlert?.id == report.id, headphoneAlert != report { headphoneAlert = report }
    }

}

private enum AgentActivityFilter: String, CaseIterable, Identifiable {
    case all = "全部", attention = "待处理", running = "运行中"
    var id: String { rawValue }
    func includes(_ activity: IslandActivity) -> Bool {
        guard activity.kind == "agent" else { return false }
        switch self {
        case .all: return true
        case .attention: return activity.priority >= 85
        case .running: return activity.priority < 50
        }
    }
    var emptyMessage: String {
        switch self {
        case .all: return "暂无活动提醒"
        case .attention: return "没有需要处理的提醒"
        case .running: return "暂无正在运行的会话"
        }
    }
}

/// Compact viewport inside Boring Notch’s existing page geometry.
struct NotchWingActivityView: View {
    let activity: IslandActivity
    let headphone: DeviceAlert?
    let centerWidth: CGFloat
    let height: CGFloat
    let reveal: CGFloat
    let open: () -> Void
    private var action: String { activity.kind == "agent" ? activity.agentCurrentAction : activity.detail }
    private var name: String { activity.title.components(separatedBy: " · ").first ?? "Agent" }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                Group {
                    if activity.kind == "headphones", let headphone {
                        DeviceArt(alert: headphone, size: 27)
                    } else {
                        ActivityAvatar(activity: activity, size: 18)
                    }
                }
                    .accessibilityHidden(true)
                    .frame(width: SystemIslandHoverGeometry.agentWingWidth, height: height)
                    .modifier(NotchWingVisibility(progress: reveal, side: -1))
                    .clipped()
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("展开 \(name)")
            .accessibilityIdentifier("agent-island-left-wing")
            Group {
                Color.clear.frame(width: centerWidth, height: height).allowsHitTesting(false)
                Button(action: open) {
                    Group {
                        if activity.kind == "headphones", let headphone {
                            HeadphoneBatteryRing(level: headphone.battery, size: 18, showsValue: false)
                        } else if activity.isGeneratingAgentReply {
                            AgentReplyGenerationSparkle()
                        } else if activity.kind == "agent", let phase = activity.progress?.islandPhase {
                            if phase == .processing {
                                AgentNotchProcessingSpinner(color: phase.tint)
                            } else {
                                Image(systemName: phase.symbol)
                                    .foregroundStyle(phase.tint)
                            }
                        } else {
                            Image(systemName: "chevron.down").foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
                        .frame(width: SystemIslandHoverGeometry.agentWingWidth, height: height)
                        .modifier(NotchWingVisibility(progress: reveal, side: 1))
                        .clipped()
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("\(action)，展开详情")
                .accessibilityIdentifier("agent-island-right-wing")
            }
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .help("\(name) · \(action)")
        .accessibilityElement(children: .contain)
    }
}

enum AgentSessionListMetrics {
    static let rowHeight: CGFloat = 37
    static let compactCount = 2
    static let expandedCount = 4
    static let headingHeight: CGFloat = 18
    static let listInset: CGFloat = 2

    static func height(for rowCount: Int) -> CGFloat {
        headingHeight + listInset * 2 + CGFloat(rowCount) * rowHeight
    }

    static func extraHeight(for count: Int) -> CGFloat {
        CGFloat(max(0, min(count, expandedCount) - compactCount)) * rowHeight
    }
}

private struct AgentSessionsPage: View {
    @Binding var selectedID: String?
    var viewportHeight: CGFloat
    let listHeightChanged: (CGFloat) -> Void
    @ObservedObject private var hub = UnifiedActivities.shared
    @State private var listExpanded = false
    private var sessions: [IslandActivity] { hub.agentSessions }

    // Agent Notch SessionListMetrics / ClaudeInstancesView (Apache-2.0).
    private let rowHeight = AgentSessionListMetrics.rowHeight
    private let headingHeight = AgentSessionListMetrics.headingHeight
    private let listInset = AgentSessionListMetrics.listInset

    var body: some View {
        Group {
            if let selected = sessions.first(where: { $0.id == selectedID }) {
                detailsPage(selected)
            } else if sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("任务会在这里出现").font(.system(size: 14, weight: .semibold))
                    Text("在已连接的 Agent 中开始一段会话。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).frame(height: 66)
                .overlay(alignment: .topTrailing) { AgentUsageSummary(hub: hub).padding(.trailing, 12) }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 7) {
                        Text("任务").font(.system(size: 13, weight: .semibold))
                        Text("\(sessions.count)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        AgentUsageSummary(hub: hub)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: headingHeight)
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(sessions) { item in
                                AgentNotchTaskRow(
                                    item: item, name: agentName(item), title: sessionName(item),
                                    activity: currentAction(item, fallback: fallbackStatus(item)),
                                    rowHeight: rowHeight
                                ) { open(item.id) }
                                .id(item.id)
                            }
                        }
                        .padding(.vertical, listInset)
                    }
                    .scrollDisabled(!listExpanded)
                    .scrollIndicators(.never)
                    .scrollBounceBehavior(.basedOnSize)
                    // AppKit reports negative vertical deltas when scrolling toward later rows.
                    .panGesture(direction: .up, threshold: 12, isEnabled: { canExpandList }) { _, phase in
                        if phase == .began || phase == .changed { expandList() }
                    }
                    .accessibilityAction(named: "显示更多会话") { expandList() }
                }
                .frame(height: min(viewportHeight, AgentSessionListMetrics.height(for: visibleRowCount)))
            }
        }
        .onChange(of: sessions.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
            if listExpanded { listHeightChanged(AgentSessionListMetrics.extraHeight(for: ids.count)) }
        }
    }

    private var visibleRowCount: Int {
        min(sessions.count, listExpanded ? AgentSessionListMetrics.expandedCount : AgentSessionListMetrics.compactCount)
    }

    private var canExpandList: Bool {
        selectedID == nil && !listExpanded && sessions.count > AgentSessionListMetrics.compactCount
    }

    private func expandList() {
        guard canExpandList else { return }
        listExpanded = true
        listHeightChanged(AgentSessionListMetrics.extraHeight(for: sessions.count))
    }

    private func open(_ id: String?) {
        selectedID = id
    }

    private func agentName(_ item: IslandActivity) -> String {
        item.title.components(separatedBy: " · ").first ?? "Agent"
    }

    private func projectName(_ item: IslandActivity) -> String {
        item.detail.components(separatedBy: " · ").first ?? ""
    }

    private func sessionName(_ item: IslandActivity) -> String {
        let project = projectName(item)
        return item.sessionTitle.flatMap { $0.isEmpty ? nil : $0 }
            ?? (project.isEmpty || project == "本地会话" ? agentName(item) : project)
    }

    private func fallbackStatus(_ item: IslandActivity) -> String {
        item.title.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
    }

    private func detailsPage(_ item: IslandActivity) -> some View {
        let title = sessionName(item)
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { open(nil) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary).frame(width: 20, height: 20)
                        AgentNotchBadge(activity: item, name: agentName(item))
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回任务列表")
                .accessibilityIdentifier("agent-back-to-tasks")

                if item.progress?.phase == "waiting_for_approval" {
                    Button {
                        AgentApplicationIcons.open(activity: item)
                    } label: {
                        Label("待审批 · 在原会话处理", systemImage: "hand.raised.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(AgentNotchTaskButtonStyle())
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 2)
            if let source = item.source.flatMap(AgentConversationSource.init(rawValue:)),
               let id = (item.conversationID ?? item.sessionID).flatMap(UUID.init(uuidString:)) {
                AgentConversationSection(source: source, sessionID: id, updatedAt: item.progress?.observedAt,
                                         viewportHeight: max(38, viewportHeight - 31))
                    .id(item.id)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            } else {
                Text("暂无可读取的对话")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
        .accessibilityIdentifier("agent-session-detail")
    }

    private func currentAction(_ item: IslandActivity, fallback: String) -> String { item.agentCurrentAction }

}

/// InstanceRow and TaskRowButtonStyle from Agent Notch, adapted to IslandActivity.
private struct AgentNotchTaskRow: View {
    let item: IslandActivity
    let name: String
    let title: String
    let activity: String
    let rowHeight: CGFloat
    let openDetails: () -> Void
    @State private var isHovered = false

    private var phase: String { item.progress?.phase ?? "" }
    private var working: Bool { ["processing", "running_tool", "compacting"].contains(phase) }
    private var waiting: Bool { ["waiting_for_input", "waiting_for_approval"].contains(phase) }
    private var accent: Color { item.source == "claude" ? Color(red: 0.85, green: 0.47, blue: 0.34) : .primary }
    private var status: String {
        switch phase {
        case "processing", "running_tool": "工作中"
        case "compacting": "整理上下文"
        case "waiting_for_approval": "待审批"
        case "waiting_for_input": "等待输入"
        case "finished": "已完成"
        case "failed": "失败"
        default: "空闲"
        }
    }
    private var statusSymbol: String {
        switch phase {
        case "waiting_for_approval": "hand.raised"
        case "waiting_for_input": "bubble.left"
        case "finished": "checkmark.circle"
        case "failed": "exclamationmark.circle"
        default: "circle.dotted"
        }
    }
    private var statusColor: Color {
        waiting ? .orange : phase == "finished" ? .green : phase == "failed" ? .red : .secondary
    }

    var body: some View {
        Button(action: openDetails) {
            HStack(spacing: 9) {
                ActivityAvatar(activity: item, size: 18).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        statusLabel.fixedSize()
                    }
                    Text(activity).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name)：\(title)")
        .accessibilityValue("\(status)，\(activity)")
        .accessibilityIdentifier("agent-session-summary")
        .background {
            RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(isHovered ? 0.07 : 0))
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.primary.opacity(0.12)).frame(height: 0.5)
                .padding(.horizontal, 12).allowsHitTesting(false)
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
    }

    private var statusLabel: some View {
        HStack(spacing: 5) {
            if working {
                AgentNotchProcessingSpinner(color: accent).frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: statusSymbol).font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(status).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(statusColor)
        .accessibilityElement(children: .combine)
    }
}

/// AgentBadge's original sizing, tint and capsule treatment.
private struct AgentNotchBadge: View {
    let activity: IslandActivity
    let name: String

    private var accent: Color {
        activity.source == "claude" ? Color(red: 0.85, green: 0.47, blue: 0.34) : .primary
    }

    var body: some View {
        HStack(spacing: 3) {
            if let icon = activity.source.flatMap({ AgentApplicationIcons.icon(for: $0) }) {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 9, height: 9)
            } else {
                Image(systemName: "terminal").font(.system(size: 8, weight: .bold))
            }
            Text(name).font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(accent.opacity(0.14), in: Capsule())
        .overlay { Capsule().strokeBorder(accent.opacity(0.28), lineWidth: 0.5) }
        .accessibilityLabel("\(name) 会话")
    }
}

private struct AgentNotchTaskButtonStyle: ButtonStyle {
    @State private var isHovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.primary.opacity(configuration.isPressed ? 0.22 : (isHovered ? 0.17 : 0.09)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { isHovered = $0 }
    }
}

// Agent Notch ProcessingSpinner's symbol and timing sequence.
private struct AgentReplyGenerationSparkle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { context in
            let pulse = reduceMotion ? 1.0 : (sin(context.date.timeIntervalSinceReferenceDate * 5) + 1) / 2
            Image(systemName: "sparkles")
                .foregroundStyle(.white.opacity(0.65 + 0.35 * pulse))
                .scaleEffect(0.91 + 0.14 * pulse)
        }
    }
}

private struct AgentNotchProcessingSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    private let symbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let frameInterval = 0.15

    var body: some View {
        if reduceMotion { symbol(1) }
        else {
            TimelineView(.periodic(from: .now, by: frameInterval)) { context in
                symbol(Int(context.date.timeIntervalSinceReferenceDate / frameInterval) % symbols.count)
            }
        }
    }

    private func symbol(_ phase: Int) -> some View {
        Text(symbols[phase]).font(.system(size: 12, weight: .bold))
            .foregroundStyle(color).frame(width: 12, alignment: .center)
    }
}

/// A nonactivating notch panel only becomes key after a click in this field.
private struct AgentReplyField: NSViewRepresentable {
    @Binding var text: String
    var canSubmit: Bool
    var submit: () -> Void
    var voiceFocus: UUID?
    var voiceReady: () -> Void


    final class Input: NSTextField {
        weak var editingPanel: BoringNotchSkyLightWindow?

        var pendingVoiceFocus: UUID?
        var deliveredVoiceFocus: UUID?
        var voiceReady: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleVoiceFocus()
        }

        func scheduleVoiceFocus() {
            guard let id = pendingVoiceFocus, deliveredVoiceFocus != id, window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingVoiceFocus == id, self.deliveredVoiceFocus != id,
                      let panel = self.window as? BoringNotchSkyLightWindow,
                      panel.beginAgentReplyEditing(self) else { return }
                self.deliveredVoiceFocus = id
                self.editingPanel = panel
                if let editor = self.currentEditor() as? NSTextView, !editor.hasMarkedText() {
                    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                }
                self.voiceReady?()
            }
        }

        override var needsPanelToBecomeKey: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if let panel = window as? BoringNotchSkyLightWindow {
                guard panel.beginAgentReplyEditing(self) else { return }
                editingPanel = panel
            }
            super.mouseDown(with: event)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var field: AgentReplyField
        init(_ field: AgentReplyField) { self.field = field }

        func controlTextDidChange(_ notification: Notification) {
            guard let input = notification.object as? NSTextField,
                  (input.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            field.text = (input.currentEditor() as? NSTextView)?.string ?? input.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let input = notification.object as? Input else { return }
            let panel = input.window as? BoringNotchSkyLightWindow
            Task { @MainActor [weak input, weak panel] in
                if let input { panel?.endAgentReplyEditing(input) }
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard let input = control as? Input, !textView.hasMarkedText() else { return false }
            if command == #selector(NSResponder.insertNewline(_:)) {
                if field.canSubmit {
                    field.text = textView.string
                    field.submit()
                    (input.window as? BoringNotchSkyLightWindow)?.endAgentReplyEditing(input)
                }
                return true
            }
            if command == #selector(NSResponder.cancelOperation(_:)) {
                (input.window as? BoringNotchSkyLightWindow)?.endAgentReplyEditing(input)
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Input {
        let input = Input()
        input.delegate = context.coordinator
        input.appearance = NSAppearance(named: .darkAqua)
        input.font = .systemFont(ofSize: 12)
        input.isBordered = false
        input.isBezeled = false
        input.focusRingType = .none
        input.drawsBackground = false
        input.usesSingleLineMode = true
        input.placeholderString = "回复当前会话…"
        input.setAccessibilityIdentifier("agent-reply-input")
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return input
    }

    func updateNSView(_ input: Input, context: Context) {
        context.coordinator.field = self
        input.pendingVoiceFocus = voiceFocus
        input.voiceReady = voiceReady
        input.scheduleVoiceFocus()
        guard input.stringValue != text,
              (input.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        input.stringValue = text
        if let editor = input.currentEditor() as? NSTextView, editor.string != text {
            editor.string = text
        }
    }

    static func dismantleNSView(_ input: Input, coordinator: Coordinator) {
        let panel = input.editingPanel ?? input.window as? BoringNotchSkyLightWindow
        Task { @MainActor [weak panel] in panel?.endAgentReplyEditing(input) }
    }
}

@MainActor
private struct AgentConversationSection: View {
    let source: AgentConversationSource
    let sessionID: UUID
    let updatedAt: Double?
    @ObservedObject private var interaction = AgentInteraction.shared
    @AppStorage(AgentSuggestionAPI.enabledKey) private var useSuggestionAPI = false
    @AppStorage("agentConversationRoot.codex") private var codexRoot: Data?
    @AppStorage("agentConversationRoot.gemini") private var geminiRoot: Data?
    @AppStorage("agentConversationRoot.antigravity") private var antigravityRoot: Data?
    @AppStorage("agentConversationRoot.claude") private var claudeRoot: Data?
    @State private var messages: [AgentConversationMessage] = []
    @State private var cursor: UInt64?
    @State private var isLoading = true
    @State private var showingOlder = false
    @State private var message: String?
    @State private var fileHint: URL?
    @State private var activeRequest = UUID()
    @EnvironmentObject private var vm: BoringViewModel
    @StateObject private var voice = AgentVoiceReply()
    @AppStorage(AgentVoiceEngine.preferenceKey) private var voiceEngine = AgentVoiceEngine.onDevice
    @State private var draft = ""

    private var bookmark: Data? {
        switch source {
        case .codex: codexRoot
        case .claude: claudeRoot
        case .gemini: geminiRoot
        case .antigravity: antigravityRoot
        }
    }
    private struct Refresh: Equatable {
        var bookmark: Data?
        var updatedAt: Double?
    }

    var viewportHeight: CGFloat
    @State private var contentHeight: CGFloat = 44
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var baseMessageViewportHeight: CGFloat {
        let controls: CGFloat = !source.supportsQuickReplies ? 0 : (interaction.state(sessionID).status == nil ? 63 : 78)
        return max(18, min(viewportHeight - controls, contentHeight))
    }

    private var glassUnderlap: CGFloat {
        source.supportsQuickReplies && !reduceTransparency && contentHeight > baseMessageViewportHeight ? 36 : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: glassUnderlap > 0 ? -glassUnderlap : 3) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        conversationContent
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                geometry.size.height
                            } action: { height in
                                contentHeight = height
                            }
                        // Start with a little of the last line behind the first
                        // control row. The remaining inset lets it scroll clear.
                        let restingInset = min(15, glassUnderlap)
                        Color.clear.frame(height: 1 + restingInset).id("agent-conversation-end")
                        Color.clear.frame(height: glassUnderlap - restingInset)
                    }
                }
                .frame(height: baseMessageViewportHeight + glassUnderlap)
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .mask(alignment: .bottom) {
                    VStack(spacing: 0) {
                        Rectangle()
                        if glassUnderlap > 0 {
                            LinearGradient(colors: [.black, .black.opacity(0.42)], startPoint: .top, endPoint: .bottom)
                                .frame(height: glassUnderlap)
                        }
                    }
                }
                .onChange(of: messages.last?.id) { _, _ in
                    if !showingOlder { proxy.scrollTo("agent-conversation-end", anchor: .bottom) }
                }
                .onChange(of: glassUnderlap) { old, new in
                    if old == 0, new > 0, !showingOlder, !messages.isEmpty {
                        proxy.scrollTo("agent-conversation-end", anchor: .bottom)
                    }
                }
            }
            if source.supportsQuickReplies {
                quickReplies
                    .background(alignment: .top) {
                        if glassUnderlap > 0 { conversationControlGlass }
                    }
                    .layoutPriority(1)
                    .zIndex(1)
            }
        }
        .onAppear { draft = interaction.draft(for: sessionID) }
        .onChange(of: voice.isActive) { _, active in vm.isAgentVoiceReplyActive = active }
        .onChange(of: vm.isAgentReplyEditing) { _, editing in
            if !editing, voice.hasStartedRecording || voiceEngine == .doubao { voice.cancel() }
        }
        .onDisappear {
            voice.cancel()
            vm.isAgentVoiceReplyActive = false
            if vm.agentVoiceFocus?.sessionID == sessionID { vm.agentVoiceFocus = nil }
        }
        .onChange(of: interaction.state(sessionID).sending) { _, sending in
            if !sending {
                draft = interaction.draft(for: sessionID)
                if !showingOlder { Task { await load(before: nil) } }
            }
        }
        .task(id: Refresh(bookmark: bookmark, updatedAt: updatedAt)) {
            guard !showingOlder else { return }
            // Coalesce the burst of session updates for successive tool calls.
            if !messages.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            await load(before: nil)
        }
    }

    private var conversationControlGlass: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .opacity(0.28)
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.28)], startPoint: .top, endPoint: .bottom)
            }
            .frame(height: glassUnderlap)
            .mask {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.82), location: 0.22),
                    .init(color: .black, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var quickReplies: some View {
        let state = interaction.state(sessionID)
        return VStack(alignment: .leading, spacing: 5) {
            if !state.detailReplyOptions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(state.detailReplyOptions, id: \.body) { reply in
                            Button {
                                interaction.send(reply.body, source: source.rawValue, id: sessionID)
                            } label: {
                                Text(reply.title).lineLimit(1).frame(maxWidth: 240, alignment: .leading)
                            }
                            .buttonStyle(AgentNotchTaskButtonStyle())
                            .disabled(state.sending)
                            .help(reply.body)
                        }
                    }
                }.frame(height: 28).scrollIndicators(.never)
            } else {
                Button {
                    interaction.generate(source: source.rawValue, id: sessionID, messages: messages)
                } label: {
                    HStack(spacing: 5) {
                        if state.generating { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "sparkles") }
                        Text(state.generating ? "正在生成回复…" : useSuggestionAPI ? "生成 API 建议" : "让 \(source.appName) 建议回复")
                    }
                }
                .buttonStyle(AgentNotchTaskButtonStyle())
                .disabled(messages.isEmpty || state.generating || state.sending)
                .help(useSuggestionAPI ? "使用设置中选定的 API，根据最近对话生成建议" : "根据最近对话生成回复，使用现有 Agent 账号的模型额度")
                .accessibilityIdentifier("agent-generate-replies")
            }
            HStack(spacing: 5) {
                AgentReplyField(
                    text: Binding(get: { draft }, set: { value in
                        draft = String(value.prefix(8000))
                        interaction.setDraft(draft, for: sessionID)
                    }),
                    canSubmit: !state.sending && !voice.isActive,
                    submit: sendDraft,
                    voiceFocus: vm.agentVoiceFocus?.sessionID == sessionID ? vm.agentVoiceFocus?.id : nil,
                    voiceReady: startVoiceReply
                )
                Button {
                    vm.agentVoiceFocus = AgentVoiceFocus(sessionID: sessionID)
                } label: {
                    Image(systemName: voice.isActive ? "stop.fill" : "mic")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 23)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NotchControlStyle())
                .disabled(state.sending)
                .help(voice.isActive ? "结束听写" : "语音回复")
                .accessibilityLabel(voice.isActive ? "结束听写" : "语音回复")
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 25, height: 23)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(state.sending || voice.isActive || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("发送到\(source.appName)")
            }
            .padding(.leading, 8).padding(.trailing, 3)
            .frame(height: 28)
            .background(.white.opacity(0.075), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            if let status = voice.status {
                Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).help(status)
            }
            if let status = state.status {
                HStack(spacing: 8) {
                    Text(status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(status)
                    if let text = state.unsentReply {
                        Button(source == .codex ? "复制并打开会话" : "复制引导语") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            interaction.dismissUnsent(sessionID)
                            if source == .codex, let url = URL(string: "codex://threads/\(sessionID.uuidString.lowercased())") {
                                NSWorkspace.shared.open(url)
                            }
                        }.buttonStyle(.plain).font(.caption)
                    }
                }
            }
        }
        .accessibilityIdentifier("agent-quick-replies")
    }

    private func startVoiceReply() {
        guard !interaction.state(sessionID).sending else { return }
        let base = draft
        var last = base
        voice.toggle(engine: voiceEngine) { sample in
            guard draft == last else { return false }
            let separator = base.isEmpty || base.last?.isWhitespace == true ? "" : " "
            last = String((base + separator + sample).prefix(8000))
            draft = last
            interaction.setDraft(last, for: sessionID)
            return true
        }
    }

    private func sendDraft() {
        interaction.sendDraft(source: source.rawValue, id: sessionID)
    }

    private var conversationContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if cursor != nil {
                Button("加载更早的消息") {
                    guard let cursor else { return }
                    showingOlder = true
                    Task { await load(before: cursor) }
                }
                .buttonStyle(.plain).font(.caption)
                .disabled(isLoading)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("选择会话记录目录…", action: chooseFolder)
                    .buttonStyle(.plain).font(.caption)
            } else if messages.isEmpty && !isLoading {
                Text("等待回复…").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(messages) { entry in
                if entry.role == "user" {
                    HStack {
                        Spacer(minLength: 24)
                        messageText(entry)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.primary.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                    }
                } else {
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill((source == .claude
                            ? Color(red: 0.85, green: 0.47, blue: 0.34) : .primary).opacity(0.9))
                            .frame(width: 6, height: 6).padding(.top, 5).accessibilityHidden(true)
                        messageText(entry).foregroundStyle(.primary.opacity(0.9))
                        Spacer(minLength: 24)
                    }
                }
            }
            if isLoading && messages.isEmpty { ProgressView().controlSize(.small) }
            if showingOlder {
                Button("返回最新消息") {
                    showingOlder = false
                    Task { await load(before: nil) }
                }
                .buttonStyle(.plain).font(.caption)
                .disabled(isLoading)
            }
        }
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func messageText(_ entry: AgentConversationMessage) -> some View {
        Text(verbatim: entry.text)
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityIdentifier("agent-conversation-message")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "选择 \(source.appName) 的会话日志目录。仅在展开会话时读取对应记录。"
        panel.directoryURL = source.defaultDirectory
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do {
            let data = try selected.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
            activeRequest = UUID()
            isLoading = false
            fileHint = nil
            showingOlder = false
            messages = []
            cursor = nil
            message = nil
            switch source {
            case .codex: codexRoot = data
            case .claude: claudeRoot = data
            case .gemini: geminiRoot = data
            case .antigravity: antigravityRoot = data
            }
        } catch {
            message = "无法保存该目录的读取授权"
        }
    }

    private func load(before: UInt64?) async {
        let bookmark = bookmark
        let request = UUID()
        activeRequest = request
        isLoading = true
        defer { if activeRequest == request { isLoading = false } }
        let source = source
        let id = sessionID
        let knownFile = fileHint
        let worker = Task.detached(priority: .utility) {
            try AgentConversationHistory.read(bookmark: bookmark, source: source, id: id,
                                              before: before, knownFile: knownFile)
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                              onCancel: { worker.cancel() })
            guard activeRequest == request, !Task.isCancelled else { return }
            fileHint = result.file
            cursor = result.page.before
            if before == nil {
                if !result.page.messages.isEmpty || messages.isEmpty { messages = result.page.messages }
            }
            else { messages.insert(contentsOf: result.page.messages, at: 0) }
            if before == nil { interaction.updateContext(id: sessionID, messages: messages) }
            message = nil
        } catch is CancellationError {
            return
        } catch {
            guard activeRequest == request, !Task.isCancelled else { return }
            message = (error as? AgentConversationHistory.AccessError) == .noSession
                ? "在所选目录里找不到这个会话"
                : "无法读取会话记录"
        }
    }
}

private struct AgentUsageSummary: View {
    @ObservedObject var hub: UnifiedActivities
    @ObservedObject private var apiUsage = AgentAPIUsageLedger.shared
    @AppStorage(AgentUsageSelection.key) private var preferred = ""
    @AppStorage(AgentSuggestionAPI.enabledKey) private var apiEnabled = false

    var body: some View {
        switch AgentUsageSelection.resolve(hub.agentUsage, preferred: preferred, active: hub.runningAgent?.source,
                                           apiEnabled: apiEnabled, today: apiUsage.today) {
        case .provider(let snapshot):
            providerBadge(snapshot)
        case .replyAPI(let today):
            Label(AgentUsageSelection.apiLabel(today), systemImage: "number")
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .accessibilityLabel("快捷回复 API 今日用量")
        case .unavailable:
            EmptyView()
        }
    }

    private func providerBadge(_ snapshot: AgentProviderUsage) -> some View {
        let now = Date().timeIntervalSince1970
        let current = snapshot.windows.filter { snapshot.isCurrent($0, at: now) }
        let detail = ([snapshot.name] + current.map { "\($0.cycle)剩余 \(Int($0.remaining))%" }).joined(separator: " · ")
        return HStack(spacing: 5) {
            if let icon = AgentApplicationIcons.icon(for: snapshot.id) {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 16, height: 16)
            } else {
                Image(systemName: "terminal").font(.system(size: 11)).frame(width: 16, height: 16)
            }
            if snapshot.showsQuotaRings {
                Image(nsImage: AgentQuotaRings.image(for: snapshot, at: now)).frame(width: 18, height: 18)
            } else if let usage = AgentUsageSelection.compactBilling(snapshot) {
                Text(usage).font(.system(size: 11, weight: .medium)).monospacedDigit()
            }
        }
        .help(detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent 用量 · \(snapshot.name)")
        .accessibilityValue(detail)
    }
}

struct UnifiedActivityPanel: View {
    @Binding var selectedID: String?
    var viewportHeight: CGFloat = 104
    var listHeightChanged: (CGFloat) -> Void = { _ in }
    var body: some View {
        AgentSessionsPage(selectedID: $selectedID, viewportHeight: viewportHeight, listHeightChanged: listHeightChanged)
    }
}


private struct ActivityActionButton: View {
    var symbol: String
    var label: String
    var selected = false
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 32, height: 32)
                .background {
                    NotchControlSurface(
                        shape: RoundedRectangle(cornerRadius: 8), emphasized: selected, isHovered: hovered
                    )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchControlStyle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
        .accessibilityLabel(label).help(label)
    }
}


struct ActivityAvatar: View {
    var activity: IslandActivity?
    var size: CGFloat
    private var source: String {
        activity?.source?.lowercased() ?? activity?.title.components(separatedBy: " · ").first?.lowercased() ?? ""
    }
    var body: some View {
        Group {
            if activity?.kind == "agent" || activity?.isGeneratingAgentReply == true,
               let icon = AgentApplicationIcons.icon(for: source) {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: activity?.symbol ?? "circle")
                    .resizable().scaledToFit().padding(3)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(activity?.kind == "agent" ? source : activity?.title ?? "活动")
    }
}

@MainActor
private enum AgentApplicationIcons {
    static var cache: [String: NSImage] = [:]
    static var agentNotchURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.github.lihao505.AgentNotch")
    }
    static func open(activity: IslandActivity) {
        let source = activity.source ?? ""
        if source == "codex", let id = activity.sessionID,
           UUID(uuidString: id) != nil,
           let url = URL(string: "codex://threads/\(id)"),
           NSWorkspace.shared.open(url) { return }
        open(source: source)
    }
    static func open(source: String) {
        let identifiers = ["codex": "com.openai.codex", "gpt": "com.openai.codex", "claude": "com.anthropic.claudefordesktop", "codebuddy": "com.tencent.codebuddy", "workbuddy": "com.workbuddy.workbuddy-ai", "antigravity": "com.google.antigravity"]
        guard let id = identifiers[source.lowercased()], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    static func icon(for source: String) -> NSImage? {
        if let image = cache[source] { return image }
        let identifiers = [
            "codex": "com.openai.codex", "gpt": "com.openai.codex",
            "claude": "com.anthropic.claudefordesktop",
            "codebuddy": "com.tencent.codebuddy", "workbuddy": "com.workbuddy.workbuddy-ai",
            "antigravity": "com.google.antigravity"
        ]
        guard let identifier = identifiers[source],
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[source] = image
        return image
    }
}
