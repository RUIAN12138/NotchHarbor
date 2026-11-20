"""Exercise session targeting, no delayed sends, and context freshness without model calls."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
activity_source = (root / 'boringNotch/components/Notch/UnifiedActivities.swift').read_text()
model = activity_source.split('private enum AgentActivityFilter:')[0]
metrics = activity_source[activity_source.index('enum AgentSessionListMetrics {'):activity_source.index('private struct AgentSessionsPage:')]
checks = r'''
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
    let missing = try apiFixture(Array(replies.prefix(2)))
    precondition(AgentSuggestionAPI.replyOptions(in: missing) == nil)
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
    precondition(AgentSessionListMetrics.extraHeight(for: 0) == 0)
    precondition(AgentSessionListMetrics.extraHeight(for: 2) == 0)
    precondition(AgentSessionListMetrics.extraHeight(for: 3) == 37)
    precondition(AgentSessionListMetrics.extraHeight(for: 4) == 74)
    precondition(AgentSessionListMetrics.extraHeight(for: 20) == 74)
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
            progress: AgentProgress(phase: phase, observedAt: now + tick, children: []))
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
    let client = AgentInteraction(hub: hub) { request, reply in sent.append(request); finish = reply }
    let messages = [AgentConversationMessage(id: 1, role: "assistant", text: "布局已完成")]
    client.generate(source: "codex", id: id, messages: messages)
    precondition(sent.count == 1 && sent[0].operation == "suggest")
    client.generate(source: "codex", id: id, messages: messages)
    precondition(sent.count == 1) // Coalesces duplicate clicks.
    finish?(.init(suggestions: ["检查间距", "检查标题"]))
    client.generate(source: "codex", id: id, messages: messages)
    precondition(sent.count == 1) // Same context reuses model output.
    let changed = [AgentConversationMessage(id: 2, role: "assistant", text: "测试已通过")]
    client.updateContext(id: id, messages: changed)
    precondition(client.state(id).suggestions.isEmpty)
    client.generate(source: "codex", id: id, messages: changed)
    client.updateContext(id: id, messages: messages)
    finish?(.init(suggestions: ["过期一", "过期二"]))
    precondition(client.state(id).suggestions.isEmpty) // Ignore stale in-flight generation.
    try hub.receiveFixture([session("processing")])
    precondition(hub.resumableAgentDetailID == nil)
    hub.lastViewedAgentID = "test"
    precondition(hub.resumableAgentDetailID == "test")
    client.send("检查标题", source: "codex", id: id)
    precondition(sent.count == 3 && sent.last?.text == "检查标题")
    finish?(.init(busy: true))
    precondition(client.state(id).unsentReply == "检查标题")
    try hub.receiveFixture([session("finished")])
    precondition(hub.resumableAgentDetailID == nil)
    try await Task.sleep(for: .milliseconds(30))
    precondition(sent.count == 3 && client.state(id).unsentReply == "检查标题")
    client.dismissUnsent(id)
    client.send("检查间距", source: "codex", id: id)
    precondition(sent.count == 4 && sent.last?.sessionID == id && sent.last?.text == "检查间距")
    client.send("不可重复", source: "codex", id: id)
    precondition(sent.count == 4)
    finish?(.init(text: "ok"))
    precondition(!client.state(id).sending && client.state(id).unsentReply == nil)
    client.send("第二个会话", source: "claude", id: second)
    precondition(sent.count == 5 && sent.last?.sessionID == second && sent.last?.source == "claude")
    finish?(.init(error: "test failure"))
    precondition(!client.state(second).sending && sent.count == 5)
    precondition(client.state(second).unsentReply == "第二个会话")
    let completed = session("finished")
    try hub.receiveFixture([completed])
    client.prepareCompletion(completed, load: { changed }) { ready in
        hub.announceAgentCompletion(completed, hasReplies: ready)
    }
    try await Task.sleep(for: .milliseconds(30))
    precondition(sent.last?.operation == "suggest" && sent.last?.sessionID == id)
    precondition(hub.proactiveAlert == nil)
    precondition(hub.wingActivity?.isGeneratingAgentReply == true)
    precondition(hub.wingActivity?.detail == "正在生成快捷回复")
    finish?(.init(replyOptions: replies))
    try await Task.sleep(for: .milliseconds(320))
    precondition(hub.proactiveAlert?.detail == "快捷回复已准备好")
    precondition(hub.wingActivity?.isGeneratingAgentReply != true)
    precondition(client.state(id).suggestions.count == 3)
    precondition(client.state(id).detailReplyOptions == replies)
    let notice = hub.proactiveAlert!
    let options = client.completionReply(for: notice)!
    precondition(options.options[1].title == "总结测试结果")
    precondition(!client.sendCompletionReply(options, choice: 3, for: notice))
    precondition(client.sendCompletionReply(options, choice: 1, for: notice))
    precondition(sent.last?.sessionID == id && sent.last?.text == replies[1].body)
    precondition(sent.last?.text != options.options[1].title)
    precondition(!client.sendCompletionReply(options, choice: 0, for: notice))
    finish?(.init(error: "fixture recovery"))
    precondition(client.sendCompletionReply(options, choice: 2, for: notice))
    precondition(sent.last?.sessionID == id && sent.last?.text == replies[2].body)
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
    precondition(sent.last?.text == "只检查排版，不修改文件" && sent.last?.sessionID == id)
    finish?(.init(error: "temporary failure"))
    precondition(client.draft(for: id) == "只检查排版，不修改文件")
    client.sendDraft(source: "codex", id: id)
    finish?(.init(delivered: true))
    precondition(client.draft(for: id).isEmpty && client.draft(for: second) == "另一个会话的草稿")
    precondition(client.state(id).status == "已发送至 Codex")
    let interrupted = session("finished")
    try hub.receiveFixture([interrupted])
    var interruptedNotice = false
    client.prepareCompletion(interrupted, load: { messages }) { _ in interruptedNotice = true }
    try await Task.sleep(for: .milliseconds(30))
    precondition(hub.wingActivity?.isGeneratingAgentReply == true)
    try hub.receiveFixture([session("processing")])
    finish?(.init(replyOptions: replies))
    try await Task.sleep(for: .milliseconds(250))
    precondition(!interruptedNotice)
    precondition(hub.wingActivity?.isGeneratingAgentReply != true)
    var gemini = completed
    gemini.id = "gemini-fixture"
    gemini.source = "gemini"
    gemini.title = "Gemini · 已完成"
    client.prepareCompletion(gemini) { ready in
        precondition(!ready)
        hub.announceAgentCompletion(gemini, hasReplies: ready)
    }
    hub.announceAgentCompletion(gemini, hasReplies: false)
    precondition(hub.proactiveAlerts.filter { $0.source == "gemini" }.count == 1)
    hub.setWeather(city: "北京", summary: "晴")
    precondition(hub.proactiveAlerts.allSatisfy { $0.kind != "weather" })
    hub.showCalendarAlert(id: "a", title: "事项一", date: Date())
    hub.showCalendarAlert(id: "b", title: "事项二", date: Date())
    precondition(hub.proactiveAlerts.filter { $0.kind == "calendar" }.count == 2)
    print("PASS: generation wing ends at ready popup, short titles paired with full sends, AI suggestions cached, stale results discarded, exact session targeting, no delayed delivery or automatic retry")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='notch-agent-reply-') as folder:
    folder = Path(folder)
    (folder / 'Check.swift').write_text(model + metrics + checks)
    files = [folder / 'Check.swift', root / 'boringNotch/components/Notch/DeviceActivity.swift',
             root / 'boringNotch/components/Notch/AgentConversationHistory.swift',
             root / 'boringNotch/components/Notch/AgentInteraction.swift',
             root / 'boringNotch/components/Notch/AgentUsageMenu.swift',
             root / 'boringNotch/components/Notch/AgentReplyMotion.swift',
             root / 'boringNotch/XPCHelperClient/BoringNotchXPCHelperProtocol.swift']
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', *map(str, files), '-o', str(folder / 'check')], check=True)
    subprocess.run([str(folder / 'check')], check=True)
