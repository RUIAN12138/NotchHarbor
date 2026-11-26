"""Exercise the production Desktop log reducer with real-format records."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
checks = r'''
import Foundation

@main struct Check {
    static func main() throws {
        let clock = ISO8601DateFormatter()
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = clock.date(from: "2026-11-25T02:44:43.000Z")!
        let finished = clock.date(from: "2026-11-25T02:48:45.000Z")!
        let session = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let request = "2026-11-25T02:44:42.708Z info [electron-message-handler] [desktop-notifications] received approval conversationId=\(session) kind=permissionRequest rendererWindowFocused=true requestId=7"
        let response = "2026-11-25T02:48:44.761Z info [host-app-server-manager] Sending server response id=7 method=item/permissions/requestApproval response={}"
        let start = CodexDesktopApprovals.event(request, run: "desktop-run", clock: clock)!
        let end = CodexDesktopApprovals.event(response, run: "desktop-run", clock: clock)!
        let anotherRun = CodexDesktopApprovals.event(response, run: "another-run", clock: clock)!
        let duplicate = CodexDesktopApprovals.event(request.replacingOccurrences(of: ".708Z", with: ".709Z"),
                                                       run: "desktop-run", clock: clock)!
        let rows = CodexDesktopApprovals.requests(from: [start, duplicate], now: now)
        precondition(rows.count == 1 && rows[0].sessionID == session && rows[0].route == "desktop" && rows[0].command == nil)
        precondition(CodexDesktopApprovals.requests(from: [start, anotherRun], now: finished) == rows)
        precondition(CodexDesktopApprovals.requests(from: [end, start], now: finished).isEmpty)
        precondition(CodexDesktopApprovals.requests(from: [start], now: now.addingTimeInterval(26 * 3600)).isEmpty)
        for event in ["show approval", "show notification"] {
            let alternative = request.replacingOccurrences(of: "received approval", with: event)
            precondition(CodexDesktopApprovals.event(alternative, run: "desktop-run", clock: clock) == start)
        }
        let normalNotification = request.replacingOccurrences(of: "received approval", with: "show notification")
            .replacingOccurrences(of: "kind=permissionRequest", with: "kind=turnComplete")
        precondition(CodexDesktopApprovals.event(normalNotification, run: "desktop-run", clock: clock) == nil)
        precondition(CodexDesktopApprovals.requests(from: [end], now: finished).isEmpty)
        let longPending = now.addingTimeInterval(27 * 60)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let file = directory.appendingPathComponent("desktop-main.log")
        let noise = String(repeating: "unrelated desktop entry with no approval metadata\n", count: 18_000)
        try (request + "\n" + noise).write(to: file, atomically: true, encoding: .utf8)
        var cursor = CodexDesktopApprovals.Cursor()
        CodexDesktopApprovals.scan(file, run: "desktop-run", cursor: &cursor, now: longPending)
        precondition(CodexDesktopApprovals.requests(from: cursor.events, now: longPending).count == 1)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((response + "\n").utf8))
        try handle.close()
        CodexDesktopApprovals.scan(file, run: "desktop-run", cursor: &cursor, now: longPending)
        precondition(CodexDesktopApprovals.requests(from: cursor.events, now: longPending).isEmpty)
        try noise.write(to: file, atomically: true, encoding: .utf8)
        CodexDesktopApprovals.scan(file, run: "desktop-run", cursor: &cursor, now: longPending)
        precondition(cursor.events.isEmpty)
        print("PASS: desktop wait over 20 minutes, cold recovery behind busy logs, exact response, and rotated file isolation")
        typealias Labels = CodexDesktopApprovalPanel.DecisionLabels
        precondition(Labels.role("Allow once") == .allow && Labels.role("仅允许本次") == .allow)
        precondition(Labels.role("Deny") == .deny && Labels.role("拒绝") == .deny)
        precondition(Labels.role("本次允许") == .allow && Labels.role("本次允許") == .allow)
        precondition(Labels.role("本次允许 ⌘↵") == .allow && Labels.role("Allow once\u{00A0}Return") == .allow)
        precondition(Labels.role("拒绝\nEsc") == .deny && Labels.role("Deny ⎋") == .deny)
        precondition(Labels.role("Allow this conversation ⌘↵") == nil && Labels.role("允许本次对话使用 ↵") == nil)
        precondition(Labels.role("Always allow Esc") == nil && Labels.role("Allow once (all files)") == nil)
        precondition(Labels.role("Always allow") == nil && Labels.role("Allow this conversation") == nil)
        precondition(Labels.role("Allow") == nil && Labels.role("允许") == nil)
        let commandAllow = #"2026-11-25T02:48:45.100Z info [host-app-server-manager] Sending server response id=7 method=item/commandExecution/requestApproval response={"decision":"accept"}"#
        let permissionDeny = #"2026-11-25T02:48:45.200Z info [host-app-server-manager] Sending server response id=7 method=item/permissions/requestApproval response={"scope":"turn","permissions":{}}"#
        precondition(CodexDesktopApprovalPanel.receiptMatches(commandAllow, since: finished, choice: .allow, clock: clock))
        precondition(!CodexDesktopApprovalPanel.receiptMatches(commandAllow, since: finished, choice: .deny, clock: clock))
        precondition(CodexDesktopApprovalPanel.receiptMatches(permissionDeny, since: finished, choice: .deny, clock: clock))
        precondition(!CodexDesktopApprovalPanel.receiptMatches(permissionDeny, since: finished, choice: .allow, clock: clock))
        precondition(!CodexDesktopApprovalPanel.receiptMatches(commandAllow.replacingOccurrences(of: "accept", with: "acceptForSession"),
                                                               since: finished, choice: .allow, clock: clock))
        print("PASS: visible button scopes and matching one-time or denied native response")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="notch-desktop-approval-test-") as directory:
    folder = Path(directory)
    entry = folder / "check.swift"
    entry.write_text(checks)
    binary = folder / "check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path",
                    str(folder / "module-cache"), str(entry),
                    str(repo / "BoringNotchXPCHelper/CodexDesktopApprovals.swift"),
                    str(repo / "BoringNotchXPCHelper/CodexApprovalStore.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(folder)], check=True)
