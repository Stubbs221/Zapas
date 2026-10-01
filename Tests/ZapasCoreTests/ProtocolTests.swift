import Foundation
import Testing
@testable import ZapasCore

private let origin = "chrome-extension://" + String(repeating: "a", count: 32) + "/"
private let session = "11111111-1111-4111-8111-111111111111"
private let secondSession = "22222222-2222-4222-8222-222222222222"
private let now = Date(timeIntervalSince1970: 1_700_000_000)

@Test func nativeFramingUsesUTF8Bytes() throws {
    let data = Data("{\"title\":\"Привет 🦊\"}".utf8)
    let packed = try NativeFrame.pack(data)
    #expect(try NativeFrame.length(Data(packed.prefix(4))) == data.count)
    #expect(try NativeFrame.unpack(packed) == data)
    #expect(throws: ProbeIssue.self) { try NativeFrame.unpack(Data(packed.dropLast())) }
    #expect(throws: ProbeIssue.self) { try NativeFrame.unpack(packed + Data([1])) }
}

@Test func invalidFramesRejectedBeforeAllocation() {
    #expect(throws: ProbeIssue.self) { try NativeFrame.length(Data([1, 0, 0])) }
    #expect(throws: ProbeIssue.self) { try NativeFrame.length(Data([0, 0, 0, 0])) }
    #expect(throws: ProbeIssue.self) { try NativeFrame.length(Data([255, 255, 255, 255])) }
    #expect(throws: ProbeIssue.self) { try NativeFrame.pack(Data()) }
    #expect(throws: ProbeIssue.self) { try NativeFrame.pack(Data(count: NativeFrame.maximumBytes + 1)) }
}

@Test func originMustExactlyMatchConfiguredExtension() throws {
    try NativeOrigin.validate(origin, allowed: origin)
    #expect(throws: ProbeIssue.self) { try NativeOrigin.validate(origin + "evil", allowed: origin) }
    #expect(throws: ProbeIssue.self) { try NativeOrigin.validate("chrome-extension://short/", allowed: "chrome-extension://short/") }
    #expect(throws: ProbeIssue.self) { try NativeOrigin.validate("https://example.test/", allowed: "https://example.test/") }
}

@Test func requestSchemaAndVersionValidated() throws {
    var request = ProbeRequest(.hello, origin: origin, sessionID: session)
    request.version = 2
    #expect(throws: ProbeIssue.self) { try request.validate() }
    request.version = 1; request.requestID = "$(malicious command)"
    #expect(throws: ProbeIssue.self) { try request.validate() }
    request.requestID = UUID().uuidString
    request.tabs = [TabObservation(id: 1), TabObservation(id: 1)]
    #expect(throws: ProbeIssue.self) { try request.validate() }
    #expect(throws: (any Error).self) { try ProbeJSON.decode(ProbeRequest.self, from: Data("{}".utf8)) }
}

@Test(arguments: ["active", "pinned", "audible", "incognito", "discarded", "fixture", "recent", "unknown", "split"])
func tabExclusions(reason: String) {
    let tab = TabObservation(id: 1, active: reason == "active", pinned: reason == "pinned", audible: reason == "audible",
                             incognito: reason == "incognito", discarded: reason == "discarded",
                             lastAccessedMilliseconds: reason == "unknown" ? nil : reason == "recent" ? now.timeIntervalSince1970 * 1000 : 1,
                             splitViewID: reason == "split" ? 1 : nil, isTestFixture: reason != "fixture")
    #expect(TestTabPolicy.exclusion(tab, now: now) != nil)
}

@Test func eligibleFixtureAndSessionIsolation() throws {
    var broker = try ProbeBroker(allowedOrigin: origin)
    let tab = TabObservation(id: 7, lastAccessedMilliseconds: 1)
    #expect(broker.handle(ProbeRequest(.publishTabs, origin: origin, sessionID: session, tabs: [tab]), now: now).ok)
    #expect(broker.handle(ProbeRequest(.publishTabs, origin: origin, sessionID: secondSession, tabs: [tab]), now: now).ok)
    let enqueue = ProbeRequest(.discardTestTab, sessionID: session, tabID: 7)
    let reply = broker.handle(enqueue, now: now)
    #expect(reply.ok)
    #expect(reply.action?.sessionID == session)
    #expect(broker.handle(enqueue, now: now).action?.id == reply.action?.id)
    #expect(broker.handle(ProbeRequest(.pollTestAction, origin: origin, sessionID: secondSession), now: now).action == nil)
    let poll = ProbeRequest(.pollTestAction, origin: origin, sessionID: session)
    #expect(broker.handle(poll, now: now).action?.tabID == 7)
    #expect(broker.handle(poll, now: now).action == nil)
    let id = try #require(reply.action?.id)
    let result = TestActionResult(id: id, tabID: 7, status: "confirmed", discarded: true, measuredAt: now)
    #expect(!broker.handle(ProbeRequest(.submitResult, origin: origin, sessionID: secondSession, result: result), now: now).ok)
    #expect(broker.handle(ProbeRequest(.submitResult, origin: origin, sessionID: session, result: result), now: now).ok)
    #expect(broker.handle(ProbeRequest(.getActionResult, actionID: id), now: now).result?.discarded == true)
    #expect(!broker.handle(ProbeRequest(.submitResult, origin: origin, sessionID: session, result: result), now: now).ok)
}

@Test func staleSnapshotsAndExpiredActionsCannotBeUsed() throws {
    var broker = try ProbeBroker(allowedOrigin: origin)
    let publish = ProbeRequest(.publishTabs, origin: origin, sessionID: session, tabs: [TabObservation(id: 1, lastAccessedMilliseconds: 1)])
    _ = broker.handle(publish, now: now)
    let action = try #require(broker.handle(ProbeRequest(.discardTestTab, sessionID: session, tabID: 1), now: now).action)
    _ = broker.handle(publish, now: now.addingTimeInterval(11))
    #expect(broker.handle(ProbeRequest(.pollTestAction, origin: origin, sessionID: session), now: now.addingTimeInterval(11)).action == nil)
    #expect(broker.handle(ProbeRequest(.getActionResult, actionID: action.id), now: now.addingTimeInterval(11)).actionStatus == "expired_or_result_unknown")
    #expect(broker.handle(ProbeRequest(.discardTestTab, sessionID: session, tabID: 1), now: now.addingTimeInterval(30)).issue?.code == "snapshot_stale")
}

@Test func brokerRejectsBadOriginAndChangedSnapshot() throws {
    var broker = try ProbeBroker(allowedOrigin: origin)
    #expect(!broker.handle(ProbeRequest(.publishTabs, origin: "https://evil.test", sessionID: session, tabs: []), now: now).ok)
    let tab = TabObservation(id: 1, active: true, lastAccessedMilliseconds: 1)
    _ = broker.handle(ProbeRequest(.publishTabs, origin: origin, sessionID: session, tabs: [tab]), now: now)
    #expect(broker.handle(ProbeRequest(.discardTestTab, sessionID: session, tabID: 1), now: now).issue?.message == "active")
}

@Test func resultSchemaPreservesReplacementAndRejectsFalseConfirmation() throws {
    let result = TestActionResult(id: UUID().uuidString, tabID: 7, status: "confirmed", discarded: true, resultingTabID: 9, measuredAt: now)
    let request = ProbeRequest(.submitResult, origin: origin, sessionID: session, result: result)
    try request.validate()
    let decoded = try ProbeJSON.decode(ProbeRequest.self, from: ProbeJSON.encode(request))
    #expect(decoded.result?.resultingTabID == 9)
    for bad in [TestActionResult(id: result.id, tabID: 7, status: "confirmed", discarded: false),
                TestActionResult(id: result.id, tabID: 7, status: "refused", discarded: true),
                TestActionResult(id: result.id, tabID: 7, status: "made_up", discarded: false),
                TestActionResult(id: result.id, tabID: 7, status: "confirmed", discarded: true, resultingTabID: -1)] {
        #expect(throws: ProbeIssue.self) { try ProbeRequest(.submitResult, result: bad).validate() }
    }
}
