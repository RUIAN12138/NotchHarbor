import Foundation

/// Antigravity's public ACP stdio transport. A listed session and its workspace
/// are required before a prompt may be sent; this client never creates a session.
final class AntigravityACP {
    private typealias Message = [String: Any]

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let process = Process()
    private let writer: FileHandle
    private let reader: FileHandle
    private var pending = Data()
    private var nextID = 0
    private let setupTimeout: Duration
    private let turnTimeout: Duration

    init(binary: URL, directory: URL, environment: [String: String],
         setupTimeout: Duration = .seconds(20), turnTimeout: Duration = .seconds(600)) throws {
        self.setupTimeout = setupTimeout
        self.turnTimeout = turnTimeout
        let input = Pipe(), output = Pipe()
        writer = input.fileHandleForWriting
        reader = output.fileHandleForReading
        process.executableURL = binary
        process.arguments = ["acp", "--stdio"]
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw Failure(message: "无法启动 Antigravity CLI") }
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    deinit {
        try? writer.close()
        if process.isRunning { process.terminate() }
    }

    func send(_ text: String, to expected: UUID) throws -> AgentInteractionResult {
        let setupDeadline = ContinuousClock.now + setupTimeout
        let hello = try request("initialize", [
            "protocolVersion": 1, "clientCapabilities": [String: Any](),
            "clientInfo": ["name": "notch-harbor", "version": "1"]
        ], until: setupDeadline)
        let capabilities = hello["agentCapabilities"] as? Message
        let sessionCapabilities = capabilities?["sessionCapabilities"] as? Message
        guard hello["protocolVersion"] as? Int == 1, capabilities?["loadSession"] as? Bool == true,
              sessionCapabilities?["list"] != nil else {
            throw Failure(message: "当前 Antigravity CLI 未提供会话查找和续接能力")
        }
        let (sessionID, directory) = try locate(expected, until: setupDeadline)
        let loaded = try request("session/load", [
            "sessionId": sessionID, "cwd": directory, "mcpServers": []
        ], until: setupDeadline) { row in
            if row["method"] as? String == "session/update",
               let params = row["params"] as? Message,
               let reported = params["sessionId"] as? String,
               UUID(uuidString: reported) != expected {
                throw Failure(message: "Antigravity 返回了其他会话，回复未发送")
            }
        }
        if let reported = loaded["sessionId"] as? String, UUID(uuidString: reported) != expected {
            throw Failure(message: "Antigravity 返回了其他会话，回复未发送")
        }

        var acknowledged = false
        var needsApproval = false
        var answer = ""
        do {
            let result = try request("session/prompt", [
                "sessionId": sessionID, "prompt": [["type": "text", "text": text]]
            ], until: ContinuousClock.now + turnTimeout) { row in
                guard let params = row["params"] as? Message,
                      (params["sessionId"] as? String).flatMap(UUID.init(uuidString:)) == expected else { return }
                switch row["method"] as? String {
                case "session/request_permission":
                    acknowledged = true
                    needsApproval = true
                    if let id = row["id"] {
                        try write(["id": id, "result": ["outcome": ["outcome": "cancelled"]]])
                    }
                    try cancel(sessionID)
                    let promptID = nextID
                    let cancellationDeadline = ContinuousClock.now + .seconds(1)
                    while let reply = try? read(until: cancellationDeadline) {
                        if reply["method"] == nil, reply["id"] as? Int == promptID { break }
                    }
                    throw Failure(message: "Antigravity 此轮需要审批")
                case "session/update":
                    guard let update = params["update"] as? Message else { return }
                    switch update["sessionUpdate"] as? String {
                    case "agent_message_chunk":
                        acknowledged = true
                        if let content = update["content"] as? Message, content["type"] as? String == "text",
                           let chunk = content["text"] as? String {
                            answer = String((answer + chunk).suffix(8000))
                        }
                    case "user_message_chunk", "tool_call":
                        acknowledged = true
                    default: break
                    }
                default: break
                }
            }
            guard let reason = result["stopReason"] as? String else {
                throw Failure(message: "Antigravity 未返回结束状态")
            }
            if reason == "end_turn" {
                return .init(text: answer.isEmpty ? nil : answer, delivered: true)
            }
            return .init(error: "回复已进入 Antigravity 原会话，此轮未完整结束，请查看原窗口", delivered: true)
        } catch {
            if needsApproval {
                return .init(error: "回复已送达。此轮请求审批，请在 Antigravity 原会话查看并继续", delivered: true)
            }
            try? cancel(sessionID)
            let status = acknowledged ? "回复已进入 Antigravity 原会话，请查看后续进度"
                : "Antigravity 未确认是否送达，请先检查原会话，避免重复发送"
            return .init(error: status, delivered: acknowledged ? true : nil)
        }
    }

    private func locate(_ expected: UUID, until deadline: ContinuousClock.Instant) throws -> (String, String) {
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            let list = try request("session/list", cursor.map { ["cursor": $0] } ?? [:], until: deadline)
            if let rows = list["sessions"] as? [Message],
               let found = rows.first(where: { ($0["sessionId"] as? String).flatMap(UUID.init(uuidString:)) == expected }) {
                guard let id = found["sessionId"] as? String, let path = found["cwd"] as? String,
                      path.hasPrefix("/") else {
                    throw Failure(message: "Antigravity 原会话没有可用的本地工作目录")
                }
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
                    throw Failure(message: "Antigravity 原会话的工作目录已不可用")
                }
                return (id, path)
            }
            cursor = list["nextCursor"] as? String
        } while cursor.map { seenCursors.insert($0).inserted } == true && seenCursors.count < 32
        throw Failure(message: "CLI 中找不到这条 Antigravity 原会话，回复未发送")
    }

    private func cancel(_ sessionID: String) throws {
        try write(["method": "session/cancel", "params": ["sessionId": sessionID]])
    }

    private func request(_ method: String, _ params: Message, until deadline: ContinuousClock.Instant,
                         onMessage: (Message) throws -> Void = { _ in }) throws -> Message {
        nextID += 1
        let id = nextID
        try write(["id": id, "method": method, "params": params])
        while true {
            let row = try read(until: deadline)
            if row["method"] == nil, row["id"] as? Int == id {
                if let result = row["result"] as? Message { return result }
                let code = (row["error"] as? Message)?["code"] as? Int ?? 0
                if code == -32000 { throw Failure(message: "Antigravity CLI 需要登录，请在终端打开 agy") }
                throw Failure(message: "Antigravity 无法处理此会话请求（\(code)）")
            }
            try onMessage(row)
            if row["method"] != nil, let requestID = row["id"] {
                // The notch provides no client filesystem, terminal or permission grants.
                try write(["id": requestID, "error": ["code": -32601, "message": "Client method unavailable"]])
            }
        }
    }

    private func write(_ message: Message) throws {
        var rpc = message
        rpc["jsonrpc"] = "2.0"
        let data = try JSONSerialization.data(withJSONObject: rpc)
        try writer.write(contentsOf: data + Data([10]))
    }

    private func read(until deadline: ContinuousClock.Instant) throws -> Message {
        while ContinuousClock.now < deadline {
            if let end = pending.firstIndex(of: 10) {
                let line = Data(pending[..<end])
                pending.removeSubrange(...end)
                if let row = (try? JSONSerialization.jsonObject(with: line)) as? Message { return row }
                continue
            }
            var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result < 0 && errno != EINTR { break }
            guard result > 0 else { continue }
            let bytes = reader.availableData
            if bytes.isEmpty { break }
            pending.append(bytes)
            guard pending.count < 4_000_000 else { throw Failure(message: "Antigravity ACP 返回的数据过大") }
        }
        throw Failure(message: "Antigravity CLI 连接断开或超时")
    }
}
