import Foundation
if CommandLine.arguments.contains("--codex-approval") {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("local.boringnotch.codex-approval"), object: nil,
        userInfo: nil, deliverImmediately: true)
    exit(0)
}
let data = FileHandle.standardInput.readDataToEndOfFile()
if data.count < 131072, let payload = String(data: data, encoding: .utf8) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(CommandLine.arguments.contains("--usage")
            ? "local.boringnotch.agent-usage" : "local.boringnotch.agent-state"),
        object: payload, userInfo: nil, deliverImmediately: true)
}
