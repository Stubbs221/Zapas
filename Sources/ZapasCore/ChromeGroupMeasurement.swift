import Foundation

public struct ChromeGroupMeasurement: Codable, Sendable {
    public let measuredAt: Date
    public let footprint: DiagnosticMetric
    public let rss: DiagnosticMetric
    public let observedCount: Int?
    public let unavailableFootprintCount: Int?
    public let unclassifiedInventoryFailures: Int?
    public let accounting: String
    public static func summarize(_ inventory: ProcessDiagnostics?, error: ProbeIssue? = nil, now: Date = Date()) -> Self {
        let chrome = inventory?.processes.filter { $0.executablePath?.split(separator: "/").contains("Google Chrome.app") == true } ?? []
        let time = inventory?.measuredAt ?? now
        func metric(_ values: [Double], source: String) -> DiagnosticMetric {
            DiagnosticMetric(values.isEmpty ? Metric(unavailable: error ?? ProbeIssue("chrome_memory_unavailable", "No readable Chrome metric; absence is not zero"), source: source, at: time) : Metric(values.reduce(0, +), source: source, at: time))
        }
        let values = chrome.compactMap(\.footprint.value)
        return Self(measuredAt: time, footprint: metric(values, source: "sum of observed Google Chrome.app proc_pid_rusage.ri_phys_footprint"),
                    rss: metric(chrome.compactMap(\.rss.value), source: "sum of observed Google Chrome.app proc_pid_rusage.ri_resident_size"), observedCount: inventory == nil ? nil : chrome.count,
                    unavailableFootprintCount: inventory == nil ? nil : chrome.count - values.count, unclassifiedInventoryFailures: inventory?.failures.count,
                    accounting: "Partial observed group of all Chrome profiles; not unique physical RAM or per-tab RAM. RSS separate. Deltas cannot be attributed solely to the action.")
    }
}
