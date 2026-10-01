import Foundation

/// Explicit synthetic frames for UI qualification; never used by the CLI or live coordinator.
public enum DiagnosticDemo {
    public static func frame(_ mode: String, at time: Date = Date()) -> DiagnosticFrame {
        var frame = DiagnosticFrame(); frame.detailed = true
        if mode == "empty" {
            frame.processes = ProcessDiagnostics(ProcessSnapshot(measuredAt: time, processes: [], failures: []))
            return frame
        }
        if mode == "error" {
            frame.systemError = ProbeIssue("demo_access_denied", "Synthetic API denial")
            frame.processError = ProbeIssue("demo_inventory_failed", "Synthetic inventory failure")
            return frame
        }
        let at = mode == "stale" ? time.addingTimeInterval(-120) : time
        func metric(_ bytes: Double, source: String = "demo.synthetic") -> Metric { Metric(bytes, source: source, at: at) }
        let unknown = Metric(unavailable: ProbeIssue("demo_unavailable", "Synthetic unavailable metric"), source: "demo.synthetic", at: at)
        let counters = CounterSample(wallTime: at, awakeSeconds: 10, bootID: "demo", pageSize: 4096, swapins: 0, swapouts: 0)
        let snapshot = SystemSnapshot(measuredAt: at, physical: metric(16 * 1_073_741_824), wired: metric(2 * 1_073_741_824),
                                      compressed: metric(1_073_741_824), active: metric(0), inactive: metric(0), free: metric(0),
                                      swapUsed: mode == "unknown" ? unknown : metric(0), swapTotal: metric(1_073_741_824),
                                      pressure: .unknown, counters: counters, rates: SwapRates.calculate(previous: nil, current: counters))
        frame.system = SystemDiagnostics(snapshot)
        let process = ProcessObservation(identity: ProcessIdentity(pid: 100, startSeconds: 1, startMicroseconds: 0), uid: 0, parentPID: 1,
                                         name: "Пример", executablePath: "/Demo/Пример.app/Contents/MacOS/Пример", footprint: unknown, rss: metric(1024))
        frame.processes = ProcessDiagnostics(ProcessSnapshot(measuredAt: at, processes: [process], failures: []))
        frame.applications = frame.processes?.applications ?? []
        frame.history = [HistoryPoint(measuredAt: at, compressed: DiagnosticMetric(snapshot.compressed), swapUsed: DiagnosticMetric(snapshot.swapUsed), epoch: 0, cadence: 3)]
        return frame
    }
}
