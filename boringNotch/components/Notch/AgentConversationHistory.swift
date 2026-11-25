import Foundation
import Darwin

// Visible-message formats follow Agent Notch's ConversationParser (Apache-2.0).
enum AgentConversationSource: String, Hashable, Sendable {
    case codex, claude, gemini, antigravity, doubao

    var directory: String {
        switch self {
        case .codex: ".codex/sessions"
        case .claude: ".claude/projects"
        case .gemini: ".gemini/tmp"
        case .antigravity: ".gemini/antigravity/brain"
        case .doubao: ""
        }
    }
    var appName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .gemini: "Gemini CLI"
        case .antigravity: "Antigravity"
        case .doubao: "豆包 CLI"
        }
    }


    var defaultDirectory: URL? {
        guard self != .doubao, let account = getpwuid(getuid()), let home = account.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home))
            .appending(path: directory, directoryHint: .isDirectory)
    }

    func matchesFile(_ name: String, id: UUID) -> Bool {
        let id = id.uuidString.lowercased()
        let name = name.lowercased()
        if self == .claude { return name == id + ".jsonl" }
        if self == .gemini {
            guard name.hasPrefix("session-"), name.hasSuffix(".jsonl") || name.hasSuffix(".json") else { return false }
            let stem = (name as NSString).deletingPathExtension
            return stem.hasSuffix("-" + id.prefix(8)) || stem.hasSuffix("-" + id)
        }
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return false }
        return name.hasSuffix("-" + id + ".jsonl") || name.contains("-" + id + "_")
    }
}

struct AgentConversationMessage: Equatable, Identifiable, Sendable {
    var id: UInt64
    var role: String
    var text: String
}

struct AgentConversationPage: Sendable {
    var messages: [AgentConversationMessage]
    var before: UInt64?
}

enum AgentConversationHistory {
    enum AccessError: Error, Equatable { case noAccess, noSession }

    static func read(
        bookmark: Data?, source: AgentConversationSource, id: UUID, before: UInt64?, knownFile: URL?
    ) throws -> (file: URL, page: AgentConversationPage) {
        let root: URL
        if let bookmark {
            var stale = false
            root = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale, root.startAccessingSecurityScopedResource() else { throw AccessError.noAccess }
        } else {
            guard let directory = source.defaultDirectory else { throw AccessError.noAccess }
            root = directory
        }
        defer { if bookmark != nil { root.stopAccessingSecurityScopedResource() } }
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        let verifiedHint = knownFile.flatMap { candidate in
            matches(candidate, within: resolved, source: source, id: id) ? candidate : nil
        }
        guard let file = try verifiedHint ?? find(in: resolved, source: source, id: id) else { throw AccessError.noSession }
        return (file, try page(file: file, source: source, before: before))
    }

    static func find(in root: URL, source: AgentConversationSource, id: UUID) throws -> URL? {
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw AccessError.noAccess }
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw AccessError.noAccess
        }
        if source == .antigravity {
            let file = resolved.appendingPathComponent(id.uuidString.lowercased())
                .appendingPathComponent(".system_generated/logs/transcript.jsonl")
            return matches(file, within: resolved, source: source, id: id) ? file : nil
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let walk = FileManager.default.enumerator(at: resolved, includingPropertiesForKeys: Array(keys),
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw AccessError.noAccess
        }
        var candidates: [(URL, Date)] = []
        for case let file as URL in walk {
            try Task.checkCancellation()
            guard matches(file, within: resolved, source: source, id: id),
                  let info = try? file.resourceValues(forKeys: keys) else { continue }
            candidates.append((file, info.contentModificationDate ?? .distantPast))
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }

    private static func matches(_ file: URL, within root: URL, source: AgentConversationSource, id: UUID) -> Bool {
        let expectedAntigravityPath = root.appendingPathComponent(id.uuidString.lowercased())
            .appendingPathComponent(".system_generated/logs/transcript.jsonl")
        guard (source == .antigravity ? file.path == expectedAntigravityPath.path : source.matchesFile(file.lastPathComponent, id: id)),
              let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              info.isRegularFile == true, info.isSymbolicLink != true,
              file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { return false }
        if source == .gemini {
            return file.deletingLastPathComponent().lastPathComponent == "chats" && matchesGeminiMetadata(file, id: id)
        }
        return source != .codex || matchesCodexMetadata(file, id: id)
    }

    private static func matchesCodexMetadata(_ file: URL, id: UUID) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 131_072) else { return false }
        for line in header.split(separator: 10).prefix(16) {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  row["type"] as? String == "session_meta",
                  let payload = row["payload"] as? [String: Any],
                  let identity = payload["id"] as? String else { continue }
            return UUID(uuidString: identity) == id
        }
        return false
    }

    private static func matchesGeminiMetadata(_ file: URL, id: UUID) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 131_072) else { return false }
        if file.pathExtension == "jsonl",
           let first = data.split(separator: 10).first,
           let row = (try? JSONSerialization.jsonObject(with: Data(first))) as? [String: Any] {
            return (row["sessionId"] as? String).flatMap(UUID.init(uuidString:)) == id
        }
        // The legacy JSON header puts the UUID before the message array.
        let header = String(decoding: data, as: UTF8.self)
        let boundary = header.range(of: #""messages"\s*:"# , options: .regularExpression)?.lowerBound ?? header.endIndex
        guard let match = header[..<boundary].range(of: #""sessionId"\s*:\s*"[0-9a-fA-F-]{36}""#,
                                                    options: .regularExpression) else { return false }
        return UUID(uuidString: String(header[match].dropLast().suffix(36))) == id
    }

    /// Gemini CLI uses append-only records in newer versions and whole-history
    /// checkpoints in older ones. Only user/model message text is displayed.
    private static func geminiPage(file: URL, before: UInt64?) throws -> AgentConversationPage {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let maxRead: UInt64 = 16 * 1024 * 1024
        let start = end > maxRead && file.pathExtension == "jsonl" ? end - maxRead : 0
        guard end - start <= maxRead else { throw AccessError.noAccess }
        try handle.seek(toOffset: start)
        let data = (try handle.read(upToCount: Int(end - start))) ?? Data()
        var records: [[String: Any]] = []
        var positions: [String: Int] = [:]
        func reindex() {
            positions.removeAll(keepingCapacity: true)
            for (index, row) in records.enumerated() {
                if let id = row["id"] as? String { positions[id] = index }
            }
        }
        func apply(_ row: [String: Any]) {
            if let saved = row["messages"] as? [[String: Any]]
                ?? (row["$set"] as? [String: Any])?["messages"] as? [[String: Any]] {
                records = saved
                reindex()
            } else if let rewind = row["$rewindTo"] as? String, let index = positions[rewind] {
                records = Array(records.prefix(index + 1))
                reindex()
            } else if let patch = row["$patch"] as? [String: Any] {
                for update in (patch["updates"] as? [[String: Any]]) ?? [patch] {
                    guard let id = update["id"] as? String, let index = positions[id] else { continue }
                    if let content = update["content"] { records[index]["content"] = content }
                    if let content = update["displayContent"] { records[index]["displayContent"] = content }
                }
                if let removed = patch["removeIds"] as? [String], !removed.isEmpty {
                    let ids = Set(removed)
                    records.removeAll { row in (row["id"] as? String).map(ids.contains) ?? false }
                    reindex()
                }
                if let order = patch["orderIds"] as? [String], !order.isEmpty {
                    let ordered = order.compactMap { positions[$0].map { records[$0] } }
                    let known = Set(order)
                    records = ordered + records.filter { row in !((row["id"] as? String).map(known.contains) ?? false) }
                    reindex()
                }
            } else if row["type"] as? String == "user" || row["type"] as? String == "gemini" {
                if let id = row["id"] as? String {
                    if let old = positions[id] { records[old] = row; return }
                    positions[id] = records.count
                }
                records.append(row)
            }
        }
        if file.pathExtension == "jsonl" {
            let lines = data.split(separator: 10)
            for line in start == 0 ? lines[...] : lines.dropFirst() {
                try Task.checkCancellation()
                if let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] { apply(row) }
            }
        } else if let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            apply(row)
        }
        let visible = records.enumerated().compactMap { index, row -> AgentConversationMessage? in
            guard UInt64(index) < (before ?? .max) else { return nil }
            return geminiMessage(row, offset: UInt64(index))
        }
        let page = Array(visible.suffix(6))
        return AgentConversationPage(messages: page, before: visible.count > page.count ? page.first?.id : nil)
    }

    private static func geminiMessage(_ row: [String: Any], offset: UInt64) -> AgentConversationMessage? {
        guard let type = row["type"] as? String, type == "user" || type == "gemini" else { return nil }
        func textParts(_ value: Any?) -> String {
            if let string = value as? String { return string }
            if let parts = value as? [Any] {
                return parts.compactMap { part -> String? in
                    if let string = part as? String { return string }
                    guard let block = part as? [String: Any], block["thought"] as? Bool != true else { return nil }
                    return block["text"] as? String
                }.joined(separator: "\n")
            }
            return ""
        }
        let preferred = textParts(row["displayContent"])
        let body = (preferred.isEmpty ? textParts(row["content"]) : preferred).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return AgentConversationMessage(id: offset, role: type == "user" ? "user" : "assistant", text: body)
    }

    static func page(file: URL, source: AgentConversationSource, before: UInt64?) throws -> AgentConversationPage {
        if source == .gemini { return try geminiPage(file: file, before: before) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var upper = min(before ?? end, end)
        var records: [AgentConversationMessage] = []
        // A bounded read per page also handles logs ending in many tool rows.
        for _ in 0..<32 where upper > 0 {
            try Task.checkCancellation()
            let start = upper > 262_144 ? upper - 262_144 : 0
            try handle.seek(toOffset: start)
            let bytes = try handle.read(upToCount: Int(upper - start)) ?? Data()
            let first = start == 0 ? 0 : bytes.firstIndex(of: 10).map { $0 + 1 } ?? bytes.count
            var chunk: [AgentConversationMessage] = []
            var offset = start + UInt64(first)
            for line in bytes.dropFirst(first).split(separator: 10, omittingEmptySubsequences: false) {
                if let message = message(from: Data(line), source: source, offset: offset) {
                    chunk.append(message)
                }
                offset += UInt64(line.count) + 1
            }
            let previous = first < bytes.count ? start + UInt64(first) : start
            records.insert(contentsOf: chunk, at: 0)
            upper = previous
            if records.count >= 6 { break }
        }
        let displayed = Array(records.suffix(6))
        let cursor = records.count > displayed.count ? displayed[0].id : upper
        return AgentConversationPage(messages: displayed, before: cursor > 0 ? cursor : nil)
    }

    static func message(from data: Data, source: AgentConversationSource, offset: UInt64) -> AgentConversationMessage? {
        guard let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = row["type"] as? String else { return nil }
        let role: String
        let text: String
        switch source {
        case .codex:
            guard type == "event_msg", let payload = row["payload"] as? [String: Any],
                  let event = payload["type"] as? String else { return nil }
            if event == "item_completed" {
                guard let item = payload["item"] as? [String: Any],
                      let itemType = item["type"] as? String, visiblePhase(item["phase"]),
                      let blocks = item["content"] as? [[String: Any]] else { return nil }
                switch itemType {
                case "UserMessage": role = "user"
                case "AgentMessage": role = "assistant"
                default: return nil
                }
                text = plainText(blocks)
            } else {
                guard visiblePhase(payload["phase"]), let body = payload["message"] as? String else { return nil }
                switch event {
                case "user_message": role = "user"
                case "agent_message": role = "assistant"
                default: return nil
                }
                text = body
            }
        case .claude:
            guard ["user", "assistant"].contains(type), row["isMeta"] as? Bool != true,
                  row["isSidechain"] as? Bool != true, let message = row["message"] as? [String: Any] else { return nil }
            role = type
            if let body = message["content"] as? String { text = body }
            else { text = plainText(message["content"] as? [[String: Any]] ?? []) }
        case .doubao:
            return nil
        case .gemini:
            return geminiMessage(row, offset: offset)
        case .antigravity:
            guard let body = row["content"] as? String, row["status"] as? String == "DONE" else { return nil }
            switch (type, row["source"] as? String) {
            case ("USER_INPUT", "USER_EXPLICIT"):
                role = "user"
                text = antigravityUserText(body)
            case ("GENERIC", "MODEL"):
                // In desktop transcripts this type also stores tool execution receipts.
                guard body.range(of: #"^\s*Created At:\s*\d{4}-\d{2}-\d{2}T[^\r\n]+\r?\n\s*Completed At:\s*\d{4}-\d{2}-\d{2}T"#,
                                 options: .regularExpression) == nil else { return nil }
                role = "assistant"
                text = body
            case ("PLANNER_RESPONSE", "MODEL"):
                // Text-only replies also use this record type. Tool turns and
                // the separate thinking field do not belong in the transcript.
                guard row["tool_calls"] == nil || (row["tool_calls"] as? [Any])?.isEmpty == true else { return nil }
                role = "assistant"
                text = body
            default: return nil
            }
        }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.hasPrefix("<codex_internal_context"),
              !clean.hasPrefix("<environment_context"), !clean.hasPrefix("<command-name>"),
              !clean.hasPrefix("<local-command"), !clean.hasPrefix("Caveat:") else { return nil }
        return AgentConversationMessage(id: offset, role: role, text: clean)
    }

    private static func antigravityUserText(_ body: String) -> String {
        let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = "<USER_REQUEST>"
        guard clean.hasPrefix(opening) else { return clean }
        let request = clean.dropFirst(opening.count)
        let closing = request.range(of: #"</USER_REQUEST>\s*(?:<ADDITIONAL_METADATA>|<USER_SETTINGS_CHANGE>|$)"#,
                                    options: .regularExpression)
        let end = closing?.lowerBound ?? request.range(of: "<ADDITIONAL_METADATA>")?.lowerBound
        return String(request[..<(end ?? request.endIndex)])
    }

    private static func visiblePhase(_ value: Any?) -> Bool {
        guard let phase = value as? String else { return value == nil || value is NSNull }
        return ["commentary", "final_answer"].contains(phase)
    }

    private static func plainText(_ blocks: [[String: Any]]) -> String {
        blocks.compactMap { block in
            guard let kind = block["type"] as? String, ["text", "Text"].contains(kind) else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
    }
}
