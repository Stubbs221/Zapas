import Foundation
import Dispatch
import CZapas

public struct CounterSample: Codable, Sendable {
    public let wallTime: Date
    public let awakeSeconds: Double
    public let bootID: String
    public let pageSize: UInt64
    public let swapins: UInt64
    public let swapouts: UInt64
    public let valid: Bool
    public init(wallTime: Date, awakeSeconds: Double, bootID: String, pageSize: UInt64, swapins: UInt64, swapouts: UInt64, valid: Bool = true) {
        self.wallTime = wallTime; self.awakeSeconds = awakeSeconds; self.bootID = bootID
        self.pageSize = pageSize; self.swapins = swapins; self.swapouts = swapouts; self.valid = valid
    }
}

public struct SwapRates: Codable, Sendable {
    public let read: Metric
    public let write: Metric
    public let intervalSeconds: Double?

    public static func calculate(previous: CounterSample?, current: CounterSample, maximumGap: Double = 90) -> SwapRates {
        let source = "host_statistics64.swapins/swapouts delta"
        func unavailable(_ code: String, _ message: String) -> SwapRates {
            let issue = ProbeIssue(code, message)
            return SwapRates(read: Metric(unavailable: issue, unit: "bytes/second", source: source, at: current.wallTime),
                             write: Metric(unavailable: issue, unit: "bytes/second", source: source, at: current.wallTime), intervalSeconds: nil)
        }
        guard let previous else { return unavailable("first_sample", "Two comparable samples are required") }
        guard previous.valid, current.valid else { return unavailable("counter_unavailable", "VM or boot counters unavailable") }
        guard previous.bootID == current.bootID else { return unavailable("boot_changed", "Boot identity changed") }
        guard previous.pageSize == current.pageSize, current.pageSize > 0 else { return unavailable("page_size_changed", "Page size changed or is invalid") }
        let wall = current.wallTime.timeIntervalSince(previous.wallTime)
        let awake = current.awakeSeconds - previous.awakeSeconds
        guard wall.isFinite, awake.isFinite, wall > 0, awake > 0 else { return unavailable("invalid_interval", "Clock moved backwards or interval is zero") }
        guard wall <= maximumGap, abs(wall - awake) <= 2 else { return unavailable("sampling_gap", "Sleep/wake, clock adjustment or long sampling gap; reset baseline") }
        guard current.swapins >= previous.swapins, current.swapouts >= previous.swapouts else { return unavailable("counter_reset", "Cumulative counters decreased") }
        let read = Double(current.swapins - previous.swapins) * Double(current.pageSize) / awake
        let write = Double(current.swapouts - previous.swapouts) * Double(current.pageSize) / awake
        return SwapRates(read: Metric(read, unit: "bytes/second", source: source, at: current.wallTime),
                         write: Metric(write, unit: "bytes/second", source: source, at: current.wallTime), intervalSeconds: awake)
    }
}

public enum MemoryMath {
    public static func bytes(pages: UInt64, pageSize: UInt64) throws -> UInt64 {
        guard pageSize > 0 else { throw ProbeIssue("invalid_page_size", "Page size must be positive") }
        let result = pages.multipliedReportingOverflow(by: pageSize)
        guard !result.overflow else { throw ProbeIssue("overflow", "Page count exceeds UInt64 byte range") }
        return result.partialValue
    }
}

public struct SystemSnapshot: Encodable, Sendable {
    public let schemaVersion = 1
    public let measuredAt: Date
    public let physical: Metric
    public let wired: Metric
    public let compressed: Metric
    public let active: Metric
    public let inactive: Metric
    public let free: Metric
    public let swapUsed: Metric
    public let swapTotal: Metric
    public let pressure: PressureObservation
    public let counters: CounterSample
    public let rates: SwapRates
}

public struct PressureObservation: Codable, Sendable {
    public let state: String
    public let source: String
    public let measuredAt: Date?
    public let issue: ProbeIssue?
    public static var unknown: PressureObservation {
        PressureObservation(state: "unknown", source: "DispatchSourceMemoryPressure", measuredAt: nil,
                            issue: ProbeIssue("no_pressure_event", "No event observed; RAM occupancy is not pressure"))
    }
}

/// Dispatch callbacks share only the lock-protected observation. The source is installed once and cancelled at deinit.
public final class MemoryPressureObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: PressureObservation = .unknown
    private let source: any DispatchSourceMemoryPressure
    public init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: DispatchQueue(label: "Zapas.pressure"))
        self.source = source
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event = source.data
            let state = event.contains(.critical) ? "critical" : event.contains(.warning) ? "warning" : "normal"
            self.lock.lock()
            self.latest = PressureObservation(state: state, source: "DispatchSourceMemoryPressure", measuredAt: Date(), issue: nil)
            self.lock.unlock()
        }
        source.resume()
    }
    public var observation: PressureObservation { lock.lock(); defer { lock.unlock() }; return latest }
    deinit { source.cancel() }
}

public struct SystemMonitor {
    public init() {}
    public func sample(previous: CounterSample? = nil, pressure: PressureObservation = .unknown) throws -> SystemSnapshot {
        var raw = zp_system()
        let result = zp_read_system(&raw)
        guard result == 0 else { throw ProbeIssue("system_api", "System measurement failed (\(result))") }
        let time = Date()
        func pages(_ value: UInt64, name: String) throws -> Metric {
            let source = "host_statistics64.\(name) * host_page_size"
            if raw.vm_error != 0 { return Metric(unavailable: ProbeIssue("vm_api", "Mach error \(raw.vm_error)"), source: source, at: time) }
            return Metric(Double(try MemoryMath.bytes(pages: value, pageSize: raw.page_size)), source: source, at: time)
        }
        func swap(_ value: UInt64) -> Metric {
            let source = "sysctl.vm.swapusage"
            return raw.swap_error == 0 ? Metric(Double(value), source: source, at: time)
                : Metric(unavailable: ProbeIssue("swap_api", "errno \(raw.swap_error)"), source: source, at: time)
        }
        let counters = CounterSample(wallTime: time, awakeSeconds: raw.awake_seconds, bootID: "\(raw.boot_seconds).\(raw.boot_microseconds)",
                                     pageSize: raw.page_size, swapins: raw.swapins, swapouts: raw.swapouts, valid: raw.vm_error == 0 && raw.boot_error == 0)
        return try SystemSnapshot(measuredAt: time,
                                  physical: Metric(Double(raw.physical_bytes), source: "sysctl.hw.memsize", at: time),
                                  wired: pages(raw.wired_pages, name: "wire_count"), compressed: pages(raw.compressed_pages, name: "compressor_page_count"),
                                  active: pages(raw.active_pages, name: "active_count"), inactive: pages(raw.inactive_pages, name: "inactive_count"), free: pages(raw.free_pages, name: "free_count"),
                                  swapUsed: swap(raw.swap_used_bytes), swapTotal: swap(raw.swap_total_bytes), pressure: pressure,
                                  counters: counters, rates: SwapRates.calculate(previous: previous, current: counters))
    }
}
