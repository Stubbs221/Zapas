import Foundation
import Darwin

public enum DebugActivity: String, Codable, Sendable { case active, inactive, unknown }
public enum DebugOrphanhood: String, Codable, Sendable { case proven, candidate, unknown }
public struct DebugEvidence: Codable, Sendable, Equatable {
    public let code: String
    public let explanation: String
    public let relatedIdentity: ProcessIdentity?
}
public struct DebuggerObservation: Codable, Sendable, Identifiable {
    public var id: ProcessIdentity { process.identity }
    public let process: DiagnosticProcess
    public let activity: DebugActivity
    public let orphanhood: DebugOrphanhood
    public let evidence: [DebugEvidence]
    public let measuredAt: Date
    public let qualified: Bool
    public var canTerminate: Bool { qualified && activity == .inactive && orphanhood == .proven && process.uid == getuid() }
}
public struct DebuggerDiagnostics: Codable, Sendable {
    public let measuredAt: Date
    public let debuggers: [DebuggerObservation]
    public let failures: [ProcessFailure]
    public let qualification: String
}
public enum DebuggerDiscovery {
    public static func isDebugger(_ p: DiagnosticProcess) -> Bool {
        let executable = p.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? p.name
        return ["lldb", "lldb-rpc-server"].contains(executable)
    }
    public static func read(_ inventory: ProcessDiagnostics) -> DebuggerDiagnostics {
        let debuggers = inventory.processes.filter(isDebugger).map { p in
            var evidence = [DebugEvidence(code: "libproc_identity_owner", explanation: "libproc: PID, время старта и UID. Имя executable определяет только кандидата", relatedIdentity: p.identity)]
            if p.parentPID == 1 {
                evidence.append(DebugEvidence(code: "reparented_candidate", explanation: "PPID=1 — только кандидат на сиротство, не доказательство отсутствия отлаживаемого приложения", relatedIdentity: nil))
            } else if let parent = inventory.processes.first(where: { $0.identity.pid == p.parentPID }) {
                evidence.append(DebugEvidence(code: "observed_parent", explanation: "Наблюдаемый родитель: \(parent.name). Родство не определяет активность отладки", relatedIdentity: parent.identity))
            } else {
                evidence.append(DebugEvidence(code: "parent_unknown", explanation: "Родитель не наблюдался. Отсутствие в частичном списке текущего пользователя не доказывает выход", relatedIdentity: nil))
            }
            for child in inventory.processes.filter({ $0.parentPID == p.identity.pid }).prefix(32) {
                evidence.append(DebugEvidence(code: "observed_child", explanation: "Наблюдаемый дочерний процесс: \(child.name). Возможная связь с отладкой блокирует завершение", relatedIdentity: child.identity))
            }
            evidence.append(DebugEvidence(code: "activity_unqualified", explanation: "Проверка Run / breakpoint / Stop / выхода тестового Xcode отложена. Отсутствие активной отладки не доказано", relatedIdentity: nil))
            return DebuggerObservation(process: p, activity: .unknown, orphanhood: p.parentPID == 1 ? .candidate : .unknown,
                                       evidence: evidence, measuredAt: inventory.measuredAt, qualified: false)
        }
        return DebuggerDiagnostics(measuredAt: inventory.measuredAt, debuggers: debuggers, failures: inventory.failures, qualification: "not_run_user_deferred")
    }
}
public enum DebuggerActionPolicy {
    public static func validate(expected: ProcessIdentity, owner: UInt32, current: DebuggerObservation, now: Date) throws {
        guard current.process.identity == expected else { throw ProbeIssue("process_identity_changed", "PID was reused") }
        guard owner == getuid(), current.process.uid == owner else { throw ProbeIssue("debugger_owner_changed", "Requires the current user's unchanged owner") }
        guard DebuggerDiscovery.isDebugger(current.process), current.process.executablePath != nil else { throw ProbeIssue("debugger_identity_unknown", "Executable identity unavailable") }
        guard now >= current.measuredAt, now.timeIntervalSince(current.measuredAt) <= 2 else { throw ProbeIssue("debugger_evidence_stale", "Fresh debugger evidence required") }
        guard current.qualified, current.activity == .inactive, current.orphanhood == .proven, !current.evidence.isEmpty else {
            throw ProbeIssue("debugger_activity_unproven", "Active or unknown debugging blocks termination; PPID/name/footprint are insufficient")
        }
    }
    public static func confirmation(expected: ProcessIdentity, observed: ProcessIdentity?) -> DActionResult {
        guard let observed else { return .init(status: .confirmed) }
        if observed != expected { return .init(status: .unknown, issue: ProbeIssue("process_identity_changed", "PID was reused after signal")) }
        return .init(status: .failed, issue: ProbeIssue("debugger_still_running", "The same debugger remains"))
    }
}
