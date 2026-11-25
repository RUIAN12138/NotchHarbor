import AppKit
import CryptoKit
import Foundation

/// Reads the current desktop client's own approval notification lifecycle.
/// Only the timestamps and correlation IDs are kept. Logs are never written.
final class CodexDesktopApprovals: @unchecked Sendable {
    static let shared = CodexDesktopApprovals()
    static let lifetime: TimeInterval = 20 * 60

    struct Event: Equatable {
        enum Phase: Equatable {
            case requested(session: UUID, kind: String)
            case resolved(method: String)
        }
        let run: String
        let request: String
        let date: Date
        let phase: Phase
    }

    private struct Cursor {
        var offset: UInt64 = 0
        var events: [Event] = []
    }

    private static let filename = try! NSRegularExpression(
        pattern: #"^codex-desktop-([0-9a-fA-F-]{36})-(\d+)-.*\.log$"#)
    private static let startMarker = " info [electron-message-handler] [desktop-notifications] received approval "
    private static let endMarker = " info [host-app-server-manager] Sending server response "
    private static let limit: UInt64 = 384 * 1024
    private let lock = NSLock()
    private var cursors: [URL: Cursor] = [:]
    private var files: [URL: String] = [:]
    private var discoveryAt = Date.distantPast
    private var activePIDs = Set<pid_t>()

    func pending(home: URL, now: Date = Date()) -> [CodexApprovalPacket] {
        lock.lock()
        defer { lock.unlock() }
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .map(\.processIdentifier))
        guard !pids.isEmpty else {
            files.removeAll()
            cursors.removeAll()
            activePIDs = []
            return []
        }
        if pids != activePIDs || now.timeIntervalSince(discoveryAt) >= 5 {
            activePIDs = pids
            discoveryAt = now
            files = Self.currentFiles(home: home, pids: pids, now: now)
            cursors = cursors.filter { files[$0.key] != nil }
        }

        for (file, run) in files {
            var cursor = cursors[file] ?? Cursor()
            Self.scan(file, run: run, cursor: &cursor, now: now)
            cursors[file] = cursor
        }
        return Self.requests(from: cursors.values.flatMap(\.events), now: now)
    }

    private static func currentFiles(home: URL, pids: Set<pid_t>, now: Date) -> [URL: String] {
        let base = home.appendingPathComponent("Library/Logs/com.openai.codex", isDirectory: true)
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyy/MM/dd"
        let dated = [now, now.addingTimeInterval(-86_400)].map { base.appendingPathComponent(format.string(from: $0)) }
        let paths = dated.flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }.compactMap { path -> (URL, String, pid_t)? in
            let name = path.lastPathComponent
            guard let match = filename.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let run = Range(match.range(at: 1), in: name),
                  let pid = Range(match.range(at: 2), in: name).flatMap({ pid_t(name[$0]) })
            else { return nil }
            return (path, String(name[run]), pid)
        }
        let liveRuns = Set(paths.filter { pids.contains($0.2) }.map { $0.1 })
        return Dictionary(uniqueKeysWithValues: paths.filter { liveRuns.contains($0.1) }
            .sorted { $0.0.path > $1.0.path }.prefix(48).map { ($0.0, $0.1) })
    }

    private static func scan(_ url: URL, run: String, cursor: inout Cursor, now: Date) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        cursor.events.removeAll { now.timeIntervalSince($0.date) >= lifetime }
        if size == cursor.offset { return }
        if size < cursor.offset { cursor = Cursor() }
        let start = size - cursor.offset > limit ? size - limit : cursor.offset
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
            guard let data = try handle.read(upToCount: Int(size - start)),
                  let lastNewline = data.lastIndex(of: 10) else { return }
            let oldOffset = cursor.offset
            cursor.offset = start + UInt64(lastNewline + 1)
            let complete = data.prefix(lastNewline + 1).split(separator: 10)
            let lines = start > oldOffset ? complete.dropFirst() : complete[...]
            let clock = ISO8601DateFormatter()
            clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for part in lines {
                guard part.count <= 32 * 1024,
                      let event = event(String(decoding: part, as: UTF8.self), run: run, clock: clock),
                      now.timeIntervalSince(event.date) < lifetime,
                      event.date.timeIntervalSince(now) <= 5 else { continue }
                cursor.events.append(event)
            }
            cursor.events = Array(cursor.events.suffix(128))
        } catch {}
    }

    static func event(_ line: String, run: String, clock: ISO8601DateFormatter) -> Event? {
        let starting = line.contains(startMarker)
        guard starting || line.contains(endMarker) else { return nil }
        let parts = line.split(separator: " ")
        guard let first = parts.first, let date = clock.date(from: String(first)) else { return nil }
        func field(_ key: String) -> String? {
            let prefix = key + "="
            return parts.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
        if starting {
            guard let id = field("requestId"), validID(id),
                  let session = field("conversationId").flatMap(UUID.init(uuidString:)),
                  let kind = field("kind"), validID(kind)
            else { return nil }
            return Event(run: run, request: id, date: date, phase: .requested(session: session, kind: kind))
        }
        guard let id = field("id"), validID(id), let method = field("method"),
              method.hasPrefix("item/") && method.hasSuffix("/requestApproval") else { return nil }
        return Event(run: run, request: id, date: date, phase: .resolved(method: method))
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 96 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func requests(from events: [Event], now: Date) -> [CodexApprovalPacket] {
        var active: [String: [Event]] = [:]
        for event in events.sorted(by: {
            // If timestamps tie, record the request before its resolution.
            if $0.date == $1.date, case .requested = $0.phase, case .resolved = $1.phase { return true }
            return $0.date < $1.date
        }) where now.timeIntervalSince(event.date) < lifetime && event.date.timeIntervalSince(now) <= 5 {
            let key = event.run + ":" + event.request
            switch event.phase {
            case .requested:
                if !active[key, default: []].contains(where: { $0.phase == event.phase }) {
                    active[key, default: []].append(event)
                }
            case .resolved:
                // Desktop IDs identify pending requests within a client. If
                // several threads claim that ID, drop the ambiguous reminder.
                active[key] = nil
            }
        }
        return active.values.compactMap { group -> CodexApprovalPacket? in
            guard group.count == 1, let request = group.first,
                  case .requested(let session, let kind) = request.phase else { return nil }
            let raw = request.run + ":" + request.request + ":" + session.uuidString + ":" + String(request.date.timeIntervalSince1970)
            let hash = Array(SHA256.hash(data: Data(raw.utf8)))
            let id = UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                                 hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
            return CodexApprovalPacket(id: id, sessionID: session, tool: kind, cwd: "", reason: "",
                command: nil, createdAt: request.date.timeIntervalSince1970,
                expires: request.date.timeIntervalSince1970 + lifetime, pid: 0, route: "desktop")
        }.sorted { $0.createdAt < $1.createdAt }
    }
}
