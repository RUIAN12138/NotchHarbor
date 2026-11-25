// Unified activity presentation. See docs/ACTIVITY_SOURCES.md for design sources.
import SwiftUI
import AppKit
import Combine
import CoreAudio
import CryptoKit

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
    var requestID: String? = nil

    var islandPhase: AgentIslandPhase? { AgentIslandPhase(rawValue: phase) }

    var isValid: Bool {
        islandPhase != nil
            && observedAt.isFinite && observedAt > 0 && children.count <= 16
            && children.allSatisfy { $0.id.count <= 64 }
            && (lastTool?.count ?? 0) <= 96 && (requestID?.count ?? 0) <= 64
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
        case "idle": return "暂未活动"
        default: return "正在处理"
        }
    }
}
struct CodexApprovalRequest: Codable, Equatable {
    enum Choice: String { case allow, deny, native }

    let id: UUID
    let sessionID: UUID
    let tool: String
    let cwd: String
    let reason: String
    let command: String?
    let createdAt: TimeInterval
    let expires: TimeInterval
    let pid: Int32

    var sessionActivityID: String {
        SHA256.hash(data: Data(("codex|" + sessionID.uuidString.lowercased()).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".multiagent-notch/notch-harbor-approvals", isDirectory: true)

    static func pending(in directory: URL, now: TimeInterval = Date().timeIntervalSince1970) -> [Self] {
        guard privatePath(directory.deletingLastPathComponent(), type: .typeDirectory),
              privatePath(directory, type: .typeDirectory),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }.prefix(128).compactMap { file in
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  privatePath(file, type: .typeRegular, maxBytes: 32768),
                  let data = try? Data(contentsOf: file),
                  let request = try? JSONDecoder().decode(Self.self, from: data),
                  request.id == id, request.createdAt <= now + 5, request.expires > now,
                  (0...60).contains(request.expires - request.createdAt),
                  request.pid > 1, kill(request.pid, 0) == 0
            else { return nil }
            return request
        }.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    func acknowledge(in directory: URL) {
        let ready = directory.appendingPathComponent(id.uuidString.lowercased() + ".ready")
        try? Data().write(to: ready, options: .withoutOverwriting)
    }

    func submit(_ choice: Choice, in directory: URL) throws {
        guard Self.pending(in: directory).contains(self), choice != .allow || command != nil else {
            throw CocoaError(.fileNoSuchFile)
        }
        let decision = directory.appendingPathComponent(id.uuidString.lowercased() + ".decision")
        try Data(choice.rawValue.utf8).write(to: decision, options: .withoutOverwriting)
    }

    private static func privatePath(_ url: URL, type: FileAttributeType, maxBytes: Int? = nil) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == type,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o077 == 0 else { return false }
        return maxBytes.map { (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= $0 } ?? true
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
    var weatherStartsAt: Double? = nil
    enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, symbol, priority, expires, source, sessionID, progress, sessionTitle, conversationID, weatherStartsAt
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

    var agentAttentionKey: String? {
        guard kind == "agent", let phase = progress?.islandPhase,
              phase == .waitingForApproval || phase == .waitingForInput else { return nil }
        let request = progress?.requestID.map { ":" + $0 } ?? ""
        return id + ":attention:" + phase.rawValue + request
    }

    var hasPendingAgentApproval: Bool {
        kind == "agent" && progress?.islandPhase == .waitingForApproval
    }

    var needsDoubaoApproval: Bool { source == "doubao" && hasPendingAgentApproval }

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
        weatherStartsAt = try? values.decode(Double.self, forKey: .weatherStartsAt)
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

struct CompactAlertCountdown: Equatable {
    let duration: Duration
    private var budget: Duration
    private var runningSince: ContinuousClock.Instant?

    init(duration: Duration, now: ContinuousClock.Instant, paused: Bool) {
        self.duration = duration
        budget = duration
        runningSince = paused ? nil : now
    }

    var isPaused: Bool { runningSince == nil }

    func remaining(at now: ContinuousClock.Instant) -> Duration {
        let elapsed = runningSince.map { max(.zero, $0.duration(to: now)) } ?? .zero
        return max(.zero, budget - elapsed)
    }

    func fractionRemaining(at now: ContinuousClock.Instant) -> Double {
        duration > .zero ? remaining(at: now) / duration : 0
    }

    mutating func setPaused(_ paused: Bool, at now: ContinuousClock.Instant) {
        guard paused != isPaused else { return }
        budget = remaining(at: now)
        runningSince = paused ? nil : now
    }
}

enum AgentCompletionHaloSettings {
    static let durationKey = "agentCompletionHaloDuration"
    static let defaultDuration = 8.0
    static let durationRange: ClosedRange<Double> = 0...20

    static func readyTime(afterClosingAt closedAt: Date, reduceMotion: Bool) -> Date {
        // Wait for the compact close spring and its content transition to settle.
        closedAt.addingTimeInterval(reduceMotion ? 0 : 0.48)
    }

    static func normalizedDuration(_ value: Double) -> Double {
        guard value.isFinite else { return defaultDuration }
        return min(durationRange.upperBound, max(durationRange.lowerBound, value))
    }
}

struct AgentCompletionHoverReplay {
    static let popupDuration: Duration = .seconds(2)

    static func replyPopupDuration(headphonesConnected: Bool, headControlEnabled: Bool) -> Duration {
        headphonesConnected || headControlEnabled ? .seconds(5) : popupDuration
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
    var onAgentTurnFinished: ((IslandActivity) -> Void)?
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
    private var expiryDeadline: TimeInterval?
    private var agentObserver: NSObjectProtocol?
    private var usageObserver: NSObjectProtocol?
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

    @Published private var completionSummaries: [String: String] = [:]

    func setAgentCompletionSummary(_ summary: String, session: IslandActivity) {
        guard let stamp = session.progress?.observedAt else { return }
        let id = session.id + ":completion:" + String(stamp)
        if completionSummaries.count >= 24 {
            completionSummaries = completionSummaries.filter { recentCompletionNotices[$0.key] != nil }
        }
        completionSummaries[id] = summary
    }

    func agentCompletionSummary(for alert: IslandActivity) -> String {
        if let summary = completionSummaries[alert.id] { return summary }
        if let task = alert.sessionTitle, !task.isEmpty {
            return alert.progress?.phase == "failed" ? "「\(task)」本轮异常结束。" : "已完成「\(task)」。"
        }
        return alert.detail
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
        let fallback = hasReplies ? "任务已完成，可继续追问。" : (failed ? "查看会话详情" : "本轮任务已结束。")
        notice.detail = completionSummaries[notice.id] ?? original.sessionTitle.map {
            failed ? "「\($0)」本轮异常结束。" : "已完成「\($0)」。"
        } ?? fallback
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

    @Published private var codexApprovals: [CodexApprovalRequest] = []
    private let codexApprovalDirectory: URL
    private var codexApprovalObserver: NSObjectProtocol?
    private var codexApprovalPoll: Task<Void, Never>?

    private func refreshCodexApprovals() {
        let pending = CodexApprovalRequest.pending(in: codexApprovalDirectory)
        if pending != codexApprovals {
            let known = Set(codexApprovals.map(\.id))
            for request in pending where !known.contains(request.id) {
                request.acknowledge(in: codexApprovalDirectory)
            }
            codexApprovals = pending
        }
        if pending.isEmpty {
            codexApprovalPoll?.cancel()
            codexApprovalPoll = nil
        } else if codexApprovalPoll == nil {
            codexApprovalPoll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self else { return }
                    self.refreshCodexApprovals()
                }
            }
        }
    }

    private var liveCodexApprovalActivities: [IslandActivity] {
        var sessions = Set<UUID>()
        let now = Date().timeIntervalSince1970
        return codexApprovals.filter { $0.expires > now && sessions.insert($0.sessionID).inserted }
            .map { request in
                let id = request.sessionID.uuidString.lowercased()
                let existing = (activities + agentHistory).first {
                    $0.source == "codex" && ($0.conversationID ?? $0.sessionID)?.lowercased() == id
                }
                return IslandActivity(id: existing?.id ?? request.sessionActivityID, kind: "agent",
                    title: "Codex · 已请求审批", detail: URL(fileURLWithPath: request.cwd).lastPathComponent,
                    symbol: "hand.raised.fill", priority: 95, expires: request.expires, source: "codex",
                    sessionID: id, progress: AgentProgress(phase: "waiting_for_approval",
                        observedAt: request.createdAt, children: [], lastTool: request.tool,
                        requestID: request.id.uuidString.lowercased()),
                    sessionTitle: existing?.sessionTitle, conversationID: id)
            }
    }

    func codexApproval(for item: IslandActivity) -> CodexApprovalRequest? {
        guard item.hasPendingAgentApproval, item.source == "codex",
              let id = item.progress?.requestID.flatMap(UUID.init(uuidString:)),
              let session = (item.conversationID ?? item.sessionID).flatMap(UUID.init(uuidString:))
        else { return nil }
        return codexApprovals.first { $0.id == id && $0.sessionID == session &&
            $0.expires > Date().timeIntervalSince1970 }
    }

    func submitCodexApproval(_ choice: CodexApprovalRequest.Choice, request: CodexApprovalRequest) throws {
        try request.submit(choice, in: codexApprovalDirectory)
    }

    var proactiveAlerts: [IslandActivity] {
        let approvals = liveCodexApprovalActivities
        let liveIDs = Set(approvals.map(\.id))
        return approvals + activities.filter { !liveIDs.contains($0.id) && (
            $0.kind == "preview" || $0.kind == "calendar" || $0.kind == "agent-quota-reset" || $0.kind == "weather-warning" || $0.agentAttentionKey != nil)
        } + completionNotices + [headphoneLidNotice].compactMap { $0 }
    }

    func currentAgentAttention(for key: String) -> IslandActivity? {
        let now = Date().timeIntervalSince1970
        return proactiveAlerts.first { $0.agentAttentionKey == key && $0.expires > now }
    }

    var proactiveAlert: IslandActivity? { proactiveAlerts.first }
    var wingActivity: IslandActivity? {
        proactiveAlerts.first { $0.kind != "headphone-lid" && $0.kind != "agent-quota-reset" && $0.kind != "weather-warning" && !$0.isCompletedAgentSession }
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
    @Published private(set) var weatherWarnings: [IslandActivity] = []
    private var weatherWarningExpiry: Task<Void, Never>?
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
            detail: date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened),
            symbol: "calendar.badge.clock",
            priority: 70, expires: Date().timeIntervalSince1970 + 45)
        publish(activities.filter { $0.id != alert.id } + [alert])
    }

    private func recentlyPresentedWeatherWarnings(now: Double) -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: "seenNotchWeatherWarnings") as? [String: Double] ?? [:])
            .filter { $0.value > now - 6 * 3600 }
    }

    func updateWeatherWarnings(_ warnings: [IslandActivity], popupIDs: Set<String> = []) {
        let now = Date().timeIntervalSince1970
        let latest = warnings.filter { $0.expires > now }
        if weatherWarnings != latest {
            weatherWarnings = latest
            weatherWarningExpiry?.cancel()
            if let expiry = latest.map(\.expires).min() {
                weatherWarningExpiry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0.05, expiry - now)))
                    guard !Task.isCancelled, let self else { return }
                    self.updateWeatherWarnings(self.weatherWarnings)
                }
            }
        }
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

    static let retainedAgentSessions = 2
    static let agentSessionLifetime: TimeInterval = 15 * 60
    @Published private var recentDoubaoSessions: [IslandActivity] = []
    @Published private var recentlyEndedSessions: [IslandActivity] = []

    func setRecentDoubaoSessions(_ sessions: [IslandActivity]) {
        let recent = Self.recentAgentHistory(sessions + recentDoubaoSessions, now: Date().timeIntervalSince1970)
        if recent != recentDoubaoSessions { recentDoubaoSessions = recent }
        scheduleExpiry()
    }

    var hasPendingAgentApprovals: Bool {
        proactiveAlerts.contains { $0.hasPendingAgentApproval && $0.expires > Date().timeIntervalSince1970 }
    }

    private static func recentAgentHistory(_ sessions: [IslandActivity], now: Double) -> [IslandActivity] {
        var seen = Set<String>()
        return sessions.sorted(by: newerSession).filter { item in
            let stamp = item.progress?.observedAt ?? 0
            return stamp.isFinite && stamp > 0 && stamp + agentSessionLifetime > now
                && seen.insert(item.id).inserted
        }
    }

    private static func newerSession(_ lhs: IslandActivity, _ rhs: IslandActivity) -> Bool {
        let left = lhs.progress?.observedAt ?? 0
        let right = rhs.progress?.observedAt ?? 0
        if left != right { return left > right }
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        return lhs.isCompletedAgentSession && !rhs.isCompletedAgentSession
    }

    private var agentHistory: [IslandActivity] {
        completedAgentSessions + recentlyEndedSessions + recentDoubaoSessions
    }

    var agentSessions: [IslandActivity] {
        let now = Date().timeIntervalSince1970
        let approvals = liveCodexApprovalActivities
        let approvalIDs = Set(approvals.map(\.id))
        let current = approvals + activities.filter {
            $0.kind == "agent" && !$0.isCompletedAgentSession && $0.expires > now && !approvalIDs.contains($0.id)
        }
        let currentIDs = Set(current.map(\.id))
        var inactiveCounts: [String: Int] = [:]
        let retained = Self.recentAgentHistory(agentHistory, now: now).filter { item in
            let provider = item.source ?? ""
            guard !currentIDs.contains(item.id),
                  inactiveCounts[provider, default: 0] < Self.retainedAgentSessions else { return false }
            inactiveCounts[provider, default: 0] += 1
            return true
        }
        return (current + retained).sorted(by: Self.newerSession)
    }

    func agentSession(for id: String) -> IslandActivity? {
        let now = Date().timeIntervalSince1970
        return liveCodexApprovalActivities.first { $0.id == id }
            ?? activities.first { $0.id == id && $0.kind == "agent" && $0.expires > now }
            ?? Self.recentAgentHistory(agentHistory.filter { $0.id == id }, now: now).first
    }

    init(observeSystem: Bool = true, storageURL: URL? = nil, approvalDirectory: URL? = nil) {
        codexApprovalDirectory = approvalDirectory ?? CodexApprovalRequest.directory
        observeDevices = observeSystem
        directory = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UnifiedActivities", isDirectory: true)
        if observeSystem || storageURL != nil {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: directory.appendingPathComponent("completed-agents.json")),
               let saved = try? JSONDecoder().decode([IslandActivity].self, from: data) {
                let now = Date().timeIntervalSince1970
                completedAgentSessions = Self.recentAgentHistory(saved.filter(\.isCompletedAgentSession), now: now)
                recentlyEndedSessions = Self.recentAgentHistory(
                    saved.filter { $0.kind == "agent" && $0.progress?.phase == "idle" }, now: now
                )
                if completedAgentSessions.count + recentlyEndedSessions.count != saved.count {
                    persistRecentAgentHistory()
                }
                scheduleExpiry()
            }
        }
        guard observeSystem else { return }
        // Warm artwork metadata once; later audio lookups refresh it.
        BluetoothInfo.warmArtworkCacheOnce()
        agentObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.boringnotch.agent-state"), object: nil, queue: .main
        ) { [weak self] notification in
            guard let text = notification.object as? String, let data = text.data(using: .utf8) else { return }
            Task { @MainActor in self?.receiveAgents(data) }
        }
        codexApprovalObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.boringnotch.codex-approval"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshCodexApprovals() }
        }
        refreshCodexApprovals()
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
        let visible = items.filter { $0.expires > now && dismissed[$0.id] != $0.expires }.sorted {
            $0.priority == $1.priority ? $0.id < $1.id : $0.priority > $1.priority
        }
        let incomingIDs = Set(visible.filter { $0.kind == "agent" }.map(\.id))
        var ended = recentlyEndedSessions
        for item in activities where item.kind == "agent" && !incomingIDs.contains(item.id)
            && item.progress?.islandPhase?.isTerminal == false {
            var recent = item
            recent.progress?.phase = "idle"
            recent.progress?.requestID = nil
            recent.progress?.lastTool = nil
            recent.progress?.children = []
            recent.title = item.title.components(separatedBy: " · ").first ?? "Agent"
            ended.append(recent)
        }
        let recentEnded = Self.recentAgentHistory(ended, now: now)
        let previousCompletions = completedAgentSessions
        let recentCompleted = Self.recentAgentHistory(
            items.filter { $0.isCompletedAgentSession && $0.progress?.isValid == true } + completedAgentSessions,
            now: now
        )
        if recentEnded != recentlyEndedSessions || recentCompleted != completedAgentSessions {
            if recentEnded != recentlyEndedSessions { recentlyEndedSessions = recentEnded }
            if recentCompleted != completedAgentSessions { completedAgentSessions = recentCompleted }
            persistRecentAgentHistory()
        }
        let recentDoubao = Self.recentAgentHistory(recentDoubaoSessions, now: now)
        if recentDoubao != recentDoubaoSessions { recentDoubaoSessions = recentDoubao }
        if activities != visible { activities = visible }
        if !activities.contains(where: { $0.id == selectedActivityID }) { selectedActivityID = nil }
        if !activities.contains(where: { $0.kind == "headphones" }) {
            headphoneAlert = nil
            proximityIdentity = nil
            recentWear = nil
            audioCueID = nil
        }
        scheduleExpiry()
        if let onAgentTurnFinished, recentCompleted != previousCompletions {
            for item in recentCompleted where !previousCompletions.contains(where: {
                $0.id == item.id && $0.progress?.observedAt == item.progress?.observedAt
            }) {
                onAgentTurnFinished(item)
            }
        }
    }

    private func scheduleExpiry() {
        let now = Date().timeIntervalSince1970
        let historyDeadlines = agentHistory.compactMap { $0.progress?.observedAt }
            .map { $0 + Self.agentSessionLifetime }
        let next = (activities.map(\.expires) + historyDeadlines).min()
        guard next != expiryDeadline else { return }
        expiry?.cancel()
        expiryDeadline = next
        guard let next else {
            expiry = nil
            return
        }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.02, next - now)))
            guard !Task.isCancelled, let self else { return }
            self.expiryDeadline = nil
            self.publish(self.activities)
        }
    }

    /// Only a newer provider sample can confirm a quota reset. A countdown
    /// reaching zero alone does not imply that the service restored usage.
    static func quotaResetAlerts(previous: [AgentProviderUsage], current: [AgentProviderUsage],
                                 now: Double) -> [IslandActivity] {
        current.compactMap { provider in
            guard let old = previous.first(where: { $0.id == provider.id }),
                  provider.updatedAt > old.updatedAt,
                  now - provider.updatedAt < 180 else { return nil }
            let resets = provider.windows.compactMap { window -> (String, Double)? in
                guard (window.windowMinutes != nil || window.label != nil),
                      let before = old.windows.first(where: {
                        $0.windowMinutes == window.windowMinutes && $0.label == window.label
                      }) else { return nil }
                if let reset = before.resetsAt, let next = window.resetsAt,
                   next > reset, reset <= provider.updatedAt, now - reset < 1800 {
                    return (window.cycle, next)
                }
                if before.resetsAt == nil, window.resetsAt == nil,
                   provider.updatedAt - old.updatedAt < 86400,
                   before.usedPercent >= 5, window.usedPercent == 0 {
                    return (window.cycle, provider.updatedAt)
                }
                return nil
            }
            guard !resets.isEmpty else { return nil }
            let cycles = Array(Set(resets.map(\.0))).sorted().joined(separator: " · ")
            let identity = resets.map { "\($0.0):\($0.1)" }.sorted().joined(separator: "|")
            return IslandActivity(id: "quota-reset:" + provider.id + ":" + identity,
                                  kind: "agent-quota-reset", title: provider.name + " 额度已重置",
                                  detail: cycles, symbol: "arrow.clockwise", priority: 80,
                                  expires: now + 75, source: provider.id)
        }
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
        let resets = Self.quotaResetAlerts(previous: agentUsage, current: safe, now: Date().timeIntervalSince1970)
        agentUsage = safe
        if !resets.isEmpty {
            let existing = Set(activities.map(\.id))
            publish(activities + resets.filter { !existing.contains($0.id) })
        }
        if let encoded = try? JSONEncoder().encode(safe) {
            try? encoded.write(to: directory.appendingPathComponent("agent-usage.json"), options: .atomic)
        }
    }

    private func receiveAgents(_ data: Data) {
        guard data.count < 131072,
              let incoming = try? JSONDecoder().decode([IslandActivity].self, from: data) else { return }
        bridgeAvailable = true
        // The launch agent's regular heartbeat also recovers a missed change notification.
        if observeDevices { refreshCodexApprovals() }
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
        let now = Date()
        // A delayed hook cannot restore a request from an already-closed turn.
        let history = Dictionary(uniqueKeysWithValues: Self.recentAgentHistory(
            completedAgentSessions + recentlyEndedSessions, now: now.timeIntervalSince1970
        ).map { ($0.id, $0) })
        let live = Dictionary(activities.filter { $0.kind == "agent" && $0.expires > now.timeIntervalSince1970 }
            .map { ($0.id, $0) }, uniquingKeysWith: { Self.newerSession($0, $1) ? $0 : $1 })
        let newest = Dictionary(valid.map { ($0.id, $0) },
                                uniquingKeysWith: { Self.newerSession($0, $1) ? $0 : $1 })
        let accepted = newest.values.compactMap { item -> IslandActivity? in
            let stamp = item.progress?.observedAt ?? 0
            if let current = live[item.id], (current.progress?.observedAt ?? 0) > stamp { return current }
            if let prior = history[item.id], let priorStamp = prior.progress?.observedAt {
                if stamp < priorStamp || (stamp == priorStamp && !item.isCompletedAgentSession) { return nil }
            }
            return item
        }.sorted(by: Self.newerSession)
        let cached = directory.appendingPathComponent("agents.json")
        if let encoded = try? JSONEncoder().encode(accepted),
           (try? JSONDecoder().decode([IslandActivity].self, from: Data(contentsOf: cached))) != accepted {
            try? encoded.write(to: cached, options: .atomic)
        }
        publish(activities.filter { $0.kind != "agent" } + accepted)
    }

    private func persistRecentAgentHistory() {
        let file = directory.appendingPathComponent("completed-agents.json")
        let recent = (completedAgentSessions + recentlyEndedSessions).sorted(by: Self.newerSession)
        if let data = try? JSONEncoder().encode(recent) { try? data.write(to: file, options: .atomic) }
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
    static let inlinePreviewHeight: CGFloat = 88

    static func height(for rowCount: Int) -> CGFloat {
        headingHeight + listInset * 2 + CGFloat(rowCount) * rowHeight
    }

    static func visibleRows(total: Int, expanded: Bool, previewIndex: Int?, minimum: Int = 0) -> Int {
        let visible = min(total, max(minimum, expanded ? expandedCount : compactCount))
        guard let previewIndex, previewIndex + 1 < total else { return visible }
        // An expanded list can be scrolled, so any hovered row might be at its bottom edge.
        let needsNextRow = expanded || previewIndex == visible - 1
        return needsNextRow ? min(total, visible + 1) : visible
    }
}

private struct AgentSessionsPage: View {
    @Binding var selectedID: String?
    var viewportHeight: CGFloat
    let listHeightChanged: (CGFloat) -> Void
    @ObservedObject private var hub = UnifiedActivities.shared
    @EnvironmentObject private var vm: BoringViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var listExpanded = false
    @State private var heldListHeight: CGFloat = 0
    @State private var heldVisibleRows = 0
    @State private var revealedRows = 0
    @State private var hoveredSessionID: String?
    private var sessions: [IslandActivity] { hub.agentSessions }
    private var newestDoubaoSession: UUID? {
        sessions.first { $0.source == "doubao" && $0.conversationID != nil }?
            .conversationID.flatMap(UUID.init(uuidString:))
    }

    // Agent Notch SessionListMetrics / ClaudeInstancesView (Apache-2.0).
    private let rowHeight = AgentSessionListMetrics.rowHeight
    private let headingHeight = AgentSessionListMetrics.headingHeight
    private let listInset = AgentSessionListMetrics.listInset

    var body: some View {
        Group {
            if let selectedID, let selected = hub.agentSession(for: selectedID) {
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
                            ForEach(listExpanded ? sessions[...] : sessions.prefix(max(visibleRows, heldVisibleRows))) { item in
                                AgentNotchTaskRow(
                                    item: item, name: agentName(item), title: sessionName(item),
                                    activity: currentAction(item, fallback: fallbackStatus(item)),
                                    rowHeight: rowHeight, hoveredSessionID: $hoveredSessionID
                                ) { open(item.id) }
                                .id(item.id)
                            }
                        }
                        .padding(.vertical, listInset)
                    }
                    .scrollIndicators(.never)
                    .scrollBounceBehavior(.basedOnSize)
                }
                .contentShape(Rectangle())
                .panGesture(direction: .up, threshold: 12, startsWithMomentum: false, requiresEligibleStart: true,
                            isEnabled: { canExpandList }) { _, phase in
                    if phase == .began || phase == .changed { expandList() }
                }
                .accessibilityAction(named: "显示更多会话") { expandList() }
                .frame(height: min(viewportHeight, max(listHeight, heldListHeight)), alignment: .top)
            }
        }
        .task(id: selectedID == nil ? listHeight : 0) {
            let extra = extraListHeight
            let target = selectedID == nil ? listHeight : 0
            if selectedID == nil, target < heldListHeight {
                try? await Task.sleep(for: .milliseconds(1400))
                guard !Task.isCancelled else { return }
            }
            withAnimation(reduceMotion ? nil : NotchPanelMotion.spring(reduceMotion: false)) {
                heldListHeight = target
                heldVisibleRows = selectedID == nil ? visibleRows : 0
                vm.agentListPreviewHeightHeld = previewIndex != nil
                listHeightChanged(extra)
            }
        }
        .onDisappear { vm.agentListPreviewHeightHeld = false }
        .task {
            while !Task.isCancelled {
                let result = try? await AgentInteraction.shared.recentDoubaoSessions()
                if let result, !Task.isCancelled { hub.setRecentDoubaoSessions(result) }
                do { try await Task.sleep(for: .seconds(90)) }
                catch { return }
            }
        }
        .onChange(of: visibleRows) { _, rows in
            guard previewIndex != nil, !listExpanded else { return }
            if rows > AgentSessionListMetrics.expandedCount { listExpanded = true }
            else { revealedRows = max(revealedRows, rows) }
        }
        .task(id: newestDoubaoSession) {
            guard let id = newestDoubaoSession else { return }
            _ = try? await AgentInteraction.shared.doubaoHistory(id)
        }
        .onChange(of: selectedID.flatMap { hub.agentSession(for: $0) } != nil) { _, isAvailable in
            if !isAvailable { selectedID = nil }
        }
        .onChange(of: sessions.map(\.id)) { _, ids in
            if let hoveredSessionID, !ids.contains(hoveredSessionID) { self.hoveredSessionID = nil }
        }
    }

    private var previewIndex: Int? {
        guard selectedID == nil, let id = vm.agentConversationPreviewID else { return nil }
        return sessions.firstIndex(where: { $0.id == id })
    }

    private var visibleRows: Int {
        AgentSessionListMetrics.visibleRows(total: sessions.count, expanded: listExpanded, previewIndex: previewIndex, minimum: revealedRows)
    }

    private var listHeight: CGFloat {
        AgentSessionListMetrics.height(for: visibleRows) + (previewIndex == nil ? 0 : AgentSessionListMetrics.inlinePreviewHeight)
    }

    private var extraListHeight: CGFloat {
        guard selectedID == nil else { return 0 }
        return max(0, listHeight - AgentSessionListMetrics.height(for: AgentSessionListMetrics.compactCount))
    }

    private var canExpandList: Bool {
        selectedID == nil && previewIndex == nil && !listExpanded && sessions.count > max(AgentSessionListMetrics.compactCount, revealedRows)
    }

    private func expandList() {
        guard canExpandList else { return }
        listExpanded = true
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
        Group {
            if let source = item.source.flatMap(AgentConversationSource.init(rawValue:)),
               let id = (item.conversationID ?? item.sessionID).flatMap(UUID.init(uuidString:)) {
                AgentConversationSection(source: source, sessionID: id, updatedAt: item.progress?.observedAt,
                                         viewportHeight: viewportHeight, allowsReply: !item.hasPendingAgentApproval) {
                    detailHeader(item)
                }
                .id(item.id)
                .padding(.horizontal, 12)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    detailHeader(item)
                    Text("暂无可读取的对话").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
            }
        }
        .accessibilityIdentifier("agent-session-detail")
    }

    private func detailHeader(_ item: IslandActivity) -> some View {
        VStack(spacing: 3) {
            Button { open(nil) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 20, height: 20)
                    AgentNotchBadge(activity: item, name: agentName(item))
                    Text(sessionName(item)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回任务列表")
            .accessibilityIdentifier("agent-back-to-tasks")
            if item.agentAttentionKey != nil { AgentSessionAttention(item: item) }
        }
        .padding(.vertical, 4)
    }

    private func currentAction(_ item: IslandActivity, fallback: String) -> String { item.agentCurrentAction }

}

private struct AgentSessionAttention: View {
    let item: IslandActivity
    var openDetails: (() -> Void)? = nil
    @ObservedObject private var activities = UnifiedActivities.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showCommand = true
    @State private var submitted = false
    @State private var submitFailed = false

    private var needsApproval: Bool { item.progress?.islandPhase == .waitingForApproval }

    var body: some View {
        let request = activities.codexApproval(for: item)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Label(needsApproval ? "需要审批" : "等待你的回复",
                      systemImage: needsApproval ? "hand.raised.fill" : "questionmark.bubble.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                if needsApproval, let tool = item.progress?.lastTool {
                    Text(tool).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let request, request.command != nil {
                    Button(openDetails == nil && showCommand ? "收起命令" : "查看并审批") {
                        if let openDetails { openDetails() }
                        else { withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) { showCommand.toggle() } }
                    }
                    .buttonStyle(AgentNotchTaskButtonStyle())
                    .accessibilityIdentifier("agent-codex-review")
                } else if item.needsDoubaoApproval {
                    Text("请在豆包原终端确认")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        if let request { submit(.native, request: request) }
                        AgentApplicationIcons.open(activity: item)
                    } label: {
                        Label(needsApproval ? "前往审批" : "打开原会话", systemImage: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(AgentNotchTaskButtonStyle())
                }
            }
            .frame(height: 24)
            if openDetails == nil, showCommand, let request, let command = request.command {
                if !request.reason.isEmpty {
                    Text(request.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(request.cwd).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle)
                    .help(request.cwd)
                ScrollView {
                    Text(verbatim: command).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 52)
                HStack {
                    if submitFailed { Text("请求已失效，请在 Codex 查看").font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    Button("回 Codex") {
                        submit(.native, request: request)
                        AgentApplicationIcons.open(activity: item)
                    }
                    Button("拒绝") { submit(.deny, request: request) }
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("agent-codex-deny")
                    Button("仅允许这次") { submit(.allow, request: request) }
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("agent-codex-allow-once")
                }
                .buttonStyle(AgentNotchTaskButtonStyle())
                .disabled(submitted)
            }
        }
        .onChange(of: request?.id) {
            showCommand = true
            submitted = false
            submitFailed = false
        }
    }

    private func submit(_ choice: CodexApprovalRequest.Choice, request: CodexApprovalRequest) {
        do {
            try activities.submitCodexApproval(choice, request: request)
            submitted = true
            submitFailed = false
        } catch {
            submitFailed = true
        }
    }
}

/// InstanceRow and TaskRowButtonStyle from Agent Notch, adapted to IslandActivity.
private struct AgentNotchTaskRow: View {
    let item: IslandActivity
    let name: String
    let title: String
    let activity: String
    let rowHeight: CGFloat
    @Binding var hoveredSessionID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let openDetails: () -> Void
    @EnvironmentObject private var vm: BoringViewModel
    @State private var isHovered = false
    @State private var previewHovered = false
    @State private var previewBusy = false
    @State private var recentMessages: [AgentConversationMessage] = []
    @State private var historyFile: URL?

    private var previewOpen: Bool { vm.agentConversationPreviewID == item.id }
    private var shouldClosePreview: Bool {
        previewOpen && !isHovered && !previewHovered && hoveredSessionID == nil
    }

    private var previewTarget: (AgentConversationSource, UUID)? {
        guard let source = item.source.flatMap(AgentConversationSource.init(rawValue:)),
              let id = (item.conversationID ?? item.sessionID).flatMap(UUID.init(uuidString:)) else { return nil }
        return (source, id)
    }

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
        case "idle": "最近会话"
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
        item.hasPendingAgentApproval ? .red : waiting ? .orange : phase == "finished" ? .green : phase == "failed" ? .red : .secondary
    }

    var body: some View {
        VStack(spacing: 0) {
            rowButton
            if previewOpen {
                transcriptPreview
                    .transition(.opacity.combined(with: .offset(y: -4)))
                    .onHover { previewHovered = $0 }
            }
        }
        .task(id: shouldClosePreview) {
            guard shouldClosePreview else { return }
            try? await Task.sleep(for: .milliseconds(330))
            guard !Task.isCancelled, shouldClosePreview else { return }
            closePreview()
        }
        .onChange(of: previewOpen) { _, open in
            if !open { previewHovered = false }
        }
        .task(id: previewOpen) {
            guard previewOpen, let (source, id) = previewTarget else { return }
            if source == .doubao {
                if let cached = AgentInteraction.shared.cachedDoubaoHistory(id) {
                    recentMessages = Array(cached.messages.suffix(4))
                    previewBusy = false
                }
                let result = try? await AgentInteraction.shared.doubaoHistory(id)
                guard !Task.isCancelled, previewOpen else { return }
                if let result { recentMessages = Array(result.messages.suffix(4)) }
                previewBusy = false
                return
            }
            let bookmark = UserDefaults.standard.data(forKey: "agentConversationRoot.\(source.rawValue)")
            let knownFile = historyFile
            let task = Task.detached(priority: .utility) {
                try? AgentConversationHistory.read(bookmark: bookmark, source: source, id: id, before: nil, knownFile: knownFile)
            }
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, previewOpen else { return }
            historyFile = result?.file
            recentMessages = Array(result?.page.messages.suffix(4) ?? [])
            previewBusy = false
        }
        .onDisappear {
            if hoveredSessionID == item.id { hoveredSessionID = nil }
            closePreview()
        }
        .accessibilityElement(children: .contain)
    }

    private var rowButton: some View {
        Button {
            closePreview()
            openDetails()
        } label: {
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
        .onHover { hovering in
            isHovered = hovering
            if hovering, previewTarget != nil || waiting { hoveredSessionID = item.id }
            else if hoveredSessionID == item.id { hoveredSessionID = nil }
        }
        .task(id: isHovered) {
            guard isHovered, !previewOpen, previewTarget != nil || waiting,
                  !vm.systemIslandPresentationActive else { return }
            let delay: Duration = vm.agentConversationPreviewID == nil ? .milliseconds(570) : .milliseconds(240)
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, isHovered, hoveredSessionID == item.id, vm.notchState == .open,
                  !previewOpen, !vm.systemIslandPresentationActive, NSEvent.pressedMouseButtons == 0 else { return }
            previewBusy = previewTarget != nil
            withAnimation(reduceMotion ? nil : NotchPanelMotion.spring(reduceMotion: false)) {
                vm.agentConversationPreviewID = item.id
            }
        }
    }

    private var transcriptPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            if waiting { AgentSessionAttention(item: item, openDetails: openDetails) }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    if recentMessages.isEmpty {
                        if previewBusy { ProgressView().controlSize(.small) }
                        else { Text("暂无可读取的对话").font(.caption).foregroundStyle(.secondary) }
                    }
                    ForEach(recentMessages) { message in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(message.role == "user" ? "你" : name)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            AgentConversationMessageText(entry: message)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .background(AgentPreviewScrollBoundary())
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .modifier(AgentTranscriptEdgeFade(length: 10))
        }
        .frame(height: AgentSessionListMetrics.inlinePreviewHeight - 22, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(.white)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial.opacity(0.32))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.linearGradient(colors: [.black.opacity(0.62), .black.opacity(0.23)],
                                              startPoint: .top, endPoint: .bottom))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
        }
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityIdentifier("agent-conversation-hover-preview")
    }

    private func closePreview() {
        guard previewOpen else { return }
        withAnimation(reduceMotion ? nil : NotchPanelMotion.spring(reduceMotion: false)) {
            vm.agentConversationPreviewID = nil
        }
    }

    private var statusLabel: some View {
        HStack(spacing: 5) {
            if item.hasPendingAgentApproval {
                Circle().fill(.red).frame(width: 6, height: 6).accessibilityHidden(true)
            } else if working {
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
    var placeholder = "回复当前会话…"
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
                if let input, input.currentEditor() == nil { panel?.endAgentReplyEditing(input) }
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
        input.placeholderString = placeholder
        input.setAccessibilityIdentifier("agent-reply-input")
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return input
    }

    func updateNSView(_ input: Input, context: Context) {
        context.coordinator.field = self
        input.pendingVoiceFocus = voiceFocus
        input.voiceReady = voiceReady
        input.scheduleVoiceFocus()
        if let editor = input.currentEditor() as? NSTextView {
            guard !editor.hasMarkedText(), editor.string != text else { return }
            let selection = editor.selectedRange()
            editor.string = text
            let end = (text as NSString).length
            let location = min(selection.location, end)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, end - location)))
        } else if input.stringValue != text {
            input.stringValue = text
        }
    }

    static func dismantleNSView(_ input: Input, coordinator: Coordinator) {
        let panel = input.editingPanel ?? input.window as? BoringNotchSkyLightWindow
        Task { @MainActor [weak panel] in panel?.endAgentReplyEditing(input) }
    }
}

@MainActor
private struct AgentConversationSection<Header: View>: View {
    let source: AgentConversationSource
    let sessionID: UUID
    let updatedAt: Double?
    @ObservedObject private var interaction = AgentInteraction.shared
    @AppStorage(AgentQuickReplySource.preferenceKey) private var quickReplySource = AgentQuickReplySource.current
    @AppStorage(AgentQuickReplySource.customRepliesKey) private var customReplyData = Data()
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

    private var showsComposer: Bool { allowsReply }


    private var bookmark: Data? {
        switch source {
        case .codex: codexRoot
        case .claude: claudeRoot
        case .gemini: geminiRoot
        case .antigravity: antigravityRoot
        case .doubao: nil
        }
    }
    private struct Refresh: Equatable {
        var bookmark: Data?
        var updatedAt: Double?
    }

    var viewportHeight: CGFloat
    var allowsReply = true
    @ViewBuilder var header: () -> Header
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            header()
                .padding(.horizontal, 2)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    conversationContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 16)
                    Color.clear.frame(height: 16).id("agent-conversation-end")
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .modifier(AgentTranscriptEdgeFade(length: 16))
                .onChange(of: messages.last?.id) { _, _ in
                    guard !showingOlder, !vm.isAgentReplyEditing else { return }
                    proxy.scrollTo("agent-conversation-end", anchor: .bottom)
                }
            }
            if showsComposer {
                quickReplies
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                    .padding(.bottom, 6)
                    .background { conversationControlGlass }
            }
        }
        .frame(height: viewportHeight)
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
        .onChange(of: interaction.state(sessionID).deliveredAt) { _, date in
            if source == .doubao, date != nil { Task { await load(before: nil, refresh: true) } }
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
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(reduceTransparency ? 0.96 : 0.58), location: 0.30),
                .init(color: .black.opacity(reduceTransparency ? 0.96 : 0.73), location: 1)
            ], startPoint: .top, endPoint: .bottom
        )
        .padding(.top, -6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var quickReplies: some View {
        let state = interaction.state(sessionID)
        let replyOptions: [AgentReplyOption] = switch quickReplySource {
        case .standard: AgentInteraction.immediateReplies(messages: messages, title: "")
        case .api: interaction.apiReplies(id: sessionID, messages: messages)
        case .custom: AgentQuickReplySource.customReplies(from: customReplyData)
        }
        return VStack(alignment: .leading, spacing: 5) {
            if !replyOptions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(replyOptions, id: \.body) { reply in
                            Button {
                                interaction.send(reply.body, source: source.rawValue, id: sessionID)
                            } label: {
                                Text(AgentMarkdownFormatting.inline(reply.title))
                                    .lineLimit(1)
                                    .frame(maxWidth: 240, alignment: .leading)
                            }
                            .buttonStyle(AgentNotchTaskButtonStyle())
                            .disabled(state.sending)
                            .help(reply.body)
                        }
                    }
                }
                .frame(height: 28)
                .scrollIndicators(.never)
                .reservesHorizontalNotchScrolling()
            } else if quickReplySource == .api {
                Button {
                    Task { await interaction.generateAPIReplies(id: sessionID, messages: messages) }
                } label: {
                    HStack(spacing: 5) {
                        if state.generating { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "sparkles") }
                        Text(state.generating ? "正在生成回复…" : "生成 API 建议")
                    }
                }
                .buttonStyle(AgentNotchTaskButtonStyle())
                .disabled(messages.isEmpty || state.generating || state.sending)
                .help("使用设置中选定的 API，根据最近对话生成建议")
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
                .frame(maxWidth: .infinity, minHeight: 28)
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
                        let label: LocalizedStringKey = source == .antigravity ? "复制并打开 Antigravity"
                            : source == .codex ? "复制并打开会话" : "复制引导语"
                        Button(label) {
                            guard AgentInteraction.copyReply(text) else { return }
                            interaction.dismissUnsent(sessionID)
                            if source == .codex, let url = URL(string: "codex://threads/\(sessionID.uuidString.lowercased())") {
                                NSWorkspace.shared.open(url)
                            } else if source == .antigravity {
                                AgentApplicationIcons.open(source: source.rawValue)
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
                if source == .doubao {
                    Button("重试读取") { Task { await load(before: nil, refresh: true) } }
                        .buttonStyle(.plain).font(.caption)
                } else {
                    Button("选择会话记录目录…", action: chooseFolder)
                        .buttonStyle(.plain).font(.caption)
                }
            } else if messages.isEmpty && !isLoading {
                Text("这条会话还没有保存聊天正文").font(.caption).foregroundStyle(.secondary)
                Button("重新读取") { Task { await load(before: nil) } }
                    .buttonStyle(.plain).font(.caption)
            }
            ForEach(messages) { entry in
                conversationRow(entry)
                    .id(entry.id)
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

    @ViewBuilder
    private func conversationRow(_ entry: AgentConversationMessage) -> some View {
        if entry.role == "user" {
            HStack {
                Spacer(minLength: 24)
                AgentConversationMessageText(entry: entry)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.primary.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
            }
        } else {
            HStack(alignment: .top, spacing: 6) {
                Circle().fill((source == .claude
                    ? Color(red: 0.85, green: 0.47, blue: 0.34) : .primary).opacity(0.9))
                    .frame(width: 6, height: 6).padding(.top, 5).accessibilityHidden(true)
                AgentConversationMessageText(entry: entry)
                    .foregroundStyle(.primary.opacity(0.9))
                Spacer(minLength: 24)
            }
        }
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
            case .doubao: break
            }
        } catch {
            message = "无法保存该目录的读取授权"
        }
    }

    private func load(before: UInt64?, refresh: Bool = false) async {
        let bookmark = bookmark
        let request = UUID()
        activeRequest = request
        isLoading = true
        defer { if activeRequest == request { isLoading = false } }
        let source = source
        let id = sessionID
        if source == .doubao {
            if before == nil, let cached = interaction.cachedDoubaoHistory(id) {
                messages = cached.messages
                cursor = cached.before
            }
            do {
                let page = try await interaction.doubaoHistory(id, before: before, refresh: refresh)
                guard activeRequest == request, !Task.isCancelled else { return }
                cursor = page.before
                if before == nil { messages = page.messages }
                else { messages.insert(contentsOf: page.messages, at: 0) }
                interaction.updateContext(id: sessionID, messages: messages)
                message = nil
            } catch {
                if activeRequest == request, !Task.isCancelled, messages.isEmpty { message = error.localizedDescription }
            }
            return
        }
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
            switch error as? AgentConversationHistory.AccessError {
            case .noSession:
                message = "在会话日志目录里找不到这条记录"
            case .noAccess:
                message = "无法读取日志目录，请选择对应目录授权"
            default:
                message = "无法读取会话记录"
            }
        }
    }
}

// === AGENT_TRANSCRIPT_EDGES_BEGIN ===
private struct AgentTranscriptEdges: Equatable {
    var top: Bool
    var bottom: Bool

    static func visible(offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat,
                        topInset: CGFloat, bottomInset: CGFloat) -> Self {
        let hiddenAbove = offset + topInset
        let maximumOffset = max(0, contentHeight + topInset + bottomInset - viewportHeight)
        return Self(top: hiddenAbove > 1, bottom: maximumOffset - hiddenAbove > 1)
    }
}

private struct AgentTranscriptEdgeFade: ViewModifier {
    let length: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var edges = AgentTranscriptEdges(top: false, bottom: false)

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: AgentTranscriptEdges.self) { geometry in
                    AgentTranscriptEdges.visible(offset: geometry.contentOffset.y,
                        contentHeight: geometry.contentSize.height, viewportHeight: geometry.containerSize.height,
                        topInset: geometry.contentInsets.top, bottomInset: geometry.contentInsets.bottom)
                } action: { _, next in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.13)) { edges = next }
                }
                .mask { gradient(for: edges) }
        } else {
            // Matching end padding keeps fully visible text outside these fades.
            content.mask { gradient(for: .init(top: true, bottom: true)) }
        }
    }

    private func gradient(for edges: AgentTranscriptEdges) -> some View {
        GeometryReader { viewport in
            let inset = min(0.30, length / max(1, viewport.size.height))
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(edges.top ? 0 : 1), location: 0),
                    .init(color: .black, location: inset),
                    .init(color: .black, location: 1 - inset),
                    .init(color: .black.opacity(edges.bottom ? 0 : 1), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }
}
// === AGENT_TRANSCRIPT_EDGES_END ===

private struct AgentConversationMessageText: View {
    let entry: AgentConversationMessage

    var body: some View {
        Group {
            if entry.role == "user" {
                Text(verbatim: entry.text)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                AgentMarkdownReply(markdown: entry.text).equatable()
            }
        }
        .accessibilityIdentifier("agent-conversation-message")
    }
}

enum AgentMarkdownFormatting {
    // A link label is useful in a summary or button, but the enclosing control
    // owns the action.
    static func inline(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let value = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        return value.transformingAttributes(\.link) { $0.value = nil }
    }

    static func permitsLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http"
    }
}

private struct AgentMarkdownReply: View, Equatable {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(AgentMarkdownBlock.parse(markdown)) { block in
                if !block.tableRows.isEmpty {
                    table(block.tableRows)
                } else if block.isDivider {
                    Divider()
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let marker = block.marker {
                            Text(verbatim: marker)
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(block.text)
                            .font(block.font)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, block.isCode ? 6 : 0)
                    .padding(.horizontal, block.isCode ? 8 : 0)
                    .background {
                        if block.isCode {
                            RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.08))
                        }
                    }
                    .padding(.leading, block.isQuote ? 8 : 0)
                    .overlay(alignment: .leading) {
                        if block.isQuote {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(.primary.opacity(0.27))
                                .frame(width: 2)
                        }
                    }
                    .padding(.leading, CGFloat(max(0, block.listDepth - 1)) * 11)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func table(_ rows: [[AttributedString]]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index == 1 { Divider().gridCellUnsizedAxes(.horizontal) }
                GridRow {
                    ForEach(rows[index].indices, id: \.self) { cell in
                        Text(rows[index][cell])
                            .font(.system(size: 12, weight: index == 0 ? .semibold : .regular))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(.horizontal, 7)
        .background(.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct AgentMarkdownBlock: Identifiable {
    let id: Int
    var text: AttributedString
    var heading: Int?
    var marker: String?
    var listDepth = 0
    var isCode = false
    var isQuote = false
    var isDivider = false
    var tableRows: [[AttributedString]] = []

    var font: Font {
        if let heading {
            return .system(size: heading == 1 ? 17 : heading == 2 ? 15 : 13, weight: .semibold)
        }
        return .system(size: isCode ? 12 : 13, design: isCode ? .monospaced : .default)
    }

    static func parse(_ markdown: String) -> [Self] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard let value = try? AttributedString(markdown: markdown, options: options),
              !value.characters.isEmpty else {
            return [.init(id: 0, text: AttributedString(markdown))]
        }

        var blocks: [Self] = []
        var seenItems: Set<Int> = []
        var previousTableRow: Int?
        for run in value.runs {
            var segment = AttributedString(value[run.range])
            if let url = run.link, !AgentMarkdownFormatting.permitsLink(url) {
                segment.link = nil
            }
            let components = run.presentationIntent?.components ?? []
            if components.count >= 3,
               case .tableCell(let column) = components[0].kind,
               case .table(let columns) = components[2].kind,
               columns.indices.contains(column) {
                let rowID = components[1].identity
                let tableID = components[2].identity
                if blocks.last?.id != tableID {
                    blocks.append(.init(id: tableID, text: AttributedString()))
                    previousTableRow = nil
                }
                let tableIndex = blocks.count - 1
                if previousTableRow != rowID {
                    blocks[tableIndex].tableRows.append(Array(repeating: AttributedString(), count: columns.count))
                    previousTableRow = rowID
                }
                let rowIndex = blocks[tableIndex].tableRows.count - 1
                blocks[tableIndex].tableRows[rowIndex][column] += segment
                continue
            }
            let id = components.first?.identity ?? 0
            if blocks.last?.id == id {
                blocks[blocks.count - 1].text += segment
                continue
            }

            var block = Self(id: id, text: segment)
            var item: (id: Int, position: Int)?
            for component in components {
                switch component.kind {
                case .header(let level): block.heading = level
                case .codeBlock: block.isCode = true
                case .blockQuote: block.isQuote = true
                case .thematicBreak: block.isDivider = true
                case .listItem(let ordinal):
                    block.listDepth += 1
                    if item == nil { item = (component.identity, ordinal) }
                case .orderedList, .unorderedList:
                    if let marker = item {
                        if seenItems.insert(marker.id).inserted {
                            block.marker = component.kind == .orderedList ? "\(marker.position)." : "•"
                        }
                        item = nil
                    }
                default: break
                }
            }
            blocks.append(block)
        }
        return blocks
    }
}

private struct AgentUsageSummary: View {
    @ObservedObject var hub: UnifiedActivities
    @ObservedObject private var apiUsage = AgentAPIUsageLedger.shared
    @AppStorage(AgentUsageSelection.key) private var preferred = ""
    @AppStorage(AgentQuickReplySource.preferenceKey) private var quickReplySource = AgentQuickReplySource.current

    var body: some View {
        switch AgentUsageSelection.resolve(hub.agentUsage, preferred: preferred, active: hub.runningAgent?.source,
                                           apiEnabled: quickReplySource == .api, today: apiUsage.today) {
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
    var viewportHeight: CGFloat
    var previewColorScheme: ColorScheme
    var listHeightChanged: (CGFloat) -> Void = { _ in }
    var body: some View {
        AgentSessionsPage(selectedID: $selectedID, viewportHeight: viewportHeight,
                          listHeightChanged: listHeightChanged)
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
            if activity?.kind == "agent" || activity?.kind == "agent-quota-reset" || activity?.isGeneratingAgentReply == true,
               let icon = AgentApplicationIcons.icon(for: source) {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: activity?.kind == "agent-quota-reset" && source == "gemini"
                      ? "sparkles" : activity?.symbol ?? "circle")
                    .resizable().scaledToFit().padding(3)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(activity?.kind == "agent" ? source : activity?.title ?? "活动")
    }
}

@MainActor
enum AgentApplicationIcons {
    static var cache: [String: NSImage] = [:]
    static var agentNotchURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.github.lihao505.AgentNotch")
    }
    @discardableResult
    static func open(activity: IslandActivity) -> Bool {
        let source = activity.source ?? ""
        if source == "codex", let id = activity.sessionID ?? activity.conversationID,
           UUID(uuidString: id) != nil,
           let url = URL(string: "codex://threads/\(id)"),
           NSWorkspace.shared.open(url) { return true }
        return open(source: source)
    }

    @discardableResult
    static func open(source: String) -> Bool {
        let identifiers = ["codex": "com.openai.codex", "gpt": "com.openai.codex", "claude": "com.anthropic.claudefordesktop", "codebuddy": "com.tencent.codebuddy", "workbuddy": "com.workbuddy.workbuddy-ai", "antigravity": "com.google.antigravity"]
        guard let id = identifiers[source.lowercased()],
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
    static func icon(for source: String) -> NSImage? {
        if let image = cache[source] { return image }
        let identifiers = [
            "codex": "com.openai.codex", "gpt": "com.openai.codex",
            "claude": "com.anthropic.claudefordesktop",
            "codebuddy": "com.tencent.codebuddy", "workbuddy": "com.workbuddy.workbuddy-ai",
            "antigravity": "com.google.antigravity",
            "gemini": "com.google.gemini", "doubao": "com.bot.pc.doubao"
        ]
        guard let identifier = identifiers[source],
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[source] = image
        return image
    }
}
