import Darwin
import Foundation

/// Sends user-selected text to the desktop client that already owns the thread.
/// Protocol reference: codex-web's desktop-ipc-client and Codex issue #54591.
final class CodexDesktopDelivery {
    enum DeliveryError: Error {
        case unavailable
        case interrupted
        case rejected(String)

        var userMessage: String {
            switch self {
            case .unavailable: return "Codex 桌面版未连接此会话，请打开原会话"
            case .interrupted: return "未收到 Codex 确认，请在原会话核对后再发送"
            case .rejected: return "Codex 桌面版拒绝了此条回复，请查看原会话"
            }
        }
    }

    private let descriptor: Int32
    private var clientID = "initializing-client"

    static func connection(home: URL) -> CodexDesktopDelivery? {
        let legacyName = "codex-ipc/ipc-\(getuid()).sock"
        let candidates = [
            home.appendingPathComponent(".codex/ipc/ipc.sock"),
            FileManager.default.temporaryDirectory.appendingPathComponent(legacyName),
            URL(fileURLWithPath: "/private/tmp").appendingPathComponent(legacyName)
        ]
        for candidate in candidates {
            if let connection = try? CodexDesktopDelivery(path: candidate.path) { return connection }
        }
        return nil
    }

    private init(path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        var socketInfo = stat()
        var parentInfo = stat()
        guard lstat(path, &socketInfo) == 0, lstat(parent, &parentInfo) == 0,
              socketInfo.st_uid == getuid(), parentInfo.st_uid == getuid(),
              socketInfo.st_mode & S_IFMT == S_IFSOCK,
              parentInfo.st_mode & S_IFMT == S_IFDIR,
              socketInfo.st_mode & 0o077 == 0, parentInfo.st_mode & 0o022 == 0 else {
            throw DeliveryError.unavailable
        }
        var address = sockaddr_un()
        let pathname = Array(path.utf8CString)
        guard pathname.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw DeliveryError.unavailable
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathname.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DeliveryError.unavailable }
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let connection = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let connectionError = errno
        if connection != 0 {
            do {
                guard connectionError == EINPROGRESS else { throw DeliveryError.unavailable }
                try Self.wait(fd, events: Int16(POLLOUT), until: .now + .seconds(2))
                var status: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &status, &size) == 0, status == 0 else {
                    throw DeliveryError.unavailable
                }
            } catch {
                close(fd)
                throw DeliveryError.unavailable
            }
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            throw DeliveryError.unavailable
        }
        descriptor = fd
    }

    deinit { close(descriptor) }

    func owner(of threadID: String) throws -> String? {
        let handshake = try request("initialize", version: 0, params: ["clientType": "boringnotch"], seconds: 3)
        guard let result = handshake["result"] as? [String: Any],
              let id = result["clientId"] as? String, !id.isEmpty else { throw DeliveryError.unavailable }
        clientID = id
        do {
            let discovery = try request("thread-owner-discovery", version: 1, params: [
                "hostId": "local", "conversationId": threadID
            ], seconds: 5)
            return discovery["handledByClientId"] as? String
        } catch DeliveryError.rejected(let reason) where
            ["no-client-found", "disabled", "no-handler-for-request"].contains(reason) { return nil }
    }

    /// Returns true when the owner accepted input into its active turn.
    func send(_ text: String, threadID: String, owner: String) throws -> Bool {
        let messageID = UUID().uuidString.lowercased()
        let items: [[String: Any]] = [["type": "text", "text": text, "text_elements": []]]
        let restored: [String: Any] = [
            "id": messageID, "text": text,
            "context": [
                "prompt": text, "workspaceRoots": [], "imageAttachments": [], "fileAttachments": [],
                "commentAttachments": [], "addedFiles": [], "responseTextAnnotations": [], "attachmentOrder": []
            ],
            "responsesapiClientMetadata": ["source": "codex", "client_type": "boringnotch"]
        ]
        do {
            let reply = try request("thread-follower-steer-turn", version: 1, params: [
                "conversationId": threadID, "clientUserMessageId": messageID, "input": items,
                "attachments": [], "restoreMessage": restored, "additionalContext": [String: Any]()
            ], target: owner, seconds: 12)
            guard let result = Self.receipt(reply),
                  let id = result["turnId"] as? String, !id.isEmpty else { throw DeliveryError.interrupted }
            return true
        } catch DeliveryError.rejected(let reason) where Self.inactiveTurn(reason) {
            // An explicit no-active-turn response is the only safe reason to start one.
        }
        let reply = try request("thread-follower-start-turn", version: 2, params: [
            "conversationId": threadID, "turnStart": [
                "request": ["threadId": threadID, "clientUserMessageId": messageID, "input": items],
                "context": ["restoreMessage": restored, "inheritThreadSettings": true]
            ]
        ], target: owner, seconds: 20)
        guard let result = Self.receipt(reply),
              let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String, !id.isEmpty else {
            throw DeliveryError.interrupted
        }
        return false
    }

    static func receipt(_ reply: [String: Any]) -> [String: Any]? {
        guard let body = reply["result"] as? [String: Any] else { return nil }
        return body["result"] as? [String: Any] ?? body
    }

    private static func inactiveTurn(_ reason: String) -> Bool {
        let text = reason.lowercased()
        return text.contains("no active turn to steer")
            || text.contains("cannot steer conversation because it has no active turn")
            || (text.contains("cannot steer conversation") && text.contains("active turn already ended"))
            || (text.contains("turn") && text.hasSuffix("is not active"))
    }

    private func request(_ method: String, version: Int, params: [String: Any],
                         target: String? = nil, seconds: Int) throws -> [String: Any] {
        let id = UUID().uuidString
        let deadline = ContinuousClock.now + .seconds(seconds + 1)
        var frame: [String: Any] = [
            "type": "request", "sourceClientId": clientID, "requestId": id,
            "method": method, "version": version, "params": params, "timeoutMs": seconds * 1000
        ]
        if let target { frame["targetClientId"] = target }
        try write(frame, until: deadline)

        while let payload = try readFrame(until: deadline) {
            guard let row = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
                  let type = row["type"] as? String, let responseID = row["requestId"] as? String else { continue }
            if type == "client-discovery-request" {
                try write(["type": "client-discovery-response", "requestId": responseID, "response": ["canHandle": false]],
                          until: deadline)
            } else if type == "response", responseID == id {
                guard row["resultType"] as? String == "success" else {
                    throw DeliveryError.rejected(row["error"] as? String ?? "")
                }
                if let target, row["handledByClientId"] as? String != target {
                    throw DeliveryError.interrupted
                }
                return row
            }
        }
        throw DeliveryError.interrupted
    }

    private func readFrame(until deadline: ContinuousClock.Instant) throws -> Data? {
        while ContinuousClock.now < deadline {
            let length = try read(4, until: deadline).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
            guard (1...268_435_456).contains(length) else { throw DeliveryError.interrupted }
            if length <= 4_194_304 { return try read(length, until: deadline) }
            // Large desktop state broadcasts are irrelevant to delivery.
            var remaining = length
            while remaining > 0 {
                let bytes = min(remaining, 65_536)
                _ = try read(bytes, until: deadline)
                remaining -= bytes
            }
        }
        return nil
    }

    private func read(_ count: Int, until deadline: ContinuousClock.Instant) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let base = buffer.baseAddress else { throw DeliveryError.interrupted }
            var offset = 0
            while offset < count {
                try Self.wait(descriptor, events: Int16(POLLIN), until: deadline)
                let bytes = Darwin.recv(descriptor, base.advanced(by: offset), count - offset, 0)
                if bytes < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard bytes > 0 else { throw DeliveryError.interrupted }
                offset += bytes
            }
        }
        return data
    }

    private func write(_ value: [String: Any], until deadline: ContinuousClock.Instant) throws {
        let body = try JSONSerialization.data(withJSONObject: value)
        var length = UInt32(body.count).littleEndian
        let data = withUnsafeBytes(of: &length) { Data($0) } + body
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { throw DeliveryError.interrupted }
            var offset = 0
            while offset < buffer.count {
                try Self.wait(descriptor, events: Int16(POLLOUT), until: deadline)
                let bytes = Darwin.send(descriptor, base.advanced(by: offset), buffer.count - offset, 0)
                if bytes < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard bytes > 0 else { throw DeliveryError.interrupted }
                offset += bytes
            }
        }
    }

    private static func wait(_ fd: Int32, events: Int16, until deadline: ContinuousClock.Instant) throws {
        while ContinuousClock.now < deadline {
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result > 0, descriptor.revents & events != 0 { return }
            if result > 0 || (result < 0 && errno != EINTR) { break }
        }
        throw DeliveryError.interrupted
    }
}
