import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import OSLog
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
            "仅本轮允许", "仅允许本轮", "本轮允许", "仅限本轮", "允许此回合", "仅允许此回合",
            "僅允許本次", "本次允許", "允許一次", "僅允許一次", "僅允許本輪", "允許此回合", "僅允許此回合"
        ]
        private static let deny = ["deny", "decline", "拒绝", "拒絕"]

        private static let shortcut = try! NSRegularExpression(
            pattern: #"(?:(?:\s+|(?<=[^\x00-\x7F]))(?:esc|escape|enter|return)|\s*[⌘⌥⌃⇧]*\s*[↵⏎⎋↩⮐⌤])$"#)
        private static let standaloneKeycap = try! NSRegularExpression(
            pattern: #"^(?:[⌘⌥⌃⇧]*\s*(?:esc|escape|enter|return|[↵⏎⎋↩⮐⌤]))$"#)
        private static let ignoredFormatting = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{2066}\u{2067}\u{2068}\u{2069}")

        static func isKeycapOnly(_ raw: String) -> Bool {
            let cleaned = raw.components(separatedBy: ignoredFormatting).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !cleaned.isEmpty else { return false }
            return standaloneKeycap.firstMatch(
                in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)
            ) != nil
        }

        static func role(_ label: String) -> CodexApprovalPacket.Choice? {
            let words = label.components(separatedBy: ignoredFormatting).joined()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            // Electron can append the card's keycap to the accessible button
            // name. Drop only a recognized trailing key, then match the scope.
            let name = shortcut.stringByReplacingMatches(in: words,
                range: NSRange(words.startIndex..., in: words), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private struct CardContent: Equatable {
        let tool: String
        let headline: String
        let body: String
        let canonicalKey: String
    }

    struct TextFragment {
        let text: String
        let y: CGFloat?
    }

    private struct Match {
        let pid: pid_t
        let window: AXUIElement
        let allow: AXUIElement
        let deny: AXUIElement
        let content: CardContent
        let packetID: UUID
    }

    private struct Record {
        let packet: CodexApprovalPacket
        let match: Match
    }

    private static let logger = Logger(subsystem: "com.notchharbor.app", category: "DesktopApproval")
    private let lock = NSLock()
    private var record: Record?
    private var lastScan = Date.distantPast
    private var lastMatchedAt = Date.distantPast
    private var dispatchedID: UUID?
    private var checkedPID: pid_t?
    private var trustedPID = false
    private var lastDiagnosticState = ""

    private func noteDiagnostic(_ state: String) {
        guard state != lastDiagnosticState else { return }
        lastDiagnosticState = state
        Self.logger.notice("DesktopApproval state: \(state, privacy: .public)")
    }

    static func stablePacketID(pid: pid_t, canonicalKey: String) -> UUID {
        let raw = "desktop-panel:\(pid):\(canonicalKey)"
        let digest = Array(SHA256.hash(data: Data(raw.utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

    static func smartJoin(_ lhs: String, _ rhs: String) -> String {
        guard let left = lhs.unicodeScalars.last, let right = rhs.unicodeScalars.first else {
            return lhs + rhs
        }
        let noLeadingSpacePunctuation = CharacterSet(charactersIn: "，。！？；：、）》】」』,.!?;:)]}")
        let noTrailingSpacePunctuation = CharacterSet(charactersIn: "（《【「『([{")
        if noLeadingSpacePunctuation.contains(right) || noTrailingSpacePunctuation.contains(left) {
            return lhs + rhs
        }
        let leftASCII = left.isASCII && !CharacterSet.whitespacesAndNewlines.contains(left)
        let rightASCII = right.isASCII && !CharacterSet.whitespacesAndNewlines.contains(right)
        if leftASCII || rightASCII {
            return lhs + " " + rhs
        }
        return lhs + rhs
    }

    private static let headerBadges: Set<String> = [
        "权限", "權限", "permission", "permissions",
        "命令", "终端", "command", "审批", "審批", "approval"
    ]

    static func formatCardText(_ fragments: [TextFragment]) -> (tool: String, headline: String, body: String, canonicalKey: String)? {
        guard !fragments.isEmpty else { return nil }
        var paragraphs: [String] = []
        var currentLine = ""
        var currentY: CGFloat?

        for item in fragments {
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if currentLine.isEmpty {
                currentLine = trimmed
                currentY = item.y
                continue
            }
            if let y = item.y, let prevY = currentY, abs(y - prevY) <= 8 {
                currentLine = smartJoin(currentLine, trimmed)
                currentY = (prevY + y) * 0.5
            } else {
                paragraphs.append(currentLine)
                currentLine = trimmed
                currentY = item.y
            }
        }
        if !currentLine.isEmpty {
            paragraphs.append(currentLine)
        }

        var tool = "Codex 桌面审批"
        if paragraphs.count >= 2, let first = paragraphs.first {
            let normalizedFirst = first.lowercased()
            if headerBadges.contains(normalizedFirst) {
                if ["权限", "權限", "permission", "permissions"].contains(normalizedFirst) {
                    tool = "本轮权限"
                }
                paragraphs.removeFirst()
            }
        }

        let joinedAll = paragraphs.joined(separator: "\n")
        guard !paragraphs.isEmpty, joinedAll.count >= 6, joinedAll.utf8.count <= 7_000 else { return nil }

        let headline: String
        let body: String
        if paragraphs.count >= 2 {
            headline = paragraphs[0]
            body = paragraphs.dropFirst().joined(separator: "\n")
        } else {
            headline = ""
            body = paragraphs[0]
        }
        let canonical = (headline + "\n" + body)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return (tool: tool, headline: headline, body: body, canonicalKey: canonical)
    }

    /// The panel uses a deterministic presentation key per live card so minor
    /// Electron DOM re-renders never orphan an in-flight approval click.
    func pending(now: Date = Date()) -> [CodexApprovalPacket] {
        lock.lock()
        defer { lock.unlock() }
        if now.timeIntervalSince(lastScan) >= 1.0 {
            lastScan = now
            let outcome = scanVisibleMatch()
            switch outcome {
            case .matched(let match):
                lastMatchedAt = now
                if record?.packet.id != match.packetID
                    || record?.packet.reason != match.content.headline
                    || record?.packet.command != match.content.body {
                    let stamp = record?.packet.id == match.packetID
                        ? (record?.packet.createdAt ?? now.timeIntervalSince1970)
                        : now.timeIntervalSince1970
                    if record?.packet.id != match.packetID {
                        dispatchedID = nil
                    }
                    record = Record(packet: CodexApprovalPacket(
                        id: match.packetID,
                        sessionID: match.packetID,
                        tool: match.content.tool,
                        cwd: "",
                        reason: match.content.headline,
                        command: match.content.body,
                        createdAt: stamp,
                        expires: stamp + CodexDesktopApprovals.lifetime,
                        pid: match.pid,
                        route: "desktop-panel"
                    ), match: match)
                } else if let existing = record {
                    record = Record(packet: existing.packet, match: match)
                }
            case .transientUnavailable:
                // Keep the existing record briefly across Space transitions or 1-frame AX timeouts.
                if now.timeIntervalSince(lastMatchedAt) > 3.5 {
                    record = nil
                    dispatchedID = nil
                }
            case .absent:
                record = nil
                dispatchedID = nil
            }
        }
        return record.map { [$0.packet] } ?? []
    }

    private enum ScanOutcome {
        case matched(Match)
        case transientUnavailable
        case absent
    }

    /// On submission the original controls are found again. A changed,
    /// disabled or ambiguous card can never receive a previous decision.
    func submit(_ choice: CodexApprovalPacket.Choice, id: UUID, session: UUID,
                home: URL) -> CodexApprovalSubmission {
        guard choice != .native, id == session else { return .notSent }
        let checkpoint = Self.responseFiles(home: home)
        let started = Date()

        let alreadyDispatched = lock.withLock { () -> Bool in
            if dispatchedID == id { return true }
            dispatchedID = id
            return false
        }
        if alreadyDispatched {
            Self.logger.notice("submit skipped: duplicate in-flight id=\(id.uuidString, privacy: .public)")
            return .unconfirmed
        }

        func finish(_ result: CodexApprovalSubmission, stage: String) -> CodexApprovalSubmission {
            lock.withLock {
                if result == .confirmed {
                    if record?.packet.id == id {
                        record = nil
                        lastScan = .distantPast
                    }
                    dispatchedID = nil
                } else {
                    // Allow user retry when the card did not close.
                    dispatchedID = nil
                }
            }
            Self.logger.notice("submit finished: status=\(result.rawValue, privacy: .public) stage=\(stage, privacy: .public)")
            return result
        }

        func isConfirmedDismissed(since start: Date) -> Bool {
            if !checkpoint.isEmpty && Self.receivedResponse(home: home, since: start, checkpoint: checkpoint, choice: choice) {
                return true
            }
            return lock.withLock {
                switch scanVisibleMatch() {
                case .absent:
                    return hasVisibleDesktopWebArea()
                case .matched(let live):
                    return live.packetID != id
                case .transientUnavailable:
                    return false
                }
            }
        }

        // Stage 1: Silent background AXPress (with AXManualAccessibility + focus).
        let stage1Match = lock.withLock { () -> Match? in
            if case .matched(let current) = scanVisibleMatch(), current.packetID == id {
                return current
            }
            return nil
        }

        if let current = stage1Match {
            let appRoot = AXUIElementCreateApplication(current.pid)
            _ = AXUIElementSetAttributeValue(appRoot, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            let button = choice == .allow ? current.allow : current.deny
            let err = Self.performPress(on: button)
            Self.logger.notice("submit stage1 AXPress: choice=\(choice.rawValue, privacy: .public) err=\(err.rawValue, privacy: .public)")
            if err == .success || err == .cannotComplete {
                for _ in 0..<4 {
                    Thread.sleep(forTimeInterval: 0.10)
                    if isConfirmedDismissed(since: started) {
                        return finish(.confirmed, stage: "stage1_axpress")
                    }
                }
            }
        }

        // Stage 2: Activate Codex/ChatGPT window (needed when Electron is unfocused or on another Space),
        // re-verify the exact same card, and invoke AXPress again.
        let targetPID: pid_t? = stage1Match?.pid ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first?.processIdentifier
        if let pid = targetPID, Self.officialDesktop(pid),
           let runningApp = NSRunningApplication(processIdentifier: pid) {
            DispatchQueue.main.sync {
                _ = runningApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
            if let win = stage1Match?.window {
                _ = AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                _ = AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
            Thread.sleep(forTimeInterval: 0.18)
            if isConfirmedDismissed(since: started) {
                return finish(.confirmed, stage: "stage2_post_activate")
            }

            let stage2Match = lock.withLock { () -> Match? in
                if case .matched(let refreshed) = scanVisibleMatch(), refreshed.packetID == id {
                    return refreshed
                }
                return nil
            }
            if let refreshed = stage2Match {
                let appRoot = AXUIElementCreateApplication(refreshed.pid)
                _ = AXUIElementSetAttributeValue(appRoot, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                _ = AXUIElementPerformAction(refreshed.window, kAXRaiseAction as CFString)
                let button = choice == .allow ? refreshed.allow : refreshed.deny
                let err = Self.performPress(on: button)
                Self.logger.notice("submit stage2 AXPress: err=\(err.rawValue, privacy: .public)")
                for _ in 0..<5 {
                    Thread.sleep(forTimeInterval: 0.10)
                    if isConfirmedDismissed(since: started) {
                        return finish(.confirmed, stage: "stage2_axpress")
                    }
                }

                // Stage 3: Hit-tested pointer click on the verified foreground button when React/Radix
                // binds pointer events that ignore synthetic AXPress.
                let frontPID = DispatchQueue.main.sync {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier
                }
                if frontPID == refreshed.pid,
                   let latest = lock.withLock({ () -> Match? in
                       if case .matched(let m) = scanVisibleMatch(), m.packetID == id { return m }
                       return nil
                   }) {
                    let targetButton = choice == .allow ? latest.allow : latest.deny
                    if Self.performVerifiedHitClick(on: targetButton, pid: latest.pid) {
                        Self.logger.notice("submit stage3 verified hit-click dispatched")
                        for _ in 0..<10 {
                            Thread.sleep(forTimeInterval: 0.10)
                            if isConfirmedDismissed(since: started) {
                                return finish(.confirmed, stage: "stage3_hit_click")
                            }
                        }
                    }
                }
                return finish(.unconfirmed, stage: "stage2_unconfirmed")
            }
        }

        return finish(stage1Match == nil ? .notSent : .unconfirmed, stage: "no_live_match")
    }

    private static func performPress(on button: AXUIElement) -> AXError {
        AXUIElementSetMessagingTimeout(button, 1.0)
        defer { AXUIElementSetMessagingTimeout(button, 0) }
        _ = AXUIElementSetAttributeValue(button, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let status = AXUIElementPerformAction(button, kAXPressAction as CFString)
        if status == .success { return status }
        if let kids = attribute(button, kAXChildrenAttribute) as? [AXUIElement] {
            for child in kids.prefix(6) where role(child) == kAXButtonRole {
                let childStatus = AXUIElementPerformAction(child, kAXPressAction as CFString)
                if childStatus == .success { return childStatus }
            }
        }
        return status
    }

    private static func performVerifiedHitClick(on button: AXUIElement, pid: pid_t) -> Bool {
        guard enabled(button), let rect = frame(of: button),
              rect.width >= 24, rect.height >= 16, rect.width <= 420, rect.height <= 96 else {
            return false
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var hit: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        defer { AXUIElementSetMessagingTimeout(systemWide, 0) }
        guard AXUIElementCopyElementAtPosition(systemWide, Float(center.x), Float(center.y), &hit) == .success,
              let hitElement = hit else {
            return false
        }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hitElement, &hitPID) == .success, hitPID == pid,
              element(hitElement, isOrInside: button) else {
            return false
        }
        let savedMouse = CGEvent(source: nil)?.location
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)
        else {
            return false
        }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.025)
        up.post(tap: .cghidEventTap)
        if let savedMouse,
           let restore = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: savedMouse, mouseButton: .left) {
            Thread.sleep(forTimeInterval: 0.02)
            restore.post(tap: .cghidEventTap)
        }
        return true
    }

    private static func element(_ candidate: AXUIElement, isOrInside target: AXUIElement) -> Bool {
        var current: AXUIElement? = candidate
        for _ in 0..<8 {
            guard let node = current else { return false }
            if CFEqual(node, target) { return true }
            guard let parent = attribute(node, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = (parent as! AXUIElement)
        }
        return false
    }

    private func hasVisibleDesktopWebArea() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        guard running.count == 1, let pid = running.first?.processIdentifier else { return false }
        if checkedPID != pid {
            checkedPID = pid
            trustedPID = Self.officialDesktop(pid)
        }
        guard trustedPID else { return false }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.10)
        let windows = Self.attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var queue = windows.filter { Self.attribute($0, kAXMinimizedAttribute) as? Bool != true }
        var cursor = 0
        while cursor < queue.count, cursor < 240 {
            let node = queue[cursor]
            cursor += 1
            if Self.isOfficialWebArea(node) { return true }
            let nodeRole = Self.role(node)
            if ![kAXStaticTextRole, kAXImageRole, kAXButtonRole, "AXInlineTextBox"].contains(nodeRole) {
                queue += (Self.attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(64)
            }
        }
        return false
    }

    private func scanVisibleMatch() -> ScanOutcome {
        guard AXIsProcessTrusted() else {
            noteDiagnostic("ax_untrusted")
            return .absent
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        guard running.count == 1, let pid = running.first?.processIdentifier else {
            noteDiagnostic("running_count=\(running.count)")
            return .absent
        }
        if checkedPID != pid {
            checkedPID = pid
            trustedPID = Self.officialDesktop(pid)
        }
        guard trustedPID else {
            noteDiagnostic("untrusted_pid=\(pid)")
            return .absent
        }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.35)
        let windows = Self.attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if windows.isEmpty {
            noteDiagnostic("transient_empty_windows")
            return .transientUnavailable
        }
        let (match, summary, sawWebArea) = Self.uniqueMatchWithSummary(in: windows, pid: pid)
        noteDiagnostic(summary)
        if let match {
            return .matched(match)
        }
        return sawWebArea ? .absent : .transientUnavailable
    }

    private static func isOfficialWebArea(_ node: AXUIElement) -> Bool {
        guard role(node) == "AXWebArea",
              let raw = attribute(node, kAXURLAttribute),
              let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:)),
              url.scheme == "app", url.host(percentEncoded: false) == "-"
        else { return false }
        return true
    }

    private static func uniqueMatchWithSummary(in windows: [AXUIElement], pid: pid_t) -> (Match?, String, Bool) {
        // A separate web area may belong to an in-app web page. Accept controls
        // only from Codex's own application document and never a nested frame.
        struct QueueEntry {
            let element: AXUIElement
            let window: AXUIElement
            let insideDocument: Bool
        }
        var list = windows.filter { attribute($0, kAXMinimizedAttribute) as? Bool != true }
            .map { QueueEntry(element: $0, window: $0, insideDocument: false) }
        let limit = ContinuousClock.now + .milliseconds(900)
        var matches: [Match] = []
        var cursor = 0
        var webAreas = 0
        var buttonsSeen = 0
        var allowCandidates = 0
        let leafRoles: Set<String> = [kAXStaticTextRole, kAXImageRole, "AXInlineTextBox"]
        while cursor < list.count, cursor < 12_000, ContinuousClock.now < limit {
            let entry = list[cursor]
            let node = entry.element
            cursor += 1
            let nodeRole = role(node)
            if leafRoles.contains(nodeRole) { continue }
            var inside = entry.insideDocument
            if nodeRole == "AXWebArea" {
                guard !inside, isOfficialWebArea(node) else { continue }
                inside = true
                webAreas += 1
            }
            if inside, nodeRole == kAXButtonRole {
                buttonsSeen += 1
                if buttonDecisionRole(node) == .allow, enabled(node) {
                    allowCandidates += 1
                    if let match = card(containing: node, window: entry.window, pid: pid) {
                        matches.append(match)
                        if matches.count > 1 { return (nil, "ambiguous_matches=\(matches.count)", webAreas > 0) }
                    }
                }
                continue
            }
            let kids = attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            if kids.count <= 600 {
                list += kids.map { QueueEntry(element: $0, window: entry.window, insideDocument: inside) }
            } else {
                list += (Array(kids.prefix(100)) + Array(kids.suffix(500)))
                    .map { QueueEntry(element: $0, window: entry.window, insideDocument: inside) }
            }
        }
        guard cursor == list.count else {
            return (nil, "incomplete:cursor=\(cursor),total=\(list.count),web=\(webAreas),btns=\(buttonsSeen),allow=\(allowCandidates)", webAreas > 0)
        }
        guard matches.count == 1, let matched = matches.first else {
            return (nil, "no_match:win=\(windows.count),nodes=\(cursor),web=\(webAreas),btns=\(buttonsSeen),allow=\(allowCandidates)", webAreas > 0)
        }
        return (matched, "matched:win=\(windows.count),web=\(webAreas),btns=\(buttonsSeen)", true)
    }

    private static func card(containing allow: AXUIElement, window: AXUIElement, pid: pid_t) -> Match? {
        var current = allow
        for _ in 0..<12 {
            guard let parent = attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = parent as! AXUIElement
            guard role(current) != "AXWebArea" else { return nil }
            guard let nodes = children(in: current, limit: 200) else { return nil }
            let buttons = nodes.filter { role($0) == kAXButtonRole && enabled($0) }
            let allows = buttons.filter { buttonDecisionRole($0) == .allow }
            let denies = buttons.filter { buttonDecisionRole($0) == .deny }
            if allows.count > 1 || denies.count > 1 { return nil }
            guard let deny = denies.first, allows.count == 1 else { continue }

            var seen = Set<String>()
            let fragments = nodes.compactMap { node -> TextFragment? in
                guard [kAXStaticTextRole, kAXHeadingRole].contains(role(node)), let text = label(node),
                      DecisionLabels.role(text) == nil, !DecisionLabels.isKeycapOnly(text) else { return nil }
                let y = position(of: node)?.y
                let dedupKey = "\(Int((y ?? -9999).rounded()))|\(text)"
                guard seen.insert(dedupKey).inserted else { return nil }
                return TextFragment(text: text, y: y)
            }
            guard fragments.count >= 1, fragments.count <= 36,
                  let formatted = formatCardText(fragments) else { continue }
            let content = CardContent(
                tool: formatted.tool,
                headline: formatted.headline,
                body: formatted.body,
                canonicalKey: formatted.canonicalKey
            )
            let packetID = stablePacketID(pid: pid, canonicalKey: content.canonicalKey)
            return Match(pid: pid, window: window, allow: allow, deny: deny, content: content, packetID: packetID)
        }
        return nil
    }

    private static func position(of element: AXUIElement) -> CGPoint? {
        guard let raw = attribute(element, kAXPositionAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = position(of: element),
              let rawSize = attribute(element, kAXSizeAttribute),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func buttonDecisionRole(_ button: AXUIElement) -> CodexApprovalPacket.Choice? {
        if let direct = label(button).flatMap(DecisionLabels.role) {
            return direct
        }
        var queue = [button]
        var cursor = 0
        var parts: [String] = []
        while cursor < queue.count && queue.count <= 16 {
            let item = queue[cursor]
            cursor += 1
            if item !== button, role(item) == kAXStaticTextRole, let text = label(item),
               !DecisionLabels.isKeycapOnly(text) {
                parts.append(text)
            }
            queue += (attribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(8)
        }
        guard !parts.isEmpty else { return nil }
        return DecisionLabels.role(parts.joined(separator: " "))
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
