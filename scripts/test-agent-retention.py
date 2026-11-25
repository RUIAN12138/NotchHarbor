"""Completed sessions outlive the transient notification and survive app restarts."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
model = (root / 'boringNotch/components/Notch/UnifiedActivities.swift').read_text().split('private enum AgentActivityFilter:')[0]
checks = r'''
extension UnifiedActivities {
    @MainActor func refreshTestCodexApprovals() { refreshCodexApprovals() }
    func receiveTestAgents(_ items: [IslandActivity]) throws {
        receiveAgents(try JSONEncoder().encode(items))
    }
}

@main struct Check {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hub = UnifiedActivities(observeSystem: false, storageURL: folder)
        let now = Date().timeIntervalSince1970
        func session(_ id: String, phase: String, stamp: Double) -> IslandActivity {
            IslandActivity(id: id, kind: "agent", title: "Codex", detail: "fixture", symbol: "terminal",
                           priority: phase == "finished" ? 50 : 20, expires: Date().timeIntervalSince1970 + 0.1,
                           source: "codex", progress: AgentProgress(phase: phase, observedAt: stamp, children: []))
        }
        let done = session("one", phase: "finished", stamp: now)
        try hub.receiveTestAgents([done])
        precondition(hub.agentSessions == [done])
        try await Task.sleep(for: .milliseconds(250))
        precondition(hub.activities.isEmpty)
        precondition(hub.agentSessions == [done])
        try hub.receiveTestAgents([])
        precondition(hub.agentSessions == [done])
        let restored = UnifiedActivities(observeSystem: false, storageURL: folder)
        precondition(restored.agentSessions == [done])
        let approvalRoot = folder.appendingPathComponent("private", isDirectory: true)
        let approvalFolder = approvalRoot.appendingPathComponent("approvals", isDirectory: true)
        try FileManager.default.createDirectory(at: approvalRoot, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: approvalFolder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let approvalHub = UnifiedActivities(observeSystem: false,
            storageURL: folder.appendingPathComponent("approval-history"), approvalDirectory: approvalFolder)
        let request = CodexApprovalRequest(id: UUID(), sessionID: UUID(), tool: "Bash", cwd: "/tmp/example",
            reason: "test approval", command: "/usr/bin/true", createdAt: now, expires: now + 55, pid: getpid())
        let requestURL = approvalFolder.appendingPathComponent(request.id.uuidString.lowercased() + ".json")
        try JSONEncoder().encode(request).write(to: requestURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
        var underlying = session(request.sessionActivityID, phase: "processing", stamp: now)
        underlying.sessionID = request.sessionID.uuidString
        underlying.expires = now + 50
        try approvalHub.receiveTestAgents([underlying])
        approvalHub.refreshTestCodexApprovals()
        let popup = approvalHub.proactiveAlerts.first!
        precondition(approvalHub.hasPendingAgentApprovals && popup.hasPendingAgentApproval)
        precondition(approvalHub.agentSessions.count == 1 && approvalHub.agentSessions.first?.id == popup.id)
        precondition(approvalHub.agentSession(for: popup.id) == popup && approvalHub.codexApproval(for: popup) == request)
        precondition(FileManager.default.fileExists(atPath: requestURL.deletingPathExtension().appendingPathExtension("ready").path))
        try approvalHub.submitCodexApproval(.deny, request: request)
        let result = try String(contentsOf: requestURL.deletingPathExtension().appendingPathExtension("decision"), encoding: .utf8)
        precondition(result == "deny")
        do {
            try approvalHub.submitCodexApproval(.allow, request: request)
            preconditionFailure("A second decision must not overwrite the first")
        } catch {}
        try FileManager.default.removeItem(at: requestURL)
        approvalHub.refreshTestCodexApprovals()
        precondition(approvalHub.currentAgentAttention(for: popup.agentAttentionKey!) == nil)
        precondition(approvalHub.agentSessions == [underlying])
        print("PASS: live Codex request reaches both popup and session detail, single choice, fallback to working")
        let running = session("one", phase: "processing", stamp: now + 1)
        try hub.receiveTestAgents([running])
        precondition(hub.agentSessions.count == 1 && hub.agentSessions[0].progress?.phase == "processing")
        let newer = session("one", phase: "finished", stamp: now + 2)
        try hub.receiveTestAgents([newer])
        try hub.receiveTestAgents([done])
        try hub.receiveTestAgents([])
        precondition(hub.agentSessions == [newer])
        precondition(Set(AgentIslandPhase.allCases.map(\.symbol)).count == 7)
        let waiting = session("waiting", phase: "waiting_for_input", stamp: now + 3)
        let tool = session("tool", phase: "running_tool", stamp: now + 4)
        try hub.receiveTestAgents([tool, waiting])
        precondition(hub.wingActivity?.id == waiting.id)
        precondition(hub.agentSessions.map(\.id) == ["tool", "waiting", "one"])
        let recentlyFinished = session("recent", phase: "finished", stamp: now + 5)
        try hub.receiveTestAgents([recentlyFinished, waiting, tool])
        precondition(hub.agentSessions.map(\.id) == ["recent", "tool", "waiting", "one"])
        precondition(hub.wingActivity?.id == waiting.id)
        hub.announceAgentCompletion(newer, hasReplies: true)
        let notice = hub.proactiveAlerts.first { $0.isCompletedAgentSession }!
        precondition(notice.detail.contains("任务已完成"))
        precondition(hub.wingActivity?.id == waiting.id)
        let dismissedAt = ContinuousClock.now
        let replay = AgentCompletionHoverReplay(activity: notice, dismissedAt: dismissedAt)
        precondition(AgentCompletionHoverReplay.popupDuration == .seconds(2))
        let popupStart = ContinuousClock.now
        var countdown = CompactAlertCountdown(duration: .seconds(2), now: popupStart, paused: false)
        precondition(countdown.fractionRemaining(at: popupStart) == 1)
        precondition(countdown.fractionRemaining(at: popupStart + .seconds(1)) == 0.5)
        countdown.setPaused(true, at: popupStart + .seconds(1))
        precondition(countdown.isPaused && countdown.fractionRemaining(at: popupStart + .seconds(20)) == 0.5)
        countdown.setPaused(false, at: popupStart + .seconds(20))
        precondition(countdown.remaining(at: popupStart + .milliseconds(20_500)) == .milliseconds(500))
        precondition(countdown.remaining(at: popupStart + .seconds(21)) == .zero)
        precondition(countdown.fractionRemaining(at: popupStart + .seconds(30)) == 0)
        let hoveredOnOpen = CompactAlertCountdown(duration: .seconds(4), now: popupStart, paused: true)
        precondition(hoveredOnOpen.remaining(at: popupStart + .seconds(10)) == .seconds(4))
        precondition(AgentCompletionHoverReplay.replyPopupDuration(headphonesConnected: false, headControlEnabled: false) == .seconds(2))
        precondition(AgentCompletionHoverReplay.replyPopupDuration(headphonesConnected: true, headControlEnabled: false) == .seconds(5))
        precondition(AgentCompletionHoverReplay.replyPopupDuration(headphonesConnected: false, headControlEnabled: true) == .seconds(5))
        precondition(AgentCompletionHoverReplay.replyPopupDuration(headphonesConnected: true, headControlEnabled: true) == .seconds(5))
        precondition(replay.activity(at: dismissedAt - .milliseconds(1)) == nil)
        precondition(replay.activity(at: dismissedAt) == notice)
        precondition(replay.activity(at: dismissedAt + .milliseconds(14_999)) == notice)
        precondition(replay.activity(at: dismissedAt + .seconds(15)) == nil)
        precondition(hub.consumeAgentCompletionPopup(notice.id))
        precondition(!hub.consumeAgentCompletionPopup(notice.id))
        hub.announceAgentCompletion(newer, hasReplies: false)
        precondition(!hub.proactiveAlerts.contains { $0.id == notice.id })
        precondition(hub.agentSessions.contains(newer))
        try hub.receiveTestAgents([])
        let batch = (0..<20).map { session("task-\($0)", phase: "finished", stamp: now + Double($0 + 3)) }
        try hub.receiveTestAgents(Array(batch.prefix(16)))
        try hub.receiveTestAgents(Array(batch.suffix(4)))
        precondition(hub.agentSessions.count == 2)
        try hub.receiveTestAgents([])
        precondition(hub.agentSessions.count == 2)
        precondition(hub.agentSessions.map(\.id) == ["task-19", "task-18"])
        precondition(hub.agentSession(for: "task-17") == batch[17],
                     "A detail stays open when its row falls out of the newest two")
        let stale = session("stale", phase: "finished", stamp: now - UnifiedActivities.agentSessionLifetime - 60)
        try hub.receiveTestAgents([stale])
        try hub.receiveTestAgents([])
        precondition(!hub.agentSessions.contains { $0.id == stale.id })
        var other = session("other-provider", phase: "finished", stamp: now + 21)
        other.source = "claude"
        try hub.receiveTestAgents([other])
        precondition(hub.agentSessions.contains(other) && hub.agentSessions.filter { $0.source == "codex" }.count == 2)
        let restarted = UnifiedActivities(observeSystem: false, storageURL: folder)
        precondition(restarted.agentSessions == hub.agentSessions)
        let failed = session("failure", phase: "failed", stamp: now + 50)
        try hub.receiveTestAgents([failed])
        try hub.receiveTestAgents([])
        precondition(hub.agentSessions.contains { $0.id == failed.id })
        let alertHub = UnifiedActivities(observeSystem: false, storageURL: folder.appendingPathComponent("alerts"))
        precondition(AgentCompletionHaloSettings.normalizedDuration(.nan) == 8)
        precondition(AgentCompletionHaloSettings.normalizedDuration(-1) == 0)
        precondition(AgentCompletionHaloSettings.normalizedDuration(9) == 9)
        precondition(AgentCompletionHaloSettings.normalizedDuration(35) == 20)

        let closedAt = Date(timeIntervalSince1970: now)
        precondition(AgentCompletionHaloSettings.readyTime(afterClosingAt: closedAt, reduceMotion: true) == closedAt)
        precondition(AgentCompletionHaloSettings.readyTime(afterClosingAt: closedAt, reduceMotion: false)
            >= closedAt.addingTimeInterval(0.45))
        let finished = (0..<5).map { session("done-\($0)", phase: "finished", stamp: now + 1) }
        try alertHub.receiveTestAgents(finished)
        precondition(alertHub.completedAgentSessions.count == 5)
        try alertHub.receiveTestAgents(finished)
        precondition(alertHub.completedAgentSessions.count == 5)
        let question = session("request", phase: "waiting_for_input", stamp: now)
        try alertHub.receiveTestAgents([question])
        let key = question.agentAttentionKey!
        precondition(alertHub.proactiveAlerts.contains { $0.agentAttentionKey == key })
        let questionHeartbeat = session("request", phase: "waiting_for_input", stamp: now + 1)
        try alertHub.receiveTestAgents([questionHeartbeat])
        precondition(questionHeartbeat.agentAttentionKey == key && alertHub.currentAgentAttention(for: key) != nil)
        let approval = session("request", phase: "waiting_for_approval", stamp: now + 2)
        try alertHub.receiveTestAgents([approval])
        precondition(alertHub.currentAgentAttention(for: key) == nil)
        precondition(alertHub.currentAgentAttention(for: approval.agentAttentionKey!) != nil)
        precondition(alertHub.hasPendingAgentApprovals)
        try alertHub.receiveTestAgents([])
        precondition(!alertHub.hasPendingAgentApprovals)
        precondition(alertHub.agentSession(for: approval.id)?.progress?.phase == "idle")
        precondition(alertHub.agentSession(for: approval.id)?.agentAttentionKey == nil)
        let reopenedAlerts = UnifiedActivities(observeSystem: false, storageURL: folder.appendingPathComponent("alerts"))
        precondition(reopenedAlerts.agentSession(for: approval.id)?.progress?.phase == "idle")
        precondition(!reopenedAlerts.hasPendingAgentApprovals)
        try alertHub.receiveTestAgents([approval])
        precondition(!alertHub.hasPendingAgentApprovals, "An old approval cannot reappear after stop")
        let laterApproval = session("request", phase: "waiting_for_approval", stamp: now + 2.5)
        try alertHub.receiveTestAgents([laterApproval])
        precondition(alertHub.hasPendingAgentApprovals, "A genuinely new request still appears")
        try alertHub.receiveTestAgents([approval])
        precondition(alertHub.agentSession(for: approval.id) == laterApproval, "An older snapshot cannot replace live state")
        try alertHub.receiveTestAgents([session("request", phase: "processing", stamp: now + 3)])
        precondition(alertHub.currentAgentAttention(for: approval.agentAttentionKey!) == nil)
        let stopped = session("request", phase: "finished", stamp: now + 4)
        try alertHub.receiveTestAgents([stopped])
        try alertHub.receiveTestAgents([laterApproval])
        precondition(!alertHub.hasPendingAgentApprovals)
        precondition(alertHub.agentSession(for: stopped.id) == stopped)

        let expiryFolder = folder.appendingPathComponent("expiry")
        let expiryHub = UnifiedActivities(observeSystem: false, storageURL: expiryFolder)
        let recentUntil = Date().timeIntervalSince1970 + 0.2
        var expiring = session("expires", phase: "finished", stamp: recentUntil - UnifiedActivities.agentSessionLifetime)
        expiring.expires = recentUntil - 120
        try expiryHub.receiveTestAgents([expiring])
        precondition(expiryHub.agentSession(for: expiring.id) == expiring)
        let cachedHistory = expiryFolder.appendingPathComponent("completed-agents.json")
        var stored = try JSONDecoder().decode([IslandActivity].self, from: Data(contentsOf: cachedHistory))
        precondition(stored == [expiring])
        try await Task.sleep(for: .milliseconds(350))
        precondition(expiryHub.agentSession(for: expiring.id) == nil)
        stored = try JSONDecoder().decode([IslandActivity].self, from: Data(contentsOf: cachedHistory))
        precondition(stored.isEmpty, "The expiry timer prunes the stored snapshot without another event")

        func provider(at sample: Double, reset: Double, used: Double) -> AgentProviderUsage {
            .init(id: "gemini", updatedAt: sample,
                  windows: [.init(usedPercent: used, windowMinutes: 300, resetsAt: reset, label: nil)],
                  billing: nil, localTokens30Days: nil)
        }
        let before = provider(at: now - 60, reset: now - 5, used: 90)
        let after = provider(at: now, reset: now + 18_000, used: 0)
        precondition(UnifiedActivities.quotaResetAlerts(previous: [], current: [after], now: now).isEmpty)
        precondition(UnifiedActivities.quotaResetAlerts(previous: [after], current: [after], now: now).isEmpty)
        let reset = UnifiedActivities.quotaResetAlerts(previous: [before], current: [after], now: now)
        precondition(reset.count == 1 && reset[0].source == "gemini" && reset[0].detail == "5 小时")
        precondition(UnifiedActivities.quotaResetAlerts(previous: [before], current: [after], now: now + 3600).isEmpty)
        print("PASS: completion history deduplication, configurable halo bounds, compact countdown pause/resume, stable question/approval keys and resolved requests")
        print("PASS: distinct phases, attention order, once-only automatic popup and 15-second hover replay, completion expiry, empty snapshots, restart, active-session precedence, stale updates, two per provider, details independent of the list, automatic cache expiry and failed replies")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='boring-agent-retention-') as folder:
    work = Path(folder)
    (work / 'Check.swift').write_text(model + checks)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(work / 'Check.swift'),
                    str(root / 'boringNotch/components/Notch/DeviceActivity.swift'),
                    str(root / 'boringNotch/components/Notch/AgentConversationHistory.swift'),
                    '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True)
