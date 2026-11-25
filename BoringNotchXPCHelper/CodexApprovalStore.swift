import Darwin
import Foundation

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
    }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func insert(_ packet: CodexApprovalPacket) {
        lock.lock()
        defer { lock.unlock() }
        entries[packet.id] = Entry(packet: packet)
    }

    func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        entries[id] = nil
    }

    func pending() -> [CodexApprovalPacket] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        return entries.values.filter { $0.packet.expires > now }.map(\.packet)
            .sorted { $0.createdAt < $1.createdAt }
    }

    func choose(_ choice: CodexApprovalPacket.Choice, id: UUID, sessionID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[id], entry.packet.sessionID == sessionID,
              entry.packet.expires > Date().timeIntervalSince1970,
              entry.choice == nil, choice != .native else { return false }
        entries[id]?.choice = choice
        return true
    }

    func choice(for id: UUID) -> CodexApprovalPacket.Choice? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.choice
    }
}
