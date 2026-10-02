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
            Zapas — read-only diagnostics and explicit Chrome/Simulator actions, JSON v1
            zapas status --json
            zapas processes --sort memory --limit N --json
            zapas tabs list --json
            zapas tabs preview --type discard|close --selection JSON --json
            zapas tabs apply --plan UUID --apply --json
            zapas tabs result --plan UUID --json
            zapas simulators list --json
            zapas simulators preview --selection JSON --json
            zapas simulators apply --plan UUID --apply --json
            zapas simulators result --plan UUID --json
            zapas debuggers list --json
            zapas debuggers preview --selection JSON --json
            zapas debuggers apply --plan UUID --apply --json
            zapas debuggers result --plan UUID --json
            LLDB actions are blocked until activity/orphanhood is qualified; unknown is never safe.
            zapas native install --user-data-dir PATH --apply --json
            No persistent monitor; first swap interval and pressure without an event are unknown.
            """)
            return
        }
        let command = arguments[0]
        do {
            if ["simulators", "debuggers"].contains(command) { try await development(arguments); return }
            if command == "tabs" { try await tabs(arguments); return }
            if command == "native" { try native(arguments); return }
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
            let system: SystemDiagnostics?
            let processes: ProcessDiagnostics?
            let systemError: ProbeIssue?
            let processError: ProbeIssue?
            if FileManager.default.fileExists(atPath: ServiceLocation.socket) {
                let reply = try await ServiceIPC.asyncRequest(ServiceRequest(command))
                if let issue = reply.issue { throw issue }
                system = reply.system; processes = reply.processes
                systemError = reply.systemError; processError = reply.processError
            } else {
                let coordinator = SamplingCoordinator()
                let frame = await coordinator.refresh(includeProcesses: command == "processes")
                await coordinator.stop()
                system = frame.system; processes = frame.processes
                systemError = frame.systemError; processError = frame.processError
            }
            if command == "status" {
                let errors = system?.errors ?? [systemError ?? ProbeIssue("system_failed", "No system data")]
                try emit(DiagnosticEnvelope(command: command, data: system, errors: errors))
                if system == nil { exit(1) }
            } else {
                let payload = processes.map { value in
                    // Preserve inventory failures and accounting while limiting the presented rows.
                    LimitedProcesses(measuredAt: value.measuredAt, processes: Array(value.processes.prefix(limit)),
                                     failures: value.failures, accounting: value.accounting, totalObserved: value.processes.count)
                }
                let errors = processes?.errors ?? [processError ?? ProbeIssue("processes_failed", "No process data")]
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

    static func options(_ arguments: [String], flags: Set<String>, values: Set<String>) throws -> [String: String] {
        var options: [String: String] = [:], index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard options[key] == nil else { throw ProbeIssue("invalid_arguments", "Repeated option") }
            if flags.contains(key) { options[key] = "true"; index += 1 }
            else if values.contains(key), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                options[key] = arguments[index + 1]; index += 2
            } else { throw ProbeIssue("invalid_arguments", "Unknown or incomplete option") }
        }
        guard options["--json"] != nil else { throw ProbeIssue("invalid_arguments", "--json required") }
        return options
    }
    static func tabs(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else { throw ProbeIssue("invalid_arguments", "Use tabs list/preview/apply/result") }
        let verb = arguments[1]
        let flags: Set<String> = verb == "apply" ? ["--json", "--apply"] : ["--json"]
        let values: Set<String> = verb == "preview" ? ["--type", "--selection"] : ["apply", "result"].contains(verb) ? ["--plan"] : []
        let opt = try options(Array(arguments.dropFirst(2)), flags: flags, values: values)
        var request: ServiceRequest
        switch verb {
        case "list": request = ServiceRequest("tabsList")
        case "preview":
            guard let type = opt["--type"], let kind = ChromeActionKind(rawValue: type), let selection = opt["--selection"] else { throw ProbeIssue("invalid_arguments", "--type and --selection required") }
            request = ServiceRequest("tabsPreview"); request.kind = kind
            do { request.selections = try JSONDecoder().decode([ChromeSelection].self, from: Data(selection.utf8)) }
            catch { throw ProbeIssue("invalid_arguments", "Selection must be a JSON array of profileID/sessionID/tabID/token") }
        case "apply", "result":
            guard let id = opt["--plan"], UUID(uuidString: id) != nil, verb != "apply" || opt["--apply"] != nil else { throw ProbeIssue("invalid_arguments", "UUID --plan and explicit --apply required for action") }
            request = ServiceRequest(verb == "apply" ? "tabsApply" : "tabsResult"); request.planID = id
        default: throw ProbeIssue("invalid_arguments", "Unknown tabs subcommand")
        }
        let reply = try await ServiceIPC.asyncRequest(request)
        if let issue = reply.issue { throw issue }
        try emit(DiagnosticEnvelope(command: "tabs " + verb, data: reply, errors: []))
    }
    static func development(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else { throw ProbeIssue("invalid_arguments", "Use list/preview/apply/result") }
        let group = arguments[0], verb = arguments[1]
        let opt = try options(Array(arguments.dropFirst(2)), flags: verb == "apply" ? ["--json", "--apply"] : ["--json"],
                              values: verb == "preview" ? ["--selection"] : ["apply", "result"].contains(verb) ? ["--plan"] : [])
        var request: ServiceRequest
        switch verb {
        case "list": request = ServiceRequest(group + "List")
        case "preview":
            guard let selection = opt["--selection"] else { throw ProbeIssue("invalid_arguments", "Explicit --selection required") }
            request = ServiceRequest(group + "Preview")
            do {
                if group == "simulators" { request.simulator = try JSONDecoder().decode(AssignedSimulator.self, from: Data(selection.utf8)) }
                else { request.debuggerIdentity = try JSONDecoder().decode(ProcessIdentity.self, from: Data(selection.utf8)) }
            } catch { throw ProbeIssue("invalid_arguments", "Select one exact devices entry, or debugger process.identity, from list JSON") }
        case "apply", "result":
            guard let id = opt["--plan"], UUID(uuidString: id) != nil, verb != "apply" || opt["--apply"] != nil else {
                throw ProbeIssue("invalid_arguments", "UUID --plan and explicit --apply required for action")
            }
            request = ServiceRequest(verb == "apply" ? "developmentApply" : "developmentResult")
            request.planID = id; request.apply = verb == "apply"; request.developmentKind = group == "simulators" ? .simulatorShutdown : .debuggerTerminate
        default: throw ProbeIssue("invalid_arguments", "Unknown development subcommand")
        }
        // Only read-only list can run without GUI. Plans and results belong to its single in-memory service.
        if verb == "list", !FileManager.default.fileExists(atPath: ServiceLocation.socket) {
            if group == "simulators" {
                var list = try await SimulatorDiscovery.read(assignmentPath: SimulatorAssignment.defaultPath)
                let coordinator = SamplingCoordinator()
                let frame = await coordinator.refresh(includeProcesses: true); await coordinator.stop()
                list.associate(frame.processes, issue: frame.processError)
                try emit(DiagnosticEnvelope(command: group + " list", data: list, errors: list.errors))
            } else {
                let coordinator = SamplingCoordinator()
                let frame = await coordinator.refresh(includeProcesses: true); await coordinator.stop()
                guard frame.processError == nil, let inventory = frame.processes else { throw frame.processError ?? ProbeIssue("processes_failed", "No process data") }
                let list = DebuggerDiscovery.read(inventory)
                try emit(DiagnosticEnvelope(command: group + " list", data: list, errors: list.failures.map(\.issue)))
            }
            return
        }
        let reply = try await ServiceIPC.asyncRequest(request)
        if let issue = reply.issue { throw issue }
        if let list = reply.simulators { try emit(DiagnosticEnvelope(command: group + " " + verb, data: list, errors: list.errors)) }
        else if let list = reply.debuggers { try emit(DiagnosticEnvelope(command: group + " " + verb, data: list, errors: list.failures.map(\.issue))) }
        else { try emit(DiagnosticEnvelope(command: group + " " + verb, data: reply, errors: [])) }
    }
    static func native(_ arguments: [String]) throws {
        guard arguments.count >= 2, arguments[1] == "install" else { throw ProbeIssue("invalid_arguments", "Use native install") }
        let opt = try options(Array(arguments.dropFirst(2)), flags: ["--json", "--apply"], values: ["--user-data-dir"])
        guard opt["--apply"] != nil, let directory = opt["--user-data-dir"], directory.hasPrefix("/") else { throw ProbeIssue("invalid_arguments", "Explicit absolute --user-data-dir and --apply required") }
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).deletingLastPathComponent().appendingPathComponent("zapas-native-host")
        let manifest = try NativeInstallation.install(hostExecutable: executable, userDataDirectory: URL(fileURLWithPath: directory))
        try emit(DiagnosticEnvelope(command: "native install", data: ["manifest": manifest.path], errors: []))
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
