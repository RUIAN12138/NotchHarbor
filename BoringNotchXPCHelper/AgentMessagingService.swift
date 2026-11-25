import Foundation
import OSLog

/// Reuses Agent Notch's CodexCLITransport: literal argv + stdin, never shell or UI automation.
final class AgentMessagingService {
    static let shared = AgentMessagingService()
    private let lock = NSLock()
    private let logger = Logger(subsystem: "theboringteam.boringnotch", category: "AgentDelivery")
    private var active = Set<String>()
    private var home: URL { URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir)) }

    func perform(_ data: Data, reply: @escaping (Data) -> Void) {
        func finish(_ value: AgentInteractionResult) { reply((try? JSONEncoder().encode(value)) ?? Data()) }
        guard data.count < 100_000,
              let request = try? JSONDecoder().decode(AgentInteractionRequest.self, from: data),
              ["codex", "claude", "gemini", "doubao", "antigravity"].contains(request.source),
              !["gemini", "antigravity"].contains(request.source) || request.operation == "send",
              (request.source == "doubao" ? ["list", "history", "send"] : ["suggest", "send"]).contains(request.operation),
              request.text.count <= 8000,
              request.context.count <= 24000 else {
            finish(.init(error: "消息格式不正确")); return
        }
        let key = request.source + (request.operation == "list" ? "" : request.sessionID.uuidString) + request.operation
        lock.lock()
        let inserted = active.insert(key).inserted
        lock.unlock()
        guard inserted else { finish(.init(error: "这个会话的请求仍在处理")); return }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.lock.lock(); self.active.remove(key); self.lock.unlock() }
            do {
                let result = try self.execute(request)
                let outcome = result.busy ? "busy" : result.error == nil ? "confirmed" : "submitted"
                self.logger.notice("\(request.source, privacy: .public) \(request.operation, privacy: .public): \(outcome, privacy: .public)")
                finish(result)
            } catch {
                let message = (error as? Failure)?.message ?? (error as? AntigravityACP.Failure)?.message ?? "Agent 连接失败，请检查原应用"
                self.logger.error("\(request.source, privacy: .public) \(request.operation, privacy: .public): \(message, privacy: .public)")
                finish(.init(error: message))
            }
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func executable(_ source: String, desktop: Bool = false) throws -> URL {
        let desktopCodex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let standaloneCodex = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home.path + "/.local/bin/codex"]
        let codexPaths = desktop ? [desktopCodex] + standaloneCodex : standaloneCodex + [desktopCodex]
        let paths: [String]
        let name: String
        switch source {
        case "codex":
            paths = codexPaths
            name = "Codex"
        case "doubao":
            paths = ["/opt/homebrew/bin/doubao", "/usr/local/bin/doubao", home.path + "/.local/bin/doubao"]
            name = "豆包 CLI"
        case "gemini":
            paths = ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini", home.path + "/.local/bin/gemini"]
            name = "Gemini CLI"
        case "antigravity":
            paths = ["/opt/homebrew/bin/agy", "/usr/local/bin/agy", home.path + "/.local/bin/agy"]
            name = "Antigravity CLI"
        default:
            paths = [home.path + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            name = "Claude"
        }
        guard let path = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw Failure(message: "未找到 \(name) 命令行程序")
        }
        return URL(fileURLWithPath: path)
    }

    private func state(_ request: AgentInteractionRequest) -> [String: Any]? {
        let root = home.appendingPathComponent(".multiagent-notch/session-state")
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file -> [String: Any]? in
            guard file.pathExtension == "json", let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                  info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 65536,
                  let data = try? Data(contentsOf: file),
                  let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  row["source"] as? String == request.source,
                  (row["session_id"] as? String).flatMap(UUID.init(uuidString:)) == request.sessionID else { return nil }
            return row
        }.max { ($0["observed_at"] as? Double ?? 0) < ($1["observed_at"] as? Double ?? 0) }
    }

    private func conversationLocation(_ request: AgentInteractionRequest) throws -> (directory: URL, log: URL, desktop: Bool) {
        // Resolve the exact conversation, not the caller's cwd or the most recent unrelated session.
        let root = home.appendingPathComponent(request.source == "codex" ? ".codex/sessions" : ".claude/projects")
        let identity = request.sessionID.uuidString.lowercased()
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            throw Failure(message: "无法读取会话目录")
        }
        for case let file as URL in walk {
            let name = file.lastPathComponent.lowercased()
            guard name.hasSuffix(".jsonl"),
                  request.source == "codex" ? name.hasSuffix("-" + identity + ".jsonl") || name.contains("-" + identity + "_") : name == identity + ".jsonl",
                  (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let data = (try? handle.read(upToCount: 131072)) ?? Data()
            try? handle.close()
            for line in data.split(separator: 10).prefix(32) {
                guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                let metadata = request.source == "codex" ? row["payload"] as? [String: Any] : row
                if request.source == "codex", (row["type"] as? String != "session_meta" || (metadata?["id"] as? String).flatMap(UUID.init(uuidString:)) != request.sessionID) { continue }
                if let cwd = metadata?["cwd"] as? String, cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd) {
                    let origin = (metadata?["originator"] as? String ?? "").lowercased()
                    let desktop = request.source == "codex" && origin.contains("desktop")
                    return (URL(fileURLWithPath: cwd, isDirectory: true), file, desktop)
                }
            }
        }
        throw Failure(message: "找不到此会话的工作目录，请在原应用中打开一次")
    }

    static func geminiDirectory(in root: URL, sessionID: UUID, hookDirectory: String?) -> URL? {
        let manager = FileManager.default
        let identity = sessionID.uuidString.lowercased()
        guard let projects = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: .skipsHiddenFiles) else { return nil }
        for project in projects {
            let chats = project.appendingPathComponent("chats", isDirectory: true)
            guard let files = try? manager.contentsOfDirectory(at: chats, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                                options: .skipsHiddenFiles) else { continue }
            for file in files {
                let stem = file.deletingPathExtension().lastPathComponent.lowercased()
                guard stem.hasPrefix("session-"),
                      stem.hasSuffix("-" + identity) || stem.hasSuffix("-" + identity.prefix(8)),
                      ["json", "jsonl"].contains(file.pathExtension),
                      (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
                      let log = try? FileHandle(forReadingFrom: file) else { continue }
                let prefix = (try? log.read(upToCount: 65536)) ?? Data()
                try? log.close()
                let verified: Bool
                if file.pathExtension == "jsonl", let line = prefix.split(separator: 10).first,
                   let metadata = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] {
                    verified = (metadata["sessionId"] as? String).flatMap(UUID.init(uuidString:)) == sessionID
                } else {
                    // Older Gemini JSON records place sessionId at the start.
                    let header = String(decoding: prefix, as: UTF8.self)
                    let pattern = #"(?m)^\s*\{?\s*"sessionId"\s*:\s*"([0-9a-fA-F-]{36})""#
                    let range = header.range(of: pattern, options: .regularExpression)
                    verified = range.map { header[$0].lowercased().contains(identity) } ?? false
                }
                guard verified else { continue }
                let marker = project.appendingPathComponent(".project_root")
                let path = (try? String(contentsOf: marker, encoding: .utf8))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let path = (path?.hasPrefix("/") == true ? path : hookDirectory), path.hasPrefix("/") {
                    var isDirectory: ObjCBool = false
                    if manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                        return URL(fileURLWithPath: path, isDirectory: true)
                    }
                }
            }
        }
        return nil
    }

    static func geminiReply(in output: String, sessionID: UUID) -> String? {
        var confirmed = false
        var succeeded = false
        var text = ""
        for line in output.split(separator: "\n") {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch row["type"] as? String {
            case "init":
                guard (row["session_id"] as? String).flatMap(UUID.init(uuidString:)) == sessionID else { return nil }
                confirmed = true
            case "message" where row["role"] as? String == "assistant":
                if let content = row["content"] as? String { text += content }
            case "result": succeeded = row["status"] as? String == "success"
            default: break
            }
        }
        return confirmed && succeeded ? text : nil
    }

    private func canContinueCodex(_ log: URL, hook: [String: Any]?, normallyBusy: Bool) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return !normallyBusy }
        defer { try? handle.close() }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        do {
            let end = try handle.seekToEnd()
            let start = end > 524_288 ? end - 524_288 : 0
            try handle.seek(toOffset: start)
            let rows = (try handle.read(upToCount: Int(end - start)) ?? Data()).split(separator: 10)
            let hookStamp = hook?["observed_at"] as? Double ?? 0
            for line in (start == 0 ? rows[...] : rows.dropFirst()).reversed() {
                guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      row["type"] as? String == "event_msg",
                      let event = (row["payload"] as? [String: Any])?["type"] as? String,
                      ["task_complete", "turn_aborted", "task_started"].contains(event),
                      let date = row["timestamp"] as? String,
                      let timestamp = parser.date(from: date) ?? fallback.date(from: date) else { continue }
                let stamp = timestamp.timeIntervalSince1970
                if event == "task_started" {
                    let age = Date().timeIntervalSince(timestamp)
                    return !normallyBusy && (stamp < hookStamp || age > 360)
                }
                return !normallyBusy || stamp >= hookStamp
            }
        } catch { return !normallyBusy }
        return !normallyBusy
    }

    private func execute(_ request: AgentInteractionRequest) throws -> AgentInteractionResult {
        if request.source == "doubao" { return try executeDoubao(request) }
        if request.operation == "send" {
            guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure(message: "回复不能为空") }
            let status = state(request)
            let phase = status?["status"] as? String ?? ""
            let normallyBusy = ["processing", "running_tool", "compacting", "waiting_for_approval", "waiting_for_input"].contains(phase)
                && !["Stop", "StopFailure", "SessionEnd", "SessionExpired"].contains(status?["event"] as? String ?? "")
            if request.source == "antigravity" {
                let stamp = status?["observed_at"] as? Double ?? 0
                let age = Date().timeIntervalSince1970 - stamp
                let attention = phase == "waiting_for_approval" || phase == "waiting_for_input"
                if normallyBusy, age >= -5, age < (attention ? 1200 : 300) { return .init(busy: true) }
                return try AntigravityACP(binary: executable("antigravity"), directory: home,
                                          environment: agentEnvironment).send(request.text, to: request.sessionID)
            }
            if request.source != "codex", normallyBusy { return .init(busy: true) }
            if request.source == "codex" {
                let id = request.sessionID.uuidString.lowercased()
                let delivery = try? CodexDesktopDelivery(home: home)
                if let delivery, let owner = try? delivery.owner(of: id), !owner.isEmpty {
                    do {
                        try delivery.send(request.text, threadID: id, owner: owner, preferSteer: normallyBusy)
                    } catch let error as CodexDesktopDelivery.DeliveryError {
                        throw Failure(message: error.userMessage)
                    }
                    logger.notice("codex desktop: owner acknowledged delivery")
                    return .init(delivered: true)
                }
            }
            if request.source == "gemini" {
                let root = home.appendingPathComponent(".gemini/tmp", isDirectory: true)
                guard let directory = Self.geminiDirectory(in: root, sessionID: request.sessionID,
                                                          hookDirectory: status?["cwd"] as? String) else {
                    throw Failure(message: "找不到此 Gemini CLI 会话或项目，请在原终端核对")
                }
                let binary = try executable("gemini")
                let args = ["--resume", request.sessionID.uuidString.lowercased(),
                            "--output-format", "stream-json", "--approval-mode", "default"]
                let output = try run(binary, args: args, input: request.text, cwd: directory, timeout: 600, codex: false)
                guard let response = Self.geminiReply(in: output, sessionID: request.sessionID) else {
                    throw Failure(message: "Gemini CLI 未确认此会话的回复，请在原终端核对")
                }
                return .init(text: response, delivered: true)
            }
            let location = try conversationLocation(request)
            if request.source == "codex", !canContinueCodex(location.log, hook: status, normallyBusy: normallyBusy) {
                return .init(busy: true)
            }
            let binary = try executable(request.source, desktop: location.desktop)
            if request.source == "codex" {
                return try sendViaCodexServer(binary, request: request, cwd: location.directory)
            }
            let args = ["--resume", request.sessionID.uuidString.lowercased(), "--print", "--output-format", "json"]
            let output = try run(binary, args: args, input: request.text, cwd: location.directory,
                                 timeout: 600, codex: false)
            return .init(text: output)
        }
        guard !request.context.isEmpty else { throw Failure(message: "对话加载后才能生成回复") }
        let folder = home.appendingPathComponent(".cache/boringnotch-agent-suggestions/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let schema = AgentReplyOptionBatch.schema
        let schemaFile = folder.appendingPathComponent("schema.json")
        try Data(schema.utf8).write(to: schemaFile)
        let outputFile = folder.appendingPathComponent("reply.json")
        let prompt = """
        \(AgentReplyOptionBatch.modelInstruction)
        <transcript>
        \(request.context)
        </transcript>
        """
        let args: [String]
        if request.source == "codex" {
            args = ["exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only",
                    "--disable", "hooks", "--disable", "apps", "--disable", "plugins", "--disable", "multi_agent", "--disable", "shell_tool",
                    "-c", "project_doc_max_bytes=0", "-c", "model_reasoning_effort=\"low\"", "-c", "mcp_servers={}",
                    "--output-schema", schemaFile.path, "--output-last-message", outputFile.path, "-"]
        } else {
            args = ["--print", "--no-session-persistence", "--tools", "", "--output-format", "json", "--json-schema", schema]
        }
        let binary = try executable(request.source)
        let stdout = try run(binary, args: args, input: prompt, cwd: folder,
                             timeout: 120, codex: request.source == "codex")
        let data = request.source == "codex" ? (try? Data(contentsOf: outputFile)) : Data(stdout.utf8)
        struct StructuredOutput: Decodable {
            let structured_output: AgentReplyOptionBatch
        }
        let decoder = JSONDecoder()
        let batch = data.flatMap {
            (try? decoder.decode(AgentReplyOptionBatch.self, from: $0))
                ?? (try? decoder.decode(StructuredOutput.self, from: $0).structured_output)
        }
        guard let batch, let options = AgentReplyOptionBatch.validated(batch.suggestions) else {
            throw Failure(message: "Agent 未返回三条有效的短标题和完整回复")
        }
        return .init(suggestions: options.map(\.body), replyOptions: options)
    }

    /// The public app-server protocol resumes only the requested thread,
    /// without materializing the whole turn history in the resume response.
    private func sendViaCodexServer(_ binary: URL, request: AgentInteractionRequest,
                                    cwd: URL) throws -> AgentInteractionResult {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = cwd
        process.environment = agentEnvironment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw Failure(message: "无法启动 Codex App Server") }
        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        defer {
            try? writer.close()
            if process.isRunning { process.terminate() }
        }

        func send(_ values: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: values)
            try writer.write(contentsOf: data + Data([10]))
        }

        var pending = Data()
        func read(until deadline: ContinuousClock.Instant) throws -> [String: Any] {
            while ContinuousClock.now < deadline {
                while let end = pending.firstIndex(of: 10) {
                    let bytes = Data(pending[..<end])
                    pending.removeSubrange(...end)
                    if let value = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] {
                        return value
                    }
                }
                var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let result = poll(&descriptor, 1, 200)
                if result < 0 && errno != EINTR { break }
                guard result > 0 else { continue }
                let bytes = reader.availableData
                if bytes.isEmpty { break }
                pending.append(bytes)
                guard pending.count <= 8_000_000 else {
                    throw Failure(message: "Codex 返回的数据过大，请在原会话中查看")
                }
            }
            throw Failure(message: "Codex 连接断开或超时")
        }

        func response(_ id: Int, stage: String) throws -> [String: Any] {
            let deadline = ContinuousClock.now + .seconds(30)
            while true {
                let row = try read(until: deadline)
                guard row["id"] as? Int == id, row["method"] == nil else { continue }
                if let error = row["error"] as? [String: Any] {
                    let message = Self.failureMessage(error["message"] as? String ?? "")
                    let code = error["code"] as? Int ?? 0
                    logger.error("codex app-server \(stage, privacy: .public): RPC \(code, privacy: .public) \(message, privacy: .public)")
                    throw Failure(message: "Codex \(stage)失败（\(code)）：\(message)")
                }
                guard let result = row["result"] as? [String: Any] else {
                    throw Failure(message: "Codex \(stage)响应格式不正确")
                }
                return result
            }
        }

        let threadID = request.sessionID.uuidString.lowercased()
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "boringnotch", "version": "1"]]])
        _ = try response(1, stage: "初始化")
        try send(["method": "initialized"])
        try send(["id": 2, "method": "thread/resume", "params": [
            "threadId": threadID, "excludeTurns": true, "approvalPolicy": "never"
        ]])
        let resumed = try response(2, stage: "接续会话")
        let thread = resumed["thread"] as? [String: Any]
        guard (thread?["id"] as? String).flatMap(UUID.init(uuidString:)) == request.sessionID else {
            throw Failure(message: "Codex 返回了其他会话，回复未发送")
        }

        let inputItems: [[String: Any]] = [["type": "text", "text": request.text, "text_elements": []]]
        try send(["id": 3, "method": "turn/start", "params": ["threadId": threadID, "input": inputItems]])
        let started = try response(3, stage: "提交回复")
        guard let turn = started["turn"] as? [String: Any], let turnID = turn["id"] as? String else {
            throw Failure(message: "Codex 未确认提交，请先核对原会话")
        }
        logger.notice("codex app-server: submission acknowledged")
        var text = ""
        let deadline = ContinuousClock.now + .seconds(600)
        while let notification = try? read(until: deadline) {
            guard let event = notification["method"] as? String,
                  let params = notification["params"] as? [String: Any],
                  (params["threadId"] as? String).flatMap(UUID.init(uuidString:)) == request.sessionID else { continue }
            if event == "item/completed", params["turnId"] as? String == turnID,
               let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
               let message = item["text"] as? String {
                text = String(message.suffix(8000))
            }
            if event == "turn/completed", let completed = params["turn"] as? [String: Any],
               completed["id"] as? String == turnID {
                if completed["status"] as? String == "completed" {
                    return .init(text: text, delivered: true)
                }
                return .init(error: "消息已提交，Codex 此轮未完成，请查看原会话", delivered: true)
            }
        }
        return .init(error: "消息已提交，请在原会话查看后续进度", delivered: true)
    }

    private func executeDoubao(_ request: AgentInteractionRequest) throws -> AgentInteractionResult {
        let binary = try executable("doubao")
        if request.operation == "list" {
            let output = try run(binary, args: ["--list", "--limit", "8", "--json"],
                                 input: nil, cwd: home, timeout: 12, codex: false)
            return .init(text: output)
        }
        let uuid = request.sessionID.uuidString.lowercased()
        guard uuid.hasPrefix("00000000-0000-d0ba-"),
              let numericID = UInt64(uuid.dropFirst(19).filter { $0 != "-" }, radix: 16), numericID > 0 else {
            throw Failure(message: "豆包会话标识无效")
        }
        let sessionID = String(numericID)
        if request.operation == "history" {
            let output = try run(binary, args: ["--export", sessionID],
                                 input: nil, cwd: home, timeout: 18, codex: false)
            return .init(text: output)
        }
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "回复不能为空")
        }
        let output = try run(binary, args: ["--resume", sessionID, "-p", "-",
                             "--permission-mode", "ask_always", "--output-format", "json"],
                             input: request.text, cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
                             timeout: 180, codex: false)
        guard let row = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
              row["type"] as? String == "result", row["is_error"] as? Bool == false,
              row["session_id"] as? String == sessionID else {
            throw Failure(message: "豆包 CLI 未确认原会话收到消息，请先核对会话")
        }
        let result = row["result"] as? [String: Any]
        return .init(text: (result?["content"] as? String).map { String($0.suffix(8000)) }, delivered: true)
    }

    private var agentEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home.path)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return environment
    }

    private func run(_ binary: URL, args: [String], input: String?, cwd: URL, timeout: TimeInterval, codex: Bool, expectedThread: UUID? = nil) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.currentDirectoryURL = cwd
        process.environment = agentEnvironment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin; process.standardOutput = stdout; process.standardError = stderr
        let lock = NSLock()
        let readers = DispatchGroup()
        readers.enter()
        readers.enter()
        var output = Data(), diagnostic = Data(), prefix = Data()
        // Drain both pipes while the process runs; retain only bounded output in memory.
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else {
                handle.readabilityHandler = nil
                readers.leave()
                return
            }
            lock.lock()
            if codex {
                if prefix.count < 16_000 { prefix.append(bytes.prefix(16_000 - prefix.count)) }
                output.append(bytes)
                if output.count > 1_000_000 { output.removeFirst(output.count - 1_000_000) }
            } else if output.count < 1_000_000 {
                output.append(bytes.prefix(1_000_000 - output.count))
            }
            lock.unlock()
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else {
                handle.readabilityHandler = nil
                readers.leave()
                return
            }
            lock.lock()
            diagnostic.append(bytes)
            if diagnostic.count > 16_000 { diagnostic.removeFirst(diagnostic.count - 16_000) }
            lock.unlock()
        }
        do { try process.run() }
        catch { throw Failure(message: "无法启动 Agent 命令行，请检查原应用") }
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // A command that fails during startup can close stdin before reading.
        // Its exit status and diagnostics still explain the failure.
        let inputWritten = input.map { (try? stdin.fileHandleForWriting.write(contentsOf: Data(($0 + "\n").utf8))) != nil } ?? true
        try? stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let timedOut = process.isRunning
        if timedOut { process.terminate() }
        process.waitUntilExit()
        _ = readers.wait(timeout: .now() + .seconds(1))
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let result = String(decoding: output, as: UTF8.self); let errors = String(decoding: diagnostic, as: UTF8.self); lock.unlock()
        if timedOut { throw Failure(message: "Agent 响应超时，请先检查原会话，避免重复发送") }
        var events = codex ? Self.codexEvents(in: result) : .init()
        if codex && events.threadID == nil {
            events.threadID = Self.codexEvents(in: String(decoding: prefix, as: UTF8.self)).threadID
        }
        guard inputWritten, process.terminationStatus == 0, events.failure == nil else {
            throw Failure(message: Self.failureMessage(events.failure.flatMap { $0.isEmpty ? nil : $0 } ?? errors))
        }
        if let expectedThread, events.threadID != expectedThread || !events.completed {
            throw Failure(message: "Codex 没有确认原会话已收到，请先打开会话核对")
        }
        return result
    }

    struct CodexEvents {
        var threadID: UUID?
        var completed = false
        var failure: String?

        mutating func consume(_ bytes: Data) {
            guard let event = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                  let type = event["type"] as? String else { return }
            switch type {
            case "thread.started":
                threadID = (event["thread_id"] as? String).flatMap(UUID.init(uuidString:))
            case "turn.completed":
                completed = true
                failure = nil
            case "turn.failed":
                completed = false
                failure = (event["error"] as? [String: Any])?["message"] as? String ?? ""
            case "error":
                if !completed { failure = event["message"] as? String }
            default: break
            }
        }
    }

    static func codexEvents(in output: String) -> CodexEvents {
        var events = CodexEvents()
        for line in output.split(separator: "\n") { events.consume(Data(line.utf8)) }
        return events
    }

    static func failureMessage(_ diagnostic: String) -> String {
        let message = diagnostic.lowercased()
        if ["rate limit", "usage limit", "quota", "too many requests"].contains(where: message.contains) {
            return "Agent 暂时达到用量限制"
        }
        if ["not logged in", "authentication", "unauthorized", "login required", "run codex login"].contains(where: message.contains) {
            return "请先在对应 Agent 中完成登录"
        }
        if message.contains("already has an active writer") {
            return "会话由 Codex 桌面版持有，请打开原会话后再发"
        }
        if ["no rollout found", "thread not found", "session not found", "no session found", "failed to resume"].contains(where: message.contains) {
            return "Agent 无法接续此会话，请从原应用打开"
        }
        if ["history base", "history_base", "rollout history", "parent rollout"].contains(where: message.contains) {
            return "Codex 无法恢复此分支的历史，请在原应用中打开"
        }
        if ["model is not supported", "model not found", "unsupported model"].contains(where: message.contains) {
            return "Codex 当前模型无法从快捷回复启动"
        }
        if ["at capacity", "overloaded", "stream disconnected", "error sending request", "connection refused"].contains(where: message.contains) {
            return "Agent 服务暂时不可用，请先检查原会话"
        }
        if ["permission denied", "operation not permitted", "untrusted hooks"].contains(where: message.contains) {
            return "Agent 无法启动，请在原应用中检查权限"
        }
        return "快捷回复未确认送达，请先检查原会话"
    }
}
