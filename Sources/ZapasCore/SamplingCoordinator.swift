import Foundation

public struct SamplingSources: Sendable {
    public var system: @Sendable (CounterSample?, PressureObservation) async throws -> SystemSnapshot
    public var processes: @Sendable () async throws -> ProcessSnapshot
    public init(system: @escaping @Sendable (CounterSample?, PressureObservation) async throws -> SystemSnapshot,
                processes: @escaping @Sendable () async throws -> ProcessSnapshot) {
        self.system = system; self.processes = processes
    }
    public static var live: Self { Self(system: readSystem, processes: readProcesses) }
    #if compiler(>=6.2)
    @concurrent
    #endif
    private static func readSystem(_ previous: CounterSample?, _ pressure: PressureObservation) async throws -> SystemSnapshot {
        try Task.checkCancellation()
        return try SystemMonitor().sample(previous: previous, pressure: pressure)
    }
    #if compiler(>=6.2)
    @concurrent
    #endif
    private static func readProcesses() async throws -> ProcessSnapshot {
        try Task.checkCancellation()
        return try ProcessInventory().sampleAll()
    }
}

public struct HistoryPoint: Sendable {
    public let measuredAt: Date
    public let compressed: DiagnosticMetric
    public let swapUsed: DiagnosticMetric
    public let epoch: UInt64
    public let cadence: Double
}

public struct ChartPoint: Sendable, Identifiable {
    public let id: Int
    public let measuredAt: Date
    public let valueGiB: Double
    public let kind: String
    public let segment: String
}

public enum HistoryChart {
    /// Never interpolate across unknown metrics, epoch resets or missed intervals.
    public static func points(_ history: [HistoryPoint]) -> [ChartPoint] {
        var result: [ChartPoint] = []
        for kind in ["Swap", "Компрессор"] {
            var segment = 0
            var previous: HistoryPoint?
            for point in history {
                let metric = kind == "Swap" ? point.swapUsed : point.compressed
                if let previous, previous.epoch != point.epoch || point.measuredAt.timeIntervalSince(previous.measuredAt) > 2 * max(previous.cadence, point.cadence) {
                    segment += 1
                }
                if let value = metric.value {
                    result.append(ChartPoint(id: result.count, measuredAt: point.measuredAt, valueGiB: value / 1_073_741_824,
                                             kind: kind, segment: "\(kind)-\(segment)"))
                } else { segment += 1 }
                previous = point
            }
        }
        return result
    }
}

public struct DiagnosticFrame: Sendable {
    public internal(set) var system: SystemDiagnostics?
    public internal(set) var processes: ProcessDiagnostics?
    public internal(set) var applications: [ApplicationDiagnostics] = []
    public internal(set) var systemError: ProbeIssue?
    public internal(set) var processError: ProbeIssue?
    public internal(set) var history: [HistoryPoint] = []
    public internal(set) var detailed = false
    public internal(set) var sleeping = false
    public var cadence: Double { detailed ? 3 : 30 }
    public func systemStale(at now: Date) -> Bool {
        system.map { now.timeIntervalSince($0.measuredAt) > 2 * cadence || now < $0.measuredAt } ?? false
    }
    public func processesStale(at now: Date) -> Bool {
        processes.map { now.timeIntervalSince($0.measuredAt) > 6 || now < $0.measuredAt } ?? false
    }
    public init() {}
}

private struct Collection: Sendable {
    var system: SystemSnapshot?
    var processes: ProcessSnapshot?
    var systemError: ProbeIssue?
    var processError: ProbeIssue?
}

/// One owner for sampling, baseline, pressure subscription, scheduling and bounded history.
public actor SamplingCoordinator {
    private let sources: SamplingSources
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Double) async throws -> Void
    private let pressure: MemoryPressureObserver?
    private var frame = DiagnosticFrame()
    private var baseline: CounterSample?
    private var epoch: UInt64 = 0
    private var running = false
    private var stopped = false
    private var schedule: Task<Void, Never>?
    private var inFlight: (id: UUID, epoch: UInt64, detailed: Bool, task: Task<Collection, Never>)?
    private var subscribers: [UUID: AsyncStream<DiagnosticFrame>.Continuation] = [:]
    // Internal observation for deterministic concurrency tests; no public wire/API field.
    private(set) var activeRefreshRequests = 0

    public init(sources: SamplingSources = .live, observePressure: Bool = true,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.sources = sources; self.now = now; self.sleep = sleep
        pressure = observePressure ? MemoryPressureObserver() : nil
    }
    public func updates() -> AsyncStream<DiagnosticFrame> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DiagnosticFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.yield(frame)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    private func publish() { for continuation in subscribers.values { continuation.yield(frame) } }
    public func snapshot() -> DiagnosticFrame { frame }

    public func start() {
        guard !running else { return }
        running = true; stopped = false; reschedule()
    }
    public func stop() {
        running = false; stopped = true; epoch &+= 1; baseline = nil
        schedule?.cancel(); schedule = nil; inFlight?.task.cancel()
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }
    public func setDetailed(_ value: Bool) {
        guard frame.detailed != value else { return }
        frame.detailed = value; publish(); reschedule()
    }
    public func willSleep() {
        epoch &+= 1; baseline = nil; frame.sleeping = true
        schedule?.cancel(); schedule = nil; inFlight?.task.cancel(); publish()
    }
    public func didWake() {
        epoch &+= 1; baseline = nil; frame.sleeping = false; publish(); reschedule()
    }
    private func reschedule() {
        schedule?.cancel(); schedule = nil
        guard running, !frame.sleeping else { return }
        schedule = Task { [weak self] in
            guard let self else { return }
            await self.runSchedule()
        }
    }
    private func runSchedule() async {
        while running, !frame.sleeping, !Task.isCancelled {
            _ = await refresh(includeProcesses: frame.detailed)
            guard running, !frame.sleeping, !Task.isCancelled else { return }
            do { try await sleep(frame.cadence) } catch { return }
        }
    }

    public func refresh(includeProcesses: Bool = false) async -> DiagnosticFrame {
        guard !frame.sleeping, !stopped else { return frame }
        activeRefreshRequests += 1
        defer { activeRefreshRequests -= 1 }
        let flight: (id: UUID, epoch: UInt64, detailed: Bool, task: Task<Collection, Never>)
        if let existing = inFlight { flight = existing }
        else {
            let previous = baseline
            let observation = pressure?.observation ?? .unknown
            let sources = sources
            let task = Task {
                var result = Collection()
                do { result.system = try await sources.system(previous, observation) }
                catch { result.systemError = Self.issue(error, fallback: "system_failed") }
                if includeProcesses, !Task.isCancelled {
                    do { result.processes = try await sources.processes() }
                    catch { result.processError = Self.issue(error, fallback: "processes_failed") }
                }
                return result
            }
            flight = (UUID(), epoch, includeProcesses, task); inFlight = flight
        }
        let result = await flight.task.value
        if inFlight?.id == flight.id {
            inFlight = nil
            if epoch == flight.epoch, !frame.sleeping, !stopped {
                apply(result, detailed: flight.detailed)
            }
        }
        guard !frame.sleeping, !stopped else { return frame }
        // A wake or a detailed request arriving during a background sample gets one new collection.
        if epoch != flight.epoch || (includeProcesses && !flight.detailed) {
            return await refresh(includeProcesses: includeProcesses)
        }
        return frame
    }
    private static func issue(_ error: any Error, fallback: String) -> ProbeIssue {
        error as? ProbeIssue ?? ProbeIssue(fallback, error is CancellationError ? "Collection cancelled" : String(describing: error))
    }
    private func apply(_ result: Collection, detailed: Bool) {
        let time = now()
        frame.systemError = result.systemError
        if let system = result.system {
            baseline = system.counters
            frame.system = SystemDiagnostics(system)
        } else { baseline = nil }
        if detailed {
            frame.processError = result.processError
            if let processes = result.processes {
                frame.processes = ProcessDiagnostics(processes)
                frame.applications = frame.processes?.applications ?? []
            }
        }
        let unavailable = DiagnosticMetric(Metric(unavailable: result.systemError ?? ProbeIssue("system_failed", "No system sample"), source: "SystemMonitor", at: time))
        let point = HistoryPoint(measuredAt: result.system?.measuredAt ?? time,
                                 compressed: result.system.map { DiagnosticMetric($0.compressed) } ?? unavailable,
                                 swapUsed: result.system.map { DiagnosticMetric($0.swapUsed) } ?? unavailable,
                                 epoch: epoch, cadence: frame.cadence)
        if let last = frame.history.last, point.measuredAt < last.measuredAt { frame.history.removeAll() }
        frame.history.append(point)
        frame.history.removeAll { $0.measuredAt < time.addingTimeInterval(-900) }
        if frame.history.count > 600 { frame.history.removeFirst(frame.history.count - 600) }
        publish()
    }
    deinit { schedule?.cancel(); inFlight?.task.cancel() }
}
