import Foundation
import Darwin
import Testing
@testable import ZapasCore

private let iosRuntime = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
private let testUDID = "11111111-1111-4111-8111-111111111111"
private let testIdentity = ProcessIdentity(pid: 12345, startSeconds: 456, startMicroseconds: 789)
private func assigned(state: String = "Booted", runtime: String = iosRuntime, owner: String = "Zapas", incarnation: String = "fixture-1", verified: Bool = true, available: Bool = true, path: String = "/fixture/device/data") -> AssignedSimulator {
    AssignedSimulator(device: SimulatorDevice(name: "Dedicated", udid: testUDID, runtime: runtime, state: state, isAvailable: available, dataPath: path,
        assignment: owner, isIOS: runtime.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-")), incarnation: incarnation, assignmentVerified: verified)
}
private func simulatorList(_ device: AssignedSimulator? = assigned()) -> SimulatorDiagnostics {
    SimulatorDiagnostics(measuredAt: Date(), totalDeviceCount: device == nil ? 0 : 1, devices: device.map { [$0] } ?? [], assignmentIssue: nil)
}
private func debugger(activity: DebugActivity = .inactive, orphan: DebugOrphanhood = .proven, qualified: Bool = true,
    identity: ProcessIdentity = testIdentity, uid: UInt32 = getuid(), time: Date = Date()) -> DebuggerObservation {
    let p = ProcessObservation(identity: identity, uid: uid, parentPID: 1, name: "lldb-rpc-server", executablePath: "/fixture/Xcode.app/lldb-rpc-server",
        footprint: Metric(9000, source: "fixture", at: Date()), rss: Metric(8000, source: "fixture", at: Date()))
    return DebuggerObservation(process: DiagnosticProcess(p), activity: activity, orphanhood: orphan,
        evidence: [DebugEvidence(code: "test_qualified_session", explanation: "Injected deterministic fixture only", relatedIdentity: nil)], measuredAt: time, qualified: qualified)
}
private actor SimulatorFixture {
    var value = simulatorList()
    var commands = 0
    var final: SimulatorDiagnostics?
    var failDelivery = false
    var failReadAfter = false
    func read() throws -> SimulatorDiagnostics {
        if failReadAfter && commands > 0 { throw ProbeIssue("simctl_unavailable", "fixture") }
        return value
    }
    func set(_ new: SimulatorDiagnostics) { value = new }
    func behavior(final: SimulatorDiagnostics?, failDelivery: Bool = false, failReadAfter: Bool = false) {
        self.final = final; self.failDelivery = failDelivery; self.failReadAfter = failReadAfter
    }
    func shutdown(_ target: AssignedSimulator) throws {
        commands += 1
        #expect(target.id == testUDID)
        if failDelivery { throw ProbeIssue("simctl_unavailable", "fixture delivery") }
        if let final { value = final }
    }
    func sources() -> DevelopmentSources {
        var sources = DevelopmentSources()
        sources.simulators = { _ in try await self.read() }
        sources.shutdown = { target, _, deadline in
            #expect(deadline > Date())
            try await self.shutdown(target)
        }
        return sources
    }
}
private func preview(_ executor: DevelopmentActions, device: AssignedSimulator = assigned()) async throws -> DActionPlan {
    var r = ServiceRequest("simulatorsPreview"); r.simulator = device
    let reply = await executor.handle(r)
    #expect(reply.issue == nil)
    return try #require(reply.developmentPlan)
}
private func apply(_ executor: DevelopmentActions, plan: DActionPlan) async -> ServiceReply {
    var r = ServiceRequest("developmentApply"); r.planID = plan.id; r.apply = true; r.developmentKind = plan.kind
    return await executor.handle(r)
}

@Test(arguments: [assigned(incarnation: "reused"), assigned(runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-0"), assigned(owner: "OtherProject"), assigned(verified: false), assigned(available: false), assigned(state: "Shutdown"), assigned(path: "/fixture/replaced/data"), assigned(runtime: "com.apple.CoreSimulator.SimRuntime.tvOS-27-0")])
func simulatorChangesBlockDelivery(_ changed: AssignedSimulator) async throws {
    let fixture = SimulatorFixture()
    let executor = DevelopmentActions(coordinator: SamplingCoordinator(observePressure: false), sources: await fixture.sources())
    let plan = try await preview(executor)
    await fixture.set(simulatorList(changed))
    let response = await apply(executor, plan: plan)
    #expect(response.developmentOutcome?.result.status == .failed)
    #expect(await fixture.commands == 0)
}
@Test func disappearedDeviceBlocksDelivery() async throws {
    let fixture = SimulatorFixture()
    let executor = DevelopmentActions(coordinator: SamplingCoordinator(observePressure: false), sources: await fixture.sources())
    let plan = try await preview(executor)
    await fixture.set(simulatorList(nil))
    let response = await apply(executor, plan: plan)
    #expect(response.developmentOutcome?.result.issue?.code == "device_disappeared")
    #expect(await fixture.commands == 0)
}
@Test func alreadyShutdownIsConfirmedWithoutCommandAndPlansAreSingleUse() async throws {
    let fixture = SimulatorFixture(); await fixture.set(simulatorList(assigned(state: "Shutdown")))
    let executor = DevelopmentActions(coordinator: SamplingCoordinator(observePressure: false), sources: await fixture.sources())
    let plan = try await preview(executor, device: assigned(state: "Shutdown"))
    #expect(await fixture.commands == 0)
    var withoutApply = ServiceRequest("developmentApply"); withoutApply.planID = plan.id
    #expect(await executor.handle(withoutApply).issue?.code == "apply_required")
    let result = await apply(executor, plan: plan)
    #expect(result.developmentOutcome?.result.status == .confirmed)
    #expect(result.developmentOutcome?.result.issue?.code == "device_already_shutdown")
    #expect(await fixture.commands == 0)
    #expect(await apply(executor, plan: plan).issue?.code == "preview_expired_or_used")
    var query = ServiceRequest("developmentResult"); query.planID = plan.id; query.developmentKind = plan.kind
    #expect(await executor.handle(query).developmentOutcome?.result.status == .confirmed)
}
@Test(arguments: ["shutdown", "booted", "missing", "reused", "other", "delivery_error", "read_error"])
func simulatorResultsReflectActualState(_ scenario: String) async throws {
    let fixture = SimulatorFixture()
    let final: SimulatorDiagnostics = switch scenario {
    case "shutdown": simulatorList(assigned(state: "Shutdown"))
    case "missing": simulatorList(nil)
    case "reused": simulatorList(assigned(incarnation: "new"))
    case "other": simulatorList(assigned(owner: "OtherProject"))
    default: simulatorList()
    }
    await fixture.behavior(final: final, failDelivery: scenario == "delivery_error", failReadAfter: scenario == "read_error")
    let executor = DevelopmentActions(coordinator: SamplingCoordinator(observePressure: false), sources: await fixture.sources())
    let plan = try await preview(executor)
    #expect(await fixture.commands == 0)
    let response = await apply(executor, plan: plan)
    let expected: DActionStatus = scenario == "shutdown" ? .confirmed : scenario == "booted" ? .failed : .unknown
    #expect(response.developmentOutcome?.result.status == expected)
    #expect(await fixture.commands == 1)
    #expect(await apply(executor, plan: plan).issue?.code == "preview_expired_or_used")
}
@Test func suspendInvalidatesDevelopmentPlans() async throws {
    let fixture = SimulatorFixture()
    let executor = DevelopmentActions(coordinator: SamplingCoordinator(observePressure: false), sources: await fixture.sources())
    let plan = try await preview(executor)
    await executor.suspend()
    #expect(await apply(executor, plan: plan).issue?.code == "preview_expired_or_used")
    #expect(await fixture.commands == 0)
}
@Test func simulatorAssociationDoesNotInferHelpersOrPathTraversal() {
    let device = assigned().device
    #expect(SimulatorInventory.associations(path: "/fixture/device/data/../elsewhere/app", devices: [device]).isEmpty)
    #expect(SimulatorInventory.associations(path: "/fixture/device/data-sibling/app", devices: [device]).isEmpty)
    #expect(SimulatorInventory.associations(path: "/Applications/Simulator.app/helper", devices: [device]).isEmpty)
    #expect(SimulatorInventory.associations(path: "/fixture/device/data/Containers/app", devices: [device]) == [testUDID])
}
@Test func debuggerNameParentAndLargeMemoryNeverProveActivityOrOrphanhood() {
    let observation = debugger()
    let inventory = ProcessSnapshot(measuredAt: Date(), processes: [ProcessObservation(identity: observation.id, uid: getuid(), parentPID: 1,
        name: "lldb-rpc-server", executablePath: observation.process.executablePath, footprint: Metric(5e9, source: "fixture", at: Date()), rss: Metric(4e9, source: "fixture", at: Date()))], failures: [])
    let actual = DebuggerDiscovery.read(ProcessDiagnostics(inventory))
    #expect(actual.debuggers.first?.activity == .unknown)
    #expect(actual.debuggers.first?.orphanhood == .candidate)
    #expect(actual.debuggers.first?.canTerminate == false)
    #expect(actual.debuggers.first?.evidence.contains(where: { $0.code == "reparented_candidate" }) == true)
}
@Test(arguments: [DebugActivity.active, .unknown])
func activeAndUnknownDebuggingBlockPreview(_ activity: DebugActivity) async {
    var sources = DevelopmentSources(); sources.debugger = { _ in debugger(activity: activity) }
    sources.terminate = { _ in Issue.record("Must never deliver") }
    let executor = DevelopmentActions(coordinator: SamplingCoordinator(observePressure: false), sources: sources)
    var request = ServiceRequest("debuggersPreview"); request.debuggerIdentity = testIdentity
    let response = await executor.handle(request)
    #expect(response.issue?.code == "debugger_activity_unproven")
    #expect(response.developmentPlan == nil)
}
@Test func debuggerIdentityOwnerAndFreshEvidenceAreRequired() {
    #expect(throws: ProbeIssue.self) { try DebuggerActionPolicy.validate(expected: testIdentity, owner: getuid(), current: debugger(identity: ProcessIdentity(pid: testIdentity.pid, startSeconds: 999, startMicroseconds: 0)), now: Date()) }
    #expect(throws: ProbeIssue.self) { try DebuggerActionPolicy.validate(expected: testIdentity, owner: getuid(), current: debugger(uid: getuid() + 1), now: Date()) }
    #expect(throws: ProbeIssue.self) { try DebuggerActionPolicy.validate(expected: testIdentity, owner: getuid(), current: debugger(time: Date().addingTimeInterval(-3)), now: Date()) }
    #expect(throws: ProbeIssue.self) { try DebuggerActionPolicy.validate(expected: testIdentity, owner: getuid(), current: debugger(qualified: false), now: Date()) }
    #expect(throws: ProbeIssue.self) { try DebuggerActionPolicy.validate(expected: testIdentity, owner: getuid(), current: debugger(orphan: .candidate), now: Date()) }
}
private actor DebugFixture {
    var observation = debugger()
    var commands = 0
    var postIdentity: ProcessIdentity?
    var postError = false
    func read() -> DebuggerObservation { observation }
    func set(_ value: DebuggerObservation) { observation = value }
    func terminate() { commands += 1 }
    func after() throws -> ProcessIdentity? { if postError { throw ProbeIssue("process_api", "fixture") }; return postIdentity }
    func configure(_ scenario: String) {
        postIdentity = scenario == "failed" ? testIdentity : scenario == "reused" ? ProcessIdentity(pid: testIdentity.pid, startSeconds: 1000, startMicroseconds: 0) : nil
        postError = scenario == "unknown"
    }
    func sources() -> DevelopmentSources {
        var sources = DevelopmentSources()
        sources.debugger = { _ in await self.read() }
        sources.terminate = { _ in await self.terminate() }
        sources.processIdentity = { _ in try await self.after() }
        return sources
    }
}
private func debuggerPreview(_ executor: DevelopmentActions) async throws -> DActionPlan {
    var request = ServiceRequest("debuggersPreview"); request.debuggerIdentity = testIdentity
    return try #require(await executor.handle(request).developmentPlan)
}
@Test(arguments: ["confirmed", "failed", "unknown", "reused"])
func qualifiedDebuggerContractConfirmsOnlyVerifiedExit(_ scenario: String) async throws {
    let fixture = DebugFixture(); await fixture.configure(scenario)
    let executor = DevelopmentActions(coordinator: SamplingCoordinator(observePressure: false), sources: await fixture.sources())
    let plan = try await debuggerPreview(executor)
    let reply = await apply(executor, plan: plan)
    #expect(reply.developmentOutcome?.result.status.rawValue == (scenario == "reused" ? "unknown" : scenario))
    #expect(await fixture.commands == 1)
}
@Test(arguments: ["active", "unknown", "reused", "owner"])
func debuggerFreshCheckBlocksChangedSession(_ scenario: String) async throws {
    let fixture = DebugFixture()
    let executor = DevelopmentActions(coordinator: SamplingCoordinator(observePressure: false), sources: await fixture.sources())
    let plan = try await debuggerPreview(executor)
    let value: DebuggerObservation = switch scenario {
    case "active": debugger(activity: .active)
    case "unknown": debugger(activity: .unknown)
    case "owner": debugger(uid: getuid() + 1)
    default: debugger(identity: ProcessIdentity(pid: testIdentity.pid, startSeconds: 1000, startMicroseconds: 0))
    }
    await fixture.set(value)
    let reply = await apply(executor, plan: plan)
    #expect(reply.developmentOutcome?.result.status == .failed)
    #expect(await fixture.commands == 0)
}
@Test func forgedDebuggerProofIsNotARequestField() throws {
    let json = Data("{\"version\":1,\"requestID\":\"11111111-1111-4111-8111-111111111111\",\"operation\":\"debuggersPreview\",\"qualified\":true,\"activity\":\"inactive\",\"orphanhood\":\"proven\"}".utf8)
    let request = try JSONDecoder().decode(ServiceRequest.self, from: json)
    #expect(request.debuggerIdentity == nil)
}
@Test func duplicateSimulatorIDsAreRejected() {
    let d = "{\"name\":\"same\",\"udid\":\"\(testUDID)\",\"state\":\"Booted\",\"isAvailable\":true}"
    #expect(throws: ProbeIssue.self) { try SimulatorInventory.decode(Data("{\"devices\":{\"\(iosRuntime)\":[\(d),\(d)]}}".utf8)) }
}

private final class DevelopmentClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func read() -> Date { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}
@Test func expiredAndWrongKindPlansNeverDeliver() async throws {
    let fixture = SimulatorFixture(), clock = DevelopmentClock()
    var sources = await fixture.sources(); sources.now = { clock.read() }
    let executor = DevelopmentActions(coordinator: SamplingCoordinator(observePressure: false), sources: sources)
    let plan = try await preview(executor)
    var wrongKind = ServiceRequest("developmentApply"); wrongKind.planID = plan.id; wrongKind.apply = true; wrongKind.developmentKind = .debuggerTerminate
    #expect(await executor.handle(wrongKind).issue?.code == "preview_expired_or_used")
    clock.advance(31)
    #expect(await apply(executor, plan: plan).issue?.code == "preview_expired_or_used")
    #expect(await fixture.commands == 0)
}
@Test func missingXcodeAndAssignmentErrorsRemainStructured() async {
    var sources = DevelopmentSources()
    sources.simulators = { _ in throw ProbeIssue("simctl_unavailable", "Xcode unavailable") }
    let executor = DevelopmentActions(coordinator: SamplingCoordinator(observePressure: false), sources: sources)
    let reply = await executor.handle(ServiceRequest("simulatorsList"))
    #expect(reply.simulators == nil)
    #expect(reply.issue?.code == "simctl_unavailable")
}
@Test func resultRetentionIsBoundedAndNoReplayAfterExpiry() async throws {
    let fixture = SimulatorFixture(), clock = DevelopmentClock()
    await fixture.set(simulatorList(assigned(state: "Shutdown")))
    var sources = await fixture.sources(); sources.now = { clock.read() }
    let executor = DevelopmentActions(coordinator: SamplingCoordinator(observePressure: false), sources: sources)
    let plan = try await preview(executor, device: assigned(state: "Shutdown"))
    _ = await apply(executor, plan: plan)
    clock.advance(901)
    var query = ServiceRequest("developmentResult"); query.planID = plan.id; query.developmentKind = plan.kind
    #expect(await executor.handle(query).issue?.code == "result_unknown")
    #expect(await fixture.commands == 0)
}
