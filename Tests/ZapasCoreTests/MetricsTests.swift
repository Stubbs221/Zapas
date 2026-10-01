import Foundation
import Darwin
import Testing
@testable import ZapasCore

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

@Test func swapRatesUsePageSizeAndDelta() {
    let before = CounterSample(wallTime: epoch, awakeSeconds: 100, bootID: "boot", pageSize: 16384, swapins: 9999, swapouts: 100)
    let after = CounterSample(wallTime: epoch.addingTimeInterval(2), awakeSeconds: 102, bootID: "boot", pageSize: 16384, swapins: 10003, swapouts: 101)
    let rates = SwapRates.calculate(previous: before, current: after)
    #expect(rates.read.value == 32768)
    #expect(rates.write.value == 8192)
    #expect(rates.intervalSeconds == 2)
}

@Test(arguments: [4096 as UInt64, 16384]) func pageSizes(page: UInt64) throws {
    #expect(try MemoryMath.bytes(pages: 3, pageSize: page) == page * 3)
}

@Test func memoryArithmeticRejectsOverflowAndZeroPageSize() {
    #expect(throws: ProbeIssue.self) { try MemoryMath.bytes(pages: .max, pageSize: 2) }
    #expect(throws: ProbeIssue.self) { try MemoryMath.bytes(pages: 1, pageSize: 0) }
}

@Test(arguments: ["first", "boot", "page", "counter", "zero", "backwards", "sleep", "gap", "unavailable", "wall_adjustment"])
func invalidCounterPairs(reason: String) {
    let before = CounterSample(wallTime: epoch, awakeSeconds: 100, bootID: "boot", pageSize: 4096, swapins: 10, swapouts: 10)
    let after = CounterSample(wallTime: epoch.addingTimeInterval(reason == "zero" ? 0 : reason == "backwards" ? -1 : reason == "sleep" ? 30 : reason == "gap" ? 100 : reason == "wall_adjustment" ? 10 : 2),
                              awakeSeconds: reason == "zero" ? 100 : reason == "backwards" ? 99 : reason == "gap" ? 200 : 102,
                              bootID: reason == "boot" ? "other" : "boot", pageSize: reason == "page" ? 16384 : 4096,
                              swapins: reason == "counter" ? 9 : 11, swapouts: 11, valid: reason != "unavailable")
    let rates = SwapRates.calculate(previous: reason == "first" ? nil : before, current: after)
    #expect(rates.read.value == nil)
    #expect(rates.write.value == nil)
    #expect(rates.read.issue != nil)
}

@Test func largeCounterDeltasDoNotOverflowIntegerMultiplication() {
    let before = CounterSample(wallTime: epoch, awakeSeconds: 1, bootID: "b", pageSize: 16384, swapins: 0, swapouts: 0)
    let after = CounterSample(wallTime: epoch.addingTimeInterval(1), awakeSeconds: 2, bootID: "b", pageSize: 16384, swapins: .max, swapouts: .max)
    #expect(SwapRates.calculate(previous: before, current: after).read.value?.isFinite == true)
}

@Test func liveSystemSampleHasSourcesAndUnknownInitialPressure() throws {
    let sample = try SystemMonitor().sample()
    #expect((sample.physical.value ?? 0) > 0)
    #expect(sample.counters.pageSize > 0)
    #expect(sample.rates.read.issue?.code == "first_sample")
    #expect(sample.pressure.state == "unknown")
    #expect(sample.pressure.issue != nil)
    #expect(sample.wired.source.contains("host_statistics64"))
}

@Test func liveSelfProcessAndPIDReuseGuard() throws {
    let inventory = ProcessInventory()
    let sample = try inventory.sample(pid: getpid())
    #expect(sample.uid == getuid())
    #expect((sample.footprint.value ?? 0) > 0)
    #expect((sample.rss.value ?? 0) > 0)
    #expect(try inventory.revalidate(sample.identity).identity == sample.identity)
    let reused = ProcessIdentity(pid: sample.identity.pid, startSeconds: sample.identity.startSeconds + 1, startMicroseconds: sample.identity.startMicroseconds)
    #expect(throws: ProbeIssue.self) { try inventory.revalidate(reused) }
    #expect(throws: ProbeIssue.self) { try inventory.sample(pid: Int32.max) }
}

@Test func unavailableMetricIsNotZero() throws {
    let metric = Metric(unavailable: ProbeIssue("access_denied", "No permission"), source: "fixture", at: epoch)
    let json = try ProbeJSON.encode(metric)
    let decoded = try ProbeJSON.decode(Metric.self, from: json)
    #expect(decoded.value == nil)
    #expect(decoded.issue?.code == "access_denied")
}
