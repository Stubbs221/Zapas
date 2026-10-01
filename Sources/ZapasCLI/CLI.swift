import Foundation
import Darwin
import ZapasCore

@main
struct ZapasCLI {
    static func main() async {
        // A disconnected JSON consumer is a delivery error (exit 1), not SIGPIPE termination.
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] {
            print("""
            Zapas — read-only diagnostics, JSON v1
            zapas status --json
            zapas processes --sort memory --limit N --json
            No persistent monitor; first swap interval and pressure without an event are unknown.
            """)
            return
        }
        let command = arguments[0]
        do {
            var limit = 20
            var seen: Set<String> = []
            var index = 1
            while index < arguments.count {
                let key = arguments[index]
                guard seen.insert(key).inserted else { throw ProbeIssue("invalid_arguments", "Repeated argument \(key)") }
                switch key {
                case "--json": index += 1
                case "--sort" where command == "processes":
                    guard index + 1 < arguments.count, arguments[index + 1] == "memory" else { throw ProbeIssue("invalid_arguments", "--sort must be memory") }
                    index += 2
                case "--limit" where command == "processes":
                    guard index + 1 < arguments.count, let number = Int(arguments[index + 1]), (1...10000).contains(number) else {
                        throw ProbeIssue("invalid_arguments", "--limit must be 1...10000")
                    }
                    limit = number; index += 2
                default: throw ProbeIssue("invalid_arguments", "Unknown argument \(key)")
                }
            }
            guard ["status", "processes"].contains(command), seen.contains("--json") else {
                throw ProbeIssue("invalid_arguments", "Use status --json or processes --json")
            }
            let coordinator = SamplingCoordinator()
            let frame = await coordinator.refresh(includeProcesses: command == "processes")
            await coordinator.stop()
            if command == "status" {
                let errors = frame.system?.errors ?? [frame.systemError ?? ProbeIssue("system_failed", "No system data")]
                try emit(DiagnosticEnvelope(command: command, data: frame.system, errors: errors))
                if frame.system == nil { exit(1) }
            } else {
                let payload = frame.processes.map { value in
                    // Preserve inventory failures and accounting while limiting the presented rows.
                    LimitedProcesses(measuredAt: value.measuredAt, processes: Array(value.processes.prefix(limit)),
                                     failures: value.failures, accounting: value.accounting, totalObserved: value.processes.count)
                }
                let errors = frame.processes?.errors ?? [frame.processError ?? ProbeIssue("processes_failed", "No process data")]
                try emit(DiagnosticEnvelope(command: command, data: payload, errors: errors))
                if payload == nil { exit(1) }
            }
        } catch {
            let issue = error as? ProbeIssue ?? ProbeIssue("cli_failed", String(describing: error))
            let empty: SystemDiagnostics? = nil
            try? emit(DiagnosticEnvelope(command: command, data: empty, errors: [issue]))
            exit(issue.code == "invalid_arguments" ? 2 : 1)
        }
    }
    struct LimitedProcesses: Codable, Sendable {
        let measuredAt: Date
        let processes: [DiagnosticProcess]
        let failures: [ProcessFailure]
        let accounting: String
        let totalObserved: Int
    }
    static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value); data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
