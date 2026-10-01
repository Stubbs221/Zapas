import Foundation
import Testing
@testable import ZapasCore

private let at = Date(timeIntervalSince1970: 1_800_000_000)
private func observation(_ pid: Int32, path: String?, value: Double?) -> ProcessObservation {
    let metric = value.map { Metric($0, source: "test.footprint", at: at) }
        ?? Metric(unavailable: ProbeIssue("access_denied", "Synthetic denial"), source: "test.footprint", at: at)
    return ProcessObservation(identity: ProcessIdentity(pid: pid, startSeconds: 100, startMicroseconds: UInt64(pid)), uid: 1, parentPID: 1,
                              name: "process", executablePath: path, footprint: metric, rss: Metric(999, source: "test.rss", at: at))
}

@Test func applicationGroupingUsesOutermostBundleAndPartialFootprintOnly() {
    let snapshot = ProcessSnapshot(measuredAt: at, processes: [
        observation(1, path: "/Applications/Browser.app/Contents/MacOS/Browser", value: 100),
        observation(2, path: "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", value: 200),
        observation(3, path: "/Applications/Browser.app/Contents/MacOS/unreadable", value: nil),
        observation(4, path: nil, value: nil),
        observation(5, path: "/usr/bin/service", value: 50),
    ], failures: [ProcessFailure(pid: 999, issue: ProbeIssue("process_disappeared", "Synthetic disappearance"))])
    let diagnostics = ProcessDiagnostics(snapshot)
    let apps = diagnostics.applications
    #expect(apps.count == 3)
    #expect(apps[0].name == "Browser")
    #expect(apps[0].footprint.value == 300)
    #expect(apps[0].measuredCount == 2)
    #expect(apps[0].unavailableCount == 1)
    #expect(apps.last?.footprint.value == nil)
    #expect(diagnostics.failures.count == 1)
    #expect(diagnostics.processes.first?.rss.value == 999)
    #expect(ProcessDiagnostics.bundlePath("relative.app/path") == nil)
    #expect(ProcessDiagnostics.bundlePath("/Applications/test.application/bin") == nil)
}

@Test func stableJSONEncodesExplicitNullsSourcesUnitsAndErrors() throws {
    let frame = DiagnosticDemo.frame("unknown", at: at)
    let envelope = DiagnosticEnvelope(command: "status", generatedAt: at, data: frame.system, errors: frame.system?.errors ?? [])
    let encoded = try ProbeJSON.encode(envelope)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let data = try #require(object["data"] as? [String: Any])
    let swap = try #require(data["swapUsed"] as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["status"] as? String == "partial")
    #expect(swap["value"] is NSNull)
    #expect(swap["status"] as? String == "unknown")
    #expect(swap["unit"] as? String == "bytes")
    #expect(swap["source"] as? String == "demo.synthetic")
    #expect(data["intervalSeconds"] is NSNull)
    let physical = try #require(data["physical"] as? [String: Any])
    #expect(physical["error"] is NSNull)
    let pressure = try #require(data["pressure"] as? [String: Any])
    #expect(pressure["measuredAt"] is NSNull)
    #expect((swap["error"] as? [String: Any])?["code"] as? String == "demo_unavailable")
    let decoded = try ProbeJSON.decode(DiagnosticEnvelope<SystemDiagnostics>.self, from: encoded)
    #expect(decoded.data?.swapUsed.value == nil)
    let empty: SystemDiagnostics? = nil
    let failure = try ProbeJSON.encode(DiagnosticEnvelope(command: "status", data: empty, errors: [ProbeIssue("system_failed", "test")]))
    let failureObject = try #require(JSONSerialization.jsonObject(with: failure) as? [String: Any])
    #expect(failureObject["data"] is NSNull)
    #expect(failureObject["status"] as? String == "error")
}

@Test func chartSplitsUnknownEpochAndLongGapsWithoutZeros() {
    func metric(_ value: Double?, time: Date) -> DiagnosticMetric {
        DiagnosticMetric(value.map { Metric($0, source: "test", at: time) }
                         ?? Metric(unavailable: ProbeIssue("unavailable", "test"), source: "test", at: time))
    }
    let history = [(0.0, 0 as UInt64, 1.0 as Double?), (3, 0, nil), (6, 0, 2), (9, 1, 3), (90, 1, 4)].map { offset, epoch, value in
        HistoryPoint(measuredAt: at.addingTimeInterval(offset), compressed: metric(value, time: at.addingTimeInterval(offset)),
                     swapUsed: metric(value, time: at.addingTimeInterval(offset)), epoch: epoch, cadence: 3)
    }
    let swap = HistoryChart.points(history).filter { $0.kind == "Swap" }
    #expect(swap.count == 4)
    #expect(Set(swap.map(\.segment)).count == 4)
    #expect(swap.allSatisfy { $0.valueGiB > 0 })
}

@Test func staleThresholdsAreModeSpecificAndUnknownIsNotStale() {
    var frame = DiagnosticDemo.frame("unknown", at: at)
    #expect(!frame.systemStale(at: at.addingTimeInterval(6)))
    #expect(frame.systemStale(at: at.addingTimeInterval(7)))
    frame.detailed = false
    #expect(!frame.systemStale(at: at.addingTimeInterval(60)))
    #expect(frame.systemStale(at: at.addingTimeInterval(61)))
    #expect(frame.processesStale(at: at.addingTimeInterval(7)))
    #expect(frame.system?.swapUsed.status == "unknown")
    #expect(!DiagnosticFrame().systemStale(at: at))
}
