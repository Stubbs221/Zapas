import Foundation
import Darwin

/// Assignment is local evidence supplied by the user, never inferred from a name or Booted state.
public struct SimulatorAssignment: Codable, Sendable {
    public let project: String
    public let udids: [String]
    public let bindings: [SimulatorBinding]?
    public struct SimulatorBinding: Codable, Sendable, Equatable {
        public let udid: String
        public let runtime: String
        public let dataPath: String
        public let incarnation: String
    }
    public static var defaultPath: String {
        ProcessInfo.processInfo.environment["ZAPAS_SIMULATOR_ASSIGNMENT"]
            ?? UserDefaults.standard.string(forKey: "simulatorAssignmentPath")
            ?? FileManager.default.currentDirectoryPath + "/.local/simulator-assignment.json"
    }
    public static func read(path: String) throws -> Self {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"), url.lastPathComponent == "simulator-assignment.json",
              url.deletingLastPathComponent().lastPathComponent == ".local" else {
            throw ProbeIssue("assignment_path", "Select .local/simulator-assignment.json")
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0, info.st_size <= 65536 else {
            throw ProbeIssue("assignment_unavailable", "Assignment must be an owned regular file, not writable by other users")
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard !value.project.isEmpty, value.project.utf8.count <= 128, value.udids.count <= 8,
              Set(value.udids).count == value.udids.count,
              value.udids.allSatisfy({ UUID(uuidString: $0) != nil }),
              (value.bindings?.count ?? 0) <= 8,
              Set(value.bindings?.map(\.udid) ?? []).count == (value.bindings?.count ?? 0),
              value.bindings?.allSatisfy({ value.udids.contains($0.udid) && $0.dataPath.hasPrefix("/") && !$0.incarnation.isEmpty }) ?? true else {
            throw ProbeIssue("assignment_schema", "Invalid or excessive assignment")
        }
        return value
    }
}

public struct AssignedSimulator: Codable, Sendable, Equatable, Identifiable {
    public var id: String { device.udid }
    public let device: SimulatorDevice
    public let incarnation: String?
    public let assignmentVerified: Bool
    public var canSelect: Bool {
        device.isIOS && device.isAvailable && device.assignment == "Zapas" && assignmentVerified
            && incarnation != nil && ["Booted", "Shutdown"].contains(device.state)
    }
}
public struct SimulatorDiagnostics: Codable, Sendable {
    public let measuredAt: Date
    public let totalDeviceCount: Int
    public let devices: [AssignedSimulator]
    public let assignmentIssue: ProbeIssue?
    public var processes: [SimulatorProcessGroup] = []
    public var unassignedProcesses: [DiagnosticProcess] = []
    public var processIssue: ProbeIssue?
    public var processFailures: [ProcessFailure] = []
    public var processMeasuredAt: Date?
    public var errors: [ProbeIssue] { [assignmentIssue, processIssue].compactMap { $0 } + processFailures.map(\.issue) }
    public mutating func associate(_ inventory: ProcessDiagnostics?, issue: ProbeIssue?) {
        processIssue = issue; processMeasuredAt = inventory?.measuredAt; processFailures = inventory?.failures ?? []
        let all = devices.map(\.device)
        processes = devices.map { entry in
            SimulatorProcessGroup(udid: entry.id, processes: inventory?.processes.filter {
                SimulatorInventory.associations(path: $0.executablePath, devices: all) == [entry.id]
            } ?? [])
        }
        // Generic helpers remain unknown; do not infer a device from ancestry or its human-readable name.
        unassignedProcesses = inventory?.processes.filter {
            let path = $0.executablePath ?? ""
            return (path.contains("CoreSimulator") || path.contains("Simulator.app"))
                && SimulatorInventory.associations(path: $0.executablePath, devices: all).count != 1
        } ?? []
    }
}
public struct SimulatorProcessGroup: Codable, Sendable {
    public let udid: String
    public let processes: [DiagnosticProcess]
}

public enum SimulatorDiscovery {
    /// Device directory inode + birth time pins an incarnation; erase/recreate requires a new assignment.
    public static func incarnation(dataPath: String?) -> String? {
        guard let dataPath, dataPath.hasPrefix("/"), URL(fileURLWithPath: dataPath).lastPathComponent == "data" else { return nil }
        let directory = URL(fileURLWithPath: dataPath).deletingLastPathComponent().path
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return nil }
        return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }
    #if compiler(>=6.2)
    @concurrent
    #endif
    public static func read(assignmentPath: String) async throws -> SimulatorDiagnostics {
        // ALL runtimes, including unavailable and foreign devices, before every targeted action.
        let snapshot = try SimulatorInventory.read()
        let assignment: SimulatorAssignment?
        let assignmentIssue: ProbeIssue?
        do { assignment = try SimulatorAssignment.read(path: assignmentPath); assignmentIssue = nil }
        catch { assignment = nil; assignmentIssue = error as? ProbeIssue ?? ProbeIssue("assignment_schema", "Assignment could not be decoded") }
        let devices = snapshot.devices.map { device in
            let owner = assignment?.udids.contains(device.udid) == true ? assignment?.project ?? "unknown_or_other_project" : "unknown_or_other_project"
            let owned = SimulatorDevice(name: device.name, udid: device.udid, runtime: device.runtime, state: device.state,
                                        isAvailable: device.isAvailable, dataPath: device.dataPath, assignment: owner, isIOS: device.isIOS)
            let identity = incarnation(dataPath: device.dataPath)
            let binding = assignment?.bindings?.first { $0.udid == device.udid }
            return AssignedSimulator(device: owned, incarnation: identity,
                                     assignmentVerified: binding != nil && binding?.runtime == device.runtime
                                        && binding?.dataPath == device.dataPath && binding?.incarnation == identity)
        }
        return SimulatorDiagnostics(measuredAt: snapshot.measuredAt, totalDeviceCount: snapshot.totalDeviceCount, devices: devices, assignmentIssue: assignmentIssue)
    }
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func shutdown(_ expected: AssignedSimulator, assignmentPath: String, expiresAt: Date) async throws {
        let current = try await read(assignmentPath: assignmentPath)
        try SimulatorActionPolicy.validate(expected, in: current)
        guard Date() < expiresAt else { throw ProbeIssue("preview_expired_or_used", "Preview expired during final backend verification") }
        guard expected.device.state == "Booted" else { throw ProbeIssue("device_already_shutdown", "No shutdown command for Shutdown") }
        // Fixed executable and exact validated UUID. No 'all', generic 'booted', shell or helper termination.
        _ = try SimulatorInventory.command(["shutdown", expected.id], timeoutSeconds: 10)
    }
}
public enum SimulatorActionPolicy {
    public static func validate(_ expected: AssignedSimulator, in snapshot: SimulatorDiagnostics) throws {
        guard let current = snapshot.devices.first(where: { $0.id == expected.id }) else { throw ProbeIssue("device_disappeared", "Selected device disappeared") }
        guard expected.canSelect, current.canSelect else { throw ProbeIssue("device_not_authorized", "Requires a pinned, assigned, available Zapas iOS device") }
        guard current == expected else { throw ProbeIssue("device_identity_or_state_changed", "Device runtime, incarnation, assignment or state changed; preview again") }
    }
    public static func confirm(_ expected: AssignedSimulator, in snapshot: SimulatorDiagnostics) -> DActionResult {
        guard let current = snapshot.devices.first(where: { $0.id == expected.id }) else { return .init(status: .unknown, issue: ProbeIssue("device_disappeared", "Device missing after command")) }
        guard current.device.isIOS, current.device.isAvailable, current.device.assignment == "Zapas",
              current.assignmentVerified, current.incarnation != nil, current.incarnation == expected.incarnation,
              current.device.runtime == expected.device.runtime, current.device.dataPath == expected.device.dataPath else {
            return .init(status: .unknown, issue: ProbeIssue("device_identity_or_assignment_changed", "Post-command identity cannot be confirmed"))
        }
        if current.device.state == "Shutdown" { return .init(status: .confirmed, issue: expected.device.state == "Shutdown" ? ProbeIssue("device_already_shutdown", "Already Shutdown; no command sent") : nil) }
        if current.device.state == "Booted" { return .init(status: .failed, issue: ProbeIssue("device_still_booted", "Device remains Booted")) }
        return .init(status: .unknown, issue: ProbeIssue("device_state_unknown", "Device is in a transitional state"))
    }
}
