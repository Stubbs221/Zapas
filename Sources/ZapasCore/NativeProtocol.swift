import Foundation
import Darwin
import CZapas

public enum NativeFrame {
    public static let maximumBytes = 1_048_576
    public static func pack(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumBytes else { throw ProbeIssue("frame_size", "Frame must be 1...1 MiB") }
        let length = UInt32(payload.count)
        // macOS arm64 and x86_64 use the native little-endian format specified by Chrome.
        var output = Data([UInt8(length & 255), UInt8((length >> 8) & 255), UInt8((length >> 16) & 255), UInt8((length >> 24) & 255)])
        output.append(payload); return output
    }
    public static func length(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw ProbeIssue("truncated_frame", "Four-byte header required") }
        let bytes = Array(header)
        let length = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        guard length > 0, length <= maximumBytes else { throw ProbeIssue("frame_size", "Frame must be 1...1 MiB") }
        return Int(length)
    }
    public static func unpack(_ frame: Data) throws -> Data {
        let length = try length(Data(frame.prefix(4)))
        guard frame.count == length + 4 else { throw ProbeIssue("truncated_frame", "Body length does not match header") }
        return Data(frame.dropFirst(4))
    }
    public static func read(from fd: Int32) throws -> Data? {
        var header = Data(count: 4)
        let status = header.withUnsafeMutableBytes { zp_read_exact(fd, $0.baseAddress, 4) }
        if status == 0 { return nil }
        guard status > 0 else { throw ProbeIssue("frame_io", "Header read failed (\(status))") }
        let length = try length(header)
        var body = Data(count: length)
        let result = body.withUnsafeMutableBytes { zp_read_exact(fd, $0.baseAddress, length) }
        guard result > 0 else { throw ProbeIssue("truncated_frame", "Body read failed (\(result))") }
        return body
    }
    public static func write(_ data: Data, to fd: Int32) throws {
        let frame = try pack(data)
        let result = frame.withUnsafeBytes { zp_write_exact(fd, $0.baseAddress, frame.count) }
        guard result == 0 else { throw ProbeIssue("frame_io", "Write failed (\(result))") }
    }
}

public enum NativeOrigin {
    public static func validate(_ origin: String, allowed: String) throws {
        guard origin == allowed, origin.hasPrefix("chrome-extension://"), origin.hasSuffix("/") else {
            throw ProbeIssue("origin_denied", "Native Messaging origin is not the configured extension")
        }
        let id = String(origin.dropFirst("chrome-extension://".count).dropLast())
        guard id.count == 32, id.allSatisfy({ ("a"..."p").contains(String($0)) }) else {
            throw ProbeIssue("origin_denied", "Invalid extension ID")
        }
    }
}

public struct TabObservation: Codable, Sendable, Equatable {
    public let id: Int
    public let windowID: Int
    public let title: String
    public let domain: String?
    public let active: Bool
    public let pinned: Bool
    public let audible: Bool
    public let incognito: Bool
    public let discarded: Bool
    public let lastAccessedMilliseconds: Double?
    public let splitViewID: Int?
    public let isTestFixture: Bool
    public init(id: Int, windowID: Int = 1, title: String = "Fixture", domain: String? = nil,
                active: Bool = false, pinned: Bool = false, audible: Bool = false, incognito: Bool = false,
                discarded: Bool = false, lastAccessedMilliseconds: Double? = nil, splitViewID: Int? = nil, isTestFixture: Bool = true) {
        self.id = id; self.windowID = windowID; self.title = title; self.domain = domain
        self.active = active; self.pinned = pinned; self.audible = audible; self.incognito = incognito
        self.discarded = discarded; self.lastAccessedMilliseconds = lastAccessedMilliseconds
        self.splitViewID = splitViewID; self.isTestFixture = isTestFixture
    }
}

public enum TestTabPolicy {
    public static let recentSeconds: Double = 60 // Research-only; not an approved product threshold.
    public static func exclusion(_ tab: TabObservation, now: Date) -> String? {
        if !tab.isTestFixture { return "not_test_fixture" }
        if tab.active { return "active" }
        if tab.pinned { return "pinned" }
        if tab.audible { return "audible" }
        if tab.incognito { return "incognito" }
        if tab.discarded { return "already_discarded" }
        if let id = tab.splitViewID, id != -1 { return "split_view" }
        guard let access = tab.lastAccessedMilliseconds, access.isFinite, access >= 0 else { return "activity_unknown" }
        if now.timeIntervalSince1970 * 1000 - access < recentSeconds * 1000 { return "recently_active" }
        return nil
    }
}

public enum ProbeOperation: String, Codable, Sendable {
    case hello, publishTabs, pollTestAction, submitResult, listTabs, discardTestTab, getActionResult
}

public struct TestAction: Codable, Sendable, Equatable {
    public let id: String
    public let sessionID: String
    public let tabID: Int
    public let expiresAt: Date
    public let expectedWindowID: Int
    public let expectedLastAccessedMilliseconds: Double
}

public struct TestActionResult: Codable, Sendable {
    public let id: String
    public let tabID: Int
    public let status: String
    public let discarded: Bool
    public let resultingTabID: Int?
    public let issue: String?
    public let measuredAt: Date
    public init(id: String, tabID: Int, status: String, discarded: Bool, resultingTabID: Int? = nil, issue: String? = nil, measuredAt: Date = Date()) {
        self.id = id; self.tabID = tabID; self.status = status; self.discarded = discarded
        self.resultingTabID = resultingTabID; self.issue = issue; self.measuredAt = measuredAt
    }
}

public struct ProbeRequest: Codable, Sendable {
    public var version: Int = 1
    public var requestID: String = UUID().uuidString
    public var operation: ProbeOperation
    public var origin: String?
    public var sessionID: String?
    public var tabs: [TabObservation]?
    public var tabID: Int?
    public var actionID: String?
    public var result: TestActionResult?
    public init(_ operation: ProbeOperation, origin: String? = nil, sessionID: String? = nil, tabs: [TabObservation]? = nil,
                tabID: Int? = nil, actionID: String? = nil, result: TestActionResult? = nil) {
        self.operation = operation; self.origin = origin; self.sessionID = sessionID
        self.tabs = tabs; self.tabID = tabID; self.actionID = actionID; self.result = result
    }
    public func validate() throws {
        guard version == 1 else { throw ProbeIssue("protocol_version", "Only experimental version 1 is supported") }
        guard UUID(uuidString: requestID) != nil else { throw ProbeIssue("request_id", "requestID must be a UUID") }
        if let sessionID, UUID(uuidString: sessionID) == nil { throw ProbeIssue("session_id", "sessionID must be a UUID") }
        if let tabs {
            guard tabs.count <= 2000, Set(tabs.map(\.id)).count == tabs.count,
                  tabs.allSatisfy({ $0.id >= 0 && $0.title.utf8.count <= 4096 && ($0.domain?.utf8.count ?? 0) <= 1024 }) else {
                throw ProbeIssue("tab_schema", "Invalid tab IDs, duplicates, excessive text or too many tabs")
            }
        }
        if let result {
            guard ["confirmed", "refused", "unknown"].contains(result.status), result.tabID >= 0,
                  result.resultingTabID.map({ $0 >= 0 }) ?? true,
                  result.status == "confirmed" ? result.discarded : !result.discarded else {
                throw ProbeIssue("result_schema", "Invalid status, tab identity or discard confirmation")
            }
        }
    }
}

public struct TabSession: Codable, Sendable {
    public let id: String
    public let measuredAt: Date
    public let stale: Bool
    public let tabs: [TabObservation]
    public let tabMemoryIssue: String
    public init(id: String, measuredAt: Date, stale: Bool, tabs: [TabObservation]) {
        self.id = id; self.measuredAt = measuredAt; self.stale = stale; self.tabs = tabs
        self.tabMemoryIssue = "No verified per-tab RAM source in Chrome Stable"
    }
}

public struct ProbeReply: Codable, Sendable {
    public var version: Int = 1
    public var requestID: String
    public var ok: Bool = true
    public var issue: ProbeIssue?
    public var sessionID: String?
    public var sessions: [TabSession]?
    public var action: TestAction?
    public var result: TestActionResult?
    public var actionStatus: String?
    public init(requestID: String, issue: ProbeIssue? = nil) {
        self.requestID = requestID; self.issue = issue; self.ok = issue == nil
    }
}

/// Serialized by the broker accept loop. No URLs, snapshots or commands are persisted.
public struct ProbeBroker {
    private struct Session { var time: Date; var tabs: [TabObservation] }
    private struct Pending { var action: TestAction; var delivered: Bool = false; var result: TestActionResult? }
    private var sessions: [String: Session] = [:]
    private var actions: [String: Pending] = [:]
    private let allowedOrigin: String
    public init(allowedOrigin: String) throws {
        try NativeOrigin.validate(allowedOrigin, allowed: allowedOrigin)
        self.allowedOrigin = allowedOrigin
    }
    public mutating func handle(_ request: ProbeRequest, now: Date = Date()) -> ProbeReply {
        do { return try process(request, now: now) }
        catch { return ProbeReply(requestID: request.requestID, issue: error as? ProbeIssue ?? ProbeIssue("request_failed", String(describing: error))) }
    }
    private mutating func process(_ request: ProbeRequest, now: Date) throws -> ProbeReply {
        try request.validate()
        // Bound research state; a disconnected session cannot keep accumulating data indefinitely.
        sessions = sessions.filter { now.timeIntervalSince($0.value.time) < 300 }
        actions = actions.filter { now.timeIntervalSince($0.value.action.expiresAt) < 300 }
        var reply = ProbeReply(requestID: request.requestID)
        switch request.operation {
        case .hello, .publishTabs, .pollTestAction, .submitResult:
            try NativeOrigin.validate(request.origin ?? "", allowed: allowedOrigin)
            guard let sessionID = request.sessionID else { throw ProbeIssue("session_required", "Host session required") }
            reply.sessionID = sessionID
            switch request.operation {
            case .hello: break
            case .publishTabs:
                guard let tabs = request.tabs else { throw ProbeIssue("tabs_required", "Snapshot required") }
                guard sessions[sessionID] != nil || sessions.count < 32 else { throw ProbeIssue("session_limit", "Too many active host sessions") }
                sessions[sessionID] = Session(time: now, tabs: tabs)
            case .pollTestAction:
                guard let session = sessions[sessionID], now.timeIntervalSince(session.time) <= 10 else {
                    throw ProbeIssue("snapshot_stale", "Publish a fresh snapshot before polling")
                }
                if let id = actions.keys.sorted().first(where: { id in
                    let value = actions[id]!
                    return value.action.sessionID == sessionID && !value.delivered && value.result == nil && value.action.expiresAt > now
                }) {
                    actions[id]?.delivered = true; reply.action = actions[id]?.action
                }
            case .submitResult:
                guard let result = request.result, var pending = actions[result.id],
                      pending.delivered, pending.action.sessionID == sessionID, pending.action.tabID == result.tabID else {
                    throw ProbeIssue("action_mismatch", "Result must match a delivered action and host session")
                }
                guard pending.result == nil else { throw ProbeIssue("result_already_received", "Action result is immutable") }
                pending.result = result; actions[result.id] = pending; reply.result = result
            default: break
            }
        case .listTabs:
            reply.sessions = sessions.map { id, session in
                TabSession(id: id, measuredAt: session.time, stale: now.timeIntervalSince(session.time) > 10, tabs: session.tabs)
            }.sorted { $0.id < $1.id }
        case .discardTestTab:
            guard let sessionID = request.sessionID, let tabID = request.tabID,
                  let session = sessions[sessionID], now.timeIntervalSince(session.time) <= 10 else {
                throw ProbeIssue("snapshot_stale", "Select a tab from a fresh connected session")
            }
            if let existing = actions[request.requestID] {
                guard existing.action.sessionID == sessionID, existing.action.tabID == tabID else {
                    throw ProbeIssue("request_reused", "requestID belongs to a different action")
                }
                reply.action = existing.action; return reply
            }
            guard let tab = session.tabs.first(where: { $0.id == tabID }) else { throw ProbeIssue("tab_missing", "Tab no longer exists") }
            if let reason = TestTabPolicy.exclusion(tab, now: now) { throw ProbeIssue("tab_excluded", reason) }
            guard actions.count < 256 else { throw ProbeIssue("action_limit", "Research action queue is full") }
            let action = TestAction(id: request.requestID, sessionID: sessionID, tabID: tabID,
                                    expiresAt: now.addingTimeInterval(10), expectedWindowID: tab.windowID,
                                    expectedLastAccessedMilliseconds: tab.lastAccessedMilliseconds!)
            actions[action.id] = Pending(action: action); reply.action = action; reply.actionStatus = "queued"
        case .getActionResult:
            guard let id = request.actionID, let pending = actions[id] else { throw ProbeIssue("action_unknown", "Unknown or expired research action") }
            reply.result = pending.result
            reply.actionStatus = pending.result?.status ?? (pending.action.expiresAt <= now ? "expired_or_result_unknown" : pending.delivered ? "delivered" : "queued")
        }
        return reply
    }
}
