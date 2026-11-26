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
assert mode.startswith("approval-") or mode == "immediate-steer"
print('{"id":1,"result":{}}', flush=True)
assert json.loads(sys.stdin.readline())["method"] == "initialized"
request = json.loads(sys.stdin.readline())
if mode == "immediate-steer":
    assert request["method"] == "thread/resume" and request["params"]["threadId"] == thread
    print(json.dumps({"id": 2, "result": {"thread": {"id": thread}}}), flush=True)
    start = json.loads(sys.stdin.readline())
    assert start["method"] == "turn/start"
    print(json.dumps({"id": 3, "result": {"turn": {"id": "turn-1"}}}), flush=True)
    steer = json.loads(sys.stdin.readline())
    assert steer["method"] == "turn/steer"
    assert steer["params"] == {"threadId": thread, "expectedTurnId": "turn-1",
                               "input": [{"type": "text", "text": "立即补充\n--literal", "text_elements": []}]}
    print(json.dumps({"id": steer["id"], "result": {"turnId": "turn-1"}}), flush=True)
    root.joinpath("submitted").write_text("steered")
    print(json.dumps({"method": "turn/completed",
                      "params": {"threadId": thread, "turn": {"id": "turn-1", "status": "completed"}}}), flush=True)
    sys.exit(0)
if mode.startswith("approval-"):
    assert request["method"] == "thread/resume"
    assert request["params"] == {"threadId": thread, "excludeTurns": True}
    print(json.dumps({"id": 2, "result": {"thread": {"id": thread}}}), flush=True)
    start = json.loads(sys.stdin.readline())
    assert start["method"] == "turn/start" and start["params"]["threadId"] == thread
    params = {"threadId": thread, "turnId": "turn-1", "command": "printf harmless-fixture",
              "cwd": str(root), "availableDecisions": ["accept", "decline", "cancel"],
              "itemId": "item-1"}
    method = "item/commandExecution/requestApproval"
    wire_id = "live-request-2"
    changes = [{"path": str(root / "example.txt"), "kind": {"type": "update"}, "diff": "-old\n+new"}]
    file_scope = {"threadId": thread, "turnId": "turn-1"}
    permissions = {"fileSystem": {"read": [str(root / "example.txt")]}, "network": {"enabled": True}}
    if mode.startswith("approval-file-"):
        method = "item/fileChange/requestApproval"
        params = {**file_scope, "itemId": "item-1"}
        item = {"type": "fileChange", "id": "item-1", "changes": changes, "status": "inProgress"}
        print(json.dumps({"method": "item/started", "params": {**file_scope, "item": item}}), flush=True)
        if mode == "approval-file-grant-root":
            params["grantRoot"] = str(root)
    elif mode.startswith("approval-permission-"):
        method = "item/permissions/requestApproval"
        wire_id = 37
        if mode == "approval-permission-glob":
            permissions["fileSystem"]["entries"] = [{"access": "write", "path": {"type": "glob", "pattern": "**/*"}}]
        params = {**file_scope, "itemId": "item-1", "cwd": str(root), "permissions": permissions}
    if mode.startswith("approval-native-"):
        params["availableDecisions"] = ["accept", {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["printf"]}}, "cancel"]
    if mode == "approval-scope":
        params["additionalPermissions"] = {"network": {"enabled": True}}
    if mode == "approval-wrong-thread":
        params["threadId"] = "00000000-0000-0000-0000-0000000000b2"
    # Includes an approval before the turn/start acknowledgment.
    print(json.dumps({"id": wire_id, "method": method, "params": params}), flush=True)
    if mode == "approval-file-changed":
        changes[0]["diff"] = "-old\n+different"
        print(json.dumps({"method": "item/fileChange/patchUpdated",
                          "params": {**file_scope, "itemId": "item-1", "changes": changes}}), flush=True)
    print(json.dumps({"id": 3, "result": {"turn": {"id": "turn-1"}}}), flush=True)
    reply = json.loads(sys.stdin.readline())
    assert reply["id"] == wire_id
    if mode in ("approval-scope", "approval-wrong-thread", "approval-file-grant-root", "approval-permission-glob"):
        assert reply["error"]["code"] == -32601
    elif method == "item/permissions/requestApproval":
        expected = permissions if mode.endswith("-allow") else {}
        assert reply["result"] == {"permissions": expected, "scope": "turn"}
    else:
        expected = "accept" if mode.endswith("-allow") else "cancel" if mode == "approval-native-deny" else "decline"
        assert reply["result"] == {"decision": expected}
    root.joinpath("submitted").write_text("checked")
    print(json.dumps({"method": "serverRequest/resolved",
                      "params": {"threadId": thread, "requestId": wire_id}}), flush=True)
    print(json.dumps({"method": "turn/completed",
                      "params": {"threadId": thread, "turn": {"id": "turn-1", "status": "completed"}}}), flush=True)
    sys.exit(0)
raise AssertionError("Expected the CLI queue or a CLI-owned approval turn")
'''
checks = r'''
extension AgentMessagingService {
    func testQueue(binary: URL, cwd: URL, queueOnly: Bool = true, onAccepted: (() -> Void)? = nil) throws -> AgentInteractionResult {
        let thread = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
        let request = AgentInteractionRequest(operation: "send", source: "codex", sessionID: thread,
                                              text: "保留换行\n--literal")
        if queueOnly { return try enqueueWithCodexCLI(binary, request: request, cwd: cwd) }
        return try sendViaCodexServer(binary, request: request, cwd: cwd, onAccepted: onAccepted)
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
        let choices = ["approval-allow", "approval-deny", "approval-native-allow", "approval-native-deny",
                       "approval-file-allow", "approval-file-deny",
                       "approval-permission-allow", "approval-permission-deny"]
        let automatic = ["approval-scope", "approval-wrong-thread", "approval-file-changed",
                         "approval-file-grant-root", "approval-permission-glob"]
        for mode in choices + automatic {
            try? FileManager.default.removeItem(at: record)
            try Data(mode.utf8).write(to: root.appendingPathComponent("mode"))
            let tested = DispatchGroup()
            let received = DispatchSemaphore(value: 0)
            if choices.contains(mode) {
                tested.enter()
                DispatchQueue.global().async {
                    defer { tested.leave() }
                    let deadline = Date().addingTimeInterval(5)
                    let store = CodexServerApprovals.shared
                    while Date() < deadline {
                        if let approval = store.pending().first {
                            let example = root.appendingPathComponent("example.txt").path
                            if mode.hasPrefix("approval-file-") {
                                precondition(approval.tool == "文件变更")
                                precondition(approval.command == "修改 · \(example)\n-old\n+new")
                            } else if mode.hasPrefix("approval-permission-") {
                                precondition(approval.tool == "本轮权限")
                                precondition(approval.command == "联网 · 本轮\n读取 · \(example)")
                            } else {
                                precondition(approval.command == "printf harmless-fixture")
                            }
                            precondition(approval.route == "app-server")
                            precondition((approval.denialCancelsTurn == true) == mode.hasPrefix("approval-native-"))
                            precondition(!store.choose(.allow, id: approval.id, sessionID: UUID()))
                            precondition(!store.choose(.native, id: approval.id, sessionID: approval.sessionID))
                            let actual: CodexApprovalPacket.Choice = mode.hasSuffix("-allow") ? .allow : .deny
                            precondition(store.choose(actual, id: approval.id, sessionID: approval.sessionID) { confirmed in
                                precondition(confirmed, "Server must resolve the matching request before reporting success")
                                received.signal()
                            })
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
            if choices.contains(mode) { precondition(received.wait(timeout: .now() + 1) == .success) }
            precondition(result.delivered == true && result.error == nil)
            precondition(CodexServerApprovals.shared.pending().isEmpty)
            let trace = try String(contentsOf: record, encoding: .utf8)
            precondition(trace == "checked")
        }
        print("PASS: original string and integer request IDs, one-shot command/file/permission decisions, scoped grants and resolution")
        print("PASS: mismatched thread, hidden command permissions, replaced patch, permanent root and glob rejected")

        try Data("immediate-steer".utf8).write(to: root.appendingPathComponent("mode"))
        let steered = DispatchSemaphore(value: 0)
        let result = try AgentMessagingService.shared.testQueue(binary: binary, cwd: root, queueOnly: false) {
            let target = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
            let request = AgentInteractionRequest(operation: "send", source: "codex", sessionID: target,
                                                  text: "立即补充\n--literal", immediate: true)
            AgentMessagingService.shared.perform(try! JSONEncoder().encode(request)) { payload in
                let receipt = try! JSONDecoder().decode(AgentInteractionResult.self, from: payload)
                precondition(receipt.delivered == true && receipt.steered == true && receipt.queued == nil)
                steered.signal()
            }
        }
        precondition(result.delivered == true && steered.wait(timeout: .now() + 1) == .success)
        precondition(try! String(contentsOf: record, encoding: .utf8) == "steered")
        print("PASS: input accepted and steered on the active turn before completion")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="notch-codex-queue-") as directory:
    root = Path(directory).resolve()
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
