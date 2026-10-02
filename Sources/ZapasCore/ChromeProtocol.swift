import Foundation

public enum ChromeActionKind: String, Codable, Sendable { case discard, close }
public struct ChromeTab: Codable, Sendable, Equatable, Identifiable {
    public var id: Int = 0
    public var token = ""
    public var windowID = 0
    public var title = ""
    public var domain: String?
    public var active = false
    public var pinned = false
    public var audible = false
    public var incognito = false
    public var discarded = false
    public var pending = false
    public var splitView = false
    public var lastAccessedMilliseconds: Double?
    public init() {}
    public func activityAgeMinutes(now: Date) -> Double? {
        let current = now.timeIntervalSince1970 * 1000
        guard let access = lastAccessedMilliseconds, access.isFinite, access >= 0,
              current.isFinite, access <= current else { return nil }
        return (current - access) / 60_000
    }
}
public enum ChromeTabFilter: String, CaseIterable, Sendable {
    case all, available, protected, discarded, selected
    public func matches(_ tab: ChromeTab, query: String, policy: ChromePolicy, stale: Bool,
                        selected: Bool, now: Date) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || tab.title.localizedStandardContains(text) ||
                (tab.domain?.localizedStandardContains(text) == true) else { return false }
        let protected = stale || policy.exclusion(tab, kind: .close, now: now) != nil
        switch self {
        case .all: return true
        case .available: return !protected
        case .protected: return protected
        case .discarded: return tab.discarded
        case .selected: return selected
        }
    }
}
public struct ChromeSelection: Codable, Sendable, Hashable {
    public var profileID: String
    public var sessionID: String
    public var tabID: Int
    public var token: String
    public init(profileID: String, sessionID: String, tabID: Int, token: String) {
        self.profileID = profileID; self.sessionID = sessionID; self.tabID = tabID; self.token = token
    }
}
public struct ChromePolicy: Codable, Sendable, Equatable {
    // Approved by the user for both actions on 2026-10-01. Fixture A's 60 seconds are unrelated.
    public static let recentSeconds: Double = 600
    public var excludedDomains: [String] = ["meet.google.com", "teams.microsoft.com", "app.zoom.us", "web.whatsapp.com"]
    public init(excludedDomains: [String]? = nil) { if let excludedDomains { self.excludedDomains = excludedDomains } }
    public func exclusion(_ tab: ChromeTab, kind: ChromeActionKind, now: Date) -> String? {
        if tab.active { return "active" }; if tab.pinned { return "pinned" }
        if tab.audible { return "audible" }; if tab.incognito { return "incognito" }
        if tab.pending { return "navigation_pending" }; if tab.splitView { return "split_view" }
        if tab.domain == nil { return "domain_unknown" }
        if excludedDomains.contains(tab.domain ?? "") { return "user_excluded" }
        if kind == .discard && tab.discarded { return "already_discarded" }
        guard let access = tab.lastAccessedMilliseconds, access.isFinite, access >= 0,
              access <= now.timeIntervalSince1970 * 1000 else { return "activity_unknown" }
        if now.timeIntervalSince1970 * 1000 - access < Self.recentSeconds * 1000 { return "recently_active" }
        return nil
    }
}
public struct ChromeProfile: Codable, Sendable, Identifiable {
    public var id: String
    public var sessionID: String
    public var label: String
    public var measuredAt: Date
    public var stale: Bool
    public var tabs: [ChromeTab]
    public var policy: ChromePolicy
}
public struct ChromeTarget: Codable, Sendable {
    public var selection: ChromeSelection
    public var expected: ChromeTab
}
public struct ChromePlan: Codable, Sendable, Identifiable {
    public var id: String
    public var kind: ChromeActionKind
    public var createdAt: Date
    public var expiresAt: Date
    public var targets: [ChromeTarget]
}
public struct ChromeCommand: Codable, Sendable {
    public var id: String
    public var planID: String
    public var kind: ChromeActionKind
    public var target: ChromeTarget
    public var expiresAt: Date
    public var policy: ChromePolicy
}
public struct ChromeResult: Codable, Sendable, Identifiable {
    public var id: String
    public var status: String
    public var resultingTabID: Int?
    public var issue: String?
    public var measuredAt: Date
    public init(id: String, status: String, resultingTabID: Int? = nil, issue: String? = nil, measuredAt: Date = Date()) {
        self.id = id; self.status = status; self.resultingTabID = resultingTabID; self.issue = issue; self.measuredAt = measuredAt
    }
}
public struct ChromeBatch: Codable, Sendable {
    public var plan: ChromePlan
    public var results: [ChromeResult]
    public var before: ChromeGroupMeasurement?
    public var after: ChromeGroupMeasurement?
}
public struct ServiceRequest: Codable, Sendable {
    public var version = 1
    public var requestID = UUID().uuidString
    public var operation: String
    public var origin: String?
    public var sessionID: String?
    public var profileID: String?
    public var label: String?
    public var tabs: [ChromeTab]?
    public var selections: [ChromeSelection]?
    public var kind: ChromeActionKind?
    public var planID: String?
    public var result: ChromeResult?
    public var simulator: AssignedSimulator?
    public var debuggerIdentity: ProcessIdentity?
    public var apply: Bool?
    public var developmentKind: DActionKind?
    public init(_ operation: String) { self.operation = operation }
    public func validate() throws {
        guard version == 1, UUID(uuidString: requestID) != nil else { throw ProbeIssue("protocol_version_or_request", "Expected v1 and UUID requestID") }
        for id in [sessionID, profileID].compactMap({ $0 }) {
            guard UUID(uuidString: id) != nil else { throw ProbeIssue("identity_invalid", "UUID identity required") }
        }
        if let tabs {
            guard tabs.count <= 2000, Set(tabs.map(\.id)).count == tabs.count,
                  tabs.allSatisfy({ $0.id >= 0 && $0.windowID >= 0 && UUID(uuidString: $0.token) != nil && $0.title.utf8.count <= 4096 && Self.validDomain($0.domain) }) else {
                throw ProbeIssue("tab_schema", "Invalid or excessive tab snapshot")
            }
        }
        if let label, label.utf8.count > 200 { throw ProbeIssue("profile_label", "Profile label too long") }
        if let result {
            guard UUID(uuidString: result.id) != nil, ["confirmed", "failed", "unknown"].contains(result.status),
                  result.resultingTabID.map({ $0 >= 0 }) ?? true, (result.issue?.utf8.count ?? 0) <= 128,
                  result.issue?.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }) ?? true else { throw ProbeIssue("result_schema", "Invalid result") }
        }
    }
    public static func validDomain(_ domain: String?) -> Bool {
        guard let domain else { return true }
        return !domain.isEmpty && domain.utf8.count <= 253 && domain.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }
    }
}
public struct ServiceReply: Codable, Sendable {
    public var version = 1
    public var requestID: String
    public var ok = true
    public var issue: ProbeIssue?
    public var serviceID: String?
    public var sessionID: String?
    public var profiles: [ChromeProfile]?
    public var plan: ChromePlan?
    public var command: ChromeCommand?
    public var batch: ChromeBatch?
    public var policy: ChromePolicy?
    public var simulators: SimulatorDiagnostics?
    public var debuggers: DebuggerDiagnostics?
    public var developmentPlan: DActionPlan?
    public var developmentOutcome: DActionOutcome?
    public var system: SystemDiagnostics?
    public var processes: ProcessDiagnostics?
    public var systemError: ProbeIssue?
    public var processError: ProbeIssue?
    public init(requestID: String, issue: ProbeIssue? = nil) { self.requestID = requestID; self.issue = issue; ok = issue == nil }
}

/// Serialized production state. No URLs or disk history. Plans are single-use; submitted commands are never replayed.
public struct ChromeBroker: Sendable {
    public let serviceID = UUID().uuidString
    public let allowedOrigin: String
    private var profiles: [String: ChromeProfile] = [:]
    private var plans: [String: ChromePlan] = [:]
    private var batches: [String: ChromeBatch] = [:]
    private var commands: [String: ChromeCommand] = [:]
    private var delivered: Set<String> = []
    private var policies: [String: ChromePolicy] = [:]
    public init(allowedOrigin: String) throws {
        try NativeOrigin.validate(allowedOrigin, allowed: allowedOrigin); self.allowedOrigin = allowedOrigin
    }
    public mutating func measurement(_ value: ChromeGroupMeasurement, planID: String, before: Bool) {
        if before { batches[planID]?.before = value } else { batches[planID]?.after = value }
    }
    public mutating func setPolicy(_ policy: ChromePolicy, profileID: String) throws {
        guard policy.excludedDomains.count <= 200, policy.excludedDomains.allSatisfy({ ServiceRequest.validDomain($0) }) else { throw ProbeIssue("exclusion_schema", "Use exact hostnames, at most 200") }
        policies[profileID] = policy; profiles[profileID]?.policy = policy
        plans.removeAll() // Changing exclusions invalidates every pending preview.
    }
    public mutating func snapshot(now: Date = Date()) -> [ChromeProfile] {
        expire(now)
        return profiles.values.map { p in var p = p; p.stale = now < p.measuredAt || now.timeIntervalSince(p.measuredAt) > 10; return p }.sorted { $0.id < $1.id }
    }
    public mutating func suspend() {
        profiles.removeAll(); plans.removeAll()
        for id in Array(commands.keys) { finish(ChromeResult(id: id, status: "unknown", issue: "service_suspended")) }
    }
    private mutating func expire(_ now: Date) {
        plans = plans.filter { $0.value.expiresAt > now && $0.value.createdAt <= now }
        profiles = profiles.filter { now.timeIntervalSince($0.value.measuredAt) < 300 }
        for command in Array(commands.values) where command.expiresAt <= now {
            finish(ChromeResult(id: command.id, status: "unknown", issue: "confirmation_timeout", measuredAt: now))
        }
        batches = batches.filter { now.timeIntervalSince($0.value.plan.createdAt) < 900 }
    }
    private mutating func finish(_ result: ChromeResult) {
        guard let command = commands.removeValue(forKey: result.id), var batch = batches[command.planID] else { return }
        delivered.remove(result.id)
        if let index = batch.results.firstIndex(where: { $0.id == result.id }) { batch.results[index] = result }
        batches[command.planID] = batch
    }
    private func fresh(_ selection: ChromeSelection, now: Date) throws -> ChromeTab {
        guard let profile = profiles[selection.profileID], profile.sessionID == selection.sessionID,
              now >= profile.measuredAt, now.timeIntervalSince(profile.measuredAt) <= 10 else { throw ProbeIssue("session_stale", "Refresh and select the current profile session") }
        guard let tab = profile.tabs.first(where: { $0.id == selection.tabID && $0.token == selection.token }) else { throw ProbeIssue("tab_identity_changed", "Tab missing or replaced; select again") }
        return tab
    }
    public mutating func handle(_ request: ServiceRequest, now: Date = Date()) -> ServiceReply {
        do { return try process(request, now: now) }
        catch { return ServiceReply(requestID: request.requestID, issue: error as? ProbeIssue ?? ProbeIssue("service_request", "Request failed")) }
    }
    private mutating func process(_ request: ServiceRequest, now: Date) throws -> ServiceReply {
        try request.validate(); expire(now)
        var reply = ServiceReply(requestID: request.requestID); reply.serviceID = serviceID
        switch request.operation {
        case "chromeHello", "chromePublish", "chromePoll", "chromeResult", "chromeDisconnect":
            try NativeOrigin.validate(request.origin ?? "", allowed: allowedOrigin)
            guard let session = request.sessionID, let profileID = request.profileID else { throw ProbeIssue("session_required", "Native session and profile required") }
            reply.sessionID = session
            if request.operation == "chromeHello" {
                guard profiles[profileID] != nil || profiles.count < 32 else { throw ProbeIssue("profile_limit", "Too many profiles") }
                if profiles[profileID]?.sessionID != session {
                    for c in Array(commands.values) where c.target.selection.profileID == profileID { finish(ChromeResult(id: c.id, status: "unknown", issue: "session_replaced", measuredAt: now)) }
                    plans = plans.filter { !$0.value.targets.contains { $0.selection.profileID == profileID } }
                }
                profiles[profileID] = ChromeProfile(id: profileID, sessionID: session, label: request.label ?? "Chrome", measuredAt: now, stale: false, tabs: [], policy: policies[profileID] ?? ChromePolicy())
            }
            guard profiles[profileID]?.sessionID == session else { throw ProbeIssue("session_replaced", "Handshake required") }
            reply.policy = profiles[profileID]?.policy
            switch request.operation {
            case "chromePublish":
                guard let tabs = request.tabs else { throw ProbeIssue("tabs_required", "Publish tabs first") }
                profiles[profileID]?.tabs = tabs; profiles[profileID]?.measuredAt = now
            case "chromePoll":
                guard let profile = profiles[profileID], now >= profile.measuredAt, now.timeIntervalSince(profile.measuredAt) <= 10 else { throw ProbeIssue("session_stale", "Fresh snapshot required") }
                for c in commands.values.sorted(by: { $0.id < $1.id }) where c.target.selection.sessionID == session && !delivered.contains(c.id) {
                    do {
                        let tab = try fresh(c.target.selection, now: now)
                        guard tab == c.target.expected, profile.policy == c.policy else { throw ProbeIssue("tab_state_changed", "Refresh preview") }
                        if let reason = c.policy.exclusion(tab, kind: c.kind, now: now) { throw ProbeIssue("tab_excluded", reason) }
                        delivered.insert(c.id); reply.command = c; break
                    } catch { finish(ChromeResult(id: c.id, status: "failed", issue: (error as? ProbeIssue)?.code ?? "tab_changed", measuredAt: now)) }
                }
            case "chromeResult":
                guard let r = request.result, let c = commands[r.id], delivered.contains(r.id), c.target.selection.sessionID == session,
                      c.target.selection.profileID == profileID else { throw ProbeIssue("result_mismatch", "Result does not match a delivered command") }
                if r.status == "confirmed", c.kind == .discard, r.resultingTabID == nil { throw ProbeIssue("result_schema", "Discard requires verified resulting ID") }
                finish(r)
            case "chromeDisconnect":
                for c in Array(commands.values) where c.target.selection.sessionID == session { finish(ChromeResult(id: c.id, status: "unknown", issue: "disconnected", measuredAt: now)) }
                profiles.removeValue(forKey: profileID)
            default: break
            }
        case "tabsList": reply.profiles = snapshot(now: now)
        case "tabsPreview":
            guard let kind = request.kind, let selection = request.selections, !selection.isEmpty, selection.count <= 100, Set(selection).count == selection.count,
                  Set(selection.map { "\($0.profileID):\($0.tabID)" }).count == selection.count else { throw ProbeIssue("selection_required", "Select 1...100 distinct exact tab identities") }
            guard plans.count < 64 else { throw ProbeIssue("plan_limit", "Too many previews") }
            let targets = try selection.map { s -> ChromeTarget in
                let tab = try fresh(s, now: now)
                if let reason = profiles[s.profileID]?.policy.exclusion(tab, kind: kind, now: now) { throw ProbeIssue("tab_excluded", reason) }
                return ChromeTarget(selection: s, expected: tab)
            }
            let plan = ChromePlan(id: UUID().uuidString, kind: kind, createdAt: now, expiresAt: now.addingTimeInterval(30), targets: targets)
            plans[plan.id] = plan; reply.plan = plan
        case "tabsApply":
            guard let id = request.planID, let plan = plans.removeValue(forKey: id), plan.expiresAt > now else { throw ProbeIssue("preview_expired_or_used", "Create a new preview before applying") }
            guard batches.count < 128, commands.count + plan.targets.count <= 256 else { throw ProbeIssue("batch_limit", "Result buffer full") }
            for target in plan.targets {
                let tab = try fresh(target.selection, now: now)
                guard tab == target.expected else { throw ProbeIssue("tab_state_changed", "Refresh preview") }
                if let reason = profiles[target.selection.profileID]?.policy.exclusion(tab, kind: plan.kind, now: now) { throw ProbeIssue("tab_excluded", reason) }
            }
            let list = plan.targets.map { t in ChromeCommand(id: UUID().uuidString, planID: id, kind: plan.kind, target: t, expiresAt: now.addingTimeInterval(20), policy: profiles[t.selection.profileID]!.policy) }
            for c in list { commands[c.id] = c }
            let batch = ChromeBatch(plan: plan, results: list.map { ChromeResult(id: $0.id, status: "unknown", issue: "awaiting_confirmation", measuredAt: now) })
            batches[id] = batch; reply.batch = batch
        case "tabsResult":
            guard let id = request.planID, let batch = batches[id] else { throw ProbeIssue("result_unknown", "No result retained for this plan") }
            reply.batch = batch
        default: throw ProbeIssue("operation_denied", "Unknown service operation")
        }
        return reply
    }
}
