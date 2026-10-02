import Foundation
import Darwin

public enum DActionKind: String, Codable, Sendable { case simulatorShutdown, debuggerTerminate }
public enum DActionStatus: String, Codable, Sendable { case confirmed, failed, unknown }
public struct DActionResult: Codable, Sendable {
    public let status: DActionStatus
    public let issue: ProbeIssue?
    public let measuredAt: Date
    public init(status: DActionStatus, issue: ProbeIssue? = nil, measuredAt: Date = Date()) {
        self.status = status; self.issue = issue; self.measuredAt = measuredAt
    }
}
public struct DActionPlan: Codable, Sendable, Identifiable {
    public let id: String
    public let kind: DActionKind
    public let createdAt: Date
    public let expiresAt: Date
    public let simulator: AssignedSimulator?
    public let debugger: DebuggerObservation?
    public let affectedProcesses: [DiagnosticProcess]
    public let impact: String
    public let impactIssue: ProbeIssue?
}
public struct DActionOutcome: Codable, Sendable {
    public let plan: DActionPlan
    public var result: DActionResult
}

/// Injected only by in-module tests. Client requests can never supply proof or a command implementation.
struct DevelopmentSources: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var simulators: @Sendable (String) async throws -> SimulatorDiagnostics = { try await SimulatorDiscovery.read(assignmentPath: $0) }
    var shutdown: @Sendable (AssignedSimulator, String, Date) async throws -> Void = { try await SimulatorDiscovery.shutdown($0, assignmentPath: $1, expiresAt: $2) }
    var debugger: @Sendable (ProcessIdentity) async throws -> DebuggerObservation = liveDebugger
    var terminate: @Sendable (DebuggerObservation) async throws -> Void = liveTerminate
    var processIdentity: @Sendable (Int32) async throws -> ProcessIdentity? = liveIdentity
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func liveDebugger(_ identity: ProcessIdentity) async throws -> DebuggerObservation {
        let inventory = ProcessInventory()
        _ = try inventory.revalidate(identity)
        let snapshot = DebuggerDiscovery.read(ProcessDiagnostics(try inventory.sampleAll()))
        guard let observation = snapshot.debuggers.first(where: { $0.id == identity }) else { throw ProbeIssue("debugger_disappeared", "Debugger disappeared") }
        return observation // qualified=false: intentionally no heuristic promotion to proven orphan.
    }
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func liveTerminate(_ expected: DebuggerObservation) async throws {
        // Fail closed until a separately authorized live qualification provides an actual evidence source.
        // No PID signal is sent by the unqualified product, including when a client forges qualified=true.
        let current = try await liveDebugger(expected.id)
        try DebuggerActionPolicy.validate(expected: expected.id, owner: expected.process.uid, current: current, now: Date())
        throw ProbeIssue("debugger_qualification_required", "Termination backend remains disabled pending live qualification")
    }
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func liveIdentity(_ pid: Int32) async throws -> ProcessIdentity? {
        do { return try ProcessInventory().sample(pid: pid).identity }
        catch let issue as ProbeIssue where issue.code == "process_disappeared" { return nil }
    }
}

/// On-demand discovery and one-shot actions; no monitoring loop or disk history.
public actor DevelopmentActions {
    private let coordinator: SamplingCoordinator
    private let sources: DevelopmentSources
    private var assignmentPath: String
    private var plans: [String: DActionPlan] = [:]
    private var outcomes: [String: DActionOutcome] = [:]
    private var epoch: UInt64 = 0
    private var applying = false
    public init(coordinator: SamplingCoordinator, assignmentPath: String = SimulatorAssignment.defaultPath) {
        self.coordinator = coordinator; self.assignmentPath = assignmentPath; sources = DevelopmentSources()
    }
    init(coordinator: SamplingCoordinator, assignmentPath: String = "/fixture/.local/simulator-assignment.json", sources: DevelopmentSources) {
        self.coordinator = coordinator; self.assignmentPath = assignmentPath; self.sources = sources
    }
    public func setAssignmentPath(_ path: String) throws {
        _ = try SimulatorAssignment.read(path: path)
        guard !applying else { throw ProbeIssue("action_in_progress", "Wait for the selected action") }
        assignmentPath = path; epoch &+= 1; plans.removeAll()
    }
    public func suspend() { epoch &+= 1; plans.removeAll() }
    private func now() -> Date { sources.now() }
    private func expire(_ now: Date) {
        plans = plans.filter { $0.value.expiresAt > now && $0.value.createdAt <= now }
        outcomes = outcomes.filter { now.timeIntervalSince($0.value.plan.createdAt) < 900 }
    }
    public func handle(_ request: ServiceRequest) async -> ServiceReply {
        var reply = ServiceReply(requestID: request.requestID)
        do {
            try request.validate(); expire(now())
            switch request.operation {
            case "simulatorsList":
                var list = try await sources.simulators(assignmentPath)
                let frame = await coordinator.refresh(includeProcesses: true)
                list.associate(frame.processes, issue: frame.processError)
                reply.simulators = list
            case "debuggersList":
                let frame = await coordinator.refresh(includeProcesses: true)
                guard frame.processError == nil, let inventory = frame.processes else { throw frame.processError ?? ProbeIssue("processes_failed", "No process inventory") }
                reply.debuggers = DebuggerDiscovery.read(inventory)
            case "simulatorsPreview", "debuggersPreview":
                guard !applying, plans.count < 64 else { throw ProbeIssue("action_limit", "Action in progress or preview capacity reached") }
                let generation = epoch
                let path = assignmentPath
                let simulator: AssignedSimulator?
                let debugger: DebuggerObservation?
                let affected: [DiagnosticProcess]
                let impactIssue: ProbeIssue?
                if request.operation == "simulatorsPreview" {
                    guard let selected = request.simulator else { throw ProbeIssue("selection_required", "Select one exact device from the current inventory") }
                    let list = try await sources.simulators(path)
                    try SimulatorActionPolicy.validate(selected, in: list)
                    simulator = selected; debugger = nil
                    let frame = await coordinator.refresh(includeProcesses: true)
                    affected = frame.processes?.processes.filter { SimulatorInventory.associations(path: $0.executablePath, devices: list.devices.map(\.device)) == [selected.id] } ?? []
                    impactIssue = frame.processError ?? ProbeIssue("debug_impact_unknown", "Список процессов по dataPath частичный. Принадлежность общих helpers и активность отладки неизвестны.")
                } else {
                    guard let identity = request.debuggerIdentity else { throw ProbeIssue("selection_required", "Select PID and start identity") }
                    let current = try await sources.debugger(identity)
                    try DebuggerActionPolicy.validate(expected: identity, owner: getuid(), current: current, now: now())
                    simulator = nil; debugger = current; affected = [current.process]; impactIssue = nil
                }
                guard epoch == generation, !applying, plans.count < 64 else { throw ProbeIssue("service_suspended", "Discovery invalidated; preview again") }
                let now = now()
                let plan = DActionPlan(id: UUID().uuidString, kind: simulator == nil ? .debuggerTerminate : .simulatorShutdown,
                                       createdAt: now, expiresAt: now.addingTimeInterval(30), simulator: simulator, debugger: debugger,
                                       affectedProcesses: affected,
                                       impact: simulator?.device.state == "Shutdown" ? "Уже выключено. Команда выключения не будет отправлена." : simulator != nil ? "Завершатся все приложения и отладка только выбранного устройства. Несохранённое состояние может быть потеряно." : "Завершится только выбранный доказанно осиротевший LLDB.", impactIssue: impactIssue)
                plans[plan.id] = plan; reply.developmentPlan = plan
            case "developmentApply":
                guard request.apply == true else { throw ProbeIssue("apply_required", "Explicit apply required") }
                guard !applying else { throw ProbeIssue("action_in_progress", "Only one development action at a time") }
                guard let id = request.planID, let pending = plans[id], request.developmentKind == pending.kind else { throw ProbeIssue("preview_expired_or_used", "Unknown, expired, consumed or wrong-kind preview") }
                guard let plan = plans.removeValue(forKey: id) else { throw ProbeIssue("preview_expired_or_used", "Unknown, expired or consumed preview") }
                guard outcomes.count < 128 else { throw ProbeIssue("action_limit", "Result capacity reached") }
                applying = true
                defer { applying = false }
                let generation = epoch, path = assignmentPath
                var result: DActionResult
                do {
                    if let simulator = plan.simulator {
                        let fresh = try await sources.simulators(path)
                        try SimulatorActionPolicy.validate(simulator, in: fresh)
                        guard generation == epoch, plan.expiresAt > now() else { throw ProbeIssue("preview_expired_or_used", "Action invalidated during verification") }
                        if simulator.device.state == "Shutdown" { result = SimulatorActionPolicy.confirm(simulator, in: fresh) }
                        else {
                            // At this point command delivery is possible; errors cannot promise no impact.
                            outcomes[id] = DActionOutcome(plan: plan, result: .init(status: .unknown, issue: ProbeIssue("awaiting_confirmation", "Command in progress")))
                            do {
                                try await sources.shutdown(simulator, path, plan.expiresAt)
                                let after = try await sources.simulators(path)
                                result = SimulatorActionPolicy.confirm(simulator, in: after)
                            } catch { result = .init(status: .unknown, issue: Self.issue(error)) }
                        }
                    } else if let debugger = plan.debugger {
                        let fresh = try await sources.debugger(debugger.id)
                        try DebuggerActionPolicy.validate(expected: debugger.id, owner: debugger.process.uid, current: fresh, now: now())
                        guard generation == epoch, plan.expiresAt > now() else { throw ProbeIssue("preview_expired_or_used", "Action invalidated during verification") }
                        outcomes[id] = DActionOutcome(plan: plan, result: .init(status: .unknown, issue: ProbeIssue("awaiting_confirmation", "Termination in progress")))
                        do {
                            try await sources.terminate(fresh)
                            let after = try await sources.processIdentity(debugger.id.pid)
                            result = DebuggerActionPolicy.confirmation(expected: debugger.id, observed: after)
                        } catch { result = .init(status: .unknown, issue: Self.issue(error)) }
                    } else { throw ProbeIssue("selection_required", "No target") }
                } catch { result = .init(status: .failed, issue: Self.issue(error)) }
                let outcome = DActionOutcome(plan: plan, result: result)
                outcomes[id] = outcome; reply.developmentOutcome = outcome
            case "developmentResult":
                guard let id = request.planID, let outcome = outcomes[id], request.developmentKind == outcome.plan.kind else { throw ProbeIssue("result_unknown", "Unknown or expired result") }
                reply.developmentOutcome = outcome
            default: throw ProbeIssue("operation_denied", "Unknown development operation")
            }
            return reply
        } catch { return ServiceReply(requestID: request.requestID, issue: Self.issue(error)) }
    }
    private static func issue(_ error: any Error) -> ProbeIssue { error as? ProbeIssue ?? ProbeIssue("development_failed", "Development operation unavailable") }
}
