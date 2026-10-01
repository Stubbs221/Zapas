import Foundation
import Testing
@testable import ZapasCore

@Test func chromeGroupSeparatesRSSAndPreservesMissingCoverage() {
    let time = Date()
    func process(_ pid: Int32, path: String, footprint: Double?) -> ProcessObservation {
        let metric = footprint.map { Metric($0, source: "fixture", at: time) }
            ?? Metric(unavailable: ProbeIssue("denied", "fixture"), source: "fixture", at: time)
        return ProcessObservation(identity: ProcessIdentity(pid: pid, startSeconds: 1, startMicroseconds: 0), uid: 1,
                                  parentPID: 1, name: "fixture", executablePath: path, footprint: metric,
                                  rss: Metric(99999, source: "fixture", at: time))
    }
    let snapshot = ProcessSnapshot(measuredAt: time, processes: [
        process(1, path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", footprint: 100),
        process(2, path: "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", footprint: nil),
        process(3, path: "/Applications/Google Chrome Canary.app/Contents/MacOS/Chrome", footprint: 900),
        process(4, path: "/Applications/FakeGoogle Chrome.app/Contents/MacOS/Chrome", footprint: 900)
    ], failures: [ProcessFailure(pid: 5, issue: ProbeIssue("denied", "fixture"))])
    let result = ChromeMemoryObservation.summarize(snapshot)
    #expect(result.observedProcessCount == 2)
    #expect(result.measuredProcessCount == 1)
    #expect(result.unavailableProcessCount == 1)
    #expect(result.unclassifiedInventoryFailures == 1)
    #expect(result.observedFootprintSum.value == 100)
    #expect(result.accounting.contains("not unique physical RAM"))
    #expect(ChromeMemoryObservation.summarize(ProcessSnapshot(measuredAt: time, processes: [], failures: [])).observedFootprintSum.value == nil)
}
