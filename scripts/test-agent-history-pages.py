"""Verify recent-six pagination and visible text after multi-megabyte tool tails."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
check = r'''
import Foundation
@main struct Check {
 static func main() throws {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
  defer { try? FileManager.default.removeItem(at: file) }
  func visible(_ i: Int) throws -> Data {
   let row: [String: Any] = ["type":"event_msg", "payload":["type": i % 2 == 0 ? "user_message":"agent_message", "message":"visible-\(i)"]]
   return try JSONSerialization.data(withJSONObject: row) + Data([10])
  }
  var data = Data()
  for i in 0..<16 { data.append(try visible(i)) }
  let tool: [String: Any] = ["type":"response_item", "payload":["type":"function_call_output", "output":String(repeating:"x", count:70000)]]
  let toolLine = try JSONSerialization.data(withJSONObject:tool) + Data([10])
  for _ in 0..<32 { data.append(toolLine) }
  try data.write(to:file)
  let recent = try AgentConversationHistory.page(file:file,source:.codex,before:nil)
  precondition(recent.messages.map(\.text) == (10..<16).map { "visible-\($0)" })
  precondition(recent.before != nil)
  let older = try AgentConversationHistory.page(file:file,source:.codex,before:recent.before)
  precondition(older.messages.map(\.text) == (4..<10).map { "visible-\($0)" })
  precondition(Set(recent.messages.map(\.id)).isDisjoint(with:Set(older.messages.map(\.id))))
  let first = try AgentConversationHistory.page(file:file,source:.codex,before:older.before)
  precondition(first.messages.map(\.text) == (0..<4).map { "visible-\($0)" } && first.before == nil)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let chats = root.appendingPathComponent("test-project/chats")
  try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
  let identity = UUID()
  let short = identity.uuidString.lowercased().prefix(8)
  let log = chats.appendingPathComponent("session-2026-11-18-" + short + ".jsonl")
  let legacy = chats.appendingPathComponent("session-2026-11-17-" + short + ".json")
  let other = chats.appendingPathComponent("session-wrong-" + short + ".jsonl")
  func row(_ id: String, _ role: String, _ value: String) -> [String: Any] {
    ["id": id, "type": role, "content": [["text": value], ["text": "PRIVATE_THOUGHT", "thought": true]]]
  }
  func writeRows(_ rows: [[String: Any]], _ file: URL) throws {
    let data = try rows.reduce(into: Data()) { $0.append(try JSONSerialization.data(withJSONObject: $1) + Data([10])) }
    try data.write(to: file)
  }
  try writeRows([["sessionId": UUID().uuidString], row("oops", "user", "wrong-thread")], other)
  let checkpoint = (0..<8).map { row("old-\($0)", $0 % 2 == 0 ? "user" : "gemini", "old-\($0)") }
  try writeRows([["sessionId": identity.uuidString], ["$set": ["messages": checkpoint]],
      row("new", "gemini", "draft"),
      ["$patch": ["id": "new", "content": [["text": "final reply"]]]],
      ["type": "info", "content": "PRIVATE_INTERNAL"]], log)
  let found = try AgentConversationHistory.find(in: root, source: .gemini, id: identity)
  precondition(found?.lastPathComponent == log.lastPathComponent)
  let gemini = try AgentConversationHistory.page(file: log, source: .gemini, before: nil)
  precondition(gemini.messages.count == 6 && gemini.messages.last?.text == "final reply")
  let firstGemini = try AgentConversationHistory.page(file: log, source: .gemini, before: gemini.before)
  precondition(firstGemini.messages.count == 3 && firstGemini.messages.first?.role == "user")
  let json = try JSONSerialization.data(withJSONObject: ["messages": [row("legacy", "user", "legacy text")]])
  let prior = "{\"sessionId\":\"\(identity.uuidString)\"," + String(decoding: json.dropFirst(), as: UTF8.self)
  try Data(prior.utf8).write(to: legacy)
  try FileManager.default.removeItem(at: log)
  let foundLegacy = try AgentConversationHistory.find(in: root, source: .gemini, id: identity)
  precondition(foundLegacy?.lastPathComponent == legacy.lastPathComponent)
  let legacyPage = try AgentConversationHistory.page(file: legacy, source: .gemini, before: nil)
  precondition(legacyPage.messages.map(\.text) == ["legacy text"])
  let brain = root.appendingPathComponent(identity.uuidString.lowercased())
      .appendingPathComponent(".system_generated/logs")
  try FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
  let transcript = brain.appendingPathComponent("transcript.jsonl")
  try writeRows([
      ["type": "USER_INPUT", "source": "USER_EXPLICIT", "status": "DONE", "content": "<USER_REQUEST>\nquestion\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nlocal clock\n</ADDITIONAL_METADATA>"],
      ["type": "PLANNER_RESPONSE", "source": "MODEL", "status": "DONE", "content": "tool narration", "tool_calls": [["name": "read"]]],
      ["type": "PLANNER_RESPONSE", "source": "MODEL", "status": "DONE", "thinking": "hidden thought"],
      ["type": "PLANNER_RESPONSE", "source": "MODEL", "status": "DONE", "content": "answer", "thinking": "hidden thought"],
      ["type": "GENERIC", "source": "MODEL", "status": "DONE", "content": "Created At: 2026-11-21T18:15:14+08:00\nCompleted At: 2026-11-21T18:15:18+08:00\nCreated At: 2026-11-21T18:15:14+08:00"],
      ["type": "GENERIC", "source": "MODEL", "status": "DONE", "content": "An older-format reply"],
      ["type": "USER_INPUT", "source": "USER_EXPLICIT", "status": "DONE", "content": "<USER_REQUEST>\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nlocal clock\n</ADDITIONAL_METADATA>"],
      ["type": "GENERIC", "source": "MODEL", "status": "RUNNING", "content": "draft"]
  ], transcript)
  let antigravity = try AgentConversationHistory.find(in: root, source: .antigravity, id: identity)
  precondition(antigravity == transcript.resolvingSymlinksInPath())
  let antigravityPage = try AgentConversationHistory.page(file: transcript, source: .antigravity, before: nil)
  precondition(antigravityPage.messages.map(\.text) == ["question", "answer", "An older-format reply"])
  precondition(antigravityPage.messages.map(\.role) == ["user", "assistant", "assistant"])
  print("PASS: Antigravity user question and text reply; tool calls and thinking skipped")
  print("PASS: Gemini full UUID lookup, JSONL checkpoint and append, patches, paging, thought filtering, legacy JSON")
  print("PASS: six visible messages, older pagination, no duplicates, 2 MB tool tail does not hide conversation")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='notch-history-pages-') as folder:
    folder=Path(folder);(folder/'Check.swift').write_text(check)
    subprocess.run(['xcrun','swiftc','-parse-as-library',str(root/'boringNotch/components/Notch/AgentConversationHistory.swift'),str(folder/'Check.swift'),'-o',str(folder/'check')],check=True)
    subprocess.run([str(folder/'check')],check=True)
