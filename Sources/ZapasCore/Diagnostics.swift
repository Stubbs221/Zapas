import Foundation

/// Public diagnostics v1 is independent of the stage A probe wire format.
public struct DiagnosticMetric: Codable, Sendable {
    public let value: Double?
    public let unit: String
    public let source: String
    public let measuredAt: Date
    public let status: String
    public let error: ProbeIssue?

    public init(_ metric: Metric) {
        value = metric.value; unit = metric.unit; source = metric.source
        measuredAt = metric.measuredAt
        status = metric.value == nil ? "unknown" : "available"
        error = metric.issue
    }
    enum CodingKeys: String, CodingKey { case value, unit, source, measuredAt, status, error }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value); try c.encode(unit, forKey: .unit)
        try c.encode(source, forKey: .source); try c.encode(measuredAt, forKey: .measuredAt)
        try c.encode(status, forKey: .status); try c.encode(error, forKey: .error)
    }
}

public struct DiagnosticPressure: Codable, Sendable {
    public let state: String
    public let source: String
    public let measuredAt: Date?
    public let error: ProbeIssue?
    public init(_ observation: PressureObservation) {
        state = observation.state; source = observation.source
        measuredAt = observation.measuredAt; error = observation.issue
    }
    enum CodingKeys: String, CodingKey { case state, source, measuredAt, error }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state); try c.encode(source, forKey: .source)
        try c.encode(measuredAt, forKey: .measuredAt); try c.encode(error, forKey: .error)
    }
}

public struct SystemDiagnostics: Codable, Sendable {
    public let measuredAt: Date
    public let physical, wired, compressed, swapUsed, swapTotal: DiagnosticMetric
    public let swapReadRate, swapWriteRate: DiagnosticMetric
    public let intervalSeconds: Double?
    public let pressure: DiagnosticPressure
    public init(_ s: SystemSnapshot) {
        measuredAt = s.measuredAt
        physical = DiagnosticMetric(s.physical); wired = DiagnosticMetric(s.wired)
        compressed = DiagnosticMetric(s.compressed); swapUsed = DiagnosticMetric(s.swapUsed)
        swapTotal = DiagnosticMetric(s.swapTotal)
        swapReadRate = DiagnosticMetric(s.rates.read); swapWriteRate = DiagnosticMetric(s.rates.write)
        intervalSeconds = s.rates.intervalSeconds; pressure = DiagnosticPressure(s.pressure)
    }
    public var errors: [ProbeIssue] {
        [physical, wired, compressed, swapUsed, swapTotal, swapReadRate, swapWriteRate].compactMap(\.error)
            + [pressure.error].compactMap { $0 }
    }
    enum CodingKeys: String, CodingKey {
        case measuredAt, physical, wired, compressed, swapUsed, swapTotal, swapReadRate, swapWriteRate, intervalSeconds, pressure
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(measuredAt, forKey: .measuredAt); try c.encode(physical, forKey: .physical)
        try c.encode(wired, forKey: .wired); try c.encode(compressed, forKey: .compressed)
        try c.encode(swapUsed, forKey: .swapUsed); try c.encode(swapTotal, forKey: .swapTotal)
        try c.encode(swapReadRate, forKey: .swapReadRate); try c.encode(swapWriteRate, forKey: .swapWriteRate)
        try c.encode(intervalSeconds, forKey: .intervalSeconds); try c.encode(pressure, forKey: .pressure)
    }
}

public struct DiagnosticProcess: Codable, Sendable, Identifiable {
    public var id: ProcessIdentity { identity }
    public let identity: ProcessIdentity
    public let uid: UInt32
    public let parentPID: Int32
    public let name: String
    public let executablePath: String?
    public let footprint, rss: DiagnosticMetric
    public init(_ p: ProcessObservation) {
        identity = p.identity; uid = p.uid; parentPID = p.parentPID
        name = p.name; executablePath = p.executablePath
        footprint = DiagnosticMetric(p.footprint); rss = DiagnosticMetric(p.rss)
    }
    enum CodingKeys: String, CodingKey { case identity, uid, parentPID, name, executablePath, footprint, rss }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identity, forKey: .identity); try c.encode(uid, forKey: .uid)
        try c.encode(parentPID, forKey: .parentPID); try c.encode(name, forKey: .name)
        try c.encode(executablePath, forKey: .executablePath)
        try c.encode(footprint, forKey: .footprint); try c.encode(rss, forKey: .rss)
    }
}

public struct ApplicationDiagnostics: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let bundlePath: String?
    public let processes: [DiagnosticProcess]
    public let footprint: DiagnosticMetric
    public var measuredCount: Int { processes.filter { $0.footprint.value != nil }.count }
    public var unavailableCount: Int { processes.count - measuredCount }
}

public struct ProcessDiagnostics: Codable, Sendable {
    public let measuredAt: Date
    public let processes: [DiagnosticProcess]
    public let failures: [ProcessFailure]
    public let accounting: String
    public init(_ s: ProcessSnapshot, limit: Int = 10000) {
        measuredAt = s.measuredAt
        processes = s.processes.map(DiagnosticProcess.init).sorted {
            if $0.footprint.value != $1.footprint.value { return ($0.footprint.value ?? -1) > ($1.footprint.value ?? -1) }
            return $0.identity.pid < $1.identity.pid
        }.prefix(limit).map { $0 }
        failures = s.failures
        accounting = "Observed current-user footprint and RSS are separate; partial sums are not unique physical RAM or tab RAM. Inventory failures cannot be attributed to an application."
    }
    public var applications: [ApplicationDiagnostics] {
        let groups = Dictionary(grouping: processes) { p in
            Self.bundlePath(p.executablePath) ?? "process:\(p.identity.pid):\(p.identity.startSeconds):\(p.identity.startMicroseconds)"
        }
        return groups.map { key, members in
            let bundle = Self.bundlePath(members[0].executablePath)
            let values = members.compactMap(\.footprint.value)
            let source = bundle == nil ? members[0].footprint.source : "sum of observed app processes: proc_pid_rusage.ri_phys_footprint"
            let metric = values.isEmpty
                ? Metric(unavailable: ProbeIssue("application_memory_unavailable", "No readable footprint"), source: source, at: measuredAt)
                : Metric(values.reduce(0, +), source: source, at: measuredAt)
            return ApplicationDiagnostics(id: key,
                name: bundle.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? members[0].name,
                bundlePath: bundle, processes: members, footprint: DiagnosticMetric(metric))
        }.sorted {
            if $0.footprint.value != $1.footprint.value { return ($0.footprint.value ?? -1) > ($1.footprint.value ?? -1) }
            return $0.id < $1.id
        }
    }
    public static func bundlePath(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/")
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return "/" + parts[...index].joined(separator: "/")
    }
    public var errors: [ProbeIssue] {
        failures.map(\.issue) + processes.flatMap { [$0.footprint.error, $0.rss.error].compactMap { $0 } }
    }
}

public struct DiagnosticEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let schemaVersion: Int
    public let command: String
    public let generatedAt: Date
    public let status: String
    public let data: Payload?
    public let errors: [ProbeIssue]
    public init(command: String, generatedAt: Date = Date(), data: Payload?, errors: [ProbeIssue]) {
        schemaVersion = 1; self.command = command; self.generatedAt = generatedAt
        self.data = data; self.errors = errors
        status = data == nil ? "error" : errors.isEmpty ? "available" : "partial"
    }
    enum CodingKeys: String, CodingKey { case schemaVersion, command, generatedAt, status, data, errors }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(command, forKey: .command)
        try c.encode(generatedAt, forKey: .generatedAt); try c.encode(status, forKey: .status)
        try c.encode(data, forKey: .data); try c.encode(errors, forKey: .errors)
    }
}
