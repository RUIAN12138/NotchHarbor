import Foundation
import AppKit
import Combine
import Security

enum AgentQuickReplySource: String {
    case standard, api, custom

    static let preferenceKey = "agentQuickReplySource"
    static let customRepliesKey = "agentQuickReplyTemplates"
    static let maximumChoices = 3
    static let customTitleLimit = 12
    static let customBodyLimit = 1000

    static var current: Self { resolve(in: .standard) }

    static func resolve(in settings: UserDefaults) -> Self {
        if let raw = settings.string(forKey: preferenceKey), let source = Self(rawValue: raw) {
            return source
        }
        return settings.bool(forKey: AgentSuggestionAPI.enabledKey) ? .api : .standard
    }

    static func customReplies(from data: Data) -> [AgentReplyOption] {
        normalizedCustomReplies((try? JSONDecoder().decode([AgentReplyOption].self, from: data)) ?? [])
    }

    static func normalizedCustomReplies(_ replies: [AgentReplyOption]) -> [AgentReplyOption] {
        var bodies = Set<String>()
        return replies.prefix(maximumChoices).compactMap { reply in
            let body = String(reply.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(customBodyLimit))
            guard !body.isEmpty, bodies.insert(body).inserted else { return nil }
            let title = reply.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let fallback = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return AgentReplyOption(title: String((title.isEmpty ? fallback : title).prefix(customTitleLimit)), body: body)
        }
    }

    static var savedCustomReplies: [AgentReplyOption] {
        customReplies(from: UserDefaults.standard.data(forKey: Self.customRepliesKey) ?? Data())
    }
}

/// Suggestions are generated once per context or completed turn.
@MainActor
final class AgentInteraction: ObservableObject {
    static let shared = AgentInteraction()
    typealias Transport = (AgentInteractionRequest, @escaping (AgentInteractionResult) -> Void) -> Void
    struct State {
        var replyOptions: [AgentReplyOption] = []
        var context: String = ""
        var suggestionBackend: String = ""
        var generating = false
        var sending = false
        var deliveredAt: Date?
        var unsentReply: String?
        var status: String?
    }
    @Published private var states: [UUID: State] = [:]
    @Published private(set) var revision = 0
    private var preparedTurns: [UUID: Double] = [:]
    private var preparedReplies: [UUID: CompletionReply] = [:]
    private var connection: NSXPCConnection?
    private var drafts: [UUID: String] = [:]
    private var latestContexts: [UUID: String] = [:]
    private let hub: UnifiedActivities
    private let transport: Transport?
    private let fetchSuggestions: (String) async -> AgentInteractionResult
    private var suggestionTasks: [UUID: Task<[AgentReplyOption], Never>] = [:]

    init(hub: UnifiedActivities? = nil, fetchSuggestions: ((String) async -> AgentInteractionResult)? = nil,
         transport: Transport? = nil) {
        let hub = hub ?? UnifiedActivities.shared
        self.hub = hub
        self.transport = transport
        self.fetchSuggestions = fetchSuggestions ?? { await AgentSuggestionAPI.generate(context: $0) }
    }
    private struct DoubaoTurn: Decodable {
        let query: String?
        let response: String?
    }

    private struct DoubaoTranscript: Sendable {
        let messages: [AgentConversationMessage]
        let loadedAt: Date
    }

    private struct DoubaoHistoryError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var doubaoTranscripts: [UUID: DoubaoTranscript] = [:]
    private var doubaoLoads: [UUID: Task<DoubaoTranscript, Error>] = [:]

    func recentDoubaoSessions() async throws -> [IslandActivity] {
        struct Listing: Decodable {
            struct Session: Decodable {
                let session_id: String
                let title: String?
                let updated_at: String?
            }
            struct Result: Decodable { let sessions: [Session] }
            let result: Result
        }
        let result = await withCheckedContinuation { continuation in
            call(.init(operation: "list", source: "doubao", sessionID: UUID())) {
                continuation.resume(returning: $0)
            }
        }
        guard let text = result.text, let list = try? JSONDecoder().decode(Listing.self, from: Data(text.utf8)) else {
            throw DoubaoHistoryError(message: result.error ?? "豆包 CLI 无法读取会话，请确认已登录")
        }
        let iso = ISO8601DateFormatter()
        let fractionalISO = ISO8601DateFormatter()
        fractionalISO.formatOptions.insert(.withFractionalSeconds)
        var seen = Set<UInt64>()
        return list.result.sessions.prefix(8).compactMap { row -> IslandActivity? in
            guard let number = UInt64(row.session_id), number > 0, seen.insert(number).inserted else { return nil }
            let id = String(format: "00000000-0000-d0ba-%04llx-%012llx", number >> 48, number & 0xffffffffffff)
            let date = row.updated_at.flatMap { iso.date(from: $0) ?? fractionalISO.date(from: $0) }
            let title = (row.title ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return IslandActivity(id: id, kind: "agent", title: "豆包 CLI", detail: "最近会话",
                                  symbol: "terminal", priority: 10, expires: 0, source: "doubao",
                                  progress: .init(phase: "idle", observedAt: date?.timeIntervalSince1970 ?? 0, children: []),
                                  sessionTitle: String(title.prefix(80)), conversationID: id)
        }.sorted { ($0.progress?.observedAt ?? 0) > ($1.progress?.observedAt ?? 0) }
    }

    func cachedDoubaoHistory(_ id: UUID, before: UInt64? = nil) -> AgentConversationPage? {
        doubaoTranscripts[id].map { doubaoPage($0.messages, before: before) }
    }

    func doubaoHistory(_ id: UUID, before: UInt64? = nil, refresh: Bool = false) async throws -> AgentConversationPage {
        let cached = doubaoTranscripts[id]
        if before != nil, let cached { return doubaoPage(cached.messages, before: before) }
        if !refresh, let cached, Date().timeIntervalSince(cached.loadedAt) < 60 {
            return doubaoPage(cached.messages, before: before)
        }
        if let pending = doubaoLoads[id] {
            return doubaoPage(try await pending.value.messages, before: before)
        }
        let worker = Task {
            let result = await withCheckedContinuation { continuation in
                call(.init(operation: "history", source: "doubao", sessionID: id)) {
                    continuation.resume(returning: $0)
                }
            }
            guard let text = result.text,
                  let turns = try? JSONDecoder().decode([DoubaoTurn].self, from: Data(text.utf8)) else {
                throw DoubaoHistoryError(message: result.error ?? "豆包 CLI 无法导出此会话")
            }
            let messages = turns.enumerated().flatMap { index, turn in
                [("user", turn.query), ("assistant", turn.response)].enumerated().compactMap {
                    offset, pair -> AgentConversationMessage? in
                    guard let text = pair.1, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return .init(id: UInt64(index * 2 + offset), role: pair.0, text: text)
                }
            }
            return DoubaoTranscript(messages: messages, loadedAt: Date())
        }
        doubaoLoads[id] = worker
        defer { doubaoLoads[id] = nil }
        let transcript = try await worker.value
        doubaoTranscripts[id] = transcript
        if doubaoTranscripts.count > 6, let oldest = doubaoTranscripts.min(by: { $0.value.loadedAt < $1.value.loadedAt }) {
            doubaoTranscripts.removeValue(forKey: oldest.key)
        }
        return doubaoPage(transcript.messages, before: before)
    }

    private func doubaoPage(_ messages: [AgentConversationMessage], before: UInt64?) -> AgentConversationPage {
        let end = before.flatMap { cursor in messages.firstIndex { $0.id >= cursor } } ?? messages.endIndex
        let start = max(0, end - 6)
        return .init(messages: Array(messages[start..<end]), before: start > 0 ? messages[start].id : nil)
    }

    func state(_ id: UUID) -> State { states[id] ?? State() }
    private func change(_ id: UUID, _ body: (inout State) -> Void) {
        var value = state(id); body(&value); states[id] = value; revision += 1
    }
    private func call(_ request: AgentInteractionRequest, completion: @escaping (AgentInteractionResult) -> Void) {
        if let transport { transport(request, completion); return }
        if connection == nil {
            let link = NSXPCConnection(serviceName: "theboringteam.boringnotch.BoringNotchXPCHelper")
            link.remoteObjectInterface = NSXPCInterface(with: BoringNotchXPCHelperProtocol.self)
            link.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            link.resume()
            connection = link
        }
        guard let data = try? JSONEncoder().encode(request), let connection else { return }
        let fail: (Error) -> Void = { _ in
            Task { @MainActor in completion(.init(error: "Agent 连接中断，请检查原会话；不会自动重发")) }
        }
        guard let remote = connection.remoteObjectProxyWithErrorHandler(fail) as? BoringNotchXPCHelperProtocol else {
            completion(.init(error: "Agent 连接不可用")); return
        }
        remote.agentInteraction(data) { data in
            let result = (try? JSONDecoder().decode(AgentInteractionResult.self, from: data)) ?? .init(error: "Agent 返回格式错误")
            Task { @MainActor in completion(result) }
        }
    }
    private func context(_ messages: [AgentConversationMessage]) -> String {
        messages.suffix(6).map { "\($0.role): \($0.text.suffix(3000))" }.joined(separator: "\n\n")
    }
    func updateContext(id: UUID, messages: [AgentConversationMessage]) {
        let value = context(messages)
        latestContexts[id] = value
        if !state(id).context.isEmpty && state(id).context != value {
            change(id) { $0.replyOptions = []; $0.context = "" }
        }
    }

    func apiReplies(id: UUID, messages: [AgentConversationMessage]) -> [AgentReplyOption] {
        let cached = state(id)
        return cached.context == context(messages) && cached.suggestionBackend == AgentSuggestionAPI.identity
            ? cached.replyOptions : []
    }

    @discardableResult
    func generateAPIReplies(id: UUID, messages: [AgentConversationMessage]) async -> [AgentReplyOption] {
        let context = context(messages)
        guard AgentQuickReplySource.current == .api, !context.isEmpty else { return [] }
        latestContexts[id] = context
        let cached = apiReplies(id: id, messages: messages)
        if !cached.isEmpty { return cached }
        if let existing = suggestionTasks[id] {
            _ = await existing.value
            return apiReplies(id: id, messages: messages)
        }

        let backend = AgentSuggestionAPI.identity
        change(id) { $0.generating = true; $0.status = nil }
        let task = Task { [weak self, fetchSuggestions] in
            let result = await fetchSuggestions(context)
            guard let self else { return [AgentReplyOption]() }
            self.suggestionTasks[id] = nil
            let relevant = self.latestContexts[id] == context
                && AgentQuickReplySource.current == .api && AgentSuggestionAPI.identity == backend
            let options = relevant ? result.replyOptions.flatMap(AgentReplyOptionBatch.validated) ?? [] : []
            self.change(id) {
                $0.generating = false
                if relevant {
                    $0.replyOptions = options
                    $0.context = context
                    $0.status = result.error
                    $0.suggestionBackend = backend
                }
            }
            return options
        }
        suggestionTasks[id] = task
        return await task.value
    }
    func startCompletionMonitoring() {
        hub.onAgentTurnFinished = { [weak self] item in
            self?.prepareCompletion(item) { [weak self] ready in
                self?.hub.announceAgentCompletion(item, hasReplies: ready)
            }
        }
    }

    func prepareCompletion(_ item: IslandActivity,
                           load: (() async -> [AgentConversationMessage])? = nil,
                           notify: @escaping (Bool) -> Void) {
        guard item.isCompletedAgentSession, !item.title.hasSuffix("已停止"),
              let stamp = item.progress?.observedAt,
              (-5...90).contains(Date().timeIntervalSince1970 - stamp) else { return }
        guard item.progress?.phase == "finished",
              let source = item.source.flatMap(AgentConversationSource.init(rawValue:)),
              let id = (item.conversationID ?? item.sessionID).flatMap(UUID.init(uuidString:)) else {
            notify(false)
            return
        }
        guard stamp > (preparedTurns[id] ?? 0), isCurrentCompletion(item, stamp: stamp) else { return }
        preparedTurns = preparedTurns.filter { $0.value >= stamp - 600 }
        preparedTurns[id] = stamp
        preparedReplies = preparedReplies.filter { preparedTurns[$0.key] == $0.value.turn }

        let prefersAPI = AgentQuickReplySource.current == .api && AgentSuggestionAPI.autoGenerate
        let bookmark = UserDefaults.standard.data(forKey: "agentConversationRoot.\(source.rawValue)")
        let fallbackTitle = item.sessionTitle ?? item.detail.components(separatedBy: " · ").first ?? ""
        let startedAt = ContinuousClock.now
        var announced = false
        var latestMessages: [AgentConversationMessage] = []

        func present(_ messages: [AgentConversationMessage]) {
            guard preparedTurns[id] == stamp, isCurrentCompletion(item, stamp: stamp) else { return }
            if let summary = Self.completionSummary(messages) { hub.setAgentCompletionSummary(summary, session: item) }
            guard !announced else { return }
            announced = true
            let choiceSource = AgentQuickReplySource.current
            let standard = Self.immediateReplies(messages: messages, title: fallbackTitle)
            let options: [AgentReplyOption]
            switch choiceSource {
            case .standard: options = standard
            case .custom: options = AgentQuickReplySource.savedCustomReplies
            case .api:
                let generated = apiReplies(id: id, messages: messages)
                options = generated.isEmpty ? standard : generated
            }
            if !options.isEmpty {
                preparedReplies[id] = CompletionReply(id: id, turn: stamp, source: source.rawValue, options: options)
            }
            notify(!options.isEmpty)
        }

        Task {
            try? await Task.sleep(until: startedAt + .milliseconds(650), clock: .continuous)
            guard !Task.isCancelled else { return }
            // Auto API mode gets a short chance to finish. Late results remain
            // useful in the detail page without moving an option under the pointer.
            if prefersAPI, AgentQuickReplySource.current == .api, !latestMessages.isEmpty {
                try? await Task.sleep(until: startedAt + .seconds(4), clock: .continuous)
            }
            if !Task.isCancelled { present(latestMessages) }
        }
        Task {
            let messages = if let load {
                await load()
            } else if source == .doubao {
                (try? await doubaoHistory(id, refresh: true))?.messages ?? []
            } else {
                await Task.detached(priority: .userInitiated) {
                    for attempt in 0..<3 {
                        let result = try? AgentConversationHistory.read(bookmark: bookmark, source: source,
                            id: id, before: nil, knownFile: nil)
                        if let messages = result?.page.messages, messages.last?.role == "assistant" { return messages }
                        if attempt < 2 { try? await Task.sleep(for: .milliseconds(320)) }
                    }
                    return []
                }.value
            }
            latestMessages = messages
            if prefersAPI, !messages.isEmpty, !announced, preparedTurns[id] == stamp,
               isCurrentCompletion(item, stamp: stamp), AgentQuickReplySource.current == .api {
                let wing = hub.beginAgentReplyGeneration(item, turn: stamp)
                await generateAPIReplies(id: id, messages: messages)
                hub.endAgentReplyGeneration(wing)
            }
            present(messages)
        }
    }

    static func completionSummary(_ messages: [AgentConversationMessage]) -> String? {
        guard let last = messages.last, last.role == "assistant" else { return nil }
        var inCode = false
        let lines = last.text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let raw = line.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("```") || raw.hasPrefix("~~~") {
                inCode.toggle()
                return nil
            }
            guard !inCode else { return nil }
            return raw.replacingOccurrences(of: #"^(?:#{1,6}|>|[-+*]|\d+[.)])\s+"#,
                                            with: "", options: .regularExpression)
        }
        let relevant = lines.first { $0.count >= 8 && !$0.hasPrefix("http") && !$0.hasPrefix("|") }
            ?? lines.first { $0.count >= 3 }
        guard let relevant else { return nil }
        // Skip punctuation inside inline code, links and emphasis when finding the first sentence.
        let sentenceBoundary = #"`[^`]+`|!?\[[^\]]+\]\([^)]*\)|\*\*.+?\*\*|__.+?__|\*[^*]+\*|_[^_]+_|([。！？!?]|\.\s)"#
        let bounded = String(relevant.prefix(500))
        let regex = try? NSRegularExpression(pattern: sentenceBoundary)
        let range = NSRange(bounded.startIndex..<bounded.endIndex, in: bounded)
        if let boundary = regex?.matches(in: bounded, range: range).first(where: {
            $0.range(at: 1).location != NSNotFound
        }), let index = Range(boundary.range, in: bounded)?.lowerBound, index > bounded.startIndex {
            return String(bounded[..<index])
        }
        return bounded
    }

    static func immediateReplies(messages: [AgentConversationMessage], title: String) -> [AgentReplyOption] {
        let task = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = task.isEmpty ? "这轮任务" : "「\(String(task.prefix(55)))」"
        let outcome = completionSummary(messages).map { "你刚才提到「\(String($0.prefix(75)))」。" } ?? ""
        return [
            .init(title: "复查结果", body: outcome + "请复查\(scope)的最终结果、边界情况和仍需人工确认的部分。"),
            .init(title: "说明改动", body: "请简要说明\(scope)这轮实际完成的工作、关键决定和已验证的结果。"),
            .init(title: "梳理下一步", body: "请根据\(scope)目前的结果，列出最值得继续做的下一步，并说明原因。")
        ]
    }

    struct CompletionReply: Equatable {
        let id: UUID
        let turn: Double
        let source: String
        let options: [AgentReplyOption]
    }

    func completionReply(for notice: IslandActivity) -> CompletionReply? {
        guard notice.isCompletedAgentSession, let source = notice.source,
              let stamp = notice.progress?.observedAt,
              let id = (notice.conversationID ?? notice.sessionID).flatMap(UUID.init(uuidString:)),
              preparedTurns[id] == stamp,
              let live = session(id, source: source), isCurrentCompletion(live, stamp: stamp),
              notice.id == live.id + ":completion:" + String(stamp) else { return nil }
        guard !state(id).sending, let ready = preparedReplies[id],
              ready.turn == stamp, ready.source == source else { return nil }
        return ready
    }

    func sendCompletionReply(_ reply: CompletionReply, choice: Int, for notice: IslandActivity) -> Bool {
        guard reply.options.indices.contains(choice), completionReply(for: notice) == reply else { return false }
        send(reply.options[choice].body, source: reply.source, id: reply.id)
        return true
    }

    static func copyReply(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    private func isCurrentCompletion(_ item: IslandActivity, stamp: Double) -> Bool {
        guard let session = hub.agentSession(for: item.id) else { return false }
        return session.isCompletedAgentSession && session.progress?.observedAt == stamp
    }

    func draft(for id: UUID) -> String { drafts[id] ?? "" }

    func setDraft(_ text: String, for id: UUID) {
        drafts[id] = text.isEmpty ? nil : String(text.prefix(8000))
    }

    func sendDraft(source: String, id: UUID) {
        let text = draft(for: id)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        send(text, source: source, id: id, clearingDraft: true)
    }

    func send(_ text: String, source: String, id: UUID, clearingDraft: Bool = false) {
        guard !state(id).sending else { return }
        if source == "doubao", session(id, source: source)?.agentAttentionKey != nil {
            keepUnsent(text, id: id)
        } else if source != "codex" && source != "doubao", let session = session(id, source: source),
                  !ready(session), !(source == "antigravity" && session.progress?.phase == "idle") {
            keepUnsent(text, id: id)
        } else { submit(text, source: source, id: id, clearingDraft: clearingDraft) }
    }
    func dismissUnsent(_ id: UUID) { change(id) { $0.unsentReply = nil; $0.status = nil } }
    private func ready(_ item: IslandActivity) -> Bool {
        ["finished", "failed"].contains(item.progress?.phase ?? "")
    }
    private func session(_ id: UUID, source: String) -> IslandActivity? {
        hub.agentSessions.first {
            $0.source == source && ($0.conversationID ?? $0.sessionID).flatMap(UUID.init(uuidString:)) == id
        }
    }
    private func keepUnsent(_ text: String, id: UUID) {
        change(id) {
            $0.unsentReply = text
            $0.status = "此会话需在原应用中实时引导。未发送。"
        }
    }
    private func submit(_ text: String, source: String, id: UUID, clearingDraft: Bool) {
        change(id) { $0.unsentReply = nil; $0.sending = true; $0.status = "正在发送并等待 Agent 回复…" }
        call(.init(operation: "send", source: source, sessionID: id, text: text)) { [weak self] result in
            guard let self else { return }
            if clearingDraft, !result.busy, result.error == nil || result.delivered == true,
               self.draft(for: id) == text {
                self.setDraft("", for: id)
            }
            self.change(id) {
                $0.sending = false
                if result.delivered == true { $0.deliveredAt = Date() }
                if result.busy {
                    $0.unsentReply = text; $0.status = "此会话需在原应用中实时引导。未发送。"
                } else {
                    let provider = source == "doubao" ? "豆包 CLI" : AgentConversationSource(rawValue: source)?.appName ?? "Agent"
                    $0.status = result.error ?? (result.delivered == true && (result.text == nil || source == "doubao")
                        ? "已发送至 \(provider)" : "Agent 已回复")
                    if result.error == nil || result.delivered == true {
                        $0.replyOptions = []; $0.context = ""
                    } else {
                        // Keep the exact text so a failed transport does not
                        // leave the card without a way to resume the thread.
                        $0.unsentReply = text
                    }
                }
            }
        }
    }
}


/// Optional OpenAI-compatible suggestion backend. Replies still go through
/// the originating Agent transport, and the key never enters the helper.
enum AgentSuggestionAPI {
    static let enabledKey = "agentSuggestionAPIEnabled"
    static let endpointKey = "agentSuggestionAPIEndpoint"
    static let modelKey = "agentSuggestionAPIModel"
    static let autoGenerateKey = "agentSuggestionAPIAutoGenerate"
    private static let service = "theboringteam.boringnotch.agent-suggestions"
    private static let account = "api-key"

    static var autoGenerate: Bool { UserDefaults.standard.bool(forKey: autoGenerateKey) }
    static var identity: String {
        let settings = UserDefaults.standard
        return (settings.string(forKey: endpointKey) ?? "") + "\n" + (settings.string(forKey: modelKey) ?? "")
    }

    static func endpoint(_ value: String) -> URL? {
        guard var parsed = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed.scheme?.lowercased() == "https", let host = parsed.host, !host.isEmpty,
              parsed.user == nil, parsed.password == nil, parsed.query == nil, parsed.fragment == nil else { return nil }
        while parsed.path.hasSuffix("/") { parsed.path.removeLast() }
        if !parsed.path.hasSuffix("/chat/completions") {
            parsed.path += parsed.path.isEmpty ? "/v1/chat/completions" : "/chat/completions"
        }
        return parsed.url
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func key() -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        var data: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &data) == errSecSuccess, let bytes = data as? Data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    static func saveKey(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let update = SecItemUpdate(keychainQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = keychainQuery
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func removeKey() -> Bool {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func generate(context: String) async -> AgentInteractionResult {
        let settings = UserDefaults.standard
        guard let url = endpoint(settings.string(forKey: endpointKey) ?? ""),
              let model = settings.string(forKey: modelKey), !model.isEmpty, let key = key(), !key.isEmpty else {
            return .init(error: "请先在设置的 Agent 页填写 API 地址、模型和密钥")
        }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": AgentReplyOptionBatch.modelInstruction],
                ["role": "user", "content": context]
            ]
        ])
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                await AgentAPIUsageLedger.shared.recordResponse(data)
                guard let options = replyOptions(in: data) else {
                    return .init(error: "API 未返回 1 到 3 条有效的快捷回复")
                }
                return .init(suggestions: options.map(\.body), replyOptions: options)
            case 401, 403: return .init(error: "API 密钥无效或没有模型权限")
            case 429: return .init(error: "API 请求达到用量或频率限制")
            case 300..<400: return .init(error: "API 地址发生跳转，请填写实际接口地址")
            default: return .init(error: "API 请求失败（HTTP \(status)）")
            }
        } catch {
            return .init(error: "API 连接失败或超时")
        }
    }

    static func replyOptions(in data: Data) -> [AgentReplyOption]? {
        guard data.count <= 500_000,
              let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choice = (response["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let text = message["content"] as? String,
              let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), last >= first,
              let batch = try? JSONDecoder().decode(AgentReplyOptionBatch.self,
                    from: Data(text[first...last].utf8)) else { return nil }
        return AgentReplyOptionBatch.validated(batch.suggestions)
    }
}
