"""Completed sessions outlive the transient notification and survive app restarts."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
model = (root / 'boringNotch/components/Notch/UnifiedActivities.swift').read_text().split('private enum AgentActivityFilter:')[0]
checks = r'''
extension UnifiedActivities {
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
        hub.announceAgentCompletion(newer, hasReplies: true)
        let notice = hub.proactiveAlerts.first { $0.isCompletedAgentSession }!
        precondition(notice.detail.contains("快捷回复已准备好"))
        precondition(hub.wingActivity?.id == waiting.id)
        let dismissedAt = ContinuousClock.now
        let replay = AgentCompletionHoverReplay(activity: notice, dismissedAt: dismissedAt)
        precondition(AgentCompletionHoverReplay.popupDuration == .seconds(2))
        precondition(!AgentCompletionHoverReplay.canAutoDismiss(pointerInside: true, headActive: false))
        precondition(!AgentCompletionHoverReplay.canAutoDismiss(pointerInside: false, headActive: true))
        precondition(!AgentCompletionHoverReplay.canAutoDismiss(pointerInside: true, headActive: true))
        precondition(AgentCompletionHoverReplay.canAutoDismiss(pointerInside: false, headActive: false))
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
        precondition(hub.agentSessions.count == 3)
        try hub.receiveTestAgents([])
        precondition(hub.agentSessions.count == 3)
        precondition(hub.agentSessions.map(\.id) == ["task-19", "task-18", "task-17"])
        let restarted = UnifiedActivities(observeSystem: false, storageURL: folder)
        precondition(restarted.agentSessions == hub.agentSessions)
        let failed = session("failure", phase: "failed", stamp: now + 50)
        try hub.receiveTestAgents([failed])
        try hub.receiveTestAgents([])
        precondition(hub.agentSessions.contains { $0.id == failed.id })
        print("PASS: distinct phases, attention order, once-only automatic popup and 15-second hover replay, completion expiry, empty snapshots, restart, active-session precedence, stale updates, 3-session retention and failed replies")
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
