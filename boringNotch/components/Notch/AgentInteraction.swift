import Foundation
import Combine
import Security

/// Suggestions are generated once per context or completed turn.
@MainActor
final class AgentInteraction: ObservableObject {
    static let shared = AgentInteraction()
    typealias Transport = (AgentInteractionRequest, @escaping (AgentInteractionResult) -> Void) -> Void
    struct State {
        var suggestions: [String] = []
        var replyOptions: [AgentReplyOption] = []
        var detailReplyOptions: [AgentReplyOption] {
            replyOptions.isEmpty ? suggestions.map { AgentReplyOption(title: $0, body: $0) } : replyOptions
        }
        var context: String = ""
        var suggestionBackend: String = ""
        var generating = false
        var sending = false
        var unsentReply: String?
        var status: String?
    }
    @Published private var states: [UUID: State] = [:]
    @Published private(set) var revision = 0
    private var preparedTurns: [UUID: Double] = [:]
    private var connection: NSXPCConnection?
    private var drafts: [UUID: String] = [:]
    private var latestContexts: [UUID: String] = [:]
    private let hub: UnifiedActivities
    private let transport: Transport?

    init(hub: UnifiedActivities? = nil, transport: Transport? = nil) {
        let hub = hub ?? UnifiedActivities.shared
        self.hub = hub
        self.transport = transport
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
            change(id) { $0.suggestions = []; $0.replyOptions = []; $0.context = "" }
        }
    }
    func generate(source: String, id: UUID, messages: [AgentConversationMessage]) {
        let context = context(messages)
        latestContexts[id] = context
        guard !context.isEmpty, !state(id).generating else { return }
        let backend = AgentSuggestionAPI.enabled ? AgentSuggestionAPI.identity : "local"
        if state(id).context == context && state(id).suggestionBackend == backend
            && !state(id).suggestions.isEmpty { return }
        change(id) { $0.generating = true; $0.suggestions = []; $0.replyOptions = []; $0.status = nil }
        let receive: (AgentInteractionResult) -> Void = { [weak self] result in
            self?.change(id) {
                $0.generating = false
                let currentBackend = AgentSuggestionAPI.enabled ? AgentSuggestionAPI.identity : "local"
                if self?.latestContexts[id] == context && currentBackend == backend {
                    let options = result.replyOptions.flatMap(AgentReplyOptionBatch.validated)
                    $0.replyOptions = options ?? []
                    $0.suggestions = options?.map(\.body) ?? result.suggestions
                    $0.context = context
                    $0.status = result.error
                    $0.suggestionBackend = backend
                }
            }
        }
        if AgentSuggestionAPI.enabled {
            Task { receive(await AgentSuggestionAPI.generate(context: context)) }
        } else {
            call(.init(operation: "suggest", source: source, sessionID: id, context: context), completion: receive)
        }
    }
    func prepareCompletion(_ item: IslandActivity,
                           load: (() async -> [AgentConversationMessage])? = nil,
                           notify: @escaping (Bool) -> Void) {
        guard item.isCompletedAgentSession, !item.title.hasSuffix("已停止"),
              let stamp = item.progress?.observedAt,
              abs(Date().timeIntervalSince1970 - stamp) <= 24 else { return }
        // Completion notices apply to every Agent. Only Codex pre-generates suggestions.
        guard item.source == "codex", item.progress?.phase == "finished",
              let id = (item.conversationID ?? item.sessionID).flatMap(UUID.init(uuidString:)) else {
            notify(false)
            return
        }
        guard stamp > (preparedTurns[id] ?? 0), isCurrentCompletion(item, stamp: stamp) else { return }
        preparedTurns = preparedTurns.filter { $0.value >= stamp - 600 }
        preparedTurns[id] = stamp
        guard !AgentSuggestionAPI.enabled || AgentSuggestionAPI.autoGenerate else {
            notify(false)
            return
        }
        let generationWing = hub.beginAgentReplyGeneration(item, turn: stamp)
        let bookmark = UserDefaults.standard.data(forKey: "agentConversationRoot.codex")
        Task { [weak self, hub] in
            defer { hub.endAgentReplyGeneration(generationWing) }
            let messages: [AgentConversationMessage]
            if let load {
                messages = await load()
            } else {
                messages = await Task.detached(priority: .utility) {
                for attempt in 0..<3 {
                    let result = try? AgentConversationHistory.read(bookmark: bookmark, source: .codex,
                        id: id, before: nil, knownFile: nil)
                    if let messages = result?.page.messages, messages.last?.role == "assistant" { return messages }
                    if attempt < 2 { try? await Task.sleep(for: .milliseconds(400)) }
                }
                    return []
                }.value
            }
            guard let self, self.preparedTurns[id] == stamp,
                  self.isCurrentCompletion(item, stamp: stamp) else { return }
            if !messages.isEmpty {
                let expected = self.context(messages)
                if !self.state(id).generating { self.generate(source: "codex", id: id, messages: messages) }
                // A slow suggestion backend must not hold the completion
                // alert for its entire process timeout.
                let deadline = ContinuousClock.now + .seconds(12)
                while self.state(id).generating && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard self.preparedTurns[id] == stamp, self.isCurrentCompletion(item, stamp: stamp) else { return }
                }
                if self.state(id).context == expected && self.state(id).replyOptions.count == 3 {
                    notify(true)
                    return
                }
            }
            notify(false)
        }
    }

    struct CompletionReply: Equatable {
        let id: UUID
        let turn: Double
        let context: String
        let options: [AgentReplyOption]
    }

    func completionReply(for notice: IslandActivity) -> CompletionReply? {
        guard notice.isCompletedAgentSession, notice.source == "codex",
              let stamp = notice.progress?.observedAt,
              let id = (notice.conversationID ?? notice.sessionID).flatMap(UUID.init(uuidString:)),
              preparedTurns[id] == stamp,
              let live = session(id, source: "codex"), isCurrentCompletion(live, stamp: stamp),
              notice.id == live.id + ":completion:" + String(stamp) else { return nil }
        let value = state(id)
        guard !value.sending, !value.context.isEmpty, value.replyOptions.count == 3 else { return nil }
        return CompletionReply(id: id, turn: stamp, context: value.context, options: value.replyOptions)
    }

    func sendCompletionReply(_ reply: CompletionReply, choice: Int, for notice: IslandActivity) -> Bool {
        guard reply.options.indices.contains(choice), completionReply(for: notice) == reply else { return false }
        send(reply.options[choice].body, source: "codex", id: reply.id)
        return true
    }

    private func isCurrentCompletion(_ item: IslandActivity, stamp: Double) -> Bool {
        hub.agentSessions.contains {
            $0.id == item.id && $0.isCompletedAgentSession && $0.progress?.observedAt == stamp
        }
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
        if source != "codex", let session = session(id, source: source), !ready(session) {
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
                if result.busy {
                    $0.unsentReply = text; $0.status = "此会话需在原应用中实时引导。未发送。"
                } else {
                    $0.status = result.error ?? (result.delivered == true && result.text == nil ? "已发送至 Codex" : "Agent 已回复")
                    if result.error == nil || result.delivered == true {
                        $0.suggestions = []; $0.replyOptions = []; $0.context = ""
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

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
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
                    return .init(error: "API 未返回三条有效的短标题和完整回复")
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
