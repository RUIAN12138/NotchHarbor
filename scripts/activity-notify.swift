import Foundation
let data = FileHandle.standardInput.readDataToEndOfFile()
if data.count < 131072, let payload = String(data: data, encoding: .utf8) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(CommandLine.arguments.contains("--usage")
            ? "local.boringnotch.agent-usage" : "local.boringnotch.agent-state"),
        object: payload, userInfo: nil, deliverImmediately: true)
}
