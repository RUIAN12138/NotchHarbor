import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import Security

/// Reads the current desktop client's own approval notification lifecycle.
/// Only the timestamps and correlation IDs are kept. Logs are never written.
final class CodexDesktopApprovals: @unchecked Sendable {
    static let shared = CodexDesktopApprovals()
    // A desktop prompt can stay open for hours. The response log normally
    // clears it sooner. Use a bounded recovery window for abandoned prompts.
    static let lifetime: TimeInterval = 24 * 60 * 60

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

    struct Cursor {
        var offset: UInt64 = 0
        var fileNumber: UInt64?
        var events: [Event] = []
    }

    private static let filename = try! NSRegularExpression(
        pattern: #"^codex-desktop-([0-9a-fA-F-]{36})-(\d+)-.*\.log$"#)
    private static let notificationMarker = "[electron-message-handler] [desktop-notifications] "
    private static let endMarker = "[host-app-server-manager] Sending server response "
    private static let acceptingKinds = ["permissionRequest", "commandExecution", "fileChange"]
    private static let signalBytes = [Data(notificationMarker.utf8), Data(endMarker.utf8)]
    private static let limit: UInt64 = 8 * 1024 * 1024
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

    static func currentFiles(home: URL, pids: Set<pid_t>, now: Date) -> [URL: String] {
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

    static func scan(_ url: URL, run: String, cursor: inout Cursor, now: Date) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        let fileNumber = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        if size < cursor.offset || fileNumber != cursor.fileNumber { cursor = Cursor(fileNumber: fileNumber) }
        cursor.events.removeAll { now.timeIntervalSince($0.date) >= lifetime }
        if size == cursor.offset { return }
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
                guard part.count <= 32 * 1024, signalBytes.contains(where: { part.range(of: $0) != nil }),
                      let event = event(String(decoding: part, as: UTF8.self), run: run, clock: clock),
                      now.timeIntervalSince(event.date) < lifetime,
                      event.date.timeIntervalSince(now) <= 5 else { continue }
                cursor.events.append(event)
            }
            cursor.events = Array(cursor.events.suffix(512))
        } catch {}
    }

    static func event(_ line: String, run: String, clock: ISO8601DateFormatter) -> Event? {
        let prefix = line.split(separator: " ", maxSplits: 2)
        guard prefix.count == 3, let date = clock.date(from: String(prefix[0])) else { return nil }
        let body = prefix[2]
        let notification: Substring? = body.hasPrefix(notificationMarker)
            ? body.dropFirst(notificationMarker.count) : nil
        let starting = notification.map {
            $0.hasPrefix("received approval ") || $0.hasPrefix("show approval ") || $0.hasPrefix("show notification ")
        } == true
        guard starting || body.hasPrefix(endMarker) else { return nil }
        let parts = body.split(separator: " ")
        func field(_ key: String) -> String? {
            let prefix = key + "="
            return parts.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
        if starting {
            guard let id = field("requestId"), validID(id),
                  let session = field("conversationId").flatMap(UUID.init(uuidString:)),
                  let kind = field("kind"), acceptingKinds.contains(kind)
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

/// Pairs the visible, enabled original controls in Codex Desktop with the
/// request shown in the island. The caller selects a decision explicitly.
final class CodexDesktopApprovalPanel: @unchecked Sendable {
    static let shared = CodexDesktopApprovalPanel()

    struct DecisionLabels {
        private static let allow = [
            "allow once", "allow for this turn", "approve once",
            "仅允许本次", "仅本次允许", "允许本次", "本次允许", "仅允许这次", "仅允许一次", "允许一次",
            "仅本轮允许", "仅允许本轮", "本轮允许", "仅限本轮",
            "僅允許本次", "本次允許", "允許一次", "僅允許一次", "僅允許本輪"
        ]
        private static let deny = ["deny", "decline", "拒绝", "拒絕"]

        private static let shortcut = try! NSRegularExpression(
            pattern: #"(?:\s+(?:esc|escape|enter|return)|\s*[⌘⌥⌃⇧]*\s*[↵⏎⎋])$"#)
        private static let ignoredFormatting = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{2066}\u{2067}\u{2068}\u{2069}")

        static func role(_ label: String) -> CodexApprovalPacket.Choice? {
            let words = label.components(separatedBy: ignoredFormatting).joined()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            // Electron can append the card's keycap to the accessible button
            // name. Drop only a recognized trailing key, then match the scope.
            let name = shortcut.stringByReplacingMatches(in: words,
                range: NSRange(words.startIndex..., in: words), withTemplate: "")
            if allow.contains(name) { return .allow }
            if deny.contains(name) { return .deny }
            return nil
        }
    }

    private static let desktopRequirement: SecRequirement? = {
        var requirement: SecRequirement?
        let rule = #"anchor apple generic and identifier "com.openai.codex" and certificate leaf[subject.OU] = "2DC432GLL2""#
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }()

    private static func officialDesktop(_ pid: pid_t) -> Bool {
        guard let desktopRequirement else { return false }
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        return SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess
            && guest.map { SecCodeCheckValidity($0, [], desktopRequirement) == errSecSuccess } == true
    }

    private struct Match {
        let allow: AXUIElement
        let deny: AXUIElement
        let detail: String

        func equals(_ other: Self) -> Bool {
            CFEqual(allow, other.allow) && CFEqual(deny, other.deny)
                && detail.utf8.elementsEqual(other.detail.utf8)
        }
    }

    private struct Record {
        let packet: CodexApprovalPacket
        let match: Match
    }

    private let lock = NSLock()
    private var record: Record?
    private var lastScan = Date.distantPast
    private var dispatchedID: UUID?
    private var checkedPID: pid_t?
    private var trustedPID = false

    /// The panel uses a local presentation key. It does not infer a Codex
    /// conversation ID from an accessibility window title or a different log.
    func pending(now: Date = Date()) -> [CodexApprovalPacket] {
        lock.lock()
        defer { lock.unlock() }
        if now.timeIntervalSince(lastScan) >= 1.25 {
            lastScan = now
            guard let match = uniqueVisibleMatch() else { record = nil; return [] }
            if record?.match.equals(match) != true {
                let id = UUID()
                let stamp = now.timeIntervalSince1970
                record = Record(packet: CodexApprovalPacket(id: id, sessionID: id,
                    tool: "Codex 桌面审批", cwd: "", reason: "", command: match.detail,
                    createdAt: stamp, expires: stamp + CodexDesktopApprovals.lifetime,
                    pid: 0, route: "desktop-panel"), match: match)
            }
        }
        return record.map { [$0.packet] } ?? []
    }

    /// On submission the original controls are found again. A changed,
    /// disabled or ambiguous card can never receive a previous decision.
    func submit(_ choice: CodexApprovalPacket.Choice, id: UUID, session: UUID,
                home: URL) -> CodexApprovalSubmission {
        // Logs confirm a response, but access to them is independent of AX.
        // Take the checkpoint before revalidating the live card, so there is
        // no filesystem work between matching and pressing the original button.
        let checkpoint = Self.responseFiles(home: home)
        let dispatch = lock.withLock { () -> (CodexApprovalSubmission, Date?) in
            guard choice != .native, let record, record.packet.id == id,
                  record.packet.sessionID == session, record.packet.expires > Date().timeIntervalSince1970
            else { return (.notSent, nil) }
            if dispatchedID == id { return (.unconfirmed, nil) }
            guard let current = uniqueVisibleMatch(), current.equals(record.match) else { return (.notSent, nil) }
            let button = choice == .allow ? current.allow : current.deny
            let started = Date()
            AXUIElementSetMessagingTimeout(button, 1)
            defer { AXUIElementSetMessagingTimeout(button, 0) }
            let action = AXUIElementPerformAction(button, kAXPressAction as CFString)
            // A timed-out accessibility call can still reach the target.
            guard action == .success || action == .cannotComplete else { return (.notSent, nil) }
            dispatchedID = id
            return (.unconfirmed, started)
        }
        guard let started = dispatch.1, !checkpoint.isEmpty else { return dispatch.0 }

        // Let polling continue while we wait for independent confirmation.
        let deadline = ContinuousClock.now + .seconds(3)
        var received = false
        while ContinuousClock.now < deadline {
            if !received {
                received = Self.receivedResponse(home: home, since: started, checkpoint: checkpoint, choice: choice)
            }
            if received, lock.withLock({
                guard let match = record?.match, record?.packet.id == id else { return true }
                let button = choice == .allow ? match.allow : match.deny
                return !Self.enabled(button) || uniqueVisibleMatch()?.equals(match) != true
            }) {
                return .confirmed
            }
            Thread.sleep(forTimeInterval: 0.12)
        }
        return .unconfirmed
    }

    private func uniqueVisibleMatch() -> Match? {
        guard AXIsProcessTrusted() else { return nil }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        guard running.count == 1, let pid = running.first?.processIdentifier else { return nil }
        if checkedPID != pid {
            checkedPID = pid
            trustedPID = Self.officialDesktop(pid)
        }
        guard trustedPID else { return nil }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.10)
        let windows = Self.attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return Self.uniqueMatch(in: windows)
    }

    private static func uniqueMatch(in windows: [AXUIElement]) -> Match? {
        // A separate web area may belong to an in-app web page. Accept controls
        // only from Codex's own application document and never a nested frame.
        var list = windows.filter { attribute($0, kAXMinimizedAttribute) as? Bool != true }.map { ($0, false) }
        let limit = ContinuousClock.now + .milliseconds(500)
        var matches: [Match] = []
        var cursor = 0
        while cursor < list.count, cursor < 1_600, ContinuousClock.now < limit {
            let (node, insideDocument) = list[cursor]
            cursor += 1
            let nodeRole = role(node)
            var inside = insideDocument
            if nodeRole == "AXWebArea" {
                guard !inside, let raw = attribute(node, kAXURLAttribute),
                      let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:)),
                      url.scheme == "app", url.host(percentEncoded: false) == "-", url.path == "/index.html"
                else { continue }
                inside = true
            }
            if inside, nodeRole == kAXButtonRole, label(node).flatMap(DecisionLabels.role) == .allow,
               enabled(node), let match = card(containing: node) {
                matches.append(match)
                if matches.count > 1 { return nil }
            }
            list += (attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(140).map { ($0, inside) }
        }
        guard cursor == list.count, matches.count == 1 else { return nil }
        return matches.first
    }

    private static func card(containing allow: AXUIElement) -> Match? {
        var current = allow
        for _ in 0..<8 {
            guard let parent = attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = parent as! AXUIElement
            guard role(current) != "AXWebArea" else { return nil }
            guard let nodes = children(in: current, limit: 56) else { return nil }
            let buttons = nodes.filter { role($0) == kAXButtonRole && enabled($0) }
            let allows = buttons.filter { label($0).flatMap(DecisionLabels.role) == .allow }
            let denies = buttons.filter { label($0).flatMap(DecisionLabels.role) == .deny }
            if allows.count > 1 || denies.count > 1 { return nil }
            guard let deny = denies.first, allows.count == 1 else { continue }

            var seen = Set<String>()
            let lines = nodes.compactMap { node -> String? in
                guard [kAXStaticTextRole, kAXHeadingRole].contains(role(node)), let text = label(node),
                      DecisionLabels.role(text) == nil, seen.insert(text).inserted else { return nil }
                return text
            }
            let detail = lines.joined(separator: "\n")
            guard lines.count >= 1, lines.count <= 16, detail.count >= 8, detail.utf8.count <= 7_000 else { continue }
            return Match(allow: allow, deny: deny, detail: detail)
        }
        return nil
    }

    private static func children(in root: AXUIElement, limit: Int) -> [AXUIElement]? {
        var list = [root]
        var cursor = 0
        while cursor < list.count && list.count <= limit {
            let item = list[cursor]
            cursor += 1
            if role(item) != kAXButtonRole {
                list += attribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
            }
        }
        return list.count <= limit ? list : nil
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    private static func role(_ element: AXUIElement) -> String {
        attribute(element, kAXRoleAttribute) as? String ?? ""
    }

    private static func label(_ element: AXUIElement) -> String? {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let value = attribute(element, key) as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func enabled(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXEnabledAttribute) as? Bool) == true
    }

    private static func responseFiles(home: URL) -> [URL: UInt64] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        let files = CodexDesktopApprovals.currentFiles(home: home, pids: Set(apps.map(\.processIdentifier)), now: Date())
        var offsets: [URL: UInt64] = [:]
        for path in files.keys {
            if let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= 0 {
                offsets[path] = UInt64(size)
            }
        }
        return offsets
    }

    private static func receivedResponse(home: URL, since start: Date, checkpoint: [URL: UInt64],
                                         choice: CodexApprovalPacket.Choice) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let recentFiles = Self.responseFiles(home: home)
        for (path, size) in recentFiles {
            let offset = checkpoint[path] ?? 0
            guard size > offset, size - offset <= 128 * 1024,
                  let handle = try? FileHandle(forReadingFrom: path) else { continue }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.readToEnd() else { continue }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            if lines.contains(where: { receiptMatches(String($0), since: start, choice: choice, clock: formatter) }) {
                return true
            }
        }
        return false
    }

    static func receiptMatches(_ line: String, since start: Date, choice: CodexApprovalPacket.Choice,
                               clock: ISO8601DateFormatter) -> Bool {
        let prefix = line.split(separator: " ", maxSplits: 2)
        guard prefix.count == 3, let date = clock.date(from: String(prefix[0])),
              date.timeIntervalSince(start) >= -0.03,
              prefix[2].hasPrefix("[host-app-server-manager] Sending server response "),
              let marker = prefix[2].range(of: " response="),
              let fields = try? JSONSerialization.jsonObject(with: Data(prefix[2][marker.upperBound...].utf8)) as? [String: Any]
        else { return false }

        let metadata = prefix[2][..<marker.lowerBound]
        if metadata.contains("method=item/permissions/requestApproval") {
            guard let grants = fields["permissions"] as? [String: Any], fields["scope"] as? String == "turn" else { return false }
            let hasGrant = grants.values.contains { value in
                if let item = value as? [String: Any] {
                    return item.values.contains {
                        if let flag = $0 as? Bool { return flag }
                        if let values = $0 as? [Any] { return !values.isEmpty }
                        return false
                    }
                }
                return false
            }
            return choice == .allow ? hasGrant : !hasGrant
        }
        guard metadata.contains("method=item/commandExecution/requestApproval")
                || metadata.contains("method=item/fileChange/requestApproval"),
              let decision = fields["decision"] as? String else { return false }
        return choice == .allow ? decision == "accept" : ["decline", "cancel"].contains(decision)
    }
}
