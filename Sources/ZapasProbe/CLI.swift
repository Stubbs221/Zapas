import Foundation
import Darwin
import ZapasCore

private struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    init(_ arguments: [String], values allowedValues: Set<String>, flags allowedFlags: Set<String> = []) throws {
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard !flags.contains(key), values[key] == nil else { throw ProbeIssue("argument", "Repeated argument \(key)") }
            if allowedFlags.contains(key) { flags.insert(key); index += 1 }
            else if allowedValues.contains(key), index + 1 < arguments.count {
                values[key] = arguments[index + 1]; index += 2
            } else { throw ProbeIssue("argument", "Unknown or incomplete argument \(key)") }
        }
    }
    func required(_ key: String) throws -> String {
        guard let value = values[key], !value.isEmpty else { throw ProbeIssue("argument", "Missing \(key)") }
        return value
    }
    func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        let value: Int
        if let text = values[key] {
            guard let parsed = Int(text) else { throw ProbeIssue("argument", "Invalid integer \(key)") }
            value = parsed
        } else { value = fallback }
        guard range.contains(value) else { throw ProbeIssue("argument", "\(key) must be in \(range)") }
        return value
    }
}

@main
struct ZapasProbe {
    static func emit<T: Encodable>(_ value: T) throws {
        var data = try ProbeJSON.encode(value, pretty: false); data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            let issue = error as? ProbeIssue ?? ProbeIssue("probe_failed", String(describing: error))
            if let data = try? ProbeJSON.encode(issue) { try? FileHandle.standardError.write(contentsOf: data + Data([10])) }
            exit(1)
        }
    }
    static func run(_ arguments: [String]) async throws {
        let command = arguments.first ?? "help"
        let rest = Array(arguments.dropFirst())
        switch command {
        case "help", "--help", "-h":
            print("""
            Zapas — stage A experimental diagnostics (JSON/NDJSON, schema v1).
            system [--samples N] [--interval SECONDS]
            processes [--pid PID] [--limit N] [--all-users]
            chrome-memory
            debuggers
            benchmark [--iterations N]
            simulators [--input JSON_FILE] [--assignment LOCAL_JSON_FILE] [--processes]
            serve --socket ABSOLUTE_PATH --origin chrome-extension://ID/ [--seconds N]
            tabs --socket ABSOLUTE_PATH
            discard-test-tab --socket PATH --session UUID --id TAB_ID --apply [--request UUID]
            result --socket PATH --action UUID
            Only explicitly selected extension-created fixtures can be discarded.
            No shutdown, kill, browser restart or Charles actions.
            """)
        case "system":
            let options = try Options(rest, values: ["--samples", "--interval"])
            let samples = try options.integer("--samples", default: 1, range: 1...600)
            let interval = Double(options.values["--interval"] ?? "3") ?? .nan
            guard interval.isFinite, (0.1...60).contains(interval) else { throw ProbeIssue("argument", "--interval must be 0.1...60 seconds") }
            let observer = MemoryPressureObserver()
            let monitor = SystemMonitor()
            var previous: CounterSample?
            for index in 0..<samples {
                if index > 0 { try await Task.sleep(for: .seconds(interval)) }
                let snapshot = try monitor.sample(previous: previous, pressure: observer.observation)
                try emit(snapshot); previous = snapshot.counters
            }
        case "processes":
            let options = try Options(rest, values: ["--pid", "--limit"], flags: ["--all-users"])
            if let pid = options.values["--pid"] {
                guard let number = Int32(pid), number > 0 else { throw ProbeIssue("argument", "PID must be positive") }
                try emit(ProcessInventory().sample(pid: number))
            } else {
                let limit = try options.integer("--limit", default: 20, range: 1...10000)
                let snapshot = try ProcessInventory().sampleAll(currentUserOnly: !options.flags.contains("--all-users"))
                try emit(ProcessSnapshot(measuredAt: snapshot.measuredAt, processes: Array(snapshot.processes.prefix(limit)), failures: snapshot.failures))
            }
        case "chrome-memory":
            _ = try Options(rest, values: [])
            try emit(ChromeMemoryObservation.summarize(ProcessInventory().sampleAll()))
        case "debuggers":
            _ = try Options(rest, values: [])
            struct Debugger: Encodable { let process: ProcessObservation; let status: String }
            let inventory = try ProcessInventory().sampleAll()
            try emit(inventory.processes.compactMap { process in process.debuggerStatus.map { Debugger(process: process, status: $0) } })
        case "benchmark":
            let options = try Options(rest, values: ["--iterations"])
            let iterations = try options.integer("--iterations", default: 30, range: 2...200)
            struct Timing: Encodable { let medianMilliseconds: Double; let maximumMilliseconds: Double }
            struct Benchmark: Encodable {
                let measuredAt: Date; let iterations: Int; let system: Timing; let processes: Timing
                let ownFootprint: Metric; let ownRSS: Metric; let cpuSeconds: Double
                let note: String = "Short probe benchmark, not GUI background CPU or launch-time qualification"
            }
            var initialCPU = rusage(); getrusage(RUSAGE_SELF, &initialCPU)
            var systemTimes: [Double] = []; var processTimes: [Double] = []
            for _ in 0..<iterations {
                var start = ProcessInfo.processInfo.systemUptime
                _ = try SystemMonitor().sample()
                systemTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                start = ProcessInfo.processInfo.systemUptime
                _ = try ProcessInventory().sampleAll()
                processTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            let own = try ProcessInventory().sample(pid: getpid())
            var finalCPU = rusage(); getrusage(RUSAGE_SELF, &finalCPU)
            func cpu(_ value: rusage) -> Double {
                Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
            }
            func timing(_ values: [Double]) -> Timing {
                let sorted = values.sorted()
                return Timing(medianMilliseconds: sorted[sorted.count / 2], maximumMilliseconds: sorted.last ?? 0)
            }
            try emit(Benchmark(measuredAt: Date(), iterations: iterations, system: timing(systemTimes), processes: timing(processTimes),
                               ownFootprint: own.footprint, ownRSS: own.rss, cpuSeconds: cpu(finalCPU) - cpu(initialCPU)))
        case "simulators":
            let options = try Options(rest, values: ["--input", "--assignment"], flags: ["--processes"])
            struct Assignment: Decodable { let project: String; let udids: [String] }
            var assigned: Set<String> = []
            if let path = options.values["--assignment"] {
                let assignment = try JSONDecoder().decode(Assignment.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                guard assignment.project == "Zapas", assignment.udids.allSatisfy({ UUID(uuidString: $0) != nil }) else {
                    throw ProbeIssue("assignment_invalid", "Assignment must name Zapas and valid UDIDs")
                }
                assigned = Set(assignment.udids)
            }
            let snapshot: SimulatorSnapshot
            if let path = options.values["--input"] { snapshot = try SimulatorInventory.decode(Data(contentsOf: URL(fileURLWithPath: path)), assignedUDIDs: assigned) }
            else { snapshot = try SimulatorInventory.read(assignedUDIDs: assigned) }
            if options.flags.contains("--processes") {
                struct Association: Encodable {
                    let identity: ProcessIdentity; let deviceUDIDs: [String]; let status: String
                }
                struct Report: Encodable {
                    let inventory: SimulatorSnapshot; let processSnapshotAt: Date
                    let associations: [Association]; let processFailures: [ProcessFailure]
                }
                let processes = try ProcessInventory().sampleAll()
                let associations = processes.processes.map { process in
                    let ids = SimulatorInventory.associations(path: process.executablePath, devices: snapshot.devices)
                    return Association(identity: process.identity, deviceUDIDs: ids, status: ids.isEmpty ? "unknown" : "executable_inside_device_data_path")
                }
                try emit(Report(inventory: snapshot, processSnapshotAt: processes.measuredAt, associations: associations, processFailures: processes.failures))
            } else { try emit(snapshot) }
        case "serve":
            let options = try Options(rest, values: ["--socket", "--origin", "--seconds"])
            let path = try options.required("--socket")
            let seconds = try options.integer("--seconds", default: 300, range: 1...3600)
            try LocalIPC.preparePrivateDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
            var broker = try ProbeBroker(allowedOrigin: options.required("--origin"))
            let server = try ProbeSocketServer(path: path)
            try server.serve(seconds: Double(seconds), broker: &broker)
        case "tabs", "discard-test-tab", "result":
            let options = try Options(rest, values: ["--socket", "--session", "--id", "--request", "--action"], flags: ["--apply"])
            var request: ProbeRequest
            if command == "tabs" { request = ProbeRequest(.listTabs) }
            else if command == "result" { request = ProbeRequest(.getActionResult, actionID: try options.required("--action")) }
            else {
                guard options.flags.contains("--apply") else { throw ProbeIssue("apply_required", "Select a fixture tab and supply --apply; no action performed") }
                let tabID = try options.integer("--id", default: -1, range: 0...Int.max)
                request = ProbeRequest(.discardTestTab, sessionID: try options.required("--session"), tabID: tabID)
                if let id = options.values["--request"] { request.requestID = id }
            }
            try request.validate()
            let reply = try LocalIPC.request(request, socketPath: options.required("--socket"))
            try emit(reply)
            if !reply.ok { exit(2) }
        default: throw ProbeIssue("command", "Unknown command \(command); use help")
        }
    }
}
