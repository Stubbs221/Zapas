import Foundation
import Testing
import Darwin
import CZapas
@testable import ZapasCore

private struct ChromeFixture {
    var broker = try! ChromeBroker(allowedOrigin: ServiceLocation.origin)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let profile = UUID().uuidString
    let session = UUID().uuidString
    var tab: ChromeTab
    init() {
        tab = ChromeTab(); tab.id = 7; tab.windowID = 3; tab.token = UUID().uuidString
        tab.title = "Own page"; tab.domain = "example.test"; tab.lastAccessedMilliseconds = now.timeIntervalSince1970 * 1000 - 601_000
        var hello = request("chromeHello"); hello.label = "Own profile"; _ = broker.handle(hello, now: now)
        publish()
    }
    func request(_ operation: String) -> ServiceRequest {
        var r = ServiceRequest(operation); r.origin = ServiceLocation.origin; r.profileID = profile; r.sessionID = session; return r
    }
    var selection: ChromeSelection { ChromeSelection(profileID: profile, sessionID: session, tabID: tab.id, token: tab.token) }
    mutating func publish() { var r = request("chromePublish"); r.tabs = [tab]; _ = broker.handle(r, now: now) }
    mutating func preview(kind: ChromeActionKind = .discard) -> ServiceReply {
        var r = ServiceRequest("tabsPreview"); r.kind = kind; r.selections = [selection]; return broker.handle(r, now: now)
    }
    mutating func apply(_ id: String, at: Date? = nil) -> ServiceReply { var r = ServiceRequest("tabsApply"); r.planID = id; return broker.handle(r, now: at ?? now) }
}
@Test(arguments: ["active", "pinned", "audible", "incognito", "pending", "split", "unknown", "future", "recent", "excluded", "domain", "discarded"])
func productionChromeProtections(flag: String) {
    var f = ChromeFixture()
    switch flag {
    case "active": f.tab.active = true
    case "pinned": f.tab.pinned = true
    case "audible": f.tab.audible = true
    case "incognito": f.tab.incognito = true
    case "pending": f.tab.pending = true
    case "split": f.tab.splitView = true
    case "unknown": f.tab.lastAccessedMilliseconds = nil
    case "future": f.tab.lastAccessedMilliseconds = f.now.timeIntervalSince1970 * 1000 + 1
    case "recent": f.tab.lastAccessedMilliseconds = f.now.timeIntervalSince1970 * 1000 - 599_999
    case "excluded": f.tab.domain = "meet.google.com"
    case "domain": f.tab.domain = nil
    case "discarded": f.tab.discarded = true
    default: break
    }
    f.publish(); #expect(f.preview().issue?.code == "tab_excluded")
    if flag == "discarded" { #expect(f.preview(kind: .close).ok) }
}
@Test func approvedThresholdBoundaryAndUnknownRemainUnknown() {
    var f = ChromeFixture(); f.tab.lastAccessedMilliseconds = f.now.timeIntervalSince1970 * 1000 - 600_000
    f.publish(); #expect(f.preview().ok); #expect(ChromePolicy.recentSeconds == 600)
}
@Test func previewDoesNotEnqueueAndApplyIsSingleUse() throws {
    var f = ChromeFixture(); let plan = try #require(f.preview().plan)
    #expect(f.broker.handle(f.request("chromePoll"), now: f.now).command == nil)
    let batch = try #require(f.apply(plan.id).batch); #expect(batch.results.count == 1)
    #expect(batch.results[0].status == "unknown")
    #expect(f.apply(plan.id).issue?.code == "preview_expired_or_used")
    let command = try #require(f.broker.handle(f.request("chromePoll"), now: f.now).command)
    #expect(command.target.selection == f.selection)
    #expect(f.broker.handle(f.request("chromePoll"), now: f.now).command == nil)
}
@Test(arguments: ["pin", "token", "window", "activity", "missing"])
func changedStateBetweenPreviewAndApplyRefusesAll(change: String) throws {
    var f = ChromeFixture(); let plan = try #require(f.preview().plan)
    switch change {
    case "pin": f.tab.pinned = true
    case "token": f.tab.token = UUID().uuidString
    case "window": f.tab.windowID += 1
    case "activity": f.tab.lastAccessedMilliseconds = f.now.timeIntervalSince1970 * 1000
    default: break
    }
    if change == "missing" { var r = f.request("chromePublish"); r.tabs = []; _ = f.broker.handle(r, now: f.now) }
    else { f.publish() }
    #expect(!f.apply(plan.id).ok)
    #expect(f.broker.handle(f.request("chromePoll"), now: f.now).command == nil)
}
@Test func pollFreshRecheckBlocksChangesAfterApply() throws {
    var f = ChromeFixture(); let plan = try #require(f.preview().plan); _ = f.apply(plan.id)
    f.tab.audible = true; f.publish()
    #expect(f.broker.handle(f.request("chromePoll"), now: f.now).command == nil)
    var r = ServiceRequest("tabsResult"); r.planID = plan.id
    #expect(f.broker.handle(r, now: f.now).batch?.results.first?.status == "failed")
}
@Test func resultBindingAndConfirmationReplacementAreImmutable() throws {
    var f = ChromeFixture(); let plan = try #require(f.preview().plan); _ = f.apply(plan.id)
    let command = try #require(f.broker.handle(f.request("chromePoll"), now: f.now).command)
    var result = f.request("chromeResult"); result.result = ChromeResult(id: command.id, status: "confirmed", resultingTabID: 9, measuredAt: f.now)
    var forged = result; forged.sessionID = UUID().uuidString
    #expect(!f.broker.handle(forged, now: f.now).ok)
    #expect(f.broker.handle(result, now: f.now).ok)
    #expect(!f.broker.handle(result, now: f.now).ok)
    var r = ServiceRequest("tabsResult"); r.planID = plan.id
    #expect(f.broker.handle(r, now: f.now).batch?.results.first?.resultingTabID == 9)
}
@Test func timeoutDisconnectAndSuspendCannotBecomeConfirmed() throws {
    for cause in ["timeout", "disconnect", "sleep"] {
        var f = ChromeFixture(); let plan = try #require(f.preview().plan); _ = f.apply(plan.id)
        let command = try #require(f.broker.handle(f.request("chromePoll"), now: f.now).command)
        if cause == "disconnect" { _ = f.broker.handle(f.request("chromeDisconnect"), now: f.now) }
        if cause == "sleep" { f.broker.suspend() }
        let after = cause == "timeout" ? f.now.addingTimeInterval(21) : f.now
        var r = ServiceRequest("tabsResult"); r.planID = plan.id
        #expect(f.broker.handle(r, now: after).batch?.results.first?.status == "unknown")
        var late = f.request("chromeResult"); late.result = ChromeResult(id: command.id, status: "confirmed", resultingTabID: 7)
        #expect(!f.broker.handle(late, now: after).ok)
    }
}
@Test func reconnectReplacesSessionAndInvalidatesPreview() throws {
    var f = ChromeFixture(); let plan = try #require(f.preview().plan)
    var hello = f.request("chromeHello"); hello.sessionID = UUID().uuidString
    #expect(f.broker.handle(hello, now: f.now).ok)
    #expect(f.apply(plan.id).issue?.code == "preview_expired_or_used")
    #expect(!f.broker.handle(f.request("chromePublish"), now: f.now).ok)
}
@Test func multiProfileSameTabIDCannotCrossSelectOrPoll() throws {
    var a = ChromeFixture(); var b = ChromeFixture()
    var hello = b.request("chromeHello"); _ = a.broker.handle(hello, now: a.now)
    hello = b.request("chromePublish"); hello.tabs = [b.tab]; _ = a.broker.handle(hello, now: a.now)
    let plan = try #require(a.preview().plan); _ = a.apply(plan.id)
    #expect(a.broker.handle(b.request("chromePoll"), now: a.now).command == nil)
    #expect(a.broker.handle(a.request("chromePoll"), now: a.now).command?.target.selection.profileID == a.profile)
    b.tab.windowID += 1
}
@Test func exceptionsInvalidatePreviewAndRejectURLs() throws {
    var f = ChromeFixture(); let plan = try #require(f.preview().plan)
    try f.broker.setPolicy(ChromePolicy(excludedDomains: ["example.test"]), profileID: f.profile)
    #expect(f.apply(plan.id).issue?.code == "preview_expired_or_used")
    #expect(f.preview().issue?.message == "user_excluded")
    #expect(throws: ProbeIssue.self) { try f.broker.setPolicy(ChromePolicy(excludedDomains: ["https://example.test/private?q=secret"]), profileID: f.profile) }
}
@Test func emptyDuplicateStaleAndExpiredSelectionRejected() throws {
    var f = ChromeFixture(); var r = ServiceRequest("tabsPreview"); r.kind = .close; r.selections = []
    #expect(!f.broker.handle(r, now: f.now).ok)
    r.selections = [f.selection, f.selection]; #expect(!f.broker.handle(r, now: f.now).ok)
    r.selections = [f.selection]; #expect(f.broker.handle(r, now: f.now.addingTimeInterval(11)).issue?.code == "session_stale")
    let plan = try #require(f.preview().plan); #expect(f.apply(plan.id, at: f.now.addingTimeInterval(31)).issue?.code == "preview_expired_or_used")
}
@Test func productionSchemaRejectsUnknownStatusOriginAndOversizedTabs() throws {
    var f = ChromeFixture(); var r = f.request("chromePublish"); r.origin = "chrome-extension://" + String(repeating: "a", count: 32) + "/"; r.tabs = [f.tab]
    #expect(f.broker.handle(r, now: f.now).issue?.code == "origin_denied")
    r.origin = ServiceLocation.origin; r.tabs = [f.tab, f.tab]
    #expect(f.broker.handle(r, now: f.now).issue?.code == "tab_schema")
    r = ServiceRequest("chromeResult"); r.result = ChromeResult(id: UUID().uuidString, status: "queued")
    #expect(throws: ProbeIssue.self) { try r.validate() }
}
@Test func listenerExclusiveLeaseCleanStopAndIPCReply() async throws {
    let runtime = "/private/tmp/zapas-c-" + UUID().uuidString.prefix(8)
    defer { try? FileManager.default.removeItem(atPath: runtime) }
    var listener: GUIServiceListener? = try GUIServiceListener(runtime: runtime) { request in ServiceReply(requestID: request.requestID) }
    listener?.start()
    #expect(throws: ProbeIssue.self) { _ = try GUIServiceListener(runtime: runtime) { ServiceReply(requestID: $0.requestID) } }
    let reply = try await ServiceIPC.asyncRequest(ServiceRequest("tabsList"), socketPath: runtime + "/gui.sock")
    #expect(reply.ok)
    listener?.stop(); listener = nil
    try await Task.sleep(for: .milliseconds(200))
    #expect(!FileManager.default.fileExists(atPath: runtime + "/gui.sock"))
    let next = try GUIServiceListener(runtime: runtime) { ServiceReply(requestID: $0.requestID) }
    next.stop()
}
@Test func nativeInstallRequiresExplicitOwnedDestinationAndProtectsConflict() throws {
    let runtime = "/private/tmp/zapas-i-" + UUID().uuidString.prefix(8)
    let root = URL(fileURLWithPath: runtime)
    defer { try? FileManager.default.removeItem(at: root) }
    try LocalIPC.preparePrivateDirectory(runtime)
    let profile = root.appendingPathComponent("profile"); try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
    let binary = root.appendingPathComponent("host"); try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let manifest = try NativeInstallation.install(hostExecutable: binary, userDataDirectory: profile, runtime: runtime)
    #expect(FileManager.default.fileExists(atPath: manifest.path))
    _ = try NativeInstallation.install(hostExecutable: binary, userDataDirectory: profile, runtime: runtime)
    let foreign = Data("{}".utf8); try foreign.write(to: manifest)
    #expect(throws: ProbeIssue.self) { try NativeInstallation.install(hostExecutable: binary, userDataDirectory: profile, runtime: runtime) }
    #expect(try Data(contentsOf: manifest) == foreign)
}

@Test func groupMeasurementsKeepMissingUnknownAndRSSSeparate() {
    let at = Date()
    let unavailable = ChromeGroupMeasurement.summarize(nil, error: ProbeIssue("processes_failed", "Denied"), now: at)
    #expect(unavailable.footprint.value == nil); #expect(unavailable.rss.value == nil)
    func process(_ pid: Int32, footprint: Double?) -> ProcessObservation {
        ProcessObservation(identity: ProcessIdentity(pid: pid, startSeconds: 1, startMicroseconds: 0), uid: 1, parentPID: 1, name: "Chrome",
                           executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                           footprint: footprint.map { Metric($0, source: "test", at: at) } ?? Metric(unavailable: ProbeIssue("denied", "Denied"), source: "test", at: at),
                           rss: Metric(999, source: "test.rss", at: at))
    }
    let inventory = ProcessDiagnostics(ProcessSnapshot(measuredAt: at, processes: [process(1, footprint: 100), process(2, footprint: nil)], failures: []))
    let group = ChromeGroupMeasurement.summarize(inventory)
    #expect(group.footprint.value == 100); #expect(group.rss.value == 1998)
    #expect(group.observedCount == 2); #expect(group.unavailableFootprintCount == 1)
    #expect(group.accounting.contains("not unique physical RAM"))
}

@Test func GUIServiceUsesInjectedCoordinatorAndSleepRetainsJSONUnknowns() async throws {
    let at = Date()
    let coordinator = SamplingCoordinator(sources: SamplingSources(system: { _, _ in
        let counters = CounterSample(wallTime: at, awakeSeconds: 1, bootID: "own-test", pageSize: 4096, swapins: 0, swapouts: 0)
        let metric = Metric(1, source: "own-test", at: at)
        return SystemSnapshot(measuredAt: at, physical: metric, wired: metric, compressed: metric, active: metric, inactive: metric, free: metric,
                              swapUsed: metric, swapTotal: metric, pressure: .unknown, counters: counters, rates: SwapRates.calculate(previous: nil, current: counters))
    }, processes: { ProcessSnapshot(measuredAt: at, processes: [], failures: []) }), observePressure: false)
    let service = try GUIService(coordinator: coordinator)
    let reply = await service.handle(ServiceRequest("status"))
    #expect(reply.system?.swapReadRate.value == nil)
    #expect(await coordinator.snapshot().history.count == 1)
    await coordinator.willSleep()
    let sleeping = await service.handle(ServiceRequest("status"))
    #expect(sleeping.system?.measuredAt == reply.system?.measuredAt)
    #expect(await coordinator.snapshot().history.count == 1) // IPC did not instantiate or run another sampler.
    await coordinator.stop()
}

@Test func storedExceptionsExistBeforeFirstNativeHandshake() async throws {
    let f = ChromeFixture()
    let coordinator = SamplingCoordinator(observePressure: false)
    let service = try GUIService(coordinator: coordinator, policies: [f.profile: ["example.test"]])
    let reply = await service.handle(f.request("chromeHello"))
    #expect(reply.policy?.excludedDomains == ["example.test"])
    await coordinator.stop()
}

@Test func oversizedIPCReplyRemainsCorrelatedStructuredError() async throws {
    let runtime = "/private/tmp/zapas-o-" + UUID().uuidString.prefix(8)
    defer { try? FileManager.default.removeItem(atPath: runtime) }
    var listener: GUIServiceListener? = try GUIServiceListener(runtime: runtime) { request in
        var reply = ServiceReply(requestID: request.requestID)
        var tab = ChromeTab(); tab.title = String(repeating: "x", count: 1000)
        reply.profiles = [ChromeProfile(id: UUID().uuidString, sessionID: UUID().uuidString, label: "Own", measuredAt: Date(), stale: false,
                                        tabs: Array(repeating: tab, count: 2000), policy: ChromePolicy())]
        return reply
    }
    listener?.start()
    let reply = try await ServiceIPC.asyncRequest(ServiceRequest("tabsList"), socketPath: runtime + "/gui.sock")
    #expect(reply.issue?.code == "ipc_reply_failed")
    listener?.stop(); listener = nil; try await Task.sleep(for: .milliseconds(200))
}

@Test func resultIssuesCannotContainAddresses() throws {
    var request = ServiceRequest("chromeResult")
    request.result = ChromeResult(id: UUID().uuidString, status: "unknown", issue: "https://private.test/path?q=secret")
    #expect(throws: ProbeIssue.self) { try request.validate() }
}


@Test func staleOwnedSocketRecoveredButRegularFileNeverRemoved() async throws {
    let runtime = "/private/tmp/zapas-r-" + UUID().uuidString.prefix(8)
    defer { try? FileManager.default.removeItem(atPath: runtime) }
    try LocalIPC.preparePrivateDirectory(runtime)
    let path = runtime + "/gui.sock"
    let fd = path.withCString { zp_socket_listen($0) }
    #expect(fd >= 0); Darwin.close(fd) // Deliberate crash fixture: private socket inode without a listener.
    var listener: GUIServiceListener? = try GUIServiceListener(runtime: runtime) { ServiceReply(requestID: $0.requestID) }
    listener?.start()
    #expect(try await ServiceIPC.asyncRequest(ServiceRequest("tabsList"), socketPath: path).ok)
    listener?.stop(); listener = nil; try await Task.sleep(for: .milliseconds(200))
    let sentinel = Data("keep".utf8); try sentinel.write(to: URL(fileURLWithPath: path))
    #expect(throws: ProbeIssue.self) { _ = try GUIServiceListener(runtime: runtime) { ServiceReply(requestID: $0.requestID) } }
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == sentinel)
}

@Test func chromeListFiltersKeepIdentityAndNeverExpandSelection() {
    let f = ChromeFixture()
    let choices: Set<ChromeSelection> = [f.selection]
    var other = f.tab; other.id = 8; other.token = UUID().uuidString; other.active = true
    let tabs = [f.tab, other]
    let visible = tabs.filter { ChromeTabFilter.protected.matches($0, query: " OWN ", policy: ChromePolicy(), stale: false, selected: $0.id == f.selection.tabID, now: f.now) }
    #expect(visible.map(\.id) == [other.id])
    #expect(choices == [f.selection])
    #expect(ChromeTabFilter.selected.matches(f.tab, query: "EXAMPLE.TEST", policy: ChromePolicy(), stale: false, selected: true, now: f.now))
    #expect(!ChromeTabFilter.available.matches(f.tab, query: "", policy: ChromePolicy(), stale: true, selected: true, now: f.now))
    #expect(!ChromeTabFilter.selected.matches(other, query: "", policy: ChromePolicy(), stale: false, selected: false, now: f.now))
    var discarded = f.tab; discarded.discarded = true
    #expect(ChromeTabFilter.discarded.matches(discarded, query: "", policy: ChromePolicy(), stale: false, selected: false, now: f.now))
}
@Test func chromeActivityPresentationHandlesExtremeAndUnknownTimestamps() {
    var f = ChromeFixture()
    #expect(f.tab.activityAgeMinutes(now: f.now) == 601_000.0 / 60_000)
    for invalid: Double? in [nil, .nan, .infinity, -.infinity, -1, .greatestFiniteMagnitude, f.now.timeIntervalSince1970 * 1000 + 1] {
        f.tab.lastAccessedMilliseconds = invalid
        #expect(f.tab.activityAgeMinutes(now: f.now) == nil)
    }
    f.tab.lastAccessedMilliseconds = 0
    #expect(f.tab.activityAgeMinutes(now: f.now)?.isFinite == true)
}

@Test(arguments: ["manifest", "binary", "config"])
func nativeInstallPreservesDanglingSymlinks(target: String) throws {
    let runtime = "/private/tmp/zapas-l-" + UUID().uuidString.prefix(8)
    let root = URL(fileURLWithPath: runtime)
    let manager = FileManager.default
    defer { try? manager.removeItem(at: root) }
    try LocalIPC.preparePrivateDirectory(runtime)
    let profile = root.appendingPathComponent("profile")
    let hosts = profile.appendingPathComponent("NativeMessagingHosts")
    try manager.createDirectory(at: hosts, withIntermediateDirectories: true)
    let native = root.appendingPathComponent("native")
    try LocalIPC.preparePrivateDirectory(native.path)
    let source = root.appendingPathComponent("source")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
    let link = target == "manifest" ? hosts.appendingPathComponent("com.zapas.chrome.json") : native.appendingPathComponent(target == "binary" ? "zapas-native-host" : "zapas-native-host.json")
    let destination = root.appendingPathComponent("missing").path
    try manager.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
    #expect(throws: ProbeIssue.self) { try NativeInstallation.install(hostExecutable: source, userDataDirectory: profile, runtime: runtime) }
    #expect(try manager.destinationOfSymbolicLink(atPath: link.path) == destination)
    #expect(!manager.fileExists(atPath: destination))
}
