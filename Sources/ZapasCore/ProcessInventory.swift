import Foundation
import Darwin
import CZapas

public struct ProcessIdentity: Codable, Sendable, Equatable, Hashable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid; self.startSeconds = startSeconds; self.startMicroseconds = startMicroseconds
    }
}

public struct ProcessObservation: Codable, Sendable {
    public let identity: ProcessIdentity
    public let uid: UInt32
    public let parentPID: Int32
    public let name: String
    public let executablePath: String?
    public let footprint: Metric
    public let rss: Metric
    public var debuggerStatus: String? {
        let executable = executablePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? name
        guard executable == "lldb-rpc-server" || executable == "lldb" else { return nil }
        return parentPID == 1 ? "orphan_candidate_activity_unknown" : "debug_activity_unknown"
    }
}

public struct ProcessFailure: Codable, Sendable {
    public let pid: Int32
    public let issue: ProbeIssue
}

public struct ProcessSnapshot: Encodable, Sendable {
    public let schemaVersion = 1
    public let measuredAt: Date
    public let processes: [ProcessObservation]
    public let failures: [ProcessFailure]
    public let accounting: String = "Footprint and RSS are distinct; group sums are not unique physical RAM"
    public init(measuredAt: Date, processes: [ProcessObservation], failures: [ProcessFailure]) {
        self.measuredAt = measuredAt; self.processes = processes; self.failures = failures
    }
}

public struct ProcessInventory {
    public init() {}
    public func sample(pid: Int32) throws -> ProcessObservation {
        var raw = zp_process()
        let result = zp_read_process(pid, &raw)
        guard result == 0 else {
            let code = result == -EAGAIN ? "process_identity_changed" : result == -ESRCH ? "process_disappeared" : "process_api"
            throw ProbeIssue(code, "Process \(pid) unavailable (errno \(-result))")
        }
        let name = withUnsafePointer(to: &raw.name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let path = withUnsafePointer(to: &raw.path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
        }
        let time = Date()
        func memory(_ value: UInt64, field: String) -> Metric {
            let source = "proc_pid_rusage.RUSAGE_INFO_V0.\(field)"
            return raw.memory_error == 0 ? Metric(Double(value), source: source, at: time)
                : Metric(unavailable: ProbeIssue("process_memory_unavailable", "errno \(raw.memory_error)"), source: source, at: time)
        }
        return ProcessObservation(identity: ProcessIdentity(pid: pid, startSeconds: raw.start_seconds, startMicroseconds: raw.start_microseconds),
                                  uid: raw.uid, parentPID: raw.ppid, name: name, executablePath: path.isEmpty ? nil : path,
                                  footprint: memory(raw.footprint_bytes, field: "ri_phys_footprint"), rss: memory(raw.rss_bytes, field: "ri_resident_size"))
    }
    public func revalidate(_ identity: ProcessIdentity) throws -> ProcessObservation {
        let observation = try sample(pid: identity.pid)
        guard observation.identity == identity else { throw ProbeIssue("process_identity_changed", "PID was reused") }
        return observation
    }
    public func sampleAll(currentUserOnly: Bool = true) throws -> ProcessSnapshot {
        let initial = zp_list_pids(nil, 0)
        guard initial > 0 else { throw ProbeIssue("process_list", "Unable to enumerate processes (\(initial))") }
        var buffer = [Int32](repeating: 0, count: Int(initial) + 128)
        var count = buffer.withUnsafeMutableBufferPointer { zp_list_pids($0.baseAddress, Int32($0.count)) }
        if count == buffer.count {
            buffer = [Int32](repeating: 0, count: buffer.count * 2)
            count = buffer.withUnsafeMutableBufferPointer { zp_list_pids($0.baseAddress, Int32($0.count)) }
        }
        guard count > 0, count < buffer.count else { throw ProbeIssue("process_list", "Process list failed or exceeded allocated capacity") }
        var observations: [ProcessObservation] = []
        var failures: [ProcessFailure] = []
        let time = Date()
        for pid in buffer.prefix(Int(count)) where pid > 0 {
            do {
                let observation = try sample(pid: pid)
                if !currentUserOnly || observation.uid == getuid() { observations.append(observation) }
            } catch {
                failures.append(ProcessFailure(pid: pid, issue: error as? ProbeIssue ?? ProbeIssue("process_api", String(describing: error))))
            }
        }
        observations.sort { ($0.footprint.value ?? -1) > ($1.footprint.value ?? -1) }
        return ProcessSnapshot(measuredAt: time, processes: observations, failures: failures)
    }
}
