"""Exercise the native ACP transport without using an account or any real session."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
fixture = r'''#!/usr/bin/env python3
import json, os, sys
mode = os.environ['ACP_TEST_MODE']
identity = os.environ['ACP_TEST_ID']
other = 'b0000000-0000-4000-8000-000000000001'
cwd = os.environ['ACP_TEST_WORKSPACE']

def write(**message):
    print(json.dumps(dict(jsonrpc='2.0', **message)), flush=True)

def update(session, role, text):
    write(method='session/update', params={'sessionId': session, 'update': {
        'sessionUpdate': role, 'content': {'type': 'text', 'text': text}}})

for line in sys.stdin:
    call = json.loads(line)
    params = call.get('params', {})
    method = call.get('method')
    if method == 'initialize':
        write(id=call['id'], result={'protocolVersion': 1, 'agentCapabilities': {
            'loadSession': True, 'sessionCapabilities': {'list': {}}}})
    elif method == 'session/list':
        if not params:
            write(id=call['id'], result={'sessions': [{'sessionId': other, 'cwd': cwd}],
                                        **({} if mode == 'missing' else {'nextCursor': 'page2'})})
        else:
            assert params == {'cursor': 'page2'}
            write(id=call['id'], result={'sessions': [{'sessionId': identity, 'cwd': cwd}]})
    elif method == 'session/load':
        assert params == {'sessionId': identity, 'cwd': cwd, 'mcpServers': []}
        update(other if mode == 'mismatch' else identity, 'agent_message_chunk', 'old history')
        write(id=call['id'], result={})
    elif method == 'session/prompt':
        with open(os.environ['ACP_TEST_SENT'], 'a') as output:
            output.write('prompt\n')
        assert params == {'sessionId': identity, 'prompt': [{'type': 'text', 'text': '测试\n仅文字'}]}
        if mode == 'timeout':
            continue
        if mode == 'permission':
            prompt_id = call['id']
            write(id='permission', method='session/request_permission', params={'sessionId': identity})
            continue
        update(other, 'agent_message_chunk', 'wrong conversation')
        update(identity, 'agent_message_chunk', '新')
        update(identity, 'agent_message_chunk', '回复')
        write(id=call['id'], result={'stopReason': 'end_turn'})
    elif call.get('id') == 'permission':
        assert call.get('result') == {'outcome': {'outcome': 'cancelled'}}
        with open(os.environ['ACP_TEST_SENT'], 'a') as output:
            output.write('no approval\n')
    elif method == 'session/cancel':
        assert params == {'sessionId': identity}
        if mode == 'permission':
            write(id=prompt_id, result={'stopReason': 'cancelled'})
'''
check = r'''
import Foundation

@main struct Check {
    static func main() throws {
        let stage = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let identity = UUID()
        let trace = stage.appendingPathComponent("trace")
        func transport(_ mode: String) throws -> AntigravityACP {
            try? FileManager.default.removeItem(at: trace)
            var env = ProcessInfo.processInfo.environment
            env["ACP_TEST_MODE"] = mode
            env["ACP_TEST_WORKSPACE"] = stage.path
            env["ACP_TEST_ID"] = identity.uuidString.lowercased()
            env["ACP_TEST_SENT"] = trace.path
            return try AntigravityACP(binary: stage.appendingPathComponent("fixture"), directory: stage,
                environment: env, setupTimeout: .seconds(4), turnTimeout: .milliseconds(350))
        }
        func send(_ mode: String) throws -> AgentInteractionResult {
            try transport(mode).send("测试\n仅文字", to: identity)
        }
        let normal = try send("normal")
        precondition(normal.delivered == true && normal.error == nil && normal.text == "新回复")
        for rejected in ["missing", "mismatch"] {
            do {
                _ = try send(rejected)
                preconditionFailure("Prompt attempted in an unverified session")
            } catch let error as AntigravityACP.Failure {
                precondition(error.message.contains("未发送"))
            }
            precondition(!FileManager.default.fileExists(atPath: trace.path))
        }
        let permission = try send("permission")
        precondition(permission.delivered == true && permission.error?.contains("审批") == true)
        let recorded = try String(contentsOf: trace, encoding: .utf8)
        precondition(recorded == "prompt\nno approval\n")
        let timeout = try send("timeout")
        precondition(timeout.delivered == nil && timeout.error?.contains("未确认") == true)
        let timedOut = try String(contentsOf: trace, encoding: .utf8)
        precondition(timedOut == "prompt\n")
        print("PASS: original ID and workspace, pagination, exact prompt, no implicit permission, and ambiguous timeout without retries")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notch-antigravity-acp-') as folder:
    stage = Path(folder)
    script = stage / 'fixture'
    script.write_text(fixture)
    script.chmod(0o700)
    main = stage / 'Check.swift'
    main.write_text(check)
    service = root / 'BoringNotchXPCHelper'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(main),
                    str(service / 'AntigravityACP.swift'), str(service / 'BoringNotchXPCHelperProtocol.swift'),
                    '-o', str(stage / 'check')], check=True)
    subprocess.run([str(stage / 'check'), str(stage)], check=True)
