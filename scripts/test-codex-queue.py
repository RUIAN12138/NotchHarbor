"""Test the production Codex queue path with a subprocess speaking its JSON-RPC protocol."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
helper = repo / "BoringNotchXPCHelper"
mock = r'''#!/usr/bin/python3
import json, pathlib, sys
root = pathlib.Path.cwd()
mode = root.joinpath("mode").read_text().strip()
expected_text = "保留换行\n--literal"
thread = "00000000-0000-0000-0000-0000000000a1"
if sys.argv[1] == "queue":
    assert mode.startswith("queue-")
    assert sys.argv[1:] == ["queue", "--thread", thread, "--message=" + expected_text]
    root.joinpath("submitted").open("a").write("cli\n")
    if mode == "queue-closed":
        sys.exit(2)
    target = thread if mode == "queue-success" else "00000000-0000-0000-0000-0000000000b2"
    print(f"Queued message 00000000-0000-0000-0000-0000000000e1 for thread {target}.")
    sys.exit(0)
request = json.loads(sys.stdin.readline())
assert request["method"] == "initialize"
assert mode.startswith("approval-")
print('{"id":1,"result":{}}', flush=True)
assert json.loads(sys.stdin.readline())["method"] == "initialized"
request = json.loads(sys.stdin.readline())
if mode.startswith("approval-"):
    assert request["method"] == "thread/resume"
    assert request["params"] == {"threadId": thread, "excludeTurns": True}
    print(json.dumps({"id": 2, "result": {"thread": {"id": thread}}}), flush=True)
    start = json.loads(sys.stdin.readline())
    assert start["method"] == "turn/start" and start["params"]["threadId"] == thread
    params = {"threadId": thread, "turnId": "turn-1", "command": "printf harmless-fixture",
              "cwd": str(root), "availableDecisions": ["accept", "decline", "cancel"]}
    if mode == "approval-scope":
        params["additionalPermissions"] = {"network": {"enabled": True}}
    if mode == "approval-wrong-thread":
        params["threadId"] = "00000000-0000-0000-0000-0000000000b2"
    # Includes an approval before the turn/start acknowledgment.
    print(json.dumps({"id": "live-request-2", "method": "item/commandExecution/requestApproval",
                      "params": params}), flush=True)
    print(json.dumps({"id": 3, "result": {"turn": {"id": "turn-1"}}}), flush=True)
    reply = json.loads(sys.stdin.readline())
    assert reply["id"] == "live-request-2"
    if mode in ("approval-scope", "approval-wrong-thread"):
        assert reply["error"]["code"] == -32601
    else:
        expected = "accept" if mode == "approval-allow" else "decline"
        assert reply["result"] == {"decision": expected}
    root.joinpath("submitted").write_text("checked")
    print(json.dumps({"method": "serverRequest/resolved",
                      "params": {"threadId": thread, "requestId": "live-request-2"}}), flush=True)
    print(json.dumps({"method": "turn/completed",
                      "params": {"threadId": thread, "turn": {"id": "turn-1", "status": "completed"}}}), flush=True)
    sys.exit(0)
raise AssertionError("Expected the CLI queue or a CLI-owned approval turn")
'''
checks = r'''
extension AgentMessagingService {
    func testQueue(binary: URL, cwd: URL, queueOnly: Bool = true) throws -> AgentInteractionResult {
        let thread = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
        let request = AgentInteractionRequest(operation: "send", source: "codex", sessionID: thread,
                                              text: "保留换行\n--literal")
        if queueOnly { return try enqueueWithCodexCLI(binary, request: request, cwd: cwd) }
        return try sendViaCodexServer(binary, request: request, cwd: cwd)
    }
}

@main struct Check {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let binary = root.appendingPathComponent("server")
        let record = root.appendingPathComponent("submitted")
        for mode in ["queue-success", "queue-wrong-thread", "queue-closed"] {
            try? FileManager.default.removeItem(at: record)
            try Data(mode.utf8).write(to: root.appendingPathComponent("mode"))
            let expectSuccess = mode == "queue-success"
            do {
                let result = try AgentMessagingService.shared.testQueue(binary: binary, cwd: root)
                precondition(expectSuccess && result.queued == true && result.delivered == nil)
            } catch {
                precondition(!expectSuccess, "Valid confirmation should return queued")
            }
            let trace = try String(contentsOf: record, encoding: .utf8)
            precondition(trace == "cli\n", "Each user send must enqueue at most once")
        }
        print("PASS: exact desktop thread and text, no resume or policy change, receipt binding and no automatic retries")
        for mode in ["approval-allow", "approval-deny", "approval-scope", "approval-wrong-thread"] {
            try? FileManager.default.removeItem(at: record)
            try Data(mode.utf8).write(to: root.appendingPathComponent("mode"))
            let tested = DispatchGroup()
            if mode == "approval-allow" || mode == "approval-deny" {
                tested.enter()
                DispatchQueue.global().async {
                    defer { tested.leave() }
                    let deadline = Date().addingTimeInterval(5)
                    let store = CodexServerApprovals.shared
                    while Date() < deadline {
                        if let approval = store.pending().first {
                            precondition(approval.command == "printf harmless-fixture")
                            precondition(approval.route == "app-server")
                            precondition(!store.choose(.allow, id: approval.id, sessionID: UUID()))
                            precondition(!store.choose(.native, id: approval.id, sessionID: approval.sessionID))
                            let actual: CodexApprovalPacket.Choice = mode == "approval-allow" ? .allow : .deny
                            precondition(store.choose(actual, id: approval.id, sessionID: approval.sessionID))
                            precondition(!store.choose(.allow, id: approval.id, sessionID: approval.sessionID))
                            return
                        }
                        Thread.sleep(forTimeInterval: 0.03)
                    }
                    preconditionFailure("no live approval shown")
                }
            }
            let result = try AgentMessagingService.shared.testQueue(binary: binary, cwd: root, queueOnly: false)
            tested.wait()
            precondition(result.delivered == true && result.error == nil)
            precondition(CodexServerApprovals.shared.pending().isEmpty)
            let trace = try String(contentsOf: record, encoding: .utf8)
            precondition(trace == "checked")
        }
        print("PASS: original wire IDs, explicit allow/deny, one-shot choices, mismatched thread and extra permissions rejected")

    }
}
'''
with tempfile.TemporaryDirectory(prefix="notch-codex-queue-") as directory:
    root = Path(directory)
    server = root / "server"
    server.write_text(mock)
    server.chmod(0o700)
    entry = root / "Check.swift"
    entry.write_text((helper / "AgentMessagingService.swift").read_text() + checks)
    output = root / "check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(root / "cache"),
                    str(entry), str(helper / "AntigravityACP.swift"),
                    str(helper / "BoringNotchXPCHelperProtocol.swift"),
                    str(helper / "CodexDesktopDelivery.swift"),
                    str(helper / "CodexApprovalStore.swift"), "-o", str(output)], check=True)
    subprocess.run([str(output), str(root)], check=True)
