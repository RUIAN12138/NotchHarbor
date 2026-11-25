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
        precondition(CodexDesktopApprovals.requests(from: [start], now: now.addingTimeInterval(1300)).isEmpty)
        precondition(CodexDesktopApprovals.event(request.replacingOccurrences(of: "received approval", with: "show notification"),
                                             run: "desktop-run", clock: clock) == nil)
        print("PASS: native request detection, exact lifecycle, cross-process isolation, expiration and duplicate suppression")
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
    subprocess.run([str(binary)], check=True)
