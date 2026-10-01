import Foundation
import Testing
@testable import ZapasCore

private let baseTime = Date(timeIntervalSince1970: 1_800_000_000)

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = baseTime
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; time = time.addingTimeInterval(seconds) }
}

private func systemSample(at time: Date, previous: CounterSample?) -> SystemSnapshot {
    let counter = CounterSample(wallTime: time, awakeSeconds: time.timeIntervalSince(baseTime) + 1, bootID: "test", pageSize: 4096,
                                swapins: UInt64(max(0, time.timeIntervalSince(baseTime))), swapouts: 0)
    func metric(_ value: Double) -> Metric { Metric(value, source: "test.source", at: time) }
    return SystemSnapshot(measuredAt: time, physical: metric(16e9), wired: metric(1e9), compressed: metric(2e9), active: metric(0),
                          inactive: metric(0), free: metric(0), swapUsed: metric(3e9), swapTotal: metric(4e9), pressure: .unknown,
                          counters: counter, rates: SwapRates.calculate(previous: previous, current: counter))
}

private actor SourceHarness {
    let clock: TestClock
    var systems = 0
    var inventories = 0
    var active = 0
    var maximumActive = 0
    var blocked = false
    var waiter: CheckedContinuation<Void, Never>?
    var failSystem = false
    var failProcesses = false
    init(clock: TestClock) { self.clock = clock }
    func block() { blocked = true }
    func release() { blocked = false; waiter?.resume(); waiter = nil }
    func failNext(system: Bool = false, processes: Bool = false) { failSystem = system; failProcesses = processes }
    func readSystem(_ previous: CounterSample?, _ pressure: PressureObservation) async throws -> SystemSnapshot {
        systems += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        // Intentionally ignores cancellation: validates rejection of obsolete work.
        if blocked { await withCheckedContinuation { waiter = $0 } }
        if failSystem { failSystem = false; throw ProbeIssue("test_system_denied", "Synthetic denial") }
        return systemSample(at: clock.read(), previous: previous)
    }
    func readProcesses() throws -> ProcessSnapshot {
        inventories += 1
        if failProcesses { failProcesses = false; throw ProbeIssue("test_inventory_denied", "Synthetic denial") }
        return ProcessSnapshot(measuredAt: clock.read(), processes: [], failures: [])
    }
    nonisolated var sources: SamplingSources {
        SamplingSources(system: { try await self.readSystem($0, $1) }, processes: { try await self.readProcesses() })
    }
}

private actor ScheduleHarness {
    var intervals: [Double] = []
    var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    func sleep(_ seconds: Double) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                intervals.append(seconds); waiters[id] = continuation
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func tick() { let pending = waiters; waiters.removeAll(); for waiter in pending.values { waiter.resume() } }
}

private func eventually(_ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("Condition did not become true")
}

@Test func concurrentRefreshesShareOneCollection() async {
    let clock = TestClock(); let source = SourceHarness(clock: clock)
    await source.block()
    let coordinator = SamplingCoordinator(sources: source.sources, observePressure: false, now: clock.read)
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<12 { group.addTask { _ = await coordinator.refresh(includeProcesses: true) } }
        await eventually { await coordinator.activeRefreshRequests == 12 }
        await source.release()
        await group.waitForAll()
    }
    #expect(await source.systems == 1)
    #expect(await source.inventories == 1)
    #expect(await source.maximumActive == 1)
    #expect(await coordinator.snapshot().history.count == 1)
    await coordinator.stop()
}

@Test func detailedRequestDuringBackgroundGetsInventoryWithoutOverlap() async {
    let clock = TestClock(); let source = SourceHarness(clock: clock)
    await source.block()
    let coordinator = SamplingCoordinator(sources: source.sources, observePressure: false, now: clock.read)
    let background = Task { await coordinator.refresh() }
    await eventually { await source.systems == 1 }
    let detailed = Task { await coordinator.refresh(includeProcesses: true) }
    await eventually { await coordinator.activeRefreshRequests == 2 }
    await source.release()
    _ = await background.value; _ = await detailed.value
    #expect(await source.systems == 2)
    #expect(await source.inventories == 1)
    #expect(await source.maximumActive == 1)
    await coordinator.stop()
}

@Test func visibilityChangesCadenceAndInventoryCollection() async {
    let clock = TestClock(); let source = SourceHarness(clock: clock); let schedule = ScheduleHarness()
    let coordinator = SamplingCoordinator(sources: source.sources, observePressure: false, now: clock.read, sleep: { try await schedule.sleep($0) })
    await coordinator.start()
    await eventually { await schedule.intervals == [30] }
    #expect(await source.inventories == 0)
    await coordinator.setDetailed(true)
    await eventually { await schedule.intervals == [30, 3] }
    #expect(await source.inventories == 1)
    await coordinator.setDetailed(false)
    await eventually { await schedule.intervals == [30, 3, 30] }
    #expect(await source.inventories == 1)
    await coordinator.stop()
}

@Test func sleepStopsSamplingAndWakeResetsShortInterval() async {
    let clock = TestClock(); let source = SourceHarness(clock: clock)
    let coordinator = SamplingCoordinator(sources: source.sources, observePressure: false, now: clock.read)
    _ = await coordinator.refresh()
    clock.advance(1)
    #expect(await coordinator.refresh().system?.swapReadRate.value == 4096)
    await coordinator.willSleep()
    _ = await coordinator.refresh(includeProcesses: true)
    #expect(await source.systems == 2)
    clock.advance(1) // Too short to be caught by the old wall/awake heuristic.
    await coordinator.didWake()
    #expect(await coordinator.refresh().system?.swapReadRate.error?.code == "first_sample")
    clock.advance(1)
    #expect(await coordinator.refresh().system?.swapReadRate.value == 4096)
    let points = await coordinator.snapshot().history
    #expect(HistoryChart.points(points).filter { $0.kind == "Swap" }.map(\.segment).last != HistoryChart.points(points).first?.segment)
    await coordinator.stop()
}

@Test func obsoleteCollectionAfterWakeIsDiscardedAndRetried() async {
    let clock = TestClock(); let source = SourceHarness(clock: clock)
    await source.block()
    let coordinator = SamplingCoordinator(sources: source.sources, observePressure: false, now: clock.read)
    let pending = Task { await coordinator.refresh() }
    await eventually { await source.systems == 1 }
    await coordinator.willSleep(); await coordinator.didWake()
    clock.advance(1); await source.release()
    let result = await pending.value
    #expect(result.history.count == 1)
    #expect(result.system?.swapReadRate.error?.code == "first_sample")
    #expect(await source.systems == 2)
    #expect(await source.maximumActive == 1)
    await coordinator.stop()
}

@Test func stopRejectsUncooperativeCollectionAndFinishesUpdates() async {
    let clock = TestClock(); let source = SourceHarness(clock: clock)
    await source.block()
    let coordinator = SamplingCoordinator(sources: source.sources, observePressure: false, now: clock.read)
    let stream = await coordinator.updates()
    let pending = Task { await coordinator.refresh() }
    await eventually { await source.systems == 1 }
    await coordinator.stop(); await source.release()
    #expect(await pending.value.system == nil)
    #expect(await coordinator.snapshot().history.isEmpty)
    var received = 0
    for await _ in stream { received += 1 }
    #expect(received == 1)
    _ = await coordinator.refresh()
    #expect(await source.systems == 1)
}

@Test func errorsKeepLastSuccessfulDataAndRecoveryClearsErrors() async {
    let clock = TestClock(); let source = SourceHarness(clock: clock)
    let coordinator = SamplingCoordinator(sources: source.sources, observePressure: false, now: clock.read)
    _ = await coordinator.refresh(includeProcesses: true)
    clock.advance(61)
    await source.failNext(system: true, processes: true)
    let failed = await coordinator.refresh(includeProcesses: true)
    #expect(failed.system?.measuredAt == baseTime)
    #expect(failed.processes?.measuredAt == baseTime)
    #expect(failed.systemStale(at: clock.read()))
    #expect(failed.processesStale(at: clock.read()))
    #expect(failed.systemError?.code == "test_system_denied")
    #expect(failed.history.last?.swapUsed.value == nil)
    #expect(failed.history.last?.swapUsed.error?.code == "test_system_denied")
    clock.advance(1)
    let recovered = await coordinator.refresh(includeProcesses: true)
    #expect(recovered.systemError == nil)
    #expect(recovered.processError == nil)
    #expect(recovered.system?.swapReadRate.error?.code == "first_sample")
    #expect(!recovered.systemStale(at: clock.read()))
    await coordinator.stop()
}

@Test func historyIsBoundedByCountAndAgeAndHandlesClockReversal() async {
    let clock = TestClock(); let source = SourceHarness(clock: clock)
    let coordinator = SamplingCoordinator(sources: source.sources, observePressure: false, now: clock.read)
    for _ in 0..<610 { _ = await coordinator.refresh(); clock.advance(1) }
    #expect(await coordinator.snapshot().history.count == 600)
    clock.advance(901)
    #expect(await coordinator.refresh().history.count == 1)
    clock.advance(-10)
    #expect(await coordinator.refresh().history.count == 1)
    await coordinator.stop()
}

@Test func newestOnlyUpdateBufferDoesNotAccumulateFrames() async {
    let clock = TestClock(); let source = SourceHarness(clock: clock)
    let coordinator = SamplingCoordinator(sources: source.sources, observePressure: false, now: clock.read)
    let stream = await coordinator.updates()
    for _ in 0..<5 { _ = await coordinator.refresh(); clock.advance(1) }
    await coordinator.stop()
    var frames: [DiagnosticFrame] = []
    for await frame in stream { frames.append(frame) }
    #expect(frames.count == 1)
    #expect(frames[0].history.count == 5)
}
