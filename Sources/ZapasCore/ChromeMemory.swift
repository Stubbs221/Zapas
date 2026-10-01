import Foundation

/// Path-based research classification, not code-signature verification or a per-tab allocation.
public struct ChromeMemoryObservation: Encodable, Sendable {
    public let measuredAt: Date
    public let observedProcessCount: Int
    public let measuredProcessCount: Int
    public let unavailableProcessCount: Int
    public let unclassifiedInventoryFailures: Int
    public let observedFootprintSum: Metric
    public let accounting: String

    public static func summarize(_ inventory: ProcessSnapshot) -> Self {
        let chrome = inventory.processes.filter { process in
            guard let path = process.executablePath else { return false }
            return path.split(separator: "/").contains("Google Chrome.app")
        }
        let values = chrome.compactMap(\.footprint.value)
        let source = "sum of observed Google Chrome.app proc_pid_rusage.ri_phys_footprint"
        let metric: Metric
        if values.isEmpty {
            metric = Metric(unavailable: ProbeIssue("chrome_memory_unavailable", "No readable Chrome footprint; absence is not zero"),
                            source: source, at: inventory.measuredAt)
        } else {
            metric = Metric(values.reduce(0, +), source: source, at: inventory.measuredAt)
        }
        return Self(measuredAt: inventory.measuredAt, observedProcessCount: chrome.count,
                    measuredProcessCount: values.count, unavailableProcessCount: chrome.count - values.count,
                    unclassifiedInventoryFailures: inventory.failures.count, observedFootprintSum: metric,
                    accounting: "Partial path-classified current-user sum; unreadable processes may be absent. Shared accounting means this is not unique physical RAM or tab RAM. RSS is never added.")
    }
}
