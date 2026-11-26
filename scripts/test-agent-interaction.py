"""Exercise session targeting, no delayed sends, and context freshness without model calls."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
activity_source = (root / 'boringNotch/components/Notch/UnifiedActivities.swift').read_text()
model = activity_source.split('private enum AgentActivityFilter:')[0]
metrics = activity_source[activity_source.index('enum AgentSessionListMetrics {'):activity_source.index('private struct AgentSessionsPage:')]
checks = r'''
@MainActor final class XPCHelperClient {
    static let shared = XPCHelperClient()
    func pendingCodexApprovals() async -> Data { Data() }
    func submitCodexApproval(id: UUID, sessionID: UUID, choice: String) async -> String { "notSent" }
}

extension UnifiedActivities {
    func receiveFixture(_ items: [IslandActivity]) throws { receiveAgents(try JSONEncoder().encode(items)) }
}
@main struct Check {
 @MainActor static func main() async throws {
    precondition(AgentSuggestionAPI.endpoint("https://api.example.org/v1/")?.path == "/v1/chat/completions")
    precondition(AgentSuggestionAPI.endpoint("http://api.example.org/v1") == nil)
    precondition(AgentSuggestionAPI.endpoint("https://api.example.org/v1?key=secret") == nil)
    let replies = [
        AgentReplyOption(title: "复查关键变更", body: "请再检查这轮修改涉及的文件，尤其是本次调整可能引起的回归。"),
        AgentReplyOption(title: "总结测试结果", body: "请汇总已经通过的测试、还没验证的场景，以及每项检查的实际结果。"),
        AgentReplyOption(title: "列出后续步骤", body: "请按优先级列出下一轮准备做的事，并说明哪些需要我先确认。")
    ]
    func apiFixture(_ options: [AgentReplyOption]) throws -> Data {
        let payload = try JSONEncoder().encode(["suggestions": options])
        return try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": String(decoding: payload, as: UTF8.self)]]]
        ])
    }
    let fixtureData = try apiFixture(replies)
    precondition(AgentSuggestionAPI.replyOptions(in: fixtureData) == replies)
    let duplicatedFixture = try apiFixture([replies[0], replies[0], replies[2]])
    precondition(AgentSuggestionAPI.replyOptions(in: duplicatedFixture) == nil)
    let long = AgentReplyOption(title: "复查具体问题", body: String(repeating: "字", count: 241))
    precondition(AgentReplyOptionBatch.validated([replies[0], replies[1], long]) == nil)
    let twoOptions = Array(replies.prefix(2))
    let shortResult = try apiFixture(twoOptions)
    precondition(AgentSuggestionAPI.replyOptions(in: shortResult) == twoOptions)
    let emptyResult = try apiFixture([])
    let tooMany = try apiFixture(replies + [.init(title: "额外", body: "额外回复")])
    precondition(AgentSuggestionAPI.replyOptions(in: emptyResult) == nil)
    precondition(AgentSuggestionAPI.replyOptions(in: tooMany) == nil)
    let prefs = UserDefaults(suiteName: "notch-reply-tests-" + UUID().uuidString)!
    precondition(AgentQuickReplySource.resolve(in: prefs) == .standard)
    prefs.set(true, forKey: AgentSuggestionAPI.enabledKey)
    precondition(AgentQuickReplySource.resolve(in: prefs) == .api)
    prefs.set("custom", forKey: AgentQuickReplySource.preferenceKey)
    precondition(AgentQuickReplySource.resolve(in: prefs) == .custom)
    let customized = AgentQuickReplySource.normalizedCustomReplies([
        .init(title: " ", body: "  请说明下一步。  "),
        .init(title: "忽略", body: "\n"),
        .init(title: "复查", body: "请复查当前改动。"),
        .init(title: "超出上限", body: "第四条")
    ])
    precondition(customized.map(\.title) == ["请说明下一步。", "复查"])
    let payload = try JSONEncoder().encode(AgentInteractionResult(suggestions: replies.map(\.body), replyOptions: replies))
    let roundTrip = try JSONDecoder().decode(AgentInteractionResult.self, from: payload)
    precondition(roundTrip.replyOptions == replies)
    precondition(AgentAPIUsageLedger.responseTokens(Data(#"{"usage":{"total_tokens":17}}"#.utf8)) == 17)
    precondition(AgentAPIUsageLedger.responseTokens(Data(#"{"usage":{"prompt_tokens":12,"completion_tokens":4}}"#.utf8)) == 16)
    precondition(AgentAPIUsageLedger.responseTokens(Data(#"{"usage":{"total_tokens":-4}}"#.utf8)) == nil)
    precondition(AgentAPIUsageLedger.responseTokens(fixtureData) == nil)
    var motion = AgentReplyHeadGesture()
    precondition(motion.update(yaw: 0, pitch: 0, at: 1.0) == nil)
    precondition(motion.update(yaw: -20, pitch: 0, at: 1.3) == nil)
    precondition(motion.update(yaw: 0, pitch: 0, at: 1.55) == .left)
    precondition(motion.update(yaw: 20, pitch: 0, at: 1.6) == nil)
    precondition(motion.update(yaw: 0, pitch: 0, at: 1.9) == nil)
    precondition(motion.update(yaw: 20, pitch: 0, at: 2.0) == nil)
    precondition(motion.update(yaw: 0, pitch: 0, at: 2.3) == .right)
    precondition(motion.update(yaw: 0, pitch: -20, at: 2.55) == nil)
    precondition(motion.update(yaw: 0, pitch: 0, at: 2.8) == .confirm)
    precondition(motion.update(yaw: 0, pitch: -20, at: 3.1) == nil)
    precondition(motion.update(yaw: 0, pitch: -20, at: 4.5) == nil)
    precondition(motion.update(yaw: 0, pitch: 0, at: 4.6) == nil)

    func actions(_ samples: [(Double, Double, Double)], allowsDismissal: Bool = true) -> [AgentReplyHeadGesture.Action] {
        var gesture = AgentReplyHeadGesture()
        return samples.compactMap { gesture.update(yaw: $0.1, pitch: $0.2, at: $0.0, allowsDismissal: allowsDismissal) }
    }
    var excursion = AgentReplyMotionExcursion()
    precondition(excursion.observe(yaw: 4, pitch: 5) == nil)
    precondition(excursion.observe(yaw: 12, pitch: 0) == .began)
    precondition(excursion.observe(yaw: 16, pitch: 2) == nil && excursion.active)
    precondition(excursion.observe(yaw: 8, pitch: 2) == nil && excursion.active)
    precondition(excursion.observe(yaw: 3, pitch: 2) == .ended)
    precondition(excursion.observe(yaw: 3, pitch: 2) == nil)
    precondition(excursion.observe(yaw: 0, pitch: -12) == .began)
    let fastShake: [(Double, Double, Double)] = [(0, 0, 0), (0.25, -20, 0), (0.37, 0, 0),
                                                (0.47, 21, 0), (0.54, 0, 0), (0.64, -21, 0), (0.75, 0, 0)]
    precondition(actions(fastShake).filter { $0 == .dismiss }.count == 1)
    precondition(!actions(fastShake).contains(.confirm))
    precondition(!actions(fastShake, allowsDismissal: false).contains(.dismiss))
    precondition(!actions(Array(fastShake.prefix(5))).contains(.dismiss))
    let separateTurns: [(Double, Double, Double)] = [(0, 0, 0), (0.25, -21, 0), (0.4, 0, 0), (0.61, 0, 0),
        (0.65, 21, 0), (0.8, 0, 0), (1.01, 0, 0), (1.05, -21, 0), (1.2, 0, 0)]
    precondition(actions(separateTurns) == [.left, .right, .left])
    precondition(actions([(0, 0, 0), (0.25, 0, -20), (0.45, 0, 0)]) == [.confirm])
    var headMotionPractice = AgentReplyMotionPractice()
    headMotionPractice.recognize(.confirm)
    precondition(headMotionPractice.completed == 0 && !headMotionPractice.passed)
    for action in actions(separateTurns) { headMotionPractice.recognize(action) }
    precondition(headMotionPractice.completed == 2 && !headMotionPractice.passed)
    headMotionPractice.recognize(.confirm)
    headMotionPractice.recognize(.confirm)
    precondition(headMotionPractice.completed == 3 && headMotionPractice.passed)
    let readout = AgentReplyAngleReadout()
    let neutral = AgentReplyMotionAngles(yaw: 0, pitch: 0, roll: 0)
    let turned = AgentReplyMotionAngles(yaw: -22, pitch: 11, roll: 5)
    readout.publish(neutral, at: 1)
    readout.publish(turned, at: 1.01)
    precondition(readout.angles == neutral)
    readout.publish(turned, at: 1.06)
    readout.publish(.init(yaw: .nan, pitch: 0, roll: 0), at: 1.2)
    precondition(readout.angles == turned)
    readout.clear()
    precondition(readout.angles == nil)
    readout.publish(turned, at: 0)
    precondition(readout.angles == turned)
    precondition(AgentReplyMotionAngles.displayOffset(0) == 0)
    precondition(AgentReplyMotionAngles.displayOffset(-64) == -1)
    precondition(AgentReplyMotionAngles.displayOffset(64) == 1)
    typealias List = AgentSessionListMetrics
    precondition(List.visibleRows(total: 0, expanded: false, previewIndex: nil) == 0)
    precondition(List.visibleRows(total: 3, expanded: false, previewIndex: nil) == 2)
    precondition(List.visibleRows(total: 3, expanded: false, previewIndex: 0) == 2)
    precondition(List.visibleRows(total: 3, expanded: false, previewIndex: 1) == 3)
    precondition(List.visibleRows(total: 2, expanded: false, previewIndex: 1) == 2)
    precondition(List.visibleRows(total: 20, expanded: true, previewIndex: nil) == 4)
    precondition(List.visibleRows(total: 20, expanded: true, previewIndex: 6) == 5)
    precondition(List.visibleRows(total: 20, expanded: true, previewIndex: 19) == 4)
    precondition(List.visibleRows(total: 5, expanded: false, previewIndex: nil, minimum: 3) == 3)
    precondition(List.visibleRows(total: 5, expanded: false, previewIndex: 2, minimum: 3) == 4)
    let doubaoHub = UnifiedActivities(observeSystem: false)
    var doubaoCalls: [AgentInteractionRequest] = []
    let doubaoID = UUID(uuidString: "00000000-0000-d0ba-002b-dc545d6b4b87")!
    let doubaoClient = AgentInteraction(hub: doubaoHub) { request, reply in
        doubaoCalls.append(request)
        switch request.operation {
        case "list":
            let updated = ISO8601DateFormatter().string(from: Date())
            reply(.init(text: #"{"result":{"sessions":[{"session_id":"12345678901234567","title":"豆包","updated_at":"\#(updated)"}]}}"#))
        case "history":
            reply(.init(text: #"[{"query":"问题","response":"**回复**"}]"#))
        default:
            reply(.init(text: "fixture", delivered: true))
        }
    }
    precondition(doubaoCalls.isEmpty && doubaoHub.agentSessions.isEmpty)
    var running = IslandActivity(id: doubaoID.uuidString.lowercased(), kind: "agent", title: "豆包 CLI · 正在处理",
        detail: "测试会话", symbol: "terminal", priority: 20, expires: Date().timeIntervalSince1970 + 60,
        source: "doubao", progress: .init(phase: "processing", observedAt: Date().timeIntervalSince1970, children: []),
        conversationID: doubaoID.uuidString.lowercased())
    try doubaoHub.receiveFixture([running])
    precondition(doubaoHub.agentSessions.first?.id == running.id)
    let doubaoHistory = try await doubaoClient.doubaoHistory(doubaoID)
    precondition(doubaoHistory.messages.map(\.role) == ["user", "assistant"])
    precondition(doubaoHistory.messages.last?.text == "**回复**")
    let secondRead = try await doubaoClient.doubaoHistory(doubaoID)
    precondition(secondRead.messages == doubaoHistory.messages && doubaoCalls.map(\.operation) == ["history"])
    running.progress?.phase = "waiting_for_approval"
    running.progress?.requestID = "first"
    try doubaoHub.receiveFixture([running])
    precondition(doubaoHub.proactiveAlerts.contains { $0.needsDoubaoApproval })
    precondition(doubaoHub.hasPendingAgentApprovals)
    let previousKey = running.agentAttentionKey
    running.progress?.requestID = "second"
    precondition(running.agentAttentionKey != previousKey)
    doubaoClient.send("这不是授权", source: "doubao", id: doubaoID)
    precondition(doubaoCalls.map(\.operation) == ["history"])
    running.progress?.phase = "finished"
    try doubaoHub.receiveFixture([running])
    precondition(!doubaoHub.hasPendingAgentApprovals)
    precondition(doubaoHub.agentSession(for: running.id)?.id == running.id)
    let recent = try await doubaoClient.recentDoubaoSessions()
    precondition(recent.first?.conversationID == doubaoID.uuidString.lowercased())
    doubaoHub.setRecentDoubaoSessions(recent)
    precondition(doubaoHub.agentSessions.count == 1)
    doubaoClient.send("继续", source: "doubao", id: doubaoID)
    precondition(doubaoCalls.last?.sessionID == doubaoID && doubaoCalls.last?.operation == "send")
    precondition(doubaoClient.state(doubaoID).deliveredAt != nil)
    let hub = UnifiedActivities(observeSystem: false)
    let clock = Date().timeIntervalSince1970
    let weekly = AgentUsageWindow(usedPercent: 20, windowMinutes: 10_080, resetsAt: clock+60, label: nil)
    let expired = AgentUsageWindow(usedPercent: 10, windowMinutes: 300, resetsAt: clock-60, label: nil)
    let provider = AgentProviderUsage(id: "claude", updatedAt: clock, windows: [weekly, expired], billing: nil, localTokens30Days: nil)
    precondition(provider.window(minutes: 300, at: clock) == nil)
    precondition(provider.window(minutes: 10_080, at: clock)?.remaining == 80)
    let stale = AgentProviderUsage(id: "codex", updatedAt: clock-86_400, windows: [weekly], billing: nil, localTokens30Days: nil)
    precondition(stale.window(minutes: 10_080, at: clock) == nil)
    let api = AgentProviderUsage(id: "openai", updatedAt: clock, windows: [],
        billing: .init(currencyCode: "USD", used: 4.5, limit: 10, balance: nil), localTokens30Days: nil)
    precondition(provider.showsQuotaRings && !api.showsQuotaRings)
    precondition(AgentProviderUsage.selected(from: [provider, api], preferred: "openai", active: "claude")?.id == "openai")
    precondition(AgentProviderUsage.selected(from: [provider, api], preferred: "", active: "claude")?.id == "claude")
    precondition(AgentUsageSelection.compactBilling(api) != nil)
    let shortWindow = AgentUsageWindow(usedPercent: 80, windowMinutes: 300, resetsAt: clock+14_400, label: nil)
    precondition(provider.exhaustion(for: shortWindow, at: clock) == .beforeReset(Date(timeIntervalSince1970: clock+900)))
    precondition(provider.exhaustion(for: shortWindow, at: clock+901) == .unavailable)
    let sustainable = AgentUsageWindow(usedPercent: 10, windowMinutes: 300, resetsAt: clock+14_400, label: nil)
    precondition(provider.exhaustion(for: sustainable, at: clock) == .lastsUntilReset)
    let depleted = AgentUsageWindow(usedPercent: 100, windowMinutes: 300, resetsAt: clock+14_400, label: nil)
    precondition(provider.exhaustion(for: depleted, at: clock) == .depleted)
    let justStarted = AgentUsageWindow(usedPercent: 50, windowMinutes: 300, resetsAt: clock+17_995, label: nil)
    precondition(provider.exhaustion(for: justStarted, at: clock) == .unavailable)
    precondition(provider.exhaustion(for: expired, at: clock) == .unavailable)
    precondition(stale.exhaustion(for: shortWindow, at: clock) == .unavailable)
    precondition(AgentQuotaRings.outerMinutes == 300 && AgentQuotaRings.innerMinutes == 10_080)
    precondition(AgentQuotaRings.image(for: provider).isTemplate)
    if case .replyAPI = AgentUsageSelection.resolve([provider], preferred: AgentUsageSelection.replyAPIID,
                                                   active: "claude", apiEnabled: true, today: nil) {
    } else { preconditionFailure("Explicit reply API must override the active provider on both surfaces") }
    if case .provider(let selected) = AgentUsageSelection.resolve([provider, api], preferred: "",
                                                               active: "openai", apiEnabled: true, today: nil) {
        precondition(selected.id == "openai")
    } else { preconditionFailure("Automatic mode must follow the active provider") }
    let id = UUID(), second = UUID()
    let now = Date().timeIntervalSince1970
    var tick = 0.0
    func session(_ phase: String) -> IslandActivity {
        tick += 1
        return IslandActivity(id: "test", kind: "agent", title: "Codex", detail: "fixture", symbol: "terminal", priority: 20,
            expires: now + 600, source: "codex", sessionID: id.uuidString,
            progress: AgentProgress(phase: phase, observedAt: now - 2 + tick / 100, children: []))
    }
    let destinationCompletion = session("finished")
    var destinationNotice = destinationCompletion
    destinationNotice.id += ":completion:" + String(destinationCompletion.progress!.observedAt)
    var competingSession = destinationCompletion
    competingSession.id = "wrong-provider"
    competingSession.source = "gemini"
    precondition(destinationNotice.destinationAgentID(in: [competingSession, destinationCompletion]) == destinationCompletion.id)
    // A newer snapshot can recreate the row under a different activity ID.
    var refreshed = session("processing")
    refreshed.id = "refreshed"
    precondition(destinationNotice.destinationAgentID(in: [competingSession, refreshed]) == refreshed.id)
    precondition(destinationNotice.destinationAgentID(in: [competingSession]) == nil)
    var sent: [AgentInteractionRequest] = []
    var finish: ((AgentInteractionResult) -> Void)?
    let preferences = UserDefaults.standard
    let keys = [AgentQuickReplySource.preferenceKey, AgentQuickReplySource.customRepliesKey, AgentSuggestionAPI.autoGenerateKey]
    let previous = keys.map { preferences.object(forKey: $0) }
    defer {
        for (key, value) in zip(keys, previous) { preferences.set(value, forKey: key) }
    }
    var apiCalls = 0
    let client = AgentInteraction(hub: hub, fetchSuggestions: { _ in
        apiCalls += 1
        try? await Task.sleep(for: .milliseconds(75))
        return .init(replyOptions: twoOptions)
    }) { request, reply in sent.append(request); finish = reply }
    let messages = [AgentConversationMessage(id: 1, role: "assistant", text: "布局已完成")]
    preferences.set("api", forKey: AgentQuickReplySource.preferenceKey)
    async let first = client.generateAPIReplies(id: id, messages: messages)
    async let duplicate = client.generateAPIReplies(id: id, messages: messages)
    let pair = await (first, duplicate)
    precondition(pair.0 == twoOptions && pair.1 == twoOptions && apiCalls == 1 && sent.isEmpty)
    let cached = await client.generateAPIReplies(id: id, messages: messages)
    precondition(cached == twoOptions && apiCalls == 1)
    let changed = [AgentConversationMessage(id: 2, role: "assistant", text: "测试已通过")]
    client.updateContext(id: id, messages: changed)
    precondition(client.apiReplies(id: id, messages: changed).isEmpty)
    let pending = Task { await client.generateAPIReplies(id: id, messages: changed) }
    try await Task.sleep(for: .milliseconds(20))
    client.updateContext(id: id, messages: messages)
    let staleReplies = await pending.value
    precondition(staleReplies.isEmpty && client.state(id).replyOptions.isEmpty)
    preferences.set("standard", forKey: AgentQuickReplySource.preferenceKey)
    try hub.receiveFixture([session("processing")])
    precondition(hub.resumableAgentDetailID == nil)
    hub.lastViewedAgentID = "test"
    precondition(hub.resumableAgentDetailID == "test")
    client.send("检查标题", source: "codex", id: id)
    precondition(sent.count == 1 && sent.last?.text == "检查标题")
    finish?(.init(busy: true))
    precondition(client.state(id).unsentReply == "检查标题")
    try hub.receiveFixture([session("finished")])
    precondition(hub.resumableAgentDetailID == nil)
    try await Task.sleep(for: .milliseconds(30))
    precondition(sent.count == 1 && client.state(id).unsentReply == "检查标题")
    client.dismissUnsent(id)
    client.send("检查间距", source: "codex", id: id)
    precondition(sent.count == 2 && sent.last?.sessionID == id && sent.last?.text == "检查间距")
    client.send("不可重复", source: "codex", id: id)
    precondition(sent.count == 2)
    finish?(.init(text: "ok"))
    precondition(!client.state(id).sending && client.state(id).unsentReply == nil)
    client.send("第二个会话", source: "claude", id: second)
    precondition(sent.count == 3 && sent.last?.sessionID == second && sent.last?.source == "claude")
    finish?(.init(error: "test failure"))
    precondition(!client.state(second).sending && sent.count == 3)
    precondition(client.state(second).unsentReply == "第二个会话")
    let completed = session("finished")
    try hub.receiveFixture([completed])
    let formattedOutcome = AgentConversationMessage(id: 3, role: "assistant",
        text: "## 已修复 **播放问题** 和 `seek(1.0)`。回归通过。")
    precondition(AgentInteraction.completionSummary([formattedOutcome]) == "已修复 **播放问题** 和 `seek(1.0)`")
    let completedMessages = [AgentConversationMessage(id: 4, role: "assistant", text: "已修复进度条无法点击的问题。测试已通过。")]
    client.prepareCompletion(completed, load: { completedMessages }) { ready in
        hub.announceAgentCompletion(completed, hasReplies: ready)
    }
    try await Task.sleep(for: .milliseconds(120))
    precondition(apiCalls == 2 && sent.last?.operation == "send")
    let notice = hub.proactiveAlert!
    precondition(notice.detail == "已修复进度条无法点击的问题")
    let options = client.completionReply(for: notice)!
    precondition(options.options.count == 3 && options.options[0].body.contains("已修复进度条无法点击的问题"))
    precondition(!client.state(id).generating)
    precondition(client.completionReply(for: notice) == options)
    client.updateContext(id: id, messages: messages)
    precondition(client.completionReply(for: notice) == options)
    precondition(!client.sendCompletionReply(options, choice: 3, for: notice))
    precondition(client.sendCompletionReply(options, choice: 1, for: notice))
    precondition(sent.last?.sessionID == id && sent.last?.text == options.options[1].body)
    precondition(sent.last?.text != options.options[1].title)
    precondition(!client.sendCompletionReply(options, choice: 0, for: notice))
    finish?(.init(error: "fixture recovery"))
    precondition(client.sendCompletionReply(options, choice: 2, for: notice))
    precondition(sent.last?.sessionID == id && sent.last?.text == options.options[2].body)
    precondition(!client.sendCompletionReply(options, choice: 2, for: notice))
    finish?(.init(error: "fixture recovery"))
    try hub.receiveFixture([session("processing")])
    precondition(!client.sendCompletionReply(options, choice: 1, for: notice))
    hub.previewAgentReplyMotion()
    let practice = hub.proactiveAlerts.first { $0.id.hasPrefix(AgentReplyMotionSettings.previewPrefix) }!
    precondition(!client.sendCompletionReply(options, choice: 1, for: practice))
    hub.dismiss(practice.id)

    client.setDraft("只检查排版，不修改文件", for: id)
    client.setDraft("另一个会话的草稿", for: second)
    client.sendDraft(source: "codex", id: id)
    precondition(sent.last?.text == "只检查排版，不修改文件" && sent.last?.sessionID == id && sent.last?.immediate == true)
    finish?(.init(error: "temporary failure"))
    precondition(client.draft(for: id) == "只检查排版，不修改文件")
    client.sendDraft(source: "codex", id: id)
    finish?(.init(delivered: true))
    precondition(client.draft(for: id).isEmpty && client.draft(for: second) == "另一个会话的草稿")
    precondition(client.state(id).status == "已发送至 Codex")
    client.setDraft("这是排队回复", for: second)
    client.sendDraft(source: "codex", id: second)
    precondition(sent.last?.sessionID == second && sent.last?.text == "这是排队回复")
    finish?(.init(queued: true))
    precondition(client.draft(for: second) == "这是排队回复")
    precondition(client.state(second).status == "已在 Codex 原会话排队")
    precondition(client.state(second).deliveredAt == nil)

    let interrupted = session("finished")
    try hub.receiveFixture([interrupted])
    var interruptedNotice = false
    client.prepareCompletion(interrupted, load: {
        try? await Task.sleep(for: .milliseconds(800))
        return messages
    }) { _ in interruptedNotice = true }
    try hub.receiveFixture([session("processing")])
    try await Task.sleep(for: .milliseconds(900))
    precondition(!interruptedNotice)

    var gemini = session("finished")
    gemini.id = "gemini-fixture"
    gemini.source = "gemini"
    gemini.sessionID = nil
    gemini.conversationID = second.uuidString
    gemini.sessionTitle = "检查日历布局"
    gemini.title = "Gemini · 已完成"
    try hub.receiveFixture([gemini])
    client.prepareCompletion(gemini, load: {
        try? await Task.sleep(for: .milliseconds(1200))
        return completedMessages
    }) { ready in
        precondition(ready)
        hub.announceAgentCompletion(gemini, hasReplies: ready)
    }
    try await Task.sleep(for: .milliseconds(780))
    let geminiNotice = hub.proactiveAlerts.first { $0.source == "gemini" }!
    let geminiOptions = client.completionReply(for: geminiNotice)!
    precondition(geminiOptions.options.count == 3 && geminiNotice.detail.contains("检查日历布局"))
    precondition(client.sendCompletionReply(geminiOptions, choice: 1, for: geminiNotice))
    precondition(sent.last?.source == "gemini" && sent.last?.sessionID == second)
    finish?(.init(text: "已收到"))
    client.setDraft("继续核对第二项", for: second)
    client.sendDraft(source: "gemini", id: second)
    precondition(sent.last?.source == "gemini" && sent.last?.text == "继续核对第二项")
    finish?(.init(text: "已收到"))
    try await Task.sleep(for: .milliseconds(500))
    precondition(hub.agentCompletionSummary(for: geminiNotice) == "已修复进度条无法点击的问题")
    preferences.set("custom", forKey: AgentQuickReplySource.preferenceKey)
    preferences.set(try JSONEncoder().encode(Array(customized.prefix(1))), forKey: AgentQuickReplySource.customRepliesKey)
    let customCompletion = session("finished")
    try hub.receiveFixture([customCompletion])
    client.prepareCompletion(customCompletion, load: { completedMessages }) { ready in
        precondition(ready)
        hub.announceAgentCompletion(customCompletion, hasReplies: ready)
    }
    try await Task.sleep(for: .milliseconds(100))
    let customNotice = hub.proactiveAlerts.first { $0.progress?.observedAt == customCompletion.progress?.observedAt }!
    let customChoices = client.completionReply(for: customNotice)!
    precondition(customChoices.options == Array(customized.prefix(1)))
    precondition(client.sendCompletionReply(customChoices, choice: 0, for: customNotice))
    precondition(sent.last?.text == customized[0].body)
    finish?(.init(delivered: true))

    preferences.set("api", forKey: AgentQuickReplySource.preferenceKey)
    preferences.set(true, forKey: AgentSuggestionAPI.autoGenerateKey)
    let apiCompletion = session("finished")
    try hub.receiveFixture([apiCompletion])
    client.prepareCompletion(apiCompletion, load: { completedMessages }) { ready in
        precondition(ready)
        hub.announceAgentCompletion(apiCompletion, hasReplies: ready)
    }
    try await Task.sleep(for: .milliseconds(220))
    let apiNotice = hub.proactiveAlerts.first { $0.progress?.observedAt == apiCompletion.progress?.observedAt }!
    precondition(client.completionReply(for: apiNotice)?.options == twoOptions)
    precondition(apiCalls == 3)
    preferences.set("standard", forKey: AgentQuickReplySource.preferenceKey)
    let antigravityID = UUID()
    var antigravity = session("finished")
    antigravity.id = "antigravity-fixture"
    antigravity.source = "antigravity"
    antigravity.sessionID = nil
    antigravity.conversationID = antigravityID.uuidString
    try hub.receiveFixture([antigravity])
    client.setDraft("请继续核对", for: antigravityID)
    client.sendDraft(source: "antigravity", id: antigravityID)
    precondition(sent.last?.source == "antigravity" && sent.last?.sessionID == antigravityID
        && sent.last?.text == "请继续核对")
    finish?(.init(error: "未确认送达"))
    precondition(client.draft(for: antigravityID) == "请继续核对")
    precondition(client.state(antigravityID).unsentReply == "请继续核对")
    client.sendDraft(source: "antigravity", id: antigravityID)
    finish?(.init(delivered: true))
    precondition(client.draft(for: antigravityID).isEmpty)
    precondition(client.state(antigravityID).status == "已发送至 Antigravity")
    client.prepareCompletion(antigravity, load: { completedMessages }) { ready in
        precondition(ready)
        hub.announceAgentCompletion(antigravity, hasReplies: ready)
    }
    try await Task.sleep(for: .milliseconds(100))
    let antigravityNotice = hub.proactiveAlerts.first { $0.source == "antigravity" }!
    let antigravityChoices = client.completionReply(for: antigravityNotice)!
    precondition(client.sendCompletionReply(antigravityChoices, choice: 0, for: antigravityNotice))
    precondition(sent.last?.sessionID == antigravityID && sent.last?.text == antigravityChoices.options[0].body)
    finish?(.init(delivered: true))
    let monitorHub = UnifiedActivities(observeSystem: false)
    let monitoring = AgentInteraction(hub: monitorHub)
    monitoring.startCompletionMonitoring()
    preferences.set("standard", forKey: AgentQuickReplySource.preferenceKey)
    var lateCompletion = session("finished")
    lateCompletion.id = "bridge-late"
    lateCompletion.progress?.observedAt = Date().timeIntervalSince1970 - 35
    lateCompletion.expires = Date().timeIntervalSince1970 - 15
    try monitorHub.receiveFixture([lateCompletion])
    try await Task.sleep(for: .milliseconds(720))
    let latePopups = monitorHub.proactiveAlerts.filter { $0.id.hasPrefix("bridge-late:completion:") }
    precondition(latePopups.count == 1)
    precondition(monitorHub.consumeAgentCompletionPopup(latePopups[0].id))
    try monitorHub.receiveFixture([lateCompletion])
    precondition(monitorHub.proactiveAlerts.isEmpty)
    var stopped = lateCompletion
    stopped.id = "bridge-cancelled"
    stopped.title = "Codex · 本轮已停止"
    try monitorHub.receiveFixture([lateCompletion, stopped])
    precondition(monitorHub.proactiveAlerts.isEmpty)
    hub.setWeather(city: "北京", summary: "晴")
    precondition(hub.proactiveAlerts.allSatisfy { $0.kind != "weather" })
    hub.showCalendarAlert(id: "a", title: "事项一", date: Date())
    hub.showCalendarAlert(id: "b", title: "事项二", date: Date())
    precondition(hub.proactiveAlerts.filter { $0.kind == "calendar" }.count == 2)
    print("PASS: prompt completion with immediate choices and one-line summary, late summary, Codex, Gemini, and Antigravity exact session targeting, and no automatic retry")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='notch-agent-reply-') as folder:
    folder = Path(folder)
    (folder / 'Check.swift').write_text(model + metrics + checks)
    # This suite exercises state and transport logic. The SwiftUI view declarations
    # are compiled by the app target and don't need to load macros here.
    quota_source = (root / 'boringNotch/components/Notch/AgentUsageMenu.swift').read_text()
    (folder / 'AgentUsageModel.swift').write_text(quota_source.split('enum HarborMenuMetric:')[0])
    motion_source = (root / 'boringNotch/components/Notch/AgentReplyMotion.swift').read_text()
    (folder / 'AgentReplyModel.swift').write_text(motion_source.split('struct AgentPopupSummary:')[0])
    files = [folder / 'Check.swift', root / 'boringNotch/components/Notch/DeviceActivity.swift',
             root / 'boringNotch/components/Notch/AgentConversationHistory.swift',
             root / 'boringNotch/components/Notch/AgentInteraction.swift',
             folder / 'AgentUsageModel.swift',
             folder / 'AgentReplyModel.swift',
             root / 'boringNotch/XPCHelperClient/BoringNotchXPCHelperProtocol.swift']
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', *map(str, files), '-o', str(folder / 'check')], check=True)
    subprocess.run([str(folder / 'check')], check=True)
