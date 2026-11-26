import CoreFoundation
import CryptoKit
import Darwin
import Foundation

enum CodexApprovalSubmission: String {
    case notSent, unconfirmed, confirmed
}

struct CodexApprovalPacket: Codable, Equatable {
    enum Choice: String { case allow, deny, native }

    let id: UUID
    let sessionID: UUID
    let tool: String
    let cwd: String
    let reason: String
    let command: String?
    let createdAt: TimeInterval
    let expires: TimeInterval
    let pid: Int32
    var route: String? = nil
    var provider: String? = nil
    var denialCancelsTurn: Bool? = nil

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".multiagent-notch/notch-harbor-approvals", isDirectory: true)

    static func pending(in directory: URL, now: TimeInterval = Date().timeIntervalSince1970) -> [Self] {
        guard privatePath(directory.deletingLastPathComponent(), type: .typeDirectory),
              privatePath(directory, type: .typeDirectory),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }.prefix(128).compactMap { file in
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  privatePath(file, type: .typeRegular, maxBytes: 32768),
                  let data = try? Data(contentsOf: file),
                  let request = try? JSONDecoder().decode(Self.self, from: data),
                  request.id == id, request.route == nil,
                  ["claude", "codex"].contains(request.provider ?? "codex"),
                  request.createdAt <= now + 5, request.expires > now,
                  (0...60).contains(request.expires - request.createdAt),
                  request.pid > 1, kill(request.pid, 0) == 0
            else { return nil }
            return request
        }.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    func acknowledge(in directory: URL) {
        let ready = directory.appendingPathComponent(id.uuidString.lowercased() + ".ready")
        try? Data().write(to: ready, options: .withoutOverwriting)
    }

    func submit(_ choice: Choice, in directory: URL) throws {
        guard Self.pending(in: directory).contains(self), choice != .allow || command != nil else {
            throw CocoaError(.fileNoSuchFile)
        }
        let decision = directory.appendingPathComponent(id.uuidString.lowercased() + ".decision")
        try Data(choice.rawValue.utf8).write(to: decision, options: .withoutOverwriting)
    }

    func consumeReceipt(_ choice: Choice, in directory: URL) -> Bool {
        let url = directory.appendingPathComponent(id.uuidString.lowercased() + ".receipt")
        guard Self.privatePath(url, type: .typeRegular, maxBytes: 8),
              (try? String(contentsOf: url, encoding: .utf8)) == choice.rawValue else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }

    private static func privatePath(_ url: URL, type: FileAttributeType, maxBytes: Int? = nil) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == type,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o077 == 0 else { return false }
        return maxBytes.map { (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= $0 } ?? true
    }
}

/// Tracks only requests received on a live App Server connection owned by the helper.
/// The worker that owns that connection sends the response using the original wire ID.
final class CodexServerApprovals: @unchecked Sendable {
    static let shared = CodexServerApprovals()

    private struct Entry {
        let packet: CodexApprovalPacket
        var choice: CodexApprovalPacket.Choice?
        var onReceipt: ((Bool) -> Void)?
    }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func insert(_ packet: CodexApprovalPacket) {
        lock.lock()
        defer { lock.unlock() }
        entries[packet.id] = Entry(packet: packet)
    }

    func remove(_ id: UUID, confirmed: Bool = false) {
        lock.lock()
        let completion = entries.removeValue(forKey: id)?.onReceipt
        lock.unlock()
        completion?(confirmed)
    }

    func expireReceipt(_ id: UUID) {
        lock.lock()
        let completion = entries[id]?.onReceipt
        entries[id]?.onReceipt = nil
        lock.unlock()
        completion?(false)
    }

    func pending() -> [CodexApprovalPacket] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        return entries.values.filter { $0.packet.expires > now }.map(\.packet)
            .sorted { $0.createdAt < $1.createdAt }
    }

    func choose(_ choice: CodexApprovalPacket.Choice, id: UUID, sessionID: UUID,
                onReceipt: ((Bool) -> Void)? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[id], entry.packet.sessionID == sessionID,
              entry.packet.expires > Date().timeIntervalSince1970,
              entry.choice == nil, choice != .native else { return false }
        entries[id]?.choice = choice
        entries[id]?.onReceipt = onReceipt
        return true
    }

    func choice(for id: UUID) -> CodexApprovalPacket.Choice? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.choice
    }
}

/// A manual App Server request whose entire one-time scope can be shown in the island.
struct CodexServerReview {
    struct FileProposal: Equatable {
        let detail: String
        let digest: SHA256.Digest
    }

    let tool: String
    let cwd: String
    let detail: String
    private var permissions: [String: Any]? = nil
    var denialCancelsTurn = false

    func response(to choice: CodexApprovalPacket.Choice?) -> [String: Any] {
        if let permissions {
            return ["permissions": choice == .allow ? permissions : [:], "scope": "turn"]
        }
        let decision = choice == .allow ? "accept" : choice == .deny && !denialCancelsTurn ? "decline" : "cancel"
        return ["decision": decision]
    }

    static func make(method: String, params: [String: Any], workspace: String,
                     proposedFiles: String?) -> Self? {
        func absent(_ key: String) -> Bool { params[key] == nil || params[key] is NSNull }
        switch method {
        case "item/commandExecution/requestApproval":
            var denialCancelsTurn = false
            if !absent("availableDecisions") {
                guard let choices = params["availableDecisions"] as? [Any] else { return nil }
                let names = choices.compactMap { $0 as? String }
                guard names.contains("accept"), names.contains("decline") || names.contains("cancel") else { return nil }
                denialCancelsTurn = !names.contains("decline")
            }
            guard absent("additionalPermissions"), absent("networkApprovalContext"),
                  let command = params["command"] as? String, !command.isEmpty, command.utf8.count <= 8000,
                  let cwd = params["cwd"] as? String, safePath(cwd) else { return nil }
            return Self(tool: "Bash", cwd: cwd, detail: visibleText(command),
                        denialCancelsTurn: denialCancelsTurn)
        case "item/fileChange/requestApproval":
            // A grantRoot asks to authorize additional future writes.
            guard absent("grantRoot"), let proposedFiles else { return nil }
            return Self(tool: "文件变更", cwd: workspace, detail: proposedFiles)
        case "item/permissions/requestApproval":
            guard let itemID = params["itemId"] as? String, !itemID.isEmpty,
                  let requested = params["permissions"] as? [String: Any],
                  let cwd = params["cwd"] as? String, safePath(cwd),
                  let detail = permissionDetails(requested) else { return nil }
            return Self(tool: "本轮权限", cwd: cwd, detail: detail, permissions: requested)
        default:
            return nil
        }
    }

    private static func safePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 2000
            && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func permissionDetails(_ requested: [String: Any]) -> String? {
        guard Set(requested.keys).isSubset(of: ["network", "fileSystem"]) else { return nil }
        var rows: [String] = []
        if let value = requested["network"], !(value is NSNull) {
            guard let network = value as? [String: Any], Set(network.keys) == ["enabled"],
                  let enabled = network["enabled"] as? NSNumber,
                  CFGetTypeID(enabled) == CFBooleanGetTypeID() else { return nil }
            if enabled.boolValue { rows.append("联网 · 本轮") }
        }
        if let value = requested["fileSystem"], !(value is NSNull) {
            guard let files = value as? [String: Any],
                  Set(files.keys).isSubset(of: ["read", "write", "entries", "globScanMaxDepth"]),
                  files["globScanMaxDepth"] == nil || files["globScanMaxDepth"] is NSNull else { return nil }
            for key in ["read", "write"] {
                guard let value = files[key], !(value is NSNull) else { continue }
                guard let paths = value as? [String], paths.count <= 20,
                      paths.allSatisfy(safePath) else { return nil }
                rows += paths.map { (key == "read" ? "读取 · " : "写入 · ") + $0 }
            }
            if let value = files["entries"], !(value is NSNull) {
                guard let entries = value as? [[String: Any]], entries.count <= 20 else { return nil }
                for entry in entries {
                    guard Set(entry.keys) == ["access", "path"],
                          let access = entry["access"] as? String, ["read", "write"].contains(access),
                          let literal = entry["path"] as? [String: Any], Set(literal.keys) == ["type", "path"],
                          literal["type"] as? String == "path", let path = literal["path"] as? String,
                          safePath(path) else { return nil }
                    rows.append((access == "read" ? "读取 · " : "写入 · ") + path)
                }
            }
        }
        let result = rows.joined(separator: "\n")
        return rows.isEmpty || result.utf8.count > 16_000 ? nil : result
    }

    private static func visibleText(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            if scalar != "\n", scalar != "\t", CharacterSet.controlCharacters.contains(scalar) {
                return "⟦U+\(String(scalar.value, radix: 16, uppercase: true))⟧"
            }
            return String(scalar)
        }.joined()
    }

    static func fileProposal(_ changes: Any?) -> FileProposal? {
        guard let changes = changes as? [[String: Any]], (1...20).contains(changes.count) else { return nil }
        var rows: [String] = []
        for change in changes {
            guard let path = change["path"] as? String, safePath(path),
                  let kind = change["kind"] as? [String: Any],
                  let type = kind["type"] as? String, ["add", "delete", "update"].contains(type),
                  let diff = change["diff"] as? String, diff.utf8.count <= 15_000 else { return nil }
            let move = kind["move_path"] ?? kind["movePath"]
            let target: String
            if let move, !(move is NSNull) {
                guard let path = move as? String, safePath(path) else { return nil }
                target = " → " + path
            } else {
                target = ""
            }
            let operation = type == "add" ? "新增" : type == "delete" ? "删除" : "修改"
            rows.append("\(operation) · \(path)\(target)\n\(visibleText(diff))")
        }
        let result = rows.joined(separator: "\n\n")
        guard result.utf8.count <= 24_000,
              let original = try? JSONSerialization.data(withJSONObject: changes, options: .sortedKeys) else { return nil }
        return FileProposal(detail: result, digest: SHA256.hash(data: original))
    }
}
